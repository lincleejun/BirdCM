"""Stars and species for Lightroom: an XMP sidecar <stem>.xmp next to each RAW, written only when the person asks,
merged into a sidecar that is already there, and undone from the record kept in our own database (store.py).

The original photo is never opened for writing. exiftool merges our fields into a copy of the sidecar in a temporary
directory outside the photo folder; the result is put in place with a temporary file in the same folder and
os.replace. Which fields and why: docs/deviations.md "XMP 边车".
"""
from __future__ import annotations

import contextlib
import hashlib
import os
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from birdcm.decode import safe_arg

SIDECAR_EXT = {".arw"}          # RAW only: Lightroom keeps JPEG / DNG metadata inside the file and reads no sidecar for them
RDF = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"
KEYWORD_TAGS = ("{http://purl.org/dc/elements/1.1/}subject", "{http://ns.adobe.com/lightroom/1.0/}hierarchicalSubject")

SKIP_FORMAT = "JPEG / DNG：元数据在文件里面，Lightroom 不读旁边的 .xmp，观羽不改原片"
SKIP_PENDING = "还没识别完"
SKIP_MISSING = "原片不在了"
SKIP_ODD = "旁边的 .xmp 不是普通文件（链接或文件夹），没动它"
SKIP_BAD = "旁边的 .xmp 读不了（不是有效的 XML），没动它"
SKIP_EMPTY = "没有星级也没有鸟种，不用写"


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def keywords(p: dict) -> list[str]:
    """The species as the result page names it (the person's correction first): Chinese, English, Latin; a genus as
    "<Genus> 属" and the Latin genus; nothing when uncertain."""
    from birdcm.ebird import _effective
    sp = _effective(p)
    if not sp:
        return []
    lab = sp["label"]
    if sp["level"] == "genus":
        g = lab["sci"].removesuffix(" sp.")
        return [f"{g} 属", g]
    return list(dict.fromkeys(x for x in (lab.get("zh"), lab.get("en"), lab["sci"]) if x))


def sidecar(photo: Path) -> Path:
    """<stem>.xmp in the photo's own folder; an existing one is matched whatever its case (IMG.XMP)."""
    want = (photo.stem + ".xmp").lower()
    with contextlib.suppress(OSError):
        for e in os.scandir(photo.parent):
            if e.name.lower() == want:
                return photo.parent / e.name
    return photo.parent / (photo.stem + ".xmp")


def existing_keywords(data: bytes) -> set[str]:
    root = ET.fromstring(data)
    return {li.text or "" for tag in KEYWORD_TAGS for el in root.iter(tag) for li in el.iter(RDF + "li")}


def plan(photos: list[dict]) -> tuple[list[dict], dict[str, int]]:
    """-> ([{photo, path, side, before (bytes | None), stars, keywords}], {skip reason: count}). Reads only."""
    todo, skipped = [], {}
    for p in photos:
        path = Path(p["path"])
        why = None
        if path.suffix.lower() not in SIDECAR_EXT:
            why = SKIP_FORMAT
        elif p.get("state") != "done":
            why = SKIP_PENDING
        elif not path.is_file():
            why = SKIP_MISSING
        if why is None:
            side = sidecar(path)
            kws, stars = keywords(p), p.get("stars")
            before = None
            # same folder, same stem: never anything else (a name from the database must not point elsewhere)
            if side.parent != path.parent or side.name.lower() != (path.stem + ".xmp").lower() or not safe_arg(str(side)):
                why = SKIP_ODD
            elif side.is_symlink() or (side.exists() and not side.is_file()):
                why = SKIP_ODD
            elif side.exists():
                before = side.read_bytes()
                try:
                    existing_keywords(before)
                except ET.ParseError:
                    why = SKIP_BAD
            if why is None and stars is None and not kws:
                why = SKIP_EMPTY
        if why:
            skipped[why] = skipped.get(why, 0) + 1
        else:
            todo.append({"photo": p["id"], "path": path, "side": side, "before": before, "stars": stars, "keywords": kws})
    return todo, skipped


def args(t: dict, prev: dict | None, work: Path) -> list[str]:
    """exiftool arguments that set our fields on the work copy. prev: what our last write to this sidecar added
    (its keywords, whether it set the reject flag), taken back first so a re-export after a correction leaves no
    stale species."""
    a = ["-overwrite_original", "-charset", "filename=utf8"]
    if t["stars"] is not None:
        a.append(f"-XMP-xmp:Rating={t['stars']}")               # -1 = rejected (XMP Part 1, 8.4)
    if t["stars"] == -1:
        a += ["-XMP-xmpDM:Pick=-1", "-XMP-xmpDM:Good=false"]    # Lightroom Classic 13.2+: the Reject flag
    elif prev and prev.get("pick"):
        a += ["-XMP-xmpDM:Pick=", "-XMP-xmpDM:Good="]           # we flagged it last time; no longer 淘汰
    for k in (prev or {}).get("keywords", []):
        if k not in t["keywords"]:
            a += [f"-XMP-dc:Subject-={k}", f"-XMP-lr:HierarchicalSubject-={k}"]
    for k in t["keywords"]:                                      # -= then += : added once, never twice
        a += [f"-XMP-dc:Subject-={k}", f"-XMP-dc:Subject+={k}", f"-XMP-lr:HierarchicalSubject-={k}", f"-XMP-lr:HierarchicalSubject+={k}"]
    for x in a:
        if any(c in x for c in "\r\n\0"):
            raise ValueError(f"字段含换行，拒绝交给 exiftool：{x!r}")
    return [*a, str(work)]


def place(target: Path, data: bytes) -> None:
    """Atomic: a hidden temporary file in the same folder, fsync, os.replace; removed again on any failure."""
    fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".birdcm-tmp", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if target.exists():
            with contextlib.suppress(OSError):
                os.chmod(tmp, target.stat().st_mode & 0o7777)
        os.replace(tmp, target)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def write(store, exif, scan_id: int, photos: list[dict]) -> dict:
    """Write the sidecars for these photos; one batch in the database, recorded before any file is replaced."""
    todo, skipped = plan(photos)
    done, same, failed = [], 0, {}
    with tempfile.TemporaryDirectory(prefix="birdcm-xmp-") as tmp:
        for i, t in enumerate(todo):
            work = Path(tmp) / f"{i}.xmp"
            if t["before"] is not None:
                work.write_bytes(t["before"])
            prev = store.xmp_last(str(t["side"]))
            out = exif.run(args(t, prev, work)).decode(errors="replace")
            if not work.is_file() or not ("updated" in out or "created" in out or "unchanged" in out):
                failed["exiftool 没写成"] = failed.get("exiftool 没写成", 0) + 1
                continue
            after = work.read_bytes()
            if after == t["before"]:
                same += 1
                continue
            added = [k for k in t["keywords"] if t["before"] is None or k not in existing_keywords(t["before"])]
            if prev:                                     # still ours from last time (we added it, not the person)
                added += [k for k in prev.get("keywords", []) if k in t["keywords"] and k not in added]
            done.append({**t, "after": after, "ours": {"keywords": added, "pick": t["stars"] == -1}})
    batch = store.xmp_record(scan_id, [{"path": str(t["side"]), "before": t["before"], "after_sha": sha(t["after"]),
                                         "ours": t["ours"]} for t in done]) if done else None
    created = modified = 0
    for t in done:
        try:
            place(t["side"], t["after"])
        except OSError as e:
            store.xmp_forget(batch, str(t["side"]))
            failed[f"写不进去：{e.strerror or e}"] = failed.get(f"写不进去：{e.strerror or e}", 0) + 1
            continue
        if t["before"] is None:
            created += 1
        else:
            modified += 1
    if batch and not created + modified:
        store.xmp_drop(batch)
        batch = None
    return {"batch": batch, "created": created, "modified": modified, "unchanged": same, "skipped": {**skipped, **failed}}


def undo(store, scan_id: int) -> dict:
    """Take back this scan's last batch: a sidecar we created is deleted, one we changed gets its old bytes back. A
    sidecar changed after our write (Lightroom, the person) is left as it is and reported."""
    b = store.xmp_batch(scan_id)
    if not b:
        return {"batch": None, "deleted": 0, "restored": 0, "kept": []}
    deleted = restored = 0
    kept = []
    for f in b["files"]:
        side = Path(f["path"])
        now = side.read_bytes() if side.is_file() and not side.is_symlink() else None
        if now is not None and sha(now) == f["after_sha"]:
            if f["before"] is None:
                side.unlink()
                deleted += 1
            else:
                place(side, f["before"])
                restored += 1
        elif now != f["before"]:
            kept.append({"file": side.name, "reason": "我们写入后又被改过（Lightroom 或你自己），没动它" if now is not None
                         else "已经被删了"})
    store.xmp_drop(b["id"])
    return {"batch": b["id"], "deleted": deleted, "restored": restored, "kept": kept}
