"""Security checks (Host / Origin / token), SSE cursor, and the API over a fake engine."""
import os

import pytest
from fastapi.testclient import TestClient

from birdcm.app import create_app, sse, sse_cursor
from birdcm.store import Store
from test_queue import FakeEngine

PORT = 8799
OK = {"host": f"127.0.0.1:{PORT}"}


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    store = Store(tmp_path / "data" / "t.db")
    guarded, api = create_app(PORT, token="tok", store=store, engine_factory=FakeEngine, start_scheduler=False)
    return TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}"), api, tmp_path


def test_host_must_be_exact(env):
    c, *_ = env
    assert c.get("/api/regions", headers=OK).status_code == 200
    assert c.get("/api/regions", headers={"host": f"localhost:{PORT}"}).status_code == 200
    for bad in ("evil.com", f"127.0.0.1:{PORT + 1}", "127.0.0.1", f"attacker.127.0.0.1.nip.io:{PORT}"):
        assert c.get("/api/regions", headers={"host": bad}).status_code == 403, bad


def test_origin_checked_when_present(env):
    c, *_ = env
    assert c.get("/api/regions", headers={**OK, "origin": f"http://127.0.0.1:{PORT}"}).status_code == 200
    for bad in ("null", "http://evil.com", f"http://127.0.0.1:{PORT + 1}", f"https://127.0.0.1:{PORT}"):
        assert c.get("/api/regions", headers={**OK, "origin": bad}).status_code == 403, bad


def test_writes_need_token(env):
    c, _, tmp = env
    (tmp / "shoot").mkdir()
    body = {"folder": str(tmp / "shoot")}
    assert c.post("/api/scans", json=body, headers=OK).status_code == 403
    assert c.post("/api/scans", json=body, headers={**OK, "x-birdcm-token": "nope"}).status_code == 403
    assert c.post("/api/scans", json=body, headers={**OK, "x-birdcm-token": "tok"}).status_code == 200
    assert c.get("/api/session", headers=OK).json() == {"token": "tok"}


def test_refuses_folder_containing_our_dirs(env):
    c, _, tmp = env                       # tmp contains data/ and cache/
    r = c.post("/api/scans", json={"folder": str(tmp)}, headers={**OK, "x-birdcm-token": "tok"})
    assert r.status_code == 400 and "数据或缓存目录" in r.json()["detail"]
    os.environ["BIRDCM_DATA_DIR"] = str(tmp / "photos" / "inside")
    (tmp / "photos").mkdir()
    r = c.post("/api/scans", json={"folder": str(tmp / "photos")}, headers={**OK, "x-birdcm-token": "tok"})
    assert r.status_code == 400 and "数据或缓存目录" in r.json()["detail"]


def test_scan_flow_and_images_by_id_only(env):
    c, api, tmp = env
    photos = tmp / "shoot"
    photos.mkdir()
    for i in range(3):
        (photos / f"a{i}.jpg").write_bytes(b"x")
    (photos / "notes.txt").write_text("skip")
    before = sorted((p.name, p.stat().st_mtime_ns) for p in photos.iterdir())
    h = {**OK, "x-birdcm-token": "tok"}
    sid = c.post("/api/scans", json={"folder": str(photos)}, headers=h).json()["id"]
    snap = c.get(f"/api/scans/{sid}", headers=OK).json()
    assert [p["file"] for p in snap["photos"]] == ["a0.jpg", "a1.jpg", "a2.jpg"] and snap["scan"]["state"] == "queued"
    api.state.scheduler.run_until_idle()
    snap = c.get(f"/api/scans/{sid}", headers=OK).json()
    assert snap["scan"]["state"] == "completed" and snap["cursor"] > 0
    assert c.post(f"/api/scans/{sid}/stop", headers=h).json() == {"state": "completed"}
    assert c.get("/api/photos/999/thumb", headers=OK).status_code == 404
    assert c.get("/api/photos/../../etc/passwd/thumb", headers=OK).status_code == 404
    assert sorted((p.name, p.stat().st_mtime_ns) for p in photos.iterdir()) == before   # nothing written there


def test_sse_cursor_prefers_last_event_id():
    assert sse_cursor("17", 5) == 17
    assert sse_cursor(None, 5) == 5
    assert sse_cursor("garbage", 5) == 5
    assert sse_cursor(None, None) == 0


def test_sse_resume_replays_only_later_events(tmp_path):
    store = Store(tmp_path / "e.db")
    sid = store.create_scan("/p", False, None, {}, "fp", [("/p/a", 1, 1), ("/p/b", 2, 2)])
    first = store.events_after(sid, 0)
    pid = store.queued(sid)[0]["id"]
    store.commit(pid, {"file": "a"}, None)
    later = store.events_after(sid, sse_cursor(str(first[-1]["n"]), 0))
    assert [e["kind"] for e in later] == ["photo"] and later[0]["data"]["id"] == pid
    text = sse(later[0])
    assert text.startswith(f"id: {later[0]['n']}\nevent: photo\ndata: ") and text.endswith("\n\n")


def test_preflight_refuses_before_writing(tmp_path, monkeypatch):
    import sqlite3

    from birdcm.app import preflight
    photos = tmp_path / "photos"
    data = tmp_path / "elsewhere"
    data.mkdir(parents=True)
    photos.mkdir()
    con = sqlite3.connect(data / "birdcm.db")
    con.execute("CREATE TABLE scan (folder TEXT)")
    con.execute("INSERT INTO scan VALUES (?)", (str(photos),))
    con.commit()
    con.close()
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(data))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(photos / "cache"))       # moved into a scanned photo folder
    before = sorted(p.name for p in photos.rglob("*"))
    with pytest.raises(ValueError, match="照片文件夹"):
        preflight()
    assert sorted(p.name for p in photos.rglob("*")) == before            # nothing created there
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "nothing-yet"))
    preflight()                                                           # no database: nothing to check, nothing made
    assert not (tmp_path / "nothing-yet").exists()


def test_singles_upload_switch_delete(env):
    import io
    from concurrent.futures import Future

    from PIL import Image
    c, api, tmp = env
    calls = []

    class Eng:
        def identify(self, path, region, boxes):
            calls.append((path, region, boxes))
            sp = {"level": "species", "label": {"sci": "A b", "en": "A", "zh": None, "p": 0.9}, "top5": [], "geo": False}
            return {"subject": 0, "rejected": False, "reject_reason": None, "exif": {"taken_at": None, "gps": None},
                    "boxes": [{"box": [0, 0, 0.5, 0.5], "species": sp}, {"box": [0.5, 0.5, 1, 1], "species": sp}]}

    def submit(fn):
        f = Future()
        f.set_result(fn(Eng()))
        return f
    api.state.scheduler.submit = submit
    buf = io.BytesIO()
    Image.new("RGB", (40, 30)).save(buf, "PNG")
    h = {**OK, "x-birdcm-token": "tok"}
    assert c.post("/api/singles", files={"file": ("x.png", buf.getvalue())}, headers=OK).status_code == 403
    r = c.post("/api/singles", files={"file": ("../../evil name.png", buf.getvalue())}, data={"region": "美国 · 加利福尼亚州"}, headers=h)
    assert r.status_code == 200, r.text
    rec = r.json()
    stored = tmp / "data" / "singles" / rec["stored"]
    assert stored.is_file() and stored.parent == tmp / "data" / "singles" and rec["name"] == "evil name.png"
    assert rec["result"]["subject"] == 0 and calls[-1][1] == "美国 · 加利福尼亚州"
    sid = rec["id"]
    assert c.post(f"/api/singles/{sid}/identify", json={"subject": 1}, headers=h).json()["subject"] == 1
    assert len(calls) == 1                                                  # switching birds recomputes nothing
    assert c.post(f"/api/singles/{sid}/identify", json={"subject": 5}, headers=h).status_code == 400
    c.post(f"/api/singles/{sid}/identify", json={"box": [0.1, 0.1, 0.4, 0.5]}, headers=h)
    assert calls[-1][2] == [[0.1, 0.1, 0.4, 0.5]]
    assert c.post(f"/api/singles/{sid}/identify", json={"box": [0.5, 0.1, 0.4, 0.5]}, headers=h).status_code == 400
    assert c.post("/api/singles", files={"file": ("x.exe", b"MZ")}, headers=h).status_code == 400
    assert [x["id"] for x in c.get("/api/singles", headers=OK).json()] == [sid]
    assert c.delete(f"/api/singles/{sid}", headers=h).json() == {"deleted": 1}
    assert not stored.exists() and c.get("/api/singles", headers=OK).json() == []
    c.post("/api/singles", files={"file": ("y.png", buf.getvalue())}, headers=h)
    assert c.delete("/api/singles", headers=h).json() == {"deleted": 1}
    assert list((tmp / "data" / "singles").iterdir()) == []
