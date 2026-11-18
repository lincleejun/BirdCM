"""The shared life-list fixture (docs/fixtures/lifelist/fixture-v1.json) fed to the engine as native scans."""
import json
from datetime import datetime
from pathlib import Path

from birdcm import library, names
from birdcm.store import Store

FIXTURE = Path(__file__).resolve().parents[2] / "docs" / "fixtures" / "lifelist" / "fixture-v1.json"


def load() -> dict:
    return json.loads(FIXTURE.read_text())


def photos(fx: dict):
    """(label, bytes, photo dict) for every file, the burst expanded."""
    for p in fx["photos"]:
        for n in range(1, p.get("repeat", 1) + 1):
            yield f"{p['id']}-{n}", p["bytes"].replace("{n}", str(n)).encode(), p


def result(fx: dict, p: dict) -> dict:
    boxes = []
    for s in p["subjects"]:
        b = {"box": s["box"], "score": 0.9, "clear": True}
        if s["level"] != "unclassified":
            sci = fx["species"].get(s.get("key"))
            label = {"sci": sci + (" sp." if s["level"] == "genus" else ""), "en": sci, "zh": None, "p": 0.97} if sci else None
            b["species"] = {"level": s["level"], "label": label, "top5": [label] if label else [], "geo": True}
        boxes.append(b)
    lat, lon = fx["points"][p["place"]] if p.get("place") else (None, None)
    return {"file": "x.jpg", "exif": {"taken_at": p["taken_at"], "gps": [lat, lon] if lat is not None else None, "camera": "Fixture"},
            "boxes": boxes, "subject": 0 if boxes else None, "species": boxes[0].get("species") if boxes else None,
            "rejected": not boxes, "reject_reason": None if boxes else "没有找到鸟", "region": {"name": None}}


def catalogue(fx: dict) -> dict:
    return {fx["species"]["A"]: {"en": "Common Tern", "zh": "普通燕鸥", "family": "Laridae"},
            fx["species"]["B"]: {"en": "Great Egret", "zh": "大白鹭", "family": "Ardeidae"}}


def native(tmp_path: Path, monkeypatch, rescan: bool = True) -> tuple[Store, "library.Library", Path]:
    """Every fixture photo as a file in one folder, scanned (completed) at its first-identified time; with rescan, the
    same folder scanned again a day later (the re-identification that must not move the no-EXIF photo)."""
    fx = load()
    monkeypatch.setattr(names, "catalogue", lambda: catalogue(fx))
    monkeypatch.setattr(library, "ZONE", datetime.fromisoformat(fx["default_first_identified"]).tzinfo)
    folder = tmp_path / "photos"
    folder.mkdir()
    files, res = [], {}
    for label, data, p in photos(fx):
        f = folder / f"{label}.jpg"
        f.write_bytes(data)
        st = f.stat()
        files.append((str(f), st.st_size, st.st_mtime_ns))
        res[str(f)] = result(fx, p)
    store = Store(tmp_path / "t.db")
    when = [datetime.fromisoformat(fx["default_first_identified"]).timestamp()]
    if rescan:
        when.append(datetime.fromisoformat(fx["photos"][5]["reidentified"]).timestamp())
    for ts in when:
        sid = scan(store, str(folder), files, res, ts)
    lib = library.Library(store, singles_dir=tmp_path / "singles", imports_dir=tmp_path / "imports")
    return store, lib, folder


def scan(store: Store, folder: str, files, res: dict, ts: float, state: str = "completed", recursive: bool = False) -> int:
    sid = store.create_scan(folder, recursive, None, {"keep": 50}, "fp", files)
    store._write(lambda db: db.execute("UPDATE scan SET created_at = ? WHERE id = ?", (ts, sid)))
    for p in store.queued(sid):
        store.commit(p["id"], res[p["path"]], None)
    store.set_state(sid, state)
    return sid
