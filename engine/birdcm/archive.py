"""The portable `.birdcm` file (docs/design-lifelist.md §8): a SQLite archive with the §5 tables, archive_meta and one
original per photo in archive_blob. The same file iOS writes and reads; docs/fixtures/lifelist/README.md fixes the
details both sides must agree on.

Export builds a new archive from one read of the current life list (never a copy of the live database). Import is a
trust boundary: the file is staged on disk, opened read-only, its objects and columns checked against the whitelist,
every original's SHA-256 and size verified with bounded reads, and only then merged in one write.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import sqlite3
import threading
import time
import uuid
from pathlib import Path

from birdcm import library

APPLICATION_ID = 1112101441
MIME = "application/vnd.birdcm.archive"
ARCHIVE_DDL = library.CORE_DDL + """
CREATE TABLE archive_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE archive_blob(
 hash TEXT PRIMARY KEY REFERENCES ll_asset(hash), original BLOB NOT NULL
);
"""
META_KEYS = ("format", "version", "archive_id", "library_id", "created_utc", "producer", "taxonomy", "scope",
             "record_count", "asset_count", "subject_count")
CHUNK = 1 << 20
TOKEN_TTL = 30 * 60
MAX_ARCHIVE = 64 << 30
DROP_KEYS = {"path", "stored", "thumb", "preview", "folder"}
MIME_OF = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".heic": "image/heic", ".arw": "image/x-sony-arw",
           ".dng": "image/x-adobe-dng"}
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _shape() -> tuple[dict[str, list[str]], set[str]]:
    """Expected tables -> columns, and allowed index names, from our own DDL (never from the file)."""
    db = sqlite3.connect(":memory:")
    db.executescript(ARCHIVE_DDL)
    tables = {n: [c[1] for c in db.execute(f"PRAGMA table_info({n})")] for (n,) in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    idx = {n for (n,) in db.execute("SELECT name FROM sqlite_master WHERE type='index'")}
    db.close()
    return tables, idx


SHAPE, INDEXES = _shape()


def strip(v):
    """A payload without path authority: keys naming paths dropped, recursively."""
    if isinstance(v, dict):
        return {k: strip(x) for k, x in v.items() if k not in DROP_KEYS and not k.endswith("_path")}
    if isinstance(v, list):
        return [strip(x) for x in v]
    return v


def _copy_blob(db, rowid: int, src: Path, digest: str, size: int) -> bool:
    """Stream a file into the archive blob; False (blob left for the caller to drop) when the bytes are not `digest`."""
    h = hashlib.sha256()
    n = 0
    with open(src, "rb") as f, db.blobopen("archive_blob", "original", rowid) as b:
        while chunk := f.read(CHUNK):
            n += len(chunk)
            if n > size:
                return False
            h.update(chunk)
            b.write(chunk)
    return n == size and h.hexdigest() == digest


# ---- export -------------------------------------------------------------------------------------------------------

def export(lib: "library.Library", out: Path, frm: str | None = None, to: str | None = None) -> dict:
    """Write the archive to `out` (a new file); returns its meta. scope=selection when a range is given."""
    lib.refresh(wait=True)
    store = lib.store
    ix = lib.index()
    db = store._db()
    db.execute("BEGIN")
    try:
        hashes = {r["hash"]: dict(r) for r in db.execute("SELECT hash, min(first_identified_utc) AS first_identified_utc, "
                                                          "fallback_wall, fallback_offset_min FROM ll_hash GROUP BY hash")}
        edits = {(r[0], r[1]): json.loads(r[2]) for r in db.execute("SELECT asset_hash, subject_id, edit_json FROM ll_subject_edit")}
        gedits = [tuple(r) for r in db.execute("SELECT group_key, count_edit, updated_utc FROM ll_group_edit")]
        imp_rec = {r["id"]: dict(r) for r in db.execute("SELECT * FROM ll_record")}
        imp_sub = {r["id"]: dict(r) for r in db.execute("SELECT * FROM ll_subject")}
        imp_asset = {r["hash"]: dict(r) for r in db.execute("SELECT * FROM ll_asset")}
        issues = [dict(r) for r in db.execute("SELECT * FROM ll_legacy_issue")]
        library_id = library.meta(db, "library_id")
        photos = {}
        for h, rows in ix.by_hash.items():
            c = rows[0]
            if c["source_kind"] == "photo":
                photos[h] = dict(db.execute("SELECT p.path, p.size, p.mtime_ns, p.result, s.created_at FROM photo p JOIN scan s "
                                            "ON s.id = p.scan_id WHERE p.id = ?", (int(c["source_id"]),)).fetchone())
            elif c["source_kind"] == "single":
                r = db.execute("SELECT stored, result, created_at FROM single WHERE id = ?", (int(c["source_id"]),)).fetchone()
                photos[h] = {"path": str(lib.singles_dir / r["stored"]), "result": r["result"], "created_at": r["created_at"]}
    finally:
        db.execute("COMMIT")
    out = Path(out)
    out.unlink(missing_ok=True)
    a = sqlite3.connect(out, isolation_level=None)
    try:
        a.execute(f"PRAGMA application_id={APPLICATION_ID}")
        a.execute("PRAGMA user_version=1")
        a.execute("PRAGMA journal_mode=DELETE")
        a.executescript(ARCHIVE_DDL)
        a.execute("BEGIN")
        now = library.utc_text(time.time())
        n_rec = n_sub = 0
        for h, rows in sorted(ix.by_hash.items()):
            c = rows[0]
            if not ix.within(c["local_day"], frm, to):
                continue
            subs = [r for r in rows if r["level"] != "photo"]
            pe = edits.get((h, "photo")) or {}
            if c["source_kind"] == "import":
                rec = dict(imp_rec[c["source_id"]])
                asset = dict(imp_asset[h])
                src = lib.imports_dir / asset["relative_path"] if asset.get("relative_path") else None
                model = {s["id"]: s for s in imp_sub.values() if s["record_id"] == rec["id"]}
            else:
                p = photos[h]
                res = json.loads(p["result"]) if p["result"] else {}
                src = Path(p["path"])
                fb = hashes.get(h) or {}
                ident = library.utc_text(p["created_at"])
                if not fb:
                    wall, off = library.fallback_of(p["created_at"])
                    fb = {"first_identified_utc": ident, "fallback_wall": wall, "fallback_offset_min": off}
                wall = c["capture_wall"]
                asset = {"hash": h, "byte_count": 0, "mime": MIME_OF.get(src.suffix.lower(), "application/octet-stream"),
                         "relative_path": None, "width": res.get("width"), "height": res.get("height"),
                         "shooting_json": json.dumps(strip(res.get("exif") or {}), ensure_ascii=False), "missing": 1}
                rec = {"id": library.record_uuid(h), "asset_hash": h, "canonical": 1, "first_identified_utc": fb["first_identified_utc"],
                       "identified_utc": ident, "updated_utc": now, "deleted_utc": None, "origin": "desktop", "legacy_json": None,
                       "capture_wall": wall, "capture_offset_min": c["capture_offset_min"],
                       "capture_utc": library.utc_of(wall, c["capture_offset_min"]),
                       "date_precision": "day" if wall and len(wall) == 10 else "second",
                       "fallback_wall": fb["fallback_wall"], "fallback_offset_min": fb["fallback_offset_min"],
                       "date_source": c["date_source"], "local_day": c["local_day"],
                       "date_edit_json": json.dumps(pe["date"]["value"]) if pe.get("date") else None,
                       "lat": c["lat"], "lon": c["lon"], "place_label": c["place_label"], "place_source": c["place_source"],
                       "region_code": c["region_code"], "place_edit_json": json.dumps(pe["place"]["value"], ensure_ascii=False) if pe.get("place") else None,
                       "payload_json": json.dumps(strip({"source": c["source_kind"], "file": src.name, "result": res}), ensure_ascii=False),
                       "revision": 1}
                model = {}
                for i, b in enumerate(res.get("boxes") or []):
                    if library.valid_box(b.get("box")):
                        model[library.subject_uuid(h, b["box"])] = {"ordinal": i, "box": b["box"], "species": b.get("species")}
            # the original, once per photo, verified while it is copied
            a.execute("INSERT INTO ll_asset VALUES (:hash,:byte_count,:mime,:relative_path,:width,:height,:shooting_json,:missing)",
                      {**asset, "relative_path": None, "missing": 1, "byte_count": asset.get("byte_count") or 0})
            if src is not None and src.is_file() and HEX64.match(h):
                size = src.stat().st_size
                rowid = a.execute("INSERT INTO archive_blob VALUES (?, zeroblob(?))", (h, size)).lastrowid
                if _copy_blob(a, rowid, src, h, size):
                    a.execute("UPDATE ll_asset SET missing = 0, byte_count = ? WHERE hash = ?", (size, h))
                else:
                    a.execute("DELETE FROM archive_blob WHERE hash = ?", (h,))
            if c["source_kind"] == "import" and pe.get("date"):          # the desktop's own photo-wide edits
                rec.update(capture_wall=c["capture_wall"], capture_offset_min=c["capture_offset_min"], date_source="user",
                           capture_utc=library.utc_of(c["capture_wall"], c["capture_offset_min"]), local_day=c["local_day"],
                           date_edit_json=json.dumps(pe["date"]["value"]))
            if c["source_kind"] == "import" and pe.get("place"):
                rec.update(lat=c["lat"], lon=c["lon"], region_code=c["region_code"], place_label=c["place_label"],
                           place_source=c["place_source"], place_edit_json=json.dumps(pe["place"]["value"], ensure_ascii=False))
            a.execute("INSERT INTO ll_record VALUES (:id,:asset_hash,:canonical,:first_identified_utc,:identified_utc,:updated_utc,"
                      ":deleted_utc,:origin,:legacy_json,:capture_wall,:capture_offset_min,:capture_utc,:date_precision,:fallback_wall,"
                      ":fallback_offset_min,:date_source,:local_day,:date_edit_json,:lat,:lon,:place_label,:place_source,:region_code,"
                      ":place_edit_json,:payload_json,:revision)", rec)
            n_rec += 1
            used = set()
            for r in sorted(subs, key=lambda r: r["subject_id"]):
                m = model.get(r["subject_id"]) or {}
                box = json.loads(r["box_json"])
                if c["source_kind"] == "import":
                    mlevel, mkey, mjson, ordinal = m.get("model_level", "unclassified"), m.get("model_key"), m.get("model_json"), m.get("ordinal", 0)
                else:
                    sp = m.get("species")
                    mlevel = (sp or {}).get("level") or "unclassified"
                    mlevel = mlevel if mlevel in ("species", "genus", "uncertain") else "unclassified"
                    mkey = ((sp or {}).get("label") or {}).get("sci") if mlevel in ("species", "genus") else None
                    mjson, ordinal = json.dumps(strip(sp), ensure_ascii=False) if sp else None, m.get("ordinal", 0)
                while ordinal in used:
                    ordinal += 1
                used.add(ordinal)
                manual = r["provenance"] == "manual"
                state = ("species" if r["species_key"] and r["level"] in ("species", "unresolved", "excluded") else "uncertain") if manual else "none"
                a.execute(f"INSERT INTO ll_subject VALUES ({','.join('?' * 19)})",
                          (r["subject_id"], rec["id"], ordinal, *box, r["crop_json"], mlevel, mkey, mjson, state,
                           r["species_key"] if state == "species" else None, now if manual else None,
                           r["count_estimate"] if r["count_estimate"] != 1 else None, int(r["level"] == "excluded"), 0,
                           int(r["level"] == "needs_match"), now))
                n_sub += 1
        for k, cnt, t in gedits:
            day = json.loads(k)[2]
            if ix.within(day, frm, to):
                a.execute("INSERT INTO ll_group_edit VALUES (?,?,?)", (k, cnt, t))
        if frm is None and to is None:
            for i in issues:
                a.execute("INSERT INTO ll_legacy_issue VALUES (?,?,?,?)", (i["filename"], i["raw_json"],
                                                                           Path(i["photo_path"]).name if i["photo_path"] else None, i["error"]))
        from birdcm import models
        meta = {"format": "birdcm-archive", "version": "1", "archive_id": str(uuid.uuid4()), "library_id": library_id,
                "created_utc": now, "producer": "desktop", "taxonomy": "avilist-2026",
                "scope": "full" if frm is None and to is None else "selection", "record_count": str(n_rec),
                "asset_count": str(a.execute("SELECT count(*) FROM ll_asset").fetchone()[0]), "subject_count": str(n_sub),
                "resource_versions": json.dumps({e["role"]: e["sha256"] for e in models.manifest()["file"]
                                                 if e["role"] in ("names", "rarity", "rarity-global") and models.locate(e)})}
        a.executemany("INSERT INTO archive_meta VALUES (?,?)", list(meta.items()))
        a.execute("COMMIT")
    except BaseException:
        a.close()
        out.unlink(missing_ok=True)
        raise
    a.close()
    validate(out)                                                   # reopen and check what we wrote
    return meta


# ---- import -------------------------------------------------------------------------------------------------------

def open_ro(path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA trusted_schema=OFF")
    return con


def validate(path: Path) -> dict:
    """Everything an archive must be before anything of it is used; ValueError says what is wrong."""
    try:
        con = open_ro(path)
        con.execute("SELECT count(*) FROM sqlite_master").fetchone()
    except sqlite3.DatabaseError:
        raise ValueError("不是观羽的备份文件（打不开）") from None
    try:
        if con.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
            raise ValueError("不是观羽的备份文件")
        if con.execute("PRAGMA user_version").fetchone()[0] != 1:
            raise ValueError("备份文件的格式版本不认识（可能是更新版本的观羽写的）")
        objs = [(r[0], r[1]) for r in con.execute("SELECT type, name FROM sqlite_master")]
        tables = {n for t, n in objs if t == "table"}
        if tables != set(SHAPE):
            raise ValueError("备份文件的表不对")
        for t, n in objs:
            if t not in ("table", "index") or (t == "index" and n not in INDEXES and not n.startswith("sqlite_autoindex_")):
                raise ValueError(f"备份文件里有不认识的对象：{t} {n}")
        for n, cols in SHAPE.items():
            if [c[1] for c in con.execute(f"PRAGMA table_info({n})")] != cols:
                raise ValueError(f"备份文件的 {n} 列不对")
        if con.execute("PRAGMA integrity_check").fetchone()[0] != "ok" or con.execute("PRAGMA foreign_key_check").fetchone():
            raise ValueError("备份文件已损坏")
        meta = {r[0]: r[1] for r in con.execute("SELECT key, value FROM archive_meta")}
        if any(k not in meta for k in META_KEYS) or meta["format"] != "birdcm-archive" or meta["version"] != "1":
            raise ValueError("备份文件缺少必要信息或版本不对")
        assets = {r["hash"]: dict(r) for r in con.execute("SELECT * FROM ll_asset")}
        blobs = {r[0]: r[1] for r in con.execute("SELECT hash, length(original) FROM archive_blob")}
        for h, a in assets.items():
            if not HEX64.match(h) or a["missing"] not in (0, 1):
                raise ValueError("备份文件里的照片编号不对")
            if a["missing"] == 1 and h in blobs:
                raise ValueError("标为缺失的照片不能带原图")
            if a["missing"] == 0 and (h not in blobs or blobs[h] != a["byte_count"]):
                raise ValueError("备份文件里的原图和记录不一致")
            if a["missing"] == 0:
                rowid = con.execute("SELECT rowid FROM archive_blob WHERE hash = ?", (h,)).fetchone()[0]
                d = hashlib.sha256()
                with con.blobopen("archive_blob", "original", rowid, readonly=True) as b:
                    while chunk := b.read(CHUNK):
                        d.update(chunk)
                if d.hexdigest() != h:
                    raise ValueError("备份文件里有原图和它的校验值对不上")
            json.loads(a["shooting_json"])
        canon = set()
        rec_ids = set()
        for r in con.execute("SELECT * FROM ll_record"):
            if not UUID_RE.match(r["id"]) or r["asset_hash"] not in assets:
                raise ValueError("备份文件里的记录编号不对")
            if r["date_source"] not in ("photo", "identified", "identified_legacy_zone", "user") or r["canonical"] not in (0, 1):
                raise ValueError("备份文件里的日期来源不对")
            p = library.parse_wall(r["local_day"])
            if not p or p[3] != "day" or (r["lat"] is None) != (r["lon"] is None):
                raise ValueError("备份文件里的日期或坐标不对")
            if r["place_source"] not in ("photo", "map", "device", "region", "none"):
                raise ValueError("备份文件里的地点来源不对")
            if r["canonical"] == 1:
                if r["asset_hash"] in canon:
                    raise ValueError("同一张照片有两条当前记录")
                canon.add(r["asset_hash"])
            json.loads(r["payload_json"])
            rec_ids.add(r["id"])
        n_sub = 0
        for s in con.execute("SELECT * FROM ll_subject"):
            n_sub += 1
            if s["record_id"] not in rec_ids or not library.valid_box([s["x0"], s["y0"], s["x1"], s["y1"]]):
                raise ValueError("备份文件里的框不对")
            if s["model_level"] not in ("unclassified", "species", "genus", "uncertain", "unresolved") \
                    or s["correction_state"] not in ("none", "species", "uncertain") \
                    or (s["correction_state"] == "species") != (s["corrected_key"] is not None):
                raise ValueError("备份文件里的鸟种状态不对")
            if s["count_edit"] is not None and not 1 <= s["count_edit"] <= library.MAX_COUNT:
                raise ValueError("备份文件里的数量不对")
        for g in con.execute("SELECT group_key, count_edit FROM ll_group_edit"):
            k = json.loads(g[0])
            if not (isinstance(k, list) and len(k) == 4 and k[0] == "obs-v1") or not 1 <= g[1] <= library.MAX_COUNT:
                raise ValueError("备份文件里的观察数量更正不对")
        if int(meta["record_count"]) != len(rec_ids) or int(meta["asset_count"]) != len(assets) or int(meta["subject_count"]) != n_sub:
            raise ValueError("备份文件的计数和内容不一致")
        return {"meta": meta, "records": len(rec_ids), "assets": len(assets), "subjects": n_sub,
                "blob_bytes": sum(blobs.values()), "missing_originals": sum(1 for a in assets.values() if a["missing"])}
    finally:
        con.close()


def _iou(a, b) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0])) * max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - ix
    return ix / u if u > 0 else 0.0


def plan(lib: "library.Library", path: Path) -> tuple[dict, list[dict], list[tuple]]:
    """(summary, conflicts, file edits to map onto local native photos) of merging this archive."""
    v = validate(path)
    lib.refresh(wait=True)
    ix = lib.index()
    db = lib.store._db()
    local_ids = {r[0] for r in db.execute("SELECT id FROM ll_record")}
    local_edits = {(r[0], r[1]): json.loads(r[2]) for r in db.execute("SELECT asset_hash, subject_id, edit_json FROM ll_subject_edit")}
    con = open_ro(path)
    try:
        recs = [dict(r) for r in con.execute("SELECT * FROM ll_record ORDER BY id")]
        subs = [dict(r) for r in con.execute("SELECT * FROM ll_subject ORDER BY record_id, ordinal")]
        sizes = {r[0]: r[1] for r in con.execute("SELECT hash, byte_count FROM ll_asset")}
    finally:
        con.close()
    new = [r for r in recs if r["id"] not in local_ids and r["asset_hash"] not in ix.by_hash and r["canonical"] == 1]
    known = [r for r in recs if r["id"] not in local_ids and r["asset_hash"] in ix.by_hash]
    conflicts, mapped = [], []
    by_rec = {}
    for s in subs:
        by_rec.setdefault(s["record_id"], []).append(s)
    for r in known:
        h = r["asset_hash"]
        local = [x for x in ix.by_hash[h] if x["level"] != "photo"]
        for s in by_rec.get(r["id"], []):
            fields = {}
            if s["correction_state"] != "none":
                fields["species"] = {"op": "species", "state": s["correction_state"], "key": s["corrected_key"]}
            if s["count_edit"]:
                fields["count"] = {"op": "count", "value": s["count_edit"]}
            if s["excluded"]:
                fields["exclude"] = {"op": "exclude", "value": True}
            if not fields:
                continue
            box = [s["x0"], s["y0"], s["x1"], s["y1"]]
            match = next((x for x in local if x["subject_id"] == s["id"]), None) or max(
                (x for x in local if _iou(json.loads(x["box_json"]), box) >= 0.5), key=lambda x: _iou(json.loads(x["box_json"]), box), default=None)
            if match is None:
                continue
            mine = local_edits.get((h, match["subject_id"])) or {}
            for f, e in fields.items():
                cid = f"{h}/{match['subject_id']}/{f}"
                if f in mine and {k: v for k, v in mine[f].items()} != e:
                    conflicts.append({"id": cid, "asset_hash": h, "field": f, "local": mine[f], "file": e})
                mapped.append((cid, h, match["subject_id"], e, json.loads(match["box_json"]), f in mine))
        for f, col in (("date", "date_edit_json"), ("place", "place_edit_json")):
            if r[col]:
                e = {"op": f, "value": json.loads(r[col])}
                mine = (local_edits.get((h, "photo")) or {}).get(f)
                cid = f"{h}/photo/{f}"
                if mine and mine != e:
                    conflicts.append({"id": cid, "asset_hash": h, "field": f, "local": mine, "file": e})
                mapped.append((cid, h, "photo", e, None, bool(mine)))
    pending = sum(1 for s in subs if s["correction_state"] == "uncertain" or (s["correction_state"] == "none" and s["model_level"] != "species"))
    summary = {**{k: v[k] for k in ("records", "assets", "subjects", "missing_originals")}, "scope": v["meta"]["scope"],
               "producer": v["meta"]["producer"], "archive_id": v["meta"]["archive_id"], "library_id": v["meta"]["library_id"],
               "created_utc": v["meta"]["created_utc"], "new_photos": len({r["asset_hash"] for r in new}),
               "identical_photos": len({r["asset_hash"] for r in known}),
               "already_imported": sum(1 for r in recs if r["id"] in local_ids), "pending_subjects": pending,
               "file_bytes": path.stat().st_size}
    summary["required_bytes"] = sum(sizes.get(r["asset_hash"], 0) for r in new)
    return summary, conflicts, mapped


def apply(lib: "library.Library", path: Path, choices: dict[str, str], restore: bool = False) -> dict:
    """Merge (or, restore=True, replace the managed library and every library edit first) in one write. Originals are
    copied into the import folder and verified before the transaction that references them."""
    summary, conflicts, mapped = plan(lib, path)
    store = lib.store
    lib.imports_dir.mkdir(parents=True, exist_ok=True)
    con = open_ro(path)
    made: list[Path] = []
    try:
        recs = [dict(r) for r in con.execute("SELECT * FROM ll_record ORDER BY id")]
        subs = [dict(r) for r in con.execute("SELECT * FROM ll_subject ORDER BY record_id, ordinal")]
        assets = {r["hash"]: dict(r) for r in con.execute("SELECT * FROM ll_asset")}
        gedits = [tuple(r) for r in con.execute("SELECT group_key, count_edit, updated_utc FROM ll_group_edit")]
        issues = [dict(r) for r in con.execute("SELECT * FROM ll_legacy_issue")]
        db = store._db()
        local_ids = set() if restore else {r[0] for r in db.execute("SELECT id FROM ll_record")}
        native = {h for h, rows in lib.index().by_hash.items() if rows[0]["source_kind"] != "import"}
        local_canon = set() if restore else {r[0] for r in db.execute("SELECT asset_hash FROM ll_record WHERE canonical = 1")}
        todo = [r for r in recs if r["id"] not in local_ids]
        for h in sorted({r["asset_hash"] for r in todo if r["asset_hash"] not in native}):
            a = assets[h]
            dest = lib.imports_dir / f"{h}.photo"
            if a["missing"] or dest.is_file():
                continue
            part = dest.with_suffix(".part")
            rowid = con.execute("SELECT rowid FROM archive_blob WHERE hash = ?", (h,)).fetchone()[0]
            d = hashlib.sha256()
            with con.blobopen("archive_blob", "original", rowid, readonly=True) as b, open(part, "wb") as f:
                while chunk := b.read(CHUNK):
                    d.update(chunk)
                    f.write(chunk)
                f.flush()
                os.fsync(f.fileno())
            if d.hexdigest() != h:
                part.unlink()
                raise ValueError("原图校验没通过，没有导入")
            part.rename(dest)
            made.append(dest)
    finally:
        con.close()
    pick = {c["id"]: choices.get(c["id"], "local") for c in conflicts}
    added = merged = 0

    def go(db):
        nonlocal added, merged
        if restore:
            for t in ("ll_subject", "ll_record", "ll_asset", "ll_legacy_issue", "ll_group_edit", "ll_subject_edit"):
                db.execute(f"DELETE FROM {t}")
        canon = set(local_canon)
        for r in todo:
            h = r["asset_hash"]
            a = assets[h]
            have_file = (lib.imports_dir / f"{h}.photo").is_file()
            db.execute("INSERT OR IGNORE INTO ll_asset VALUES (?,?,?,?,?,?,?,?)",
                       (h, a["byte_count"], a["mime"], f"{h}.photo" if have_file else None, a["width"], a["height"], a["shooting_json"],
                        0 if have_file else 1))
            alias = h in native or h in canon or r["canonical"] == 0          # same photo already here: provenance only
            db.execute(f"INSERT INTO ll_record VALUES ({','.join('?' * 26)})",
                       (r["id"], h, 0 if alias else 1, r["first_identified_utc"], r["identified_utc"], r["updated_utc"], r["deleted_utc"],
                        "import", r["legacy_json"], r["capture_wall"], r["capture_offset_min"], r["capture_utc"], r["date_precision"],
                        r["fallback_wall"], r["fallback_offset_min"], r["date_source"], r["local_day"], r["date_edit_json"],
                        r["lat"], r["lon"], r["place_label"], r["place_source"], r["region_code"], r["place_edit_json"],
                        r["payload_json"], r["revision"]))
            if alias:
                merged += 1
            else:
                canon.add(h)
                added += 1
            for s in subs:
                if s["record_id"] == r["id"]:
                    db.execute(f"INSERT OR IGNORE INTO ll_subject VALUES ({','.join('?' * 19)})", tuple(s.values()))
        for k, cnt, t in gedits:
            db.execute("INSERT OR IGNORE INTO ll_group_edit VALUES (?,?,?)", (k, cnt, t))
            if pick.get(f"group/{k}") == "file":
                db.execute("UPDATE ll_group_edit SET count_edit = ? WHERE group_key = ?", (cnt, k))
        for cid, h, sid, e, box, local_has in mapped:
            if local_has and pick.get(cid, "local") != "file":
                continue                                                  # the person's local edit is kept by default
            library.write_subject_edit(db, h, sid, e, box)
        for i in issues:
            db.execute("INSERT OR IGNORE INTO ll_legacy_issue VALUES (?,?,?,?)", (i["filename"], i["raw_json"], i["photo_path"], i["error"]))
        library.touch(db)
    try:
        store._write(go)
    except BaseException:
        for f in made:
            f.unlink(missing_ok=True)
        raise
    st = lib.refresh()
    return {"generation": st["generation"], "updating": True, "added_photos": added, "merged_photos": merged,
            "pending_conflicts": sum(1 for c in conflicts if pick[c["id"]] == "local")}


class Staging:
    """Uploaded archives on disk under the data dir, by a random token: preview, then one apply (30 minutes)."""

    def __init__(self, folder: Path) -> None:
        self.folder = Path(folder)
        self.lock = threading.Lock()
        self.items: dict[str, dict] = {}

    def add(self, path: Path, summary: dict, conflicts: list) -> dict:
        tok = secrets.token_urlsafe(18)
        exp = time.time() + TOKEN_TTL
        with self.lock:
            self._sweep()
            self.items[tok] = {"path": path, "expires": exp, "summary": summary, "conflicts": conflicts, "result": None}
        return {"token": tok, "expires_utc": library.utc_text(exp), "summary": summary, "conflicts": conflicts,
                "required_bytes": summary["required_bytes"]}

    def get(self, tok: str) -> dict | None:
        with self.lock:
            self._sweep()
            return self.items.get(tok)

    def _sweep(self) -> None:
        for k, v in list(self.items.items()):
            if v["expires"] < time.time():
                Path(v["path"]).unlink(missing_ok=True)
                del self.items[k]

    def new_path(self) -> Path:
        self.folder.mkdir(parents=True, exist_ok=True)
        return self.folder / f"{secrets.token_hex(12)}.birdcm"


def free_bytes(folder: Path) -> int:
    folder.mkdir(parents=True, exist_ok=True)
    return shutil.disk_usage(folder).free
