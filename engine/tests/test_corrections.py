"""The person's species corrections: scope, undo, precedence, survive a re-scan."""
from fastapi.testclient import TestClient

from birdcm import names
from birdcm.app import create_app
from birdcm.store import Store
from test_queue import FakeEngine

PORT = 8799
OK = {"host": f"127.0.0.1:{PORT}"}
H = {**OK, "x-birdcm-token": "tok"}
CAT = {"Thalasseus maximus": {"en": "Royal Tern", "zh": "橙嘴凤头燕鸥"}, "Thalasseus elegans": {"en": "Elegant Tern", "zh": "美洲凤头燕鸥"},
       "Calypte anna": {"en": "Anna's Hummingbird", "zh": None}}


def sp(sci, p=0.97):
    lab = {"sci": sci, "en": sci, "zh": None, "p": p}
    return {"level": "species", "label": lab, "top5": [lab], "geo": False}


def res(t, sci):
    return {"rejected": False, "reject_reason": None, "subject": 0, "file": "x", "species": sp(sci),
            "boxes": [{"box": [0.4, 0.4, 0.5, 0.5], "score": 0.9}], "eye_p": 0.9, "sharpness": 2.0, "aesthetic": 0.6,
            "exif": {"camera": "A", "taken_at": f"2026-11-14T10:00:{t:06.3f}"}}


def setup(tmp_path, monkeypatch):
    monkeypatch.setattr(names, "catalogue", lambda: CAT)
    store = Store(tmp_path / "t.db")
    guarded, api = create_app(PORT, token="tok", store=store, engine_factory=FakeEngine, start_scheduler=False)
    files = [(f"/p/{i}.ARW", 1, 1) for i in range(6)]
    sid = store.create_scan(str(tmp_path), False, None, {"keep": 50}, "fp", files)
    kinds = ["Thalasseus maximus"] * 3 + ["Thalasseus maximus", "Calypte anna", "Calypte anna"]
    for k, p in enumerate(store.queued(sid)):
        store.commit(p["id"], res(0.5 * k if k < 3 else 30 + k, kinds[k]), None)       # photos 0-2: one burst
    store.set_state(sid, "completed")
    api.state.scheduler.rerate_now(sid)
    return TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}"), store, sid


def eff(store, sid):
    return [((p["species_fix"] or p["result"]["species"]).get("label") or {}).get("sci") for p in store.snapshot(sid)["photos"]]


def test_scopes_undo_and_precedence(tmp_path, monkeypatch):
    c, store, sid = setup(tmp_path, monkeypatch)
    ids = [p["id"] for p in store.snapshot(sid)["photos"]]
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[0], "scope": "one", "sci": "Thalasseus elegans"}, headers=H).json()["photos"] == 1
    assert eff(store, sid)[:4] == ["Thalasseus elegans", "Thalasseus maximus", "Thalasseus maximus", "Thalasseus maximus"]
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[1], "scope": "burst", "sci": "Thalasseus elegans"}, headers=H).json()["photos"] == 3
    assert eff(store, sid)[3] == "Thalasseus maximus"                         # another burst: untouched
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[3], "scope": "same", "sci": "Thalasseus elegans"}, headers=H).json()["photos"] == 1
    assert eff(store, sid)[:4] == ["Thalasseus elegans"] * 4
    fix = store.snapshot(sid)["photos"][0]["species_fix"]
    assert fix["manual"] and fix["label"]["en"] == "Elegant Tern"
    c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[0], "scope": "burst", "undo": True}, headers=H)
    assert eff(store, sid)[:4] == ["Thalasseus maximus"] * 3 + ["Thalasseus elegans"]
    c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[4], "scope": "one", "sci": None}, headers=H)
    assert store.snapshot(sid)["photos"][4]["species_fix"]["level"] == "uncertain"
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[4], "scope": "one", "sci": "Nope nope"}, headers=H).status_code == 400


def test_corrections_survive_a_rescan(tmp_path, monkeypatch):
    c, store, sid = setup(tmp_path, monkeypatch)
    ids = [p["id"] for p in store.snapshot(sid)["photos"]]
    c.post(f"/api/scans/{sid}/corrections", json={"photo_id": ids[0], "scope": "one", "sci": "Thalasseus elegans"}, headers=H)
    new = store.create_scan(str(tmp_path), False, None, {"keep": 50}, "fp2", [(f"/p/{i}.ARW", 1, 1) for i in range(6)])
    cor = store.corrections_for(new)
    assert len(cor) == 1 and list(cor.values())[0]["sci"] == "Thalasseus elegans" and list(cor.values())[0]["app"] == "Thalasseus maximus"


def test_selected_ids_in_one_request_equal_one_by_one(tmp_path, monkeypatch):
    """The grid's multi-select: photo_ids corrects exactly those photos (no burst / same widening), in one request,
    and ends where correcting each alone ends; an id of another scan fails the whole request."""
    c, store, sid = setup(tmp_path, monkeypatch)
    ids = [p["id"] for p in store.snapshot(sid)["photos"]]
    pick = [ids[0], ids[4]]
    r = c.post(f"/api/scans/{sid}/corrections", json={"photo_ids": pick, "sci": "Thalasseus elegans"}, headers=H)
    assert r.json() == {"ok": True, "photos": 2}
    batch = (eff(store, sid), [p["stars"] for p in store.snapshot(sid)["photos"]])
    assert batch[0] == ["Thalasseus elegans", "Thalasseus maximus", "Thalasseus maximus", "Thalasseus maximus", "Thalasseus elegans", "Calypte anna"]
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_ids": pick, "undo": True}, headers=H).json()["photos"] == 2
    assert eff(store, sid)[4] == "Calypte anna"
    for i in pick:
        c.post(f"/api/scans/{sid}/corrections", json={"photo_id": i, "scope": "one", "sci": "Thalasseus elegans"}, headers=H)
    assert (eff(store, sid), [p["stars"] for p in store.snapshot(sid)["photos"]]) == batch

    sid2 = store.create_scan(str(tmp_path / "b"), False, None, {"keep": 50}, "fp2", [("/q/x.ARW", 1, 1)])
    stranger = store.queued(sid2)[0]["id"]
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_ids": [ids[1], stranger], "sci": None}, headers=H).status_code == 404
    assert eff(store, sid) == batch[0]                                       # nothing half-applied
    assert c.post(f"/api/scans/{sid}/corrections", json={"photo_ids": [], "sci": None}, headers=H).status_code == 400
