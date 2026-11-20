"""Security checks (Host / Origin / token), SSE cursor, and the API over a fake engine."""
import os
from pathlib import Path

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
        fp = "fp1"

        def fingerprint(self, region):
            return self.fp

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


def test_ratio_validated_at_the_api(env):
    c, _, tmp = env
    (tmp / "shoot").mkdir()
    h = {**OK, "x-birdcm-token": "tok"}
    assert c.post("/api/scans", json={"folder": str(tmp / "shoot"), "ratio": {"p3": "x"}}, headers=h).status_code == 400
    sid = c.post("/api/scans", json={"folder": str(tmp / "shoot")}, headers=h).json()["id"]
    assert c.put(f"/api/scans/{sid}/ratio", json={"p3": 90, "p2": 30}, headers=h).status_code == 400
    assert c.put(f"/api/scans/{sid}/ratio", json={"p3": 20, "p2": 30, "burst_cap": 3}, headers=h).status_code == 200


def test_upload_limits_leave_nothing(env, monkeypatch):
    import io

    from PIL import Image

    from birdcm import app as appmod
    c, api, tmp = env
    h = {**OK, "x-birdcm-token": "tok"}
    buf = io.BytesIO()
    Image.new("RGB", (400, 300)).save(buf, "PNG")
    monkeypatch.setattr(appmod, "MAX_PIXELS", 1000)
    r = c.post("/api/singles", files={"file": ("big.png", buf.getvalue())}, headers=h)
    assert r.status_code == 400 and "太大" in r.json()["detail"]
    monkeypatch.setattr(appmod, "MAX_UPLOAD", 10)
    r = c.post("/api/singles", files={"file": ("x.png", b"0" * 100_000)}, headers=h)
    assert r.status_code == 413
    d = tmp / "data" / "singles"
    assert not d.exists() or list(d.iterdir()) == []


def test_preview_pool_survives_a_crashing_decode(tmp_path, monkeypatch):
    import sys
    sys.path.insert(0, str(Path(__file__).parent))
    import crashy

    from birdcm import app as appmod
    p = appmod.Previews()
    monkeypatch.setattr(appmod.decode, "decode", crashy.decode)
    try:
        with pytest.raises(Exception):
            p.make({"path": "/x/bad", "size": 1, "mtime_ns": 1})
        p.make({"path": "/x/ok", "size": 1, "mtime_ns": 1})                    # a fresh pool after the crash
    finally:
        p.close()


def test_images_by_id_are_revalidated_not_cached(env, monkeypatch):
    """ids restart with a new database: an image under /api/photos/{id} must never be served from a day-long cache."""
    c, api, tmp = env
    from birdcm import app as appmod
    photos = tmp / "shoot"
    photos.mkdir()
    from PIL import Image
    Image.new("RGB", (64, 48), (200, 10, 10)).save(photos / "a.jpg")
    h = {**OK, "x-birdcm-token": "tok"}
    c.post("/api/scans", json={"folder": str(photos)}, headers=h)
    pid = api.state.store.queued(1)[0]["id"]
    monkeypatch.setattr(appmod.Previews, "make", lambda self, job: appmod.decode.decode(job))   # in-process for the test
    r = c.get(f"/api/photos/{pid}/thumb", headers=OK)
    assert r.status_code == 200 and "max-age" not in r.headers["cache-control"] and "no-cache" in r.headers["cache-control"]
    assert r.headers.get("etag")
    again = c.get(f"/api/photos/{pid}/thumb", headers={**OK, "if-none-match": r.headers["etag"]})
    assert again.status_code == 304 and not again.content                          # Codex P5: no second transfer
    assert c.get(f"/api/photos/{pid}/thumb", headers={**OK, "if-none-match": '"other"'}).status_code == 200


def test_places_proxy_rate_limit_cache_and_ua():
    import time as _t
    from birdcm import app as A
    A._places_cache.clear()
    seen = []
    def fake(req):
        seen.append((_t.monotonic(), req.get_header("User-agent"), req.full_url))
        return [{"display_name": "Homer, Alaska", "lat": "59.64", "lon": "-151.54"}]
    assert A.places_search("Homer Alaska", fetch=fake) == [{"label": "Homer, Alaska", "lat": 59.64, "lon": -151.54}]
    A.places_search("homer alaska", fetch=fake)               # cached: no second request
    A.places_search("Bolsa Chica", fetch=fake)
    assert len(seen) == 2 and seen[1][0] - seen[0][0] >= 0.99
    assert seen[0][1].startswith("BirdCM/") and "q=Homer+Alaska" in seen[0][2]
    def down(req):
        raise OSError("offline")
    import pytest
    with pytest.raises(OSError):
        A.places_search("Nowhere", fetch=down)


def test_equivalent_old_fingerprint_moves_instead_of_going_stale(tmp_path):
    from birdcm.pipeline import EQUIVALENT_DATA, fingerprint
    old, new = fingerprint(None, "m", data=EQUIVALENT_DATA[0]), fingerprint(None, "m")
    assert old != new
    store = Store(tmp_path / "t.db")
    sid = store.create_scan(str(tmp_path), False, None, {}, old, [])
    store.move_fp(sid, old, new)
    assert [s["fp"] for s in store.scans() if s["id"] == sid] == [new]


def test_bad_star_settings_are_refused_and_nothing_changes(env):
    """Codex S2: {"size_full": 0} used to return 200, store the setting and crash the re-rating."""
    c, api, tmp = env
    h = {**OK, "X-BirdCM-Token": "tok"}
    (tmp / "shoot").mkdir()
    sid = c.post("/api/scans", json={"folder": str(tmp / "shoot"), "ratio": {"keep": 20}}, headers=h).json()["id"]
    before = c.get(f"/api/scans/{sid}", headers=OK).json()["scan"]["ratio"]
    for bad in ({"size_full": 0}, {"d_burst": -1}, {"eye3": 2}):
        assert c.put(f"/api/scans/{sid}/ratio", json=bad, headers=h).status_code == 400
    assert c.get(f"/api/scans/{sid}", headers=OK).json()["scan"]["ratio"] == before



def test_ratio_change_keeps_the_other_settings(env):
    """Codex I3: the UI sends {preset, keep}; custom weights set before must survive."""
    c, api, tmp = env
    h = {**OK, "X-BirdCM-Token": "tok"}
    (tmp / "shoot").mkdir()
    sid = c.post("/api/scans", json={"folder": str(tmp / "shoot"), "ratio": {"keep": 20, "w_eye": 0.3}}, headers=h).json()["id"]
    assert c.put(f"/api/scans/{sid}/ratio", json={"preset": "stricter", "keep": 10}, headers=h).status_code == 200
    r = c.get(f"/api/scans/{sid}", headers=OK).json()["scan"]["ratio"]
    assert r["keep"] == 10 and r["w_eye"] == 0.3
    assert c.put(f"/api/scans/{sid}/ratio", json={"replace": True, "keep": 25}, headers=h).status_code == 200
    assert c.get(f"/api/scans/{sid}", headers=OK).json()["scan"]["ratio"] == {"keep": 25}


def _single_env(env, fail_regions=()):
    import io
    from concurrent.futures import Future

    from PIL import Image
    c, api, tmp = env

    class Eng:
        fp = "fp1"

        def fingerprint(self, region):
            return self.fp

        def identify(self, path, region, boxes):
            if region in fail_regions:
                raise RuntimeError("GPU gone")
            sp = {"level": "species", "label": {"sci": "A b", "en": "A", "zh": None, "p": 0.9}, "top5": [], "geo": False,
                  "rarity": {"iucn": "NT"}}
            return {"subject": 0, "rejected": False, "reject_reason": None, "exif": {"taken_at": None, "gps": None},
                    "rarity": {"tier": 4, "label": "常见", "iucn": "NT", "region": "X"},
                    "boxes": [{"box": [0, 0, 0.5, 0.5], "species": sp}], "species": sp}
    eng = Eng()

    def submit(fn):
        f = Future()
        try:
            f.set_result(fn(eng))
        except Exception as e:  # noqa: BLE001
            f.set_exception(e)
        return f
    api.state.scheduler.submit = submit
    api.state.scheduler.engine = eng
    buf = io.BytesIO()
    Image.new("RGB", (40, 30)).save(buf, "PNG")
    h = {**OK, "x-birdcm-token": "tok"}
    rec = c.post("/api/singles", files={"file": ("a.png", buf.getvalue())}, data={"region": "美国 · 加利福尼亚州"}, headers=h).json()
    return c, h, rec, eng


def test_failed_retry_keeps_the_last_consistent_result(env):
    """Codex I6: a new place that fails must not sit beside the old place's result."""
    c, h, rec, _ = _single_env(env, fail_regions=("美国 · 得克萨斯州",))
    r = c.post(f"/api/singles/{rec['id']}/identify", json={"region": "美国 · 得克萨斯州"}, headers=h).json()
    assert r["error"] and r["region"] == "美国 · 加利福尼亚州" and r["result"]["species"]["label"]["sci"] == "A b"


def test_single_history_goes_stale_and_iucn_switch_applies_on_read(env, monkeypatch):
    """Codex I7: history entries carry their fingerprint; BIRDCM_IUCN=0 hides IUCN in old results too."""
    c, h, rec, eng = _single_env(env)
    assert c.get(f"/api/singles/{rec['id']}", headers=OK).json()["stale"] is False
    eng.fp = "fp2"
    assert c.get(f"/api/singles/{rec['id']}", headers=OK).json()["stale"] is True
    from birdcm import rarity
    monkeypatch.setattr(rarity, "SHOW_IUCN", False)
    r = c.get(f"/api/singles/{rec['id']}", headers=OK).json()["result"]
    assert r["rarity"]["iucn"] is None and r["species"]["rarity"]["iucn"] is None


def test_related_reports_cursor_and_last_good_scan(env):
    """Codex I1 / I9: a finished page can see that the stars changed; a failed re-scan keeps the last good one in view."""
    c, api, tmp = env
    store = api.state.store
    (tmp / "shoot").mkdir()
    a = store.create_scan(str(tmp / "shoot"), False, None, {"keep": 20}, "fp", [])
    store.set_state(a, "completed")
    b = store.create_scan(str(tmp / "shoot"), False, None, {"keep": 20}, "fp", [])
    store.set_state(b, "failed", error="x")
    top = [s for s in store.scans() if s["folder"] == str(tmp / "shoot")][0]
    assert top["id"] == b and top["last_completed"] == a
    rel = c.get(f"/api/scans/{a}/related", headers=OK).json()
    assert rel["newer"]["state"] == "failed" and "cursor" in rel


def test_snapshot_is_compressed_and_slim(env):
    """Codex P2: the list snapshot leaves out per-box species and the likeness thumbnail, and travels compressed."""
    c, api, tmp = env
    store = api.state.store
    (tmp / "shoot").mkdir()
    sid = store.create_scan(str(tmp / "shoot"), False, None, {"keep": 20}, "fp", [(f"/x/{i}.ARW", 1, 1) for i in range(300)])
    sp = {"level": "species", "label": {"sci": "A b", "en": "A", "zh": None, "p": 0.9}, "top5": [{"sci": "A b", "p": 0.9}] * 5}
    for p in store.queued(sid):
        store.commit(p["id"], {"rejected": False, "subject": 0, "species": sp, "look": list(range(64)), "exif": {},
                               "boxes": [{"box": [0, 0, 1, 1], "score": 0.9, "species": sp}]}, None)
    r = c.get(f"/api/scans/{sid}", headers={**OK, "accept-encoding": "gzip"})
    assert r.headers.get("content-encoding") == "gzip"
    row = r.json()["photos"][0]["result"]
    assert "look" not in row and "species" not in row["boxes"][0] and row["species"]["label"]["sci"] == "A b"
    full = c.get(f"/api/photos/{r.json()['photos'][0]['id']}", headers=OK).json()["result"]
    assert full["look"] and full["boxes"][0]["species"]


def test_requests_before_the_models_are_ready_are_queued_and_complete(tmp_path, monkeypatch):
    """The server answers while the engine loads in the background (real scheduler thread): a single photo and a scan
    sent meanwhile are accepted at once and finish when it is ready; a failed load keeps the scan queued until retry."""
    import io
    import threading
    import time

    from PIL import Image
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    gate, calls = threading.Event(), []

    class Eng(FakeEngine):
        def identify(self, path, region, boxes):
            sp = {"level": "species", "label": {"sci": "A b", "en": "A", "zh": None, "p": 0.9}, "top5": [], "geo": False}
            return {"subject": 0, "rejected": False, "reject_reason": None, "exif": {"taken_at": None, "gps": None},
                    "boxes": [{"box": [0, 0, 0.5, 0.5], "species": sp}]}

    def factory():
        calls.append(1)
        if len(calls) <= 2:
            raise FileNotFoundError("缺模型文件：x.safetensors")
        assert gate.wait(10)
        return Eng()
    files_here = [False]
    from birdcm import app as app_mod
    monkeypatch.setattr(app_mod.models, "status", lambda: {"ready": files_here[0], "missing": []})

    store = Store(tmp_path / "data" / "t.db")
    guarded, api = create_app(PORT, token="tok", store=store, engine_factory=factory)
    h = {**OK, "x-birdcm-token": "tok"}
    (tmp_path / "shoot").mkdir()
    for i in range(3):
        (tmp_path / "shoot" / f"{i}.jpg").write_bytes(b"x")
    buf = io.BytesIO()
    Image.new("RGB", (40, 30)).save(buf, "PNG")

    def until(cond, what):
        end = time.monotonic() + 10
        while not cond():
            assert time.monotonic() < end, what
            time.sleep(0.02)

    with TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}") as c:      # runs the lifespan: the scheduler starts
        until(lambda: c.get("/api/models", headers=OK).json()["engine"] == "error", "load error reported")
        assert "缺模型文件" in c.get("/api/models", headers=OK).json()["load_error"]
        sid = c.post("/api/scans", json={"folder": str(tmp_path / "shoot")}, headers=h).json()["id"]
        time.sleep(0.3)
        assert store.state(sid) == "queued" and len(calls) == 1             # waits for a retry, is not failed
        assert c.post("/api/models/retry", headers=h).json()["engine"] == "loading"    # 重试: still missing
        until(lambda: len(calls) == 2 and c.get("/api/models", headers=OK).json()["engine"] == "error", "failed again")
        files_here[0] = True                                                 # downloaded meanwhile: loads, no click
        assert c.get("/api/models", headers=OK).json()["engine"] == "loading"
        until(lambda: len(calls) == 3, "loading again")
        t = time.monotonic()
        rec = c.post("/api/singles", files={"file": ("a.png", buf.getvalue())}, headers=h).json()
        assert time.monotonic() - t < 2 and rec["result"] is None and rec["error"] is None     # accepted, queued
        assert c.get("/api/models", headers=OK).json()["engine"] == "loading"
        assert c.get("/api/regions", headers=OK).status_code == 200                           # the rest answers meanwhile
        gate.set()
        until(lambda: c.get(f"/api/singles/{rec['id']}", headers=OK).json()["result"] is not None, "single done")
        until(lambda: store.state(sid) == "completed", "scan done")
        assert c.get("/api/models", headers=OK).json()["engine"] == "ready"
        rec2 = c.post("/api/singles", files={"file": ("b.png", buf.getvalue())}, headers=h).json()
        assert rec2["result"]["subject"] == 0                               # ready: answered in the same request


def test_full_size_image_upright_by_scan_and_id(env, monkeypatch):
    """The 100 % view's image: full size, upright like the preview (so the normalised marks land on the same pixel);
    404 for an unknown id, an id of another scan and a file gone since; revalidated by ETag; nothing written."""
    c, api, tmp = env
    from io import BytesIO

    from PIL import Image

    from birdcm import app as appmod
    monkeypatch.setattr(appmod.Previews, "full", lambda self, job: appmod.decode.full_jpeg(job))   # in-process
    photos, other = tmp / "shoot", tmp / "other"
    photos.mkdir()
    other.mkdir()
    im = Image.new("RGB", (300, 200), (0, 0, 0))
    im.paste((255, 0, 0), (0, 0, 30, 30))               # stored top-left; orientation 6 shows it top-right
    ex = Image.Exif()
    ex[0x0112] = 6
    im.save(photos / "a.jpg", exif=ex, quality=95)
    Image.new("RGB", (40, 20)).save(photos / "b.jpg")
    Image.new("RGB", (40, 20)).save(other / "c.jpg")
    before = sorted((p.name, p.stat().st_mtime_ns) for p in photos.iterdir())
    h = {**OK, "x-birdcm-token": "tok"}
    sid = c.post("/api/scans", json={"folder": str(photos)}, headers=h).json()["id"]
    sid2 = c.post("/api/scans", json={"folder": str(other)}, headers=h).json()["id"]
    a, b = (p["id"] for p in c.get(f"/api/scans/{sid}", headers=OK).json()["photos"])
    elsewhere = c.get(f"/api/scans/{sid2}", headers=OK).json()["photos"][0]["id"]

    r = c.get(f"/api/scans/{sid}/photos/{a}/full", headers=OK)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg" and "no-cache" in r.headers["cache-control"]
    full = Image.open(BytesIO(r.content))
    assert full.size == (200, 300) and full.getexif().get(0x0112, 1) == 1           # upright, nothing left to rotate
    assert full.getpixel((190, 10))[0] > 200 and full.getpixel((10, 10))[0] < 60
    assert c.get(f"/api/scans/{sid}/photos/{a}/full", headers={**OK, "if-none-match": r.headers["etag"]}).status_code == 304
    upright = Image.open(BytesIO(c.get(f"/api/scans/{sid}/photos/{b}/full", headers=OK).content))
    assert upright.size == (40, 20)

    assert c.get(f"/api/scans/{sid}/photos/999/full", headers=OK).status_code == 404
    assert c.get(f"/api/scans/{sid}/photos/{elsewhere}/full", headers=OK).status_code == 404      # not this scan's
    assert c.get(f"/api/scans/{sid2}/photos/{elsewhere}/full", headers=OK).status_code == 200
    assert sorted((p.name, p.stat().st_mtime_ns) for p in photos.iterdir()) == before   # nothing written there
    (photos / "b.jpg").unlink()
    assert c.get(f"/api/scans/{sid}/photos/{b}/full", headers=OK).status_code == 404       # gone since the listing


def test_full_size_raw_jpeg_turned_like_the_preview():
    """A RAW's embedded JPEG is stored unrotated: it is turned by the RAW's orientation, as load_upright does."""
    from io import BytesIO

    from PIL import Image

    from birdcm import decode
    im = Image.new("RGB", (300, 200), (0, 0, 0))
    im.paste((255, 0, 0), (0, 0, 30, 30))
    buf = BytesIO()
    im.save(buf, "JPEG", quality=95)
    assert decode.upright_jpeg(buf.getvalue(), 1) == buf.getvalue()                 # upright: the bytes as they are
    for o, size, red in ((6, (200, 300), (190, 10)), (8, (200, 300), (10, 290)), (3, (300, 200), (290, 190))):
        out = Image.open(BytesIO(decode.upright_jpeg(buf.getvalue(), o)))
        assert out.size == size and out.getpixel(red)[0] > 200, o
        assert out.transpose(Image.Transpose.ROTATE_90 if o == 6 else Image.Transpose.ROTATE_270 if o == 8
                             else Image.Transpose.ROTATE_180).getpixel((10, 10))[0] > 200   # same as load_upright's turn
