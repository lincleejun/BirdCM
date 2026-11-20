"""The person's stars (R2): survive a re-scan and a settings change, take no budget, undo, one request for many."""
from fastapi.testclient import TestClient

from birdcm import names, stars
from birdcm.app import create_app
from birdcm.store import Store
from test_corrections import CAT, H, PORT, res
from test_queue import FakeEngine


def setup(tmp_path, monkeypatch, sched_too=False):
    """test_corrections' scan (6 photos, 0-2 one burst), and the scheduler when asked."""
    monkeypatch.setattr(names, "catalogue", lambda: CAT)
    store = Store(tmp_path / "t.db")
    guarded, api = create_app(PORT, token="tok", store=store, engine_factory=FakeEngine, start_scheduler=False)
    sid = store.create_scan(str(tmp_path), False, None, {"keep": 50}, "fp", [(f"/p/{i}.ARW", 1, 1) for i in range(6)])
    kinds = ["Thalasseus maximus"] * 4 + ["Calypte anna"] * 2
    for k, p in enumerate(store.queued(sid)):
        store.commit(p["id"], res(0.5 * k if k < 3 else 30 + k, kinds[k]), None)
    store.set_state(sid, "completed")
    api.state.scheduler.rerate_now(sid)
    c = TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}")
    return (c, store, sid, api.state.scheduler) if sched_too else (c, store, sid)


def shown(store, sid):
    return [p["stars"] for p in store.snapshot(sid)["photos"]]


def computed(store, sid, ratio):
    """What the rating gives these photos at this ratio with no stars set by hand."""
    rows = store.rows_for_rating(sid)
    out = stars.rate(rows, ratio)
    return [out[r["id"]]["stars"] for r in rows]


def test_set_undo_and_no_effect_on_others(tmp_path, monkeypatch):
    c, store, sid = setup(tmp_path, monkeypatch)
    ids = [p["id"] for p in store.snapshot(sid)["photos"]]
    base = shown(store, sid)
    want = 3 if base[5] != 3 else 1
    r = c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[5]], "stars": want}, headers=H)
    assert r.json() == {"ok": True, "photos": 1}
    after = shown(store, sid)
    assert after[5] == want and after[:5] == base[:5]                  # no budget taken, nobody else moved
    p = store.snapshot(sid)["photos"][5]
    assert p["star_auto"]["stars"] == base[5] and p["star_reason"] == "主人手动设定"
    c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[5]], "stars": None}, headers=H)
    assert shown(store, sid) == base and store.snapshot(sid)["photos"][5]["star_auto"] is None
    assert c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[0]], "stars": 4}, headers=H).status_code == 400
    assert c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [], "stars": 1}, headers=H).status_code == 400
    assert c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[0], 99999], "stars": 1}, headers=H).status_code == 404
    assert shown(store, sid) == base                                    # a refused request changes nothing


def test_survives_a_rescan(tmp_path, monkeypatch):
    c, store, sid, sched = setup(tmp_path, monkeypatch, sched_too=True)
    ids = [p["id"] for p in store.snapshot(sid)["photos"]]
    c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[2]], "stars": -1}, headers=H)
    new = store.create_scan(str(tmp_path), False, None, {"keep": 50}, "fp", [(f"/p/{i}.ARW", 1, 1) for i in range(6)])
    assert store.snapshot(new)["photos"][0]["reused"]                  # results reused, rated again at finalize
    sched.finalize(new)
    snap = store.snapshot(new)
    assert snap["scan"]["state"] == "completed"
    assert snap["photos"][2]["stars"] == -1 and snap["photos"][2]["star_auto"] is not None


def test_ratio_change_keeps_manual_and_rerates_others(tmp_path, monkeypatch):
    c, store, sid = setup(tmp_path, monkeypatch)
    ids = [p["id"] for p in store.snapshot(sid)["photos"]]
    lo, hi = {"keep": 10}, {"keep": 90}
    assert computed(store, sid, lo) != computed(store, sid, hi)         # the change moves photos: not a vacuous test
    c.put(f"/api/scans/{sid}/ratio", json={"replace": True, **lo}, headers=H)
    c.post(f"/api/scans/{sid}/stars", json={"photo_ids": [ids[3]], "stars": 2}, headers=H)
    c.put(f"/api/scans/{sid}/ratio", json={"replace": True, **hi}, headers=H)
    now, want = shown(store, sid), computed(store, sid, hi)
    assert now[3] == 2
    assert [s for k, s in enumerate(now) if k != 3] == [s for k, s in enumerate(want) if k != 3]
    assert store.snapshot(sid)["photos"][3]["star_auto"]["stars"] == want[3]


def test_many_in_one_request_equals_one_by_one(tmp_path, monkeypatch):
    c1, s1, sid1 = setup(tmp_path / "a", monkeypatch)
    c2, s2, sid2 = setup(tmp_path / "b", monkeypatch)
    ids1 = [p["id"] for p in s1.snapshot(sid1)["photos"]]
    ids2 = [p["id"] for p in s2.snapshot(sid2)["photos"]]
    assert c1.post(f"/api/scans/{sid1}/stars", json={"photo_ids": ids1[1:5], "stars": 1}, headers=H).json()["photos"] == 4
    for i in ids2[1:5]:
        c2.post(f"/api/scans/{sid2}/stars", json={"photo_ids": [i], "stars": 1}, headers=H)
    assert shown(s1, sid1) == shown(s2, sid2)
    assert shown(s1, sid1)[1:5] == [1] * 4
