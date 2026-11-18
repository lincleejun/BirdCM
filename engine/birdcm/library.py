"""The life list (docs/design-lifelist.md §3, §7): sightings DERIVED from the current scans, single photos, imported
records and the person's edits into a rebuildable index (ll_evidence) in the engine's own database. Never a copy of
the photo history: photo / single rows stay where they are, ll_evidence holds facts only (no names, no rarity, no
result JSON) and can be dropped and rebuilt at any time with the same result.

Counting (§3): one observation = one species x one local calendar day (the camera's wall-clock date) x one place
bucket (p:<floor(lat*100)>:<floor(lon*100)> | r:<ISO code> | none); a photo is its file's SHA-256, so the same bytes
in two scans, a scan and a single, or an import count once; a 300-frame burst of one bird is one observation; the
estimate is the largest per-photo count (sum of that photo's subjects of the species), never a sum over photos; a
group edit overrides it. The person's correction outranks the model; names, IUCN and rarity are read-time labels.

Writes: every commit goes through Store._write (one writer). A rebuild reads its sources in one read transaction,
hashes files outside any transaction, then swaps the whole index and bumps `generation` in one write; a source change
made meanwhile leaves `dirty` set, so the next refresh rebuilds again.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import threading
import time
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from birdcm import config

DERIVATION_VERSION = "1"
PENDING = ("genus", "uncertain", "unclassified", "unresolved", "needs_match")
THREATENED = ("VU", "EN", "CR")
MAX_COUNT = 999998
ZONE: timezone | None = None      # the zone a missing capture date's identification time is read in; None = this Mac's
TIERS = {0: "无记录", 1: "罕见", 2: "少见", 3: "不常见", 4: "常见"}

# §5 core tables, exactly (shared with the portable archive and iOS). The engine keeps imported records in them.
CORE_DDL = """
CREATE TABLE ll_asset(
 hash TEXT PRIMARY KEY CHECK(length(hash)=64), byte_count INTEGER NOT NULL,
 mime TEXT NOT NULL, relative_path TEXT, width INTEGER, height INTEGER,
 shooting_json TEXT NOT NULL, missing INTEGER NOT NULL DEFAULT 0 CHECK(missing IN(0,1))
);
CREATE TABLE ll_record(
 id TEXT PRIMARY KEY, asset_hash TEXT NOT NULL REFERENCES ll_asset(hash),
 canonical INTEGER NOT NULL CHECK(canonical IN(0,1)),
 first_identified_utc TEXT NOT NULL, identified_utc TEXT NOT NULL, updated_utc TEXT NOT NULL,
 deleted_utc TEXT, origin TEXT NOT NULL, legacy_json TEXT,
 capture_wall TEXT, capture_offset_min INTEGER, capture_utc TEXT,
 date_precision TEXT NOT NULL CHECK(date_precision IN('second','day')),
 fallback_wall TEXT NOT NULL, fallback_offset_min INTEGER NOT NULL,
 date_source TEXT NOT NULL CHECK(date_source IN('photo','identified','identified_legacy_zone','user')),
 local_day TEXT NOT NULL, date_edit_json TEXT,
 lat REAL, lon REAL, place_label TEXT, place_source TEXT NOT NULL,
 region_code TEXT, place_edit_json TEXT,
 payload_json TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
 CHECK((lat IS NULL AND lon IS NULL) OR
       (lat BETWEEN -90 AND 90 AND lon BETWEEN -180 AND 180))
);
CREATE UNIQUE INDEX ll_one_photo ON ll_record(asset_hash) WHERE canonical=1;
CREATE INDEX ll_record_day ON ll_record(local_day,asset_hash) WHERE canonical=1 AND deleted_utc IS NULL;
CREATE TABLE ll_subject(
 id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES ll_record(id), ordinal INTEGER NOT NULL,
 x0 REAL NOT NULL,y0 REAL NOT NULL,x1 REAL NOT NULL,y1 REAL NOT NULL,
 crop_json TEXT, model_level TEXT NOT NULL, model_key TEXT, model_json TEXT,
 correction_state TEXT NOT NULL DEFAULT 'none'
   CHECK(correction_state IN('none','species','uncertain')),
 corrected_key TEXT, corrected_utc TEXT,
 count_edit INTEGER CHECK(count_edit BETWEEN 1 AND 999998),
 excluded INTEGER NOT NULL DEFAULT 0 CHECK(excluded IN(0,1)),
 retired INTEGER NOT NULL DEFAULT 0 CHECK(retired IN(0,1)),
 needs_match INTEGER NOT NULL DEFAULT 0 CHECK(needs_match IN(0,1)),
 updated_utc TEXT NOT NULL,
 CHECK(0<=x0 AND x0<x1 AND x1<=1 AND 0<=y0 AND y0<y1 AND y1<=1),
 CHECK((correction_state='species' AND corrected_key IS NOT NULL) OR
       (correction_state!='species' AND corrected_key IS NULL))
);
CREATE UNIQUE INDEX ll_subject_ordinal ON ll_subject(record_id,ordinal) WHERE retired=0;
CREATE INDEX ll_subject_record ON ll_subject(record_id);
CREATE INDEX ll_subject_species ON ll_subject(model_key,corrected_key) WHERE retired=0 AND excluded=0;
CREATE TABLE ll_group_edit(
 group_key TEXT PRIMARY KEY, count_edit INTEGER NOT NULL CHECK(count_edit BETWEEN 1 AND 999998),
 updated_utc TEXT NOT NULL
);
CREATE TABLE ll_legacy_issue(
 filename TEXT PRIMARY KEY, raw_json BLOB, photo_path TEXT, error TEXT NOT NULL
);
"""

# §7: the derived index and the desktop's own edits.
ENGINE_DDL = """
CREATE TABLE ll_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE ll_hash(
 path TEXT NOT NULL,size INTEGER NOT NULL,mtime_ns INTEGER NOT NULL,
 hash TEXT NOT NULL, first_identified_utc TEXT NOT NULL,
 fallback_wall TEXT NOT NULL,fallback_offset_min INTEGER NOT NULL,
 PRIMARY KEY(path,size,mtime_ns)
);
CREATE INDEX ll_hash_digest ON ll_hash(hash);
CREATE TABLE ll_evidence(
 source_kind TEXT NOT NULL CHECK(source_kind IN('photo','single','import')),
 source_id TEXT NOT NULL, subject_id TEXT NOT NULL, asset_hash TEXT NOT NULL,
 species_key TEXT, level TEXT NOT NULL, provenance TEXT NOT NULL,
 local_day TEXT NOT NULL, capture_wall TEXT, capture_offset_min INTEGER,
 date_source TEXT NOT NULL, identified_utc TEXT NOT NULL,
 lat REAL,lon REAL,region_code TEXT,place_label TEXT,place_source TEXT NOT NULL,
 place_key TEXT NOT NULL, count_estimate INTEGER NOT NULL,
 box_json TEXT,crop_json TEXT,eligible INTEGER NOT NULL,updated_utc TEXT NOT NULL,
 PRIMARY KEY(source_kind,source_id,subject_id)
);
CREATE INDEX ll_evidence_group ON ll_evidence(eligible,species_key,local_day,place_key);
CREATE INDEX ll_evidence_asset ON ll_evidence(asset_hash);
CREATE TABLE ll_subject_edit(
 asset_hash TEXT NOT NULL,subject_id TEXT NOT NULL,edit_json TEXT NOT NULL,
 updated_utc TEXT NOT NULL,PRIMARY KEY(asset_hash,subject_id)
);
""" + CORE_DDL

EV_COLS = ("source_kind", "source_id", "subject_id", "asset_hash", "species_key", "level", "provenance", "local_day",
           "capture_wall", "capture_offset_min", "date_source", "identified_utc", "lat", "lon", "region_code",
           "place_label", "place_source", "place_key", "count_estimate", "box_json", "crop_json", "eligible", "updated_utc")


def if_not_exists(ddl: str) -> str:
    return re.sub(r"CREATE (UNIQUE )?(TABLE|INDEX) ", lambda m: f"CREATE {m.group(1) or ''}{m.group(2)} IF NOT EXISTS ", ddl)


def init(db) -> bool:
    """Additive library schema in the engine database (user_version 0 -> 1). A newer version is left alone (False)."""
    v = db.execute("PRAGMA user_version").fetchone()[0]
    if v > 1:
        return False
    db.executescript(if_not_exists(ENGINE_DDL))
    for k, val in (("derivation_version", DERIVATION_VERSION), ("generation", "0"), ("dirty", "1"), ("mutations", "0"),
                   ("library_id", str(uuid.uuid4()))):
        db.execute("INSERT OR IGNORE INTO ll_meta VALUES (?, ?)", (k, val))
    if db.execute("SELECT value FROM ll_meta WHERE key='derivation_version'").fetchone()[0] != DERIVATION_VERSION:
        db.execute("UPDATE ll_meta SET value = ? WHERE key = 'derivation_version'", (DERIVATION_VERSION,))
        db.execute("UPDATE ll_meta SET value = '1' WHERE key = 'dirty'")
    if v == 0:
        db.execute("PRAGMA user_version=1")
    return True


def touch(db) -> None:
    """A source changed (inside its own transaction): the index is stale until the next rebuild."""
    db.execute("UPDATE ll_meta SET value = '1' WHERE key = 'dirty'")
    db.execute("UPDATE ll_meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'mutations'")


def meta(db, key: str) -> str | None:
    r = db.execute("SELECT value FROM ll_meta WHERE key = ?", (key,)).fetchone()
    return r[0] if r else None


# ---- the shared definitions (iOS computes the same: docs/fixtures/lifelist/README.md) ----------------------------

def place_key(lat, lon, region_code=None) -> str:
    """p:<floor(lat*100)>:<floor(lon*100)> for a point (+180 -> -180, +90 -> the last cell 8999), r:<ISO> for a
    chosen region, none otherwise."""
    if lat is not None and lon is not None:
        lon = -180.0 if lon == 180 else float(lon)
        return f"p:{min(math.floor(float(lat) * 100), 8999)}:{math.floor(lon * 100)}"
    return f"r:{region_code}" if region_code else "none"


def group_key(sci: str, day: str, pkey: str) -> str:
    return json.dumps(["obs-v1", sci, day, pkey], separators=(",", ":"), ensure_ascii=False)


def stable_uuid(text: str) -> str:
    """First 16 bytes of SHA-256(text), version nibble 5 and RFC 4122 variant, lowercase hyphenated."""
    b = bytearray(hashlib.sha256(text.encode("utf-8")).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(b)))


def box_text(box) -> str:
    return ",".join(f"{float(v):.6f}" for v in box)


def subject_uuid(asset_hash: str, box) -> str:
    return stable_uuid(f"desktop subject/{asset_hash}/{box_text(box)}")


def record_uuid(asset_hash: str) -> str:
    return stable_uuid(f"desktop native record/{asset_hash}")


_WALL = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$")


def parse_wall(text) -> tuple[str, int | None, str, str] | None:
    """A capture time as the camera wrote it -> (wall "YYYY-MM-DDTHH:MM:SS" | "YYYY-MM-DD", offset minutes | None,
    local_day, precision second | day). The day is the wall clock's own date: never converted to UTC or to this Mac's
    zone. Invalid dates (2026-02-30, month 13, offset beyond ±14 h) -> None."""
    m = _WALL.match(text.strip()) if isinstance(text, str) else None
    if not m:
        return None
    y, mo, d, hh, mi, ss, off = m.groups()
    try:
        day = date(int(y), int(mo), int(d)).isoformat()
    except ValueError:
        return None
    if hh is None:
        return day, None, day, "day"
    if int(hh) > 23 or int(mi) > 59 or int(ss or 0) > 59:
        return None
    offset = None
    if off:
        if off == "Z":
            offset = 0
        else:
            o = off.replace(":", "")
            offset = (1 if o[0] == "+" else -1) * (int(o[1:3]) * 60 + int(o[3:5]))
            if abs(offset) > 840:
                return None
    return f"{day}T{hh}:{mi}:{ss or '00'}", offset, day, "second"


def utc_text(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(ts * 1000) % 1000:03d}Z"


def utc_of(wall: str | None, offset: int | None) -> str | None:
    if not wall or offset is None or len(wall) < 19:
        return None
    t = datetime.fromisoformat(wall).replace(tzinfo=timezone(timedelta(minutes=offset)))
    return utc_text(t.timestamp())


def fallback_of(ts: float) -> tuple[str, int]:
    """Identification time -> (wall clock, offset minutes) in ZONE (default: this Mac's zone at that instant)."""
    t = datetime.fromtimestamp(ts, ZONE) if ZONE else datetime.fromtimestamp(ts).astimezone()
    return t.strftime("%Y-%m-%dT%H:%M:%S"), int(t.utcoffset().total_seconds() // 60)


def epoch(utc: str | None) -> float:
    try:
        return datetime.fromisoformat((utc or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def valid_box(b) -> bool:
    return (isinstance(b, (list, tuple)) and len(b) == 4 and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in b)
            and 0 <= b[0] < b[2] <= 1 and 0 <= b[1] < b[3] <= 1)


def file_hash(path: str, size: int, mtime_ns: int) -> str | None:
    """SHA-256 of the whole file, streamed in 1 MiB reads; None when the file is gone or changed (before / after)."""
    import os
    try:
        with open(path, "rb") as f:
            st = os.fstat(f.fileno())
            if st.st_size != size or st.st_mtime_ns != mtime_ns:
                return None
            h = hashlib.sha256()
            while chunk := f.read(1 << 20):
                h.update(chunk)
            st2 = os.fstat(f.fileno())
        if (st2.st_size, st2.st_mtime_ns) != (size, mtime_ns):
            return None
        return h.hexdigest()
    except OSError:
        return None


def unresolved_key(path: str, size: int, mtime_ns: int) -> str:
    """A namespaced stand-in for a file that cannot be read now (unmounted volume, deleted): never a content digest."""
    return hashlib.sha256(f"unresolved desktop photo/{path}|{size}|{mtime_ns}".encode()).hexdigest()


# ---- edits (wire format §7.1, shared with iOS) --------------------------------------------------------------------

def check_edit(edit: dict, catalogue: dict) -> dict:
    """Validate one operation; returns it normalised. ValueError with a message for the person."""
    if not isinstance(edit, dict) or edit.get("op") not in ("species", "count", "exclude", "date", "place"):
        raise ValueError("edit.op 只能是 species / count / exclude / date / place")
    op = edit["op"]
    if op == "species":
        st, key = edit.get("state"), edit.get("key")
        if st not in ("species", "uncertain", "none"):
            raise ValueError("state 只能是 species / uncertain / none")
        if st == "species" and (not isinstance(key, str) or (catalogue and key not in catalogue)):
            raise ValueError(f"名录里没有这个学名：{key}")
        if st != "species" and key is not None:
            raise ValueError("不确定 / 恢复自动识别时 key 要是 null")
        return {"op": op, "state": st, "key": key}
    v = edit.get("value")
    if op == "count":
        if v is not None and not (isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= MAX_COUNT):
            raise ValueError("数量只能是 1–999998 的整数，或 null 恢复自动")
    elif op == "exclude":
        if not isinstance(v, bool):
            raise ValueError("exclude 的 value 要是 true / false")
    elif op == "date" and v is not None:
        if not isinstance(v, dict) or not isinstance(v.get("wall"), str) or not parse_wall(v["wall"]) \
                or not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?", v["wall"]):
            raise ValueError("日期要是 YYYY-MM-DD 或 YYYY-MM-DDTHH:mm:ss")
        off = v.get("offset_min")
        if off is not None and not (isinstance(off, int) and not isinstance(off, bool) and -840 <= off <= 840):
            raise ValueError("时区偏移要在 −840 到 +840 分钟之间")
        v = {"wall": v["wall"], "offset_min": off}
    elif op == "place" and v is not None:
        from birdcm import geo
        if not isinstance(v, dict) or v.get("source") not in ("photo", "map", "device", "region", "none"):
            raise ValueError("地点来源只能是 photo / map / device / region / none")
        lat, lon, code, label = v.get("lat"), v.get("lon"), v.get("region_code"), v.get("label", "")
        if not isinstance(label, str) or len(label) > 200:
            raise ValueError("地点名称要是文字")
        if v["source"] in ("map", "device"):
            if not geo.valid(lat, lon) or code is not None:
                raise ValueError("地图 / 定位的地点要有合法经纬度")
        elif v["source"] == "region":
            if lat is not None or lon is not None or not (isinstance(code, str) and re.fullmatch(r"[A-Z]{2}(-[A-Z0-9]{1,3})?", code)):
                raise ValueError("地区要有 ISO 3166 代码，且不带坐标")
        elif lat is not None or lon is not None or code is not None:
            raise ValueError("照片位置 / 无地点不带坐标和代码")
        v = {"source": v["source"], "lat": lat, "lon": lon, "label": label, "region_code": code}
    return {"op": op, "value": v}


def apply_edit(current: dict | None, edit: dict, original_box) -> dict | None:
    """ll_subject_edit.edit_json after one operation: {species, count, exclude, date, place, original_box, needs_match};
    a reset removes its field; nothing left -> None (the row is removed)."""
    cur = dict(current or {})
    field = edit["op"]
    # species "none" stays stored: 恢复自动识别 must also outrank an older correction made in the scan view
    if field != "species" and (edit.get("value") is None or edit.get("value") is False):
        cur.pop(field, None)
    else:
        cur[field] = edit
    if not any(k in cur for k in ("species", "count", "exclude", "date", "place")):
        return None
    if original_box:
        cur["original_box"] = list(original_box)
    cur.setdefault("original_box", None)
    cur.setdefault("needs_match", False)
    return cur


def write_subject_edit(db, asset_hash: str, subject_id: str, edit: dict, original_box) -> None:
    """One validated operation into ll_subject_edit (inside the caller's Store._write); the index becomes dirty."""
    r = db.execute("SELECT edit_json FROM ll_subject_edit WHERE asset_hash = ? AND subject_id = ?", (asset_hash, subject_id)).fetchone()
    new = apply_edit(json.loads(r[0]) if r else None, edit, original_box)
    if new is None:
        db.execute("DELETE FROM ll_subject_edit WHERE asset_hash = ? AND subject_id = ?", (asset_hash, subject_id))
    else:
        db.execute("INSERT OR REPLACE INTO ll_subject_edit VALUES (?,?,?,?)",
                   (asset_hash, subject_id, json.dumps(new, ensure_ascii=False), utc_text(time.time())))
    touch(db)


def bump(db) -> int:
    gen = int(meta(db, "generation") or 0) + 1
    db.execute("UPDATE ll_meta SET value = ? WHERE key = 'generation'", (str(gen),))
    return gen


def write_group_edit(db, key: str, count: int | None) -> int:
    """本次观察数量: an override of the group's estimate (None removes it). Applied at read time: no rebuild, a new
    generation so every view refreshes."""
    if count is None:
        db.execute("DELETE FROM ll_group_edit WHERE group_key = ?", (key,))
    else:
        db.execute("INSERT OR REPLACE INTO ll_group_edit VALUES (?,?,?)", (key, count, utc_text(time.time())))
    return bump(db)


# ---- derivation ---------------------------------------------------------------------------------------------------

def _resolve(model: dict | None, clear, human: dict | None, known) -> tuple[str, str | None, str]:
    """(level, key, provenance) of one subject: the person's newest word, else the model (§3.2)."""
    if human and human["state"] == "species":
        return ("species" if known(human["key"]) else "unresolved"), human["key"], "manual"
    if human and human["state"] == "uncertain":
        return "uncertain", None, "manual"
    if not model:
        return "unclassified", None, "model"
    prov = "burst" if model.get("consensus") else "model"
    key = (model.get("label") or {}).get("sci")
    if clear is False:
        return "unclear", key, prov                 # the clear-bird gate said no: neither counted nor pending
    if model.get("level") == "species" and key:
        return ("species" if known(key) else "unresolved"), key, prov
    if model.get("level") == "genus":
        return "genus", key, prov
    return "uncertain", None, prov


def _newest(*xs):
    have = [x for x in xs if x]
    return max(have, key=lambda x: x["_t"]) if have else None


class Library:
    """One per Store. rebuild() is the only writer of ll_evidence; reads are memoised per generation."""

    def __init__(self, store, singles_dir: Path | None = None, imports_dir: Path | None = None) -> None:
        self.store = store
        self.singles_dir = Path(singles_dir or config.data_dir() / "singles")
        self.imports_dir = Path(imports_dir or config.data_dir() / "imports")
        self.lock = threading.Lock()
        self.thread: threading.Thread | None = None
        self.error: str | None = None
        self._memo: tuple | None = None

    # ---- refresh ----------------------------------------------------------------------------------------------

    def status(self) -> dict:
        db = self.store._db()
        running = bool(self.thread and self.thread.is_alive())
        return {"generation": int(meta(db, "generation") or 0), "updating": running or meta(db, "dirty") == "1",
                "error": self.error}

    def refresh(self, wait: bool = False) -> dict:
        """Dirty -> rebuild in the background (wait=True: here). Returns the status the reader is looking at."""
        if meta(self.store._db(), "dirty") == "1":
            if wait:
                self.rebuild()
            elif not (self.thread and self.thread.is_alive()):
                self.thread = threading.Thread(target=self._bg, daemon=True)
                self.thread.start()
        return self.status()

    def _bg(self) -> None:
        try:
            self.rebuild()
            self.error = None
        except Exception as e:  # noqa: BLE001 - reported in status; the last complete generation stays readable
            import traceback
            traceback.print_exc()
            self.error = f"{type(e).__name__}: {e}"[:300]

    def rebuild(self) -> int:
        with self.lock:
            src = self._read()
            hashes, new_rows = self._hashes(src)
            rows = self._derive(src, hashes)

            def swap(db):
                gen = bump(db)
                db.executemany("INSERT OR IGNORE INTO ll_hash VALUES (?,?,?,?,?,?,?)", new_rows)
                db.execute("DELETE FROM ll_evidence")
                db.executemany(f"INSERT INTO ll_evidence ({','.join(EV_COLS)}) VALUES ({','.join('?' * len(EV_COLS))})",
                               [tuple(r[c] for c in EV_COLS) for r in rows])
                if meta(db, "mutations") == src["mutations"]:          # nothing changed since the read
                    db.execute("UPDATE ll_meta SET value = '0' WHERE key = 'dirty'")
                return gen
            return self.store._write(swap)

    def _read(self) -> dict:
        """Every source, from one read transaction."""
        db = self.store._db()
        db.execute("BEGIN")
        try:
            out = {"mutations": meta(db, "mutations")}
            scans = [dict(r) for r in db.execute("SELECT id, folder, recursive, region, state, created_at FROM scan ORDER BY id")]
            chosen = {}
            for s in scans:                                        # highest completed scan per (folder, recursive)
                if s["state"] == "completed":
                    chosen[(s["folder"], s["recursive"])] = s
            out["scans"] = {s["id"]: s for s in chosen.values()}
            ids = list(out["scans"])
            out["photos"] = [dict(r) for r in db.execute(
                f"SELECT id, scan_id, path, size, mtime_ns, result, species_fix FROM photo WHERE state = 'done' AND result IS NOT NULL "
                f"AND scan_id IN ({','.join('?' * len(ids))}) ORDER BY id", ids)] if ids else []
            out["first_seen"] = {(r[0], r[1], r[2]): r[3] for r in db.execute(
                "SELECT p.path, p.size, p.mtime_ns, min(s.created_at) FROM photo p JOIN scan s ON s.id = p.scan_id "
                "WHERE p.state = 'done' GROUP BY p.path, p.size, p.mtime_ns")}
            out["corrections"] = {(r[0], r[1], r[2]): {"sci": r[3], "_t": r[4]} for r in db.execute(
                "SELECT path, size, mtime_ns, species, created_at FROM correction")}
            out["singles"] = [dict(r) for r in db.execute("SELECT * FROM single WHERE result IS NOT NULL ORDER BY id")]
            out["hash"] = {(r[0], r[1], r[2]): dict(r) for r in db.execute("SELECT * FROM ll_hash")}
            out["records"] = [dict(r) for r in db.execute(
                "SELECT r.*, a.missing, a.relative_path FROM ll_record r JOIN ll_asset a ON a.hash = r.asset_hash "
                "WHERE r.canonical = 1 AND r.deleted_utc IS NULL ORDER BY r.id")]
            subj = defaultdict(list)
            for r in db.execute("SELECT * FROM ll_subject WHERE retired = 0 ORDER BY record_id, ordinal"):
                subj[r["record_id"]].append(dict(r))
            out["subjects"] = subj
            out["edits"] = {(r[0], r[1]): {**json.loads(r[2]), "_t": epoch(r[3])} for r in db.execute(
                "SELECT asset_hash, subject_id, edit_json, updated_utc FROM ll_subject_edit")}
            return out
        finally:
            db.execute("COMMIT")

    def _hashes(self, src: dict) -> tuple[dict, list]:
        """(path, size, mtime) -> {hash, first_identified_utc, fallback_wall, fallback_offset_min, missing}, and the
        new ll_hash rows. Files are read here, outside every transaction; a file that cannot be read keeps its cached
        digest, or gets a namespaced unresolved key (not stored, retried next time)."""
        import os
        sigs: dict[tuple, float] = {}
        for p in src["photos"]:
            k = (p["path"], p["size"], p["mtime_ns"])
            sigs[k] = src["first_seen"].get(k) or src["scans"][p["scan_id"]]["created_at"]
        for s in src["singles"]:
            path = str(self.singles_dir / s["stored"])
            try:
                st = os.stat(path)
                k = (path, st.st_size, st.st_mtime_ns)
            except OSError:
                k = (path, -1, -1)
            s["_sig"] = k
            sigs[k] = min(sigs.get(k, s["created_at"]), s["created_at"])
        by_hash: dict[str, dict] = {}
        for r in src["hash"].values():
            if r["hash"] not in by_hash or r["first_identified_utc"] < by_hash[r["hash"]]["first_identified_utc"]:
                by_hash[r["hash"]] = r
        out, new = {}, []
        for k, ts in sorted(sigs.items(), key=lambda kv: kv[1]):        # earliest identification first
            if k in src["hash"]:
                out[k] = {**src["hash"][k], "missing": not os.path.exists(k[0])}
                continue
            digest = file_hash(*k) if k[1] >= 0 else None
            if digest is None:
                wall, off = fallback_of(ts)
                out[k] = {"hash": unresolved_key(*k), "first_identified_utc": utc_text(ts), "fallback_wall": wall,
                          "fallback_offset_min": off, "missing": True}
                continue
            first = by_hash.get(digest)
            if first is None:
                wall, off = fallback_of(ts)
                first = by_hash[digest] = {"hash": digest, "first_identified_utc": utc_text(ts), "fallback_wall": wall,
                                           "fallback_offset_min": off}
            row = {"path": k[0], "size": k[1], "mtime_ns": k[2], "hash": digest, "first_identified_utc": first["first_identified_utc"],
                   "fallback_wall": first["fallback_wall"], "fallback_offset_min": first["fallback_offset_min"]}
            new.append(tuple(row[c] for c in ("path", "size", "mtime_ns", "hash", "first_identified_utc", "fallback_wall", "fallback_offset_min")))
            out[k] = {**row, "missing": False}
        return out, new

    def _derive(self, src: dict, hashes: dict) -> list[dict]:
        from birdcm import names, rarity
        cat = names.catalogue()
        known = (lambda k: k in cat) if cat else (lambda k: bool(k))
        snaps: dict[str, list] = defaultdict(list)
        for p in src["photos"]:
            k = (p["path"], p["size"], p["mtime_ns"])
            h = hashes[k]
            res = json.loads(p["result"])
            fix = json.loads(p["species_fix"]) if p["species_fix"] else None
            cor = src["corrections"].get(k)
            legacy = {"state": "species" if cor["sci"] else "uncertain", "key": cor["sci"], "_t": cor["_t"]} if cor else None
            scan = src["scans"][p["scan_id"]]
            snaps[h["hash"]].append({"kind": "photo", "id": p["id"], "ts": scan["created_at"], "rank": 1 if legacy else 0,
                                     "h": h, "res": res, "fix": fix if fix and not fix.get("manual") else None,
                                     "legacy": legacy, "location": _location(scan["region"]), "subject": res.get("subject")})
        for s in src["singles"]:
            h = hashes[s["_sig"]]
            res = json.loads(s["result"])
            c = json.loads(s["correction"]) if s.get("correction") else None
            legacy = {"state": "species" if c.get("sci") else "uncertain", "key": c.get("sci"), "_t": s["created_at"]} if c else None
            snaps[h["hash"]].append({"kind": "single", "id": s["id"], "ts": s["created_at"], "rank": 2 if legacy else 0,
                                     "h": h, "res": res, "fix": None, "legacy": legacy, "location": _location(s["region"]),
                                     "subject": s["subject"] if s["subject"] is not None else res.get("subject")})
        for r in src["records"]:
            subs = src["subjects"].get(r["id"], [])
            edited = any(x["correction_state"] != "none" or x["count_edit"] or x["excluded"] for x in subs)
            snaps[r["asset_hash"]].append({"kind": "import", "id": r["id"], "ts": epoch(r["identified_utc"]), "rank": 3 if edited else 0,
                                           "record": r, "subjects": subs})
        rows = []
        now = utc_text(time.time())
        for digest, cands in snaps.items():
            # one snapshot per photo: explicit edits (import > single > scan), else the newest result; ties kind, id
            kind_order = {"photo": 0, "single": 1, "import": 2}
            c = sorted(cands, key=lambda x: (-x["rank"], -x["ts"], kind_order[x["kind"]], str(x["id"])))[0]
            photo_edit = src["edits"].get((digest, "photo")) or {}
            rows += (self._import_rows if c["kind"] == "import" else self._native_rows)(digest, c, photo_edit, src["edits"], known, now)
        return rows

    def _facts(self, digest, when, where, photo_edit, ident_utc, now) -> dict:
        """Date and place of one logical photo (the photo-wide edit carrier wins)."""
        d = photo_edit.get("date", {}).get("value") if photo_edit.get("date") else None
        if d:
            wall, off, day, _ = parse_wall(d["wall"])
            off = d.get("offset_min")
            dsrc = "user"
        else:
            wall, off, day, dsrc = when
        p = photo_edit.get("place", {}).get("value") if photo_edit.get("place") else None
        if p and p["source"] != "photo":
            lat, lon, code, label, psrc = p["lat"], p["lon"], p["region_code"], p["label"], p["source"]
        else:
            lat, lon, code, label, psrc = where
        return {"asset_hash": digest, "local_day": day, "capture_wall": wall if dsrc in ("photo", "user") else None,
                "capture_offset_min": off if dsrc in ("photo", "user") else None, "date_source": dsrc, "identified_utc": ident_utc,
                "lat": lat, "lon": lon, "region_code": code if lat is None else None, "place_label": label,
                "place_source": psrc, "place_key": place_key(lat, lon, code), "updated_utc": now}

    def _native_rows(self, digest, c, photo_edit, edits, known, now) -> list[dict]:
        from birdcm import geo, rarity
        res, h = c["res"], c["h"]
        exif = res.get("exif") or {}
        pw = parse_wall(exif.get("taken_at"))
        if pw:
            when = (pw[0], pw[1], pw[2], "photo")
        else:
            when = (h["fallback_wall"], h["fallback_offset_min"], h["fallback_wall"][:10], "identified")
        gps = exif.get("gps")
        loc = c["location"]
        if gps and len(gps) == 2 and geo.valid(gps[0], gps[1]):
            where = (float(gps[0]), float(gps[1]), None, None, "photo")
        elif loc and loc[0] == "point":
            where = (loc[1], loc[2], None, loc[3], loc[4])
        elif loc and loc[0] == "region":
            where = (None, None, loc[1], loc[2], "region")
        else:
            where = (None, None, None, loc[2] if loc else None, "none")
        base = {"source_kind": c["kind"], "source_id": str(c["id"]),
                **self._facts(digest, when, where, photo_edit, h["first_identified_utc"], now)}
        out = [{**base, "subject_id": "photo", "species_key": None, "level": "photo", "provenance": "photo",
                "count_estimate": 0, "box_json": None, "crop_json": None, "eligible": 0}]
        boxes = list(res.get("boxes") or [])
        subj = c["subject"]
        if subj is None and boxes:                               # rejected photo: the box its species came from
            subj = next((i for i, b in enumerate(boxes) if b.get("species") == res.get("species")), 0)
        if not boxes and c["legacy"] and c["legacy"]["state"] == "species":
            boxes, subj = [{"box": [0.0, 0.0, 1.0, 1.0], "species": None, "clear": True}], 0      # the person says: a bird
        for i, b in enumerate(boxes):
            if not valid_box(b.get("box")):
                continue                                         # ponytail: an invalid box is skipped, not repaired
            sid = subject_uuid(digest, b["box"])
            e = edits.get((digest, sid)) or {}
            human_edit = dict(e["species"], _t=e["_t"]) if e.get("species") else None
            model = b.get("species")
            if i == subj:
                model = c["fix"] or model or res.get("species")
                human = _newest(human_edit, c["legacy"])
            else:
                human = human_edit
            if human and human["state"] == "none":
                human = None
            level, key, prov = _resolve(model, b.get("clear"), human, known)
            if e.get("exclude"):
                level = "excluded"
            cnt = (e.get("count") or {}).get("value") or 1
            out.append({**base, "subject_id": sid, "species_key": key, "level": level, "provenance": prov,
                        "count_estimate": cnt, "box_json": json.dumps(b["box"]), "crop_json": None,
                        "eligible": int(level == "species")})
        return out

    def _import_rows(self, digest, c, photo_edit, edits, known, now) -> list[dict]:
        r = c["record"]
        when = ((r["capture_wall"] if r["date_source"] in ("photo", "user") else r["fallback_wall"]), r["capture_offset_min"]
                if r["date_source"] in ("photo", "user") else r["fallback_offset_min"], r["local_day"], r["date_source"])
        where = (r["lat"], r["lon"], r["region_code"], r["place_label"], r["place_source"])
        base = {"source_kind": "import", "source_id": r["id"], **self._facts(digest, when, where, photo_edit, r["first_identified_utc"], now)}
        if when[3] not in ("photo", "user"):
            base["capture_wall"] = base["capture_offset_min"] = None
        out = [{**base, "subject_id": "photo", "species_key": None, "level": "photo", "provenance": "photo",
                "count_estimate": 0, "box_json": None, "crop_json": None, "eligible": 0}]
        for s in c["subjects"]:
            e = edits.get((digest, s["id"])) or {}
            human = dict(e["species"], _t=e["_t"]) if e.get("species") else None
            if human is None and s["correction_state"] != "none":
                human = {"state": s["correction_state"], "key": s["corrected_key"], "_t": epoch(s["corrected_utc"])}
            if human and human["state"] == "none":
                human = None
            ml = s["model_level"]
            model = {"level": ml, "label": {"sci": s["model_key"]} if s["model_key"] else None} if ml != "unclassified" else None
            if ml == "unresolved":
                model = {"level": "species", "label": {"sci": s["model_key"]}} if s["model_key"] else None
            level, key, prov = _resolve(model, None, human, known)
            if ml == "unresolved" and not human:
                level = "unresolved"
            if s["needs_match"]:
                level = "needs_match"
            if e.get("exclude") or (s["excluded"] and not ("exclude" in e)):
                level = "excluded"
            cnt = (e.get("count") or {}).get("value") or s["count_edit"] or 1
            out.append({**base, "subject_id": s["id"], "species_key": key, "level": level, "provenance": prov,
                        "count_estimate": cnt, "box_json": json.dumps([s["x0"], s["y0"], s["x1"], s["y1"]]),
                        "crop_json": s["crop_json"], "eligible": int(level == "species")})
        return out

    # ---- reads ------------------------------------------------------------------------------------------------

    def index(self) -> "Index":
        db = self.store._db()
        db.execute("BEGIN")
        try:
            gen = int(meta(db, "generation") or 0)
            if self._memo and self._memo[0] == gen:
                return self._memo[1]
            rows = [dict(r) for r in db.execute(f"SELECT {','.join(EV_COLS)} FROM ll_evidence ORDER BY asset_hash, subject_id")]
            gedits = {r[0]: r[1] for r in db.execute("SELECT group_key, count_edit FROM ll_group_edit")}
        finally:
            db.execute("COMMIT")
        ix = Index(gen, rows, gedits)
        self._memo = (gen, ix)
        return ix


def _location(v):
    """A scan's / single's chosen place -> ("point", lat, lon, label, source) | ("region", ISO, label) | None-ish."""
    from birdcm import geo, rarity
    from birdcm.store import location
    v = location(v)
    if isinstance(v, dict):
        if v.get("source") == "region":
            code = v.get("code") or rarity.label_iso(v.get("label"))
            return ("region", code, v.get("label")) if code else ("none", None, v.get("label"))
        if geo.valid(v.get("lat"), v.get("lon")):
            return ("point", float(v["lat"]), float(v["lon"]), v.get("label"), v.get("source") if v.get("source") in ("map", "device") else "map")
        v = v.get("label")
    if isinstance(v, str) and v:
        code = rarity.label_iso(v)
        return ("region", code, v) if code else ("none", None, v)
    return None


def ref(r: dict) -> dict:
    """source_ref on the wire (§7.1), plus the thumbnail URL the page uses."""
    k, i = r["source_kind"], r["source_id"]
    thumb = {"photo": f"/api/photos/{i}/thumb", "single": f"/api/singles/{i}/image?size=thumb",
             "import": f"/api/library/import-records/{i}/image?size=thumb"}[k]
    return {"kind": k, "id": str(i), "subject_id": r["subject_id"], "asset_hash": r["asset_hash"], "thumb": thumb}


class Index:
    """One generation's evidence, grouped (§3): groups by group_key with per-photo sums, first day per species."""

    def __init__(self, generation: int, rows: list[dict], group_edits: dict[str, int]) -> None:
        self.generation, self.rows, self.group_edits = generation, rows, group_edits
        self.by_hash: dict[str, list[dict]] = defaultdict(list)
        for r in rows:
            self.by_hash[r["asset_hash"]].append(r)
        self.groups: dict[str, dict] = {}
        for r in rows:
            if not r["eligible"]:
                continue
            k = group_key(r["species_key"], r["local_day"], r["place_key"])
            g = self.groups.setdefault(k, {"key": k, "sci": r["species_key"], "day": r["local_day"], "place_key": r["place_key"],
                                           "frames": defaultdict(int), "rows": []})
            g["frames"][r["asset_hash"]] += r["count_estimate"]
            g["rows"].append(r)
        self.first_day: dict[str, str] = {}
        for g in self.groups.values():
            g["max"] = max(g["frames"].values())
            g["estimate"] = group_edits.get(g["key"], g["max"])
            g["estimate_source"] = "edit" if g["key"] in group_edits else "max"
            if g["sci"] not in self.first_day or g["day"] < self.first_day[g["sci"]]:
                self.first_day[g["sci"]] = g["day"]
        self._ctx: dict[str, list] = {}

    @staticmethod
    def within(day: str, frm: str | None, to: str | None) -> bool:
        return (not frm or day >= frm) and (not to or day <= to)

    def groups_in(self, frm=None, to=None, sci=None, day=None) -> list[dict]:
        return [g for g in self.groups.values() if self.within(g["day"], frm, to)
                and (sci is None or g["sci"] == sci) and (day is None or g["day"] == day)]

    def contexts(self, g: dict) -> list[dict]:
        """Rarity at each supporting photo's own place and month (read time, the installed table): distinct contexts."""
        if g["key"] in self._ctx:
            return self._ctx[g["key"]]
        from birdcm import rarity
        t = rarity.table()
        month = int(g["day"][5:7])
        seen, out = set(), []
        for r in g["rows"]:
            if t is None or (r["lat"] is None and not r["region_code"]):
                x = {"region": r["region_code"], "tier": None, "label": "数据不足" if t else "不可用", "note": None}
            else:
                y = _lookup(t, g["sci"], r["lat"], r["lon"], r["region_code"], month)
                x = {"region": y["region"], "tier": y["tier"], "label": y["label"], "note": y.get("note")}
            k = (x["region"], x["tier"], x["label"])
            if k not in seen:
                seen.add(k)
                out.append(x)
        self._ctx[g["key"]] = out
        return out

    def rare(self, g: dict) -> bool:
        return any(c["tier"] in (1, 2) for c in self.contexts(g))

    def bucket(self, g: dict) -> str:
        known = [c["tier"] for c in self.contexts(g) if c["tier"] is not None]
        return TIERS[min(known)] if known else "不可用"

    # ---- the views (§7.1) ---------------------------------------------------------------------------------------

    def rows_in(self, frm=None, to=None) -> list[dict]:
        return [r for r in self.rows if self.within(r["local_day"], frm, to)]

    def summary(self, frm=None, to=None) -> dict:
        gs = self.groups_in(frm, to)
        rows = self.rows_in(frm, to)
        photos = {r["asset_hash"] for r in rows}
        birds = {r["asset_hash"] for r in rows if r["level"] != "photo"}
        pend = [r for r in rows if r["level"] in PENDING]
        carriers = [r for r in rows if r["level"] == "photo"]
        buckets = defaultdict(int)
        for g in gs:
            buckets[self.bucket(g)] += 1
        sp = {g["sci"] for g in gs}
        return {"metrics": {
            "species": len(sp), "observations": len(gs), "estimated_count": sum(g["estimate"] for g in gs),
            "photos": len(photos), "pending_subjects": len(pend), "pending_photos": len({r["asset_hash"] for r in pend}),
            "no_bird_photos": len(photos - birds), "active_days": len({g["day"] for g in gs}),
            "new_species": sum(1 for s, d in self.first_day.items() if self.within(d, frm, to)),
            "rare_observations": sum(1 for g in gs if self.rare(g)),
            "threatened_species": sum(1 for s in sp if (iucn_of(s) or "") in THREATENED)},
            "coverage": {"fallback_date_photos": sum(1 for r in carriers if r["date_source"].startswith("identified")),
                         "no_place_photos": sum(1 for r in carriers if r["place_key"] == "none"),
                         "region_only_photos": sum(1 for r in carriers if r["place_key"].startswith("r:"))},
            "rarity_buckets": {k: buckets.get(k, 0) for k in ("罕见", "少见", "不常见", "常见", "无记录", "不可用")},
            "species_keys": sorted(sp)}

    def species_rows(self, frm=None, to=None) -> dict[str, dict]:
        """sci -> scoped counts and its newest cover (latest day, wall time, hash, subject)."""
        out: dict[str, dict] = {}
        for g in self.groups_in(frm, to):
            e = out.setdefault(g["sci"], {"key": g["sci"], "observations": 0, "estimated_count": 0, "photos": set(),
                                          "first_day": g["day"], "last_day": g["day"], "cover": None, "rare": False, "buckets": set()})
            e["observations"] += 1
            e["estimated_count"] += g["estimate"]
            e["photos"].update(g["frames"])
            e["first_day"], e["last_day"] = min(e["first_day"], g["day"]), max(e["last_day"], g["day"])
            e["buckets"].add(self.bucket(g))
            for r in g["rows"]:
                k = (r["local_day"], r["capture_wall"] or "", r["asset_hash"], r["subject_id"])
                if e["cover"] is None or k > e["cover"][0]:
                    e["cover"] = (k, r)
        return out

    def observations(self, frm=None, to=None, sci=None, day=None, rare=None) -> list[dict]:
        out = []
        for g in sorted(self.groups_in(frm, to, sci, day), key=lambda g: (g["day"], g["key"]), reverse=True):
            if rare is not None and self.rare(g) != rare:
                continue
            r0 = g["rows"][0]
            pts = sorted({(r["lat"], r["lon"]) for r in g["rows"] if r["lat"] is not None})
            out.append({"key": g["key"], "sci": g["sci"], **names_of(g["sci"]), "day": g["day"], "place_key": g["place_key"],
                        "place": {"label": place_text(r0), "source": r0["place_source"], "region_code": r0["region_code"],
                                  "points": [list(p) for p in pts[:20]]},
                        "estimate": g["estimate"], "estimate_source": g["estimate_source"], "max_in_photo": g["max"],
                        "photo_count": len(g["frames"]), "contexts": self.contexts(g), "rare": self.rare(g),
                        "first_seen": self.first_day.get(g["sci"]) == g["day"],
                        "fallback_date": any(r["date_source"].startswith("identified") for r in g["rows"]),
                        "source_refs": [ref(r) for r in sorted(g["rows"], key=lambda r: (r["capture_wall"] or "", r["asset_hash"], r["subject_id"]))[:6]]})
        return out

    def calendar(self, year: int) -> dict:
        """Photo-first calendar (owner, 2026-11-18): per day and per month the observation and species counts and
        one cover bird (cover_of), so the page shows that day's bird instead of a colour level."""
        days: dict[str, list] = defaultdict(list)
        for g in self.groups.values():
            if g["day"][:4] == f"{year:04d}":
                days[g["day"]].append(g)

        def cell(gs):
            c = cover_of([r for g in gs for r in g["rows"]])
            return {"observations": len(gs), "species": len({g["sci"] for g in gs}),
                    "cover": {**ref(c), "crop": crop_url(c), "sci": c["species_key"],
                              **names_of(c["species_key"])}}
        months = []
        for m in range(1, 13):
            gs = [g for d, x in days.items() if int(d[5:7]) == m for g in x]
            months.append({"month": m, **(cell(gs) if gs else {"observations": 0, "species": 0, "cover": None})})
        return {"year": year, "days": {d: cell(gs) for d, gs in sorted(days.items())}, "months": months, "active_days": len(days),
                "years": sorted({g["day"][:4] for g in self.groups.values()})}

    def map(self, s: float, w: float, n: float, e: float, frm=None, to=None, sci=None) -> dict:
        """Viewport clusters of photo points (distinct groups per cell, at most 500), plus region-only and no-place
        observation totals. A bounds box crossing the antimeridian has w > e."""
        cell = max(n - s, (e - w) % 360 or 360) / 16
        cells: dict[tuple, dict] = {}
        regions, none = defaultdict(set), set()
        for g in self.groups_in(frm, to, sci):
            for r in g["rows"]:
                if r["lat"] is None:
                    (regions[r["region_code"]] if r["region_code"] else none).add(g["key"])
                    continue
                inside = s <= r["lat"] <= n and ((w <= r["lon"] <= e) if w <= e else (r["lon"] >= w or r["lon"] <= e))
                if not inside:
                    continue
                k = (math.floor(r["lat"] / cell), math.floor(r["lon"] / cell))
                c = cells.setdefault(k, {"groups": set(), "lat": 0.0, "lon": 0.0, "n": 0, "refs": []})
                c["groups"].add(g["key"])
                c["lat"] += r["lat"]
                c["lon"] += r["lon"]
                c["n"] += 1
                if len(c["refs"]) < 3:
                    c["refs"].append({**ref(r), "day": g["day"], "sci": g["sci"]})
        top = sorted(cells.values(), key=lambda c: (-len(c["groups"]), c["lat"], c["lon"]))[:500]
        return {"clusters": [{"lat": round(c["lat"] / c["n"], 5), "lon": round(c["lon"] / c["n"], 5), "observations": len(c["groups"]),
                              "refs": c["refs"]} for c in top],
                "truncated": len(cells) > 500,
                "regions": [{"code": k, "observations": len(v)} for k, v in sorted(regions.items())],
                "no_place_observations": len(none)}


REASON = {"genus": "只认到属", "uncertain": "不确定", "unclassified": "还没识别的框", "unresolved": "名录里没有这个学名",
          "needs_match": "需核对主体对应"}


def _fold(s: str | None) -> str:
    import unicodedata
    s = unicodedata.normalize("NFKD", unicodedata.normalize("NFKC", s or "")).casefold()
    return "".join(c for c in s if not unicodedata.combining(c)).strip()


def species_list(ix: Index, frm=None, to=None, q="", seen="yes", rarity="all", iucn="all", family="", sort="recent",
                 offset=0, limit=50) -> dict:
    """seen=yes: the species seen in the range; seen=no / all: catalogue mode (all-time seen state, no period totals)."""
    from birdcm import names
    scoped = ix.species_rows(frm, to)
    if seen == "yes":
        keys = list(scoped)
    else:
        cat = set(names.catalogue()) | set(ix.first_day)
        keys = [k for k in cat if seen == "all" or k not in ix.first_day]
    fq = _fold(q)
    items = []
    for k in keys:
        nm = names_of(k)
        if fq and not any(fq in _fold(x) for x in (k, nm["en"], nm["zh"])):
            continue
        if family and nm["family"] != family:
            continue
        if iucn == "threatened" and (iucn_of(k) or "") not in THREATENED:
            continue
        e = scoped.get(k)
        if rarity != "all" and not (e and TIERS.get(int(rarity)) in e["buckets"]):
            continue
        items.append({"key": k, **nm, "iucn": iucn_of(k), "seen": k in ix.first_day, "first_day": ix.first_day.get(k),
                      "last_day": e["last_day"] if e else None, "observations": e["observations"] if e else 0,
                      "estimated_count": e["estimated_count"] if e else 0, "photos": len(e["photos"]) if e else 0,
                      "cover_ref": ref(e["cover"][1]) if e and e["cover"] else None})
    rank = (lambda x: (0 if _fold(x["key"]) == fq or _fold(x["zh"]) == fq or _fold(x["en"]) == fq else 1, x["key"])) if fq else None
    if sort == "first":
        items.sort(key=lambda x: (x["first_day"] or "9999", x["key"]))
    elif sort == "name":
        items.sort(key=rank or (lambda x: x["key"]))
    else:
        items.sort(key=lambda x: x["key"])
        items.sort(key=lambda x: x["last_day"] or "", reverse=True)
    return {"total": len(items), "items": items[offset:offset + limit]}


def species_detail(ix: Index, sci: str, frm=None, to=None) -> dict:
    gs = ix.groups_in(frm, to, sci)
    every = ix.groups_in(sci=sci)
    months = [0] * 12
    places: dict[str, dict] = {}
    photos: dict[str, dict] = {}
    for g in gs:
        months[int(g["day"][5:7]) - 1] += 1
        r0 = g["rows"][0]
        p = places.setdefault(g["place_key"], {"place_key": g["place_key"], "label": place_text(r0), "source": r0["place_source"],
                                               "region_code": r0["region_code"], "observations": 0})
        p["observations"] += 1
        for r in g["rows"]:
            k = (r["local_day"], r["capture_wall"] or "", r["asset_hash"], r["subject_id"])
            if r["asset_hash"] not in photos or k > photos[r["asset_hash"]]["_k"]:
                photos[r["asset_hash"]] = {"_k": k, **ref(r), "day": r["local_day"]}
    plist = sorted(photos.values(), key=lambda x: x["_k"], reverse=True)
    return {"key": sci, **names_of(sci), "iucn": iucn_of(sci), "seen": sci in ix.first_day,
            "first_day": min((g["day"] for g in every), default=None), "last_day": max((g["day"] for g in every), default=None),
            "scope": {"observations": len(gs), "estimated_count": sum(g["estimate"] for g in gs), "photos": len(photos)},
            "months": months, "places": sorted(places.values(), key=lambda p: (-p["observations"], p["label"] or "", p["place_key"])),
            "photo_refs": [{k: v for k, v in p.items() if k != "_k"} for p in plist[:50]], "total_photos": len(plist)}


def photo_list(ix: Index, sci=None, day=None, status="all", frm=None, to=None, offset=0, limit=50) -> dict:
    """status all: one item per photo (the subject naming sci when given); pending: one per unresolved subject;
    no-bird: photos with no bird box."""
    out = []
    for h, rows in ix.by_hash.items():
        c = rows[0]
        if not ix.within(c["local_day"], frm, to) or (day and c["local_day"] != day):
            continue
        subs = [r for r in rows if r["level"] != "photo"]
        if status == "pending":
            out += [{**ref(r), "day": r["local_day"], "level": r["level"], "reason": REASON.get(r["level"], r["level"]),
                     "species_key": r["species_key"], "_k": (r["local_day"], r["capture_wall"] or "", h, r["subject_id"])}
                    for r in subs if r["level"] in PENDING and (sci is None or r["species_key"] == sci)]
            continue
        if status == "no-bird" and subs:
            continue
        if sci is not None:
            subs = [r for r in subs if r["eligible"] and r["species_key"] == sci]
            if not subs:
                continue
        best = next((r for r in subs if r["eligible"]), subs[0] if subs else next(r for r in rows if r["level"] == "photo"))
        out.append({**ref(best), "day": c["local_day"], "level": best["level"], "species_key": best["species_key"],
                    "subjects": len(subs), "date_source": c["date_source"], "place_label": c["place_label"],
                    "_k": (c["local_day"], c["capture_wall"] or "", h, best["subject_id"])})
    out.sort(key=lambda x: x["_k"], reverse=True)
    return {"total": len(out), "items": [{k: v for k, v in x.items() if k != "_k"} for x in out[offset:offset + limit]]}


def names_of(sci: str) -> dict:
    """Read-time names: Chinese from the current table, English (and family) from the installed name list."""
    from birdcm import names
    c = names.catalogue().get(sci) or {}
    zh = c.get("zh") if c else names.zh().get(sci)
    return {"zh": zh, "en": c.get("en"), "family": c.get("family"), "genus": sci.split(" ")[0]}


def iucn_of(sci: str) -> str | None:
    from birdcm import rarity
    t = rarity.table()
    return t.iucn(sci) if t is not None else None


_lookup_cache: dict = {}


def _lookup(t, sci, lat, lon, code, month) -> dict:
    k = (id(t), sci, lat, lon, code, month)
    if k not in _lookup_cache:
        if len(_lookup_cache) > 100_000:
            _lookup_cache.clear()
        _lookup_cache[k] = t.lookup(sci, lat, lon, None, month, code=code if lat is None else None)
    return _lookup_cache[k]


_libs: dict[int, Library] = {}
_libs_lock = threading.Lock()


def of(store, **kw) -> Library:
    with _libs_lock:
        lib = _libs.get(id(store))
        if lib is None or lib.store is not store:
            lib = _libs[id(store)] = Library(store, **kw)
        return lib


def place_text(r: dict) -> str | None:
    """A row's place for people: its own label, else the region the point is in (the one point -> region mapping)
    with the point, else the region code."""
    if r["place_label"]:
        return r["place_label"]
    from birdcm import rarity
    if r["lat"] is not None:
        div, country = rarity.place_region(r["lat"], r["lon"])
        name = rarity.iso_label(div) or rarity.iso_label(country) or (rarity.region_names(div or country) or (None, None))[1]
        return f"{name + ' ' if name else ''}{r['lat']:.3f}, {r['lon']:.3f}"
    return r["region_code"]


def cover_of(rows: list[dict]) -> dict:
    """The cover bird of a day / month (shared rule, iOS too): among eligible subjects the latest by local wall time,
    then photo hash, then subject id (all compared as strings, missing wall time = "")."""
    return max((r for r in rows if r["eligible"]), key=lambda r: (r["capture_wall"] or "", r["asset_hash"], r["subject_id"]))


CROP = 240           # px, square bird crop for calendar cells (cached next to the thumbnails)


def crop_file(preview, box, out) -> None:
    """A square crop around a normalised box (35 % margin, at least 12 % of the frame) from the cached preview."""
    from PIL import Image
    with Image.open(preview) as im:
        w, h = im.size
        x0, y0, x1, y1 = box
        side = max((x1 - x0) * w, (y1 - y0) * h) * 1.35
        side = min(max(side, 0.12 * max(w, h)), min(w, h))
        cx, cy = (x0 + x1) / 2 * w, (y0 + y1) / 2 * h
        left = min(max(0, cx - side / 2), w - side)
        top = min(max(0, cy - side / 2), h - side)
        c = im.convert("RGB").crop((int(left), int(top), int(left + side), int(top + side))).resize((CROP, CROP), Image.Resampling.LANCZOS)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".part")
        c.save(tmp, "JPEG", quality=85)
        tmp.replace(out)


def crop_url(r: dict) -> str:
    from urllib.parse import urlencode
    return "/api/library/crop?" + urlencode({"kind": r["source_kind"], "id": r["source_id"], "subject_id": r["subject_id"],
                                             "asset_hash": r["asset_hash"]})
