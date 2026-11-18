"""Life-list routes, the portable archive (export -> import round trip, trust boundary) and the life-list eBird file."""
import json
import shutil
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from birdcm import archive, library, names
from birdcm.app import create_app
from birdcm.store import Store
from lifelist_fixture import FIXTURE, catalogue, load, native
from test_library import check_expected
from test_queue import FakeEngine

PORT = 8798
H = {"host": f"127.0.0.1:{PORT}", "x-birdcm-token": "tok"}
GOLDEN = FIXTURE.parent


def client(store, tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    guarded, api = create_app(PORT, token="tok", store=store, engine_factory=FakeEngine, start_scheduler=False)
    lib = api.state.library
    lib.singles_dir, lib.imports_dir = tmp_path / "singles", tmp_path / "data" / "imports"
    return TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}"), lib


def empty(tmp_path, monkeypatch, name="empty"):
    fx = load()
    monkeypatch.setattr(names, "catalogue", lambda: catalogue(fx))
    d = tmp_path / name
    d.mkdir()
    return client(Store(d / "t.db"), d, monkeypatch)


def test_routes_summary_species_observations_calendar_map(tmp_path, monkeypatch):
    store, lib0, _ = native(tmp_path, monkeypatch)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    s = c.get("/api/library/summary?from=2026-01-01&to=2026-01-31", headers=H).json()
    assert not s["updating"] and s["metrics"]["observations"] == 3 and s["range"] == {"from": "2026-01-01", "to": "2026-01-31"}
    assert c.get("/api/library/summary?from=2026-1-1", headers=H).status_code == 422
    sp = c.get("/api/library/species", headers=H).json()
    assert [x["key"] for x in sp["items"]] == ["Sterna hirundo", "Ardea alba"]            # most recently seen first
    assert sp["items"][0]["zh"] == "普通燕鸥" and sp["items"][0]["cover_ref"]["kind"] == "photo"
    unseen = c.get("/api/library/species?seen=no", headers=H).json()
    assert unseen["total"] == 0                                                      # the catalogue is these two
    d = c.get("/api/library/species/detail", params={"sci": "Sterna hirundo"}, headers=H).json()
    assert d["first_day"] == "2025-12-31" and d["scope"]["observations"] == 4 and d["months"][0] == 2 and d["total_photos"] == 303
    obs = c.get("/api/library/observations?from=2026-01-01&to=2026-01-01", headers=H).json()
    assert obs["total"] == 2 and {o["sci"] for o in obs["items"]} == {"Sterna hirundo", "Ardea alba"}
    burst = next(o for o in obs["items"] if o["sci"] == "Sterna hirundo")
    assert burst["estimate"] == 1 and burst["photo_count"] == 300 and len(burst["source_refs"]) == 6
    cal = c.get("/api/library/calendar?year=2026", headers=H).json()
    assert cal["days"]["2026-01-01"]["observations"] == 2 and cal["active_days"] == 4 and len(cal["months"]) == 12
    m = c.get("/api/library/map?bounds=10,20,10.5,20.5", headers=H).json()
    assert sum(x["observations"] for x in m["clusters"]) >= 6 and m["no_place_observations"] == 0
    assert c.get("/api/library/map?bounds=1,2,3", headers=H).status_code == 422
    pend = c.get("/api/library/photos?status=pending", headers=H).json()
    assert pend["total"] == 3 and {p["reason"] for p in pend["items"]} == {"只认到属", "不确定", "还没识别的框"}
    assert c.get("/api/library/photos?status=no-bird", headers=H).json()["total"] == 1


def test_edits_through_routes_and_stale_generation(tmp_path, monkeypatch):
    store, _, _ = native(tmp_path, monkeypatch)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    gen = lib.status()["generation"]
    obs = c.get("/api/library/observations?from=2026-01-01&to=2026-01-01", headers=H).json()["items"]
    burst = next(o for o in obs if o["sci"] == "Sterna hirundo")
    r = c.post("/api/library/observation-count", json={"group_key": burst["key"], "count": 7, "expected_generation": gen}, headers=H)
    assert r.status_code == 200 and r.json()["generation"] == gen + 1
    assert c.post("/api/library/observation-count", json={"group_key": burst["key"], "count": 7, "expected_generation": gen},
                  headers=H).status_code == 409
    assert c.get("/api/library/summary?from=2026-01-01&to=2026-01-31", headers=H).json()["metrics"]["estimated_count"] == 9
    ref = burst["source_refs"][0]
    bad = c.post("/api/library/subject-edit", json={"source_ref": ref, "edit": {"op": "count", "value": 0}, "expected_generation": gen + 1}, headers=H)
    assert bad.status_code == 422
    assert c.post("/api/library/subject-edit", json={"source_ref": {**ref, "subject_id": "nope"}, "edit": {"op": "count", "value": 2},
                                                     "expected_generation": gen + 1}, headers=H).status_code == 404
    ok = c.post("/api/library/subject-edit", json={"source_ref": ref, "edit": {"op": "species", "state": "species", "key": "Ardea alba"},
                                                    "expected_generation": gen + 1}, headers=H)
    assert ok.status_code == 200 and ok.json()["updating"]
    lib.rebuild()
    assert store.corrections_for(1) or store.corrections_for(2)                      # the scan view says the same
    jan1 = c.get("/api/library/observations?from=2026-01-01&to=2026-01-01", headers=H).json()["items"]
    assert next(o for o in jan1 if o["sci"] == "Ardea alba")["photo_count"] == 2
    assert c.post("/api/library/observation-count", json={"group_key": burst["key"], "count": 1, "expected_generation": 1},
                  headers={"host": H["host"]}).status_code == 403                    # writes need the session token


def test_archive_round_trip_into_an_empty_engine_and_idempotent(tmp_path, monkeypatch):
    fx = load()
    store, _, _ = native(tmp_path, monkeypatch)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    r = c.get("/api/library/export", headers=H)
    assert r.status_code == 200 and r.headers["content-type"] == archive.MIME
    out = tmp_path / "x.birdcm"
    out.write_bytes(r.content)
    v = archive.validate(out)
    assert v["records"] == 308 and v["missing_originals"] == 0 and v["meta"]["producer"] == "desktop"
    con = sqlite3.connect(out)
    assert con.execute("PRAGMA application_id").fetchone()[0] == archive.APPLICATION_ID
    assert not con.execute("SELECT count(*) FROM ll_record WHERE payload_json LIKE '%" + str(tmp_path) + "%'").fetchone()[0]
    con.close()
    c2, lib2 = empty(tmp_path, monkeypatch)
    pv = c2.post("/api/library/import/preview", files={"file": ("x.birdcm", out.read_bytes(), archive.MIME)}, headers=H)
    assert pv.status_code == 200, pv.text
    p = pv.json()
    assert p["summary"]["new_photos"] == 308 and p["conflicts"] == []
    ap = c2.post("/api/library/import/apply", json={"token": p["token"], "expected_generation": lib2.status()["generation"]}, headers=H).json()
    assert ap["added_photos"] == 308
    again = c2.post("/api/library/import/apply", json={"token": p["token"], "expected_generation": 0}, headers=H).json()
    assert again == ap                                                               # a retried commit: same answer
    lib2.rebuild()
    check_expected(lib2.index(), fx)
    pv2 = c2.post("/api/library/import/preview", files={"file": ("x.birdcm", out.read_bytes(), archive.MIME)}, headers=H).json()
    ap2 = c2.post("/api/library/import/apply", json={"token": pv2["token"], "expected_generation": lib2.status()["generation"]}, headers=H).json()
    assert ap2["added_photos"] == 0                                                  # second merge adds nothing
    lib2.rebuild()
    check_expected(lib2.index(), fx)
    # imported media opens from the managed folder only
    rec = lib2.index().rows[0]["source_id"]
    assert c2.get(f"/api/library/import-records/{rec}", headers=H).json()["origin"] == "import"
    assert c2.get(f"/api/library/import-records/{rec}/image?size=original", headers=H).status_code == 200
    # the same archive into the engine that wrote it: every photo is already here
    pv3 = c.post("/api/library/import/preview", files={"file": ("x.birdcm", out.read_bytes(), archive.MIME)}, headers=H).json()
    assert pv3["summary"]["new_photos"] == 0 and pv3["summary"]["identical_photos"] == 308
    c.post("/api/library/import/apply", json={"token": pv3["token"], "expected_generation": lib.status()["generation"]}, headers=H)
    lib.rebuild()
    check_expected(lib.index(), fx)
    assert store._db().execute("SELECT count(*) FROM photo").fetchone()[0] == 2 * 308   # scan rows untouched


def test_golden_archive_imports_to_the_fixture_totals(tmp_path, monkeypatch):
    """docs/fixtures/lifelist/fixture-v1.birdcm: what iOS must read (and its own export must also produce these)."""
    c, lib = empty(tmp_path, monkeypatch)
    p = c.post("/api/library/import/preview", files={"file": ("f.birdcm", (GOLDEN / "fixture-v1.birdcm").read_bytes(), archive.MIME)},
               headers=H).json()
    assert c.post("/api/library/import/apply", json={"token": p["token"], "expected_generation": lib.status()["generation"]}, headers=H).status_code == 200
    lib.rebuild()
    check_expected(lib.index(), load())


def test_golden_ebird_bytes(tmp_path, monkeypatch):
    store, _, _ = native(tmp_path, monkeypatch)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    assert c.post("/api/library/ebird", json={}, headers=H).status_code == 422           # a fallback date needs a decision
    r = c.post("/api/library/ebird", json={"fallback": "include"}, headers=H)
    assert r.content == (GOLDEN / "ebird-v1.csv").read_bytes()
    rows = r.text.split("\n")
    assert all(len(x.split(",")) == 19 for x in rows if x) and r.text.endswith("\n") and '"' not in r.text
    est = c.post("/api/library/ebird", json={"fallback": "exclude", "use_estimates": True}, headers=H).text
    assert ",2," in est and "11/18/2026" not in est
    plan = c.get("/api/library/ebird/plan", headers=H).json()
    assert plan["checklists"] == 5 and plan["fallback_checklists"] == 1 and plan["pending_subjects_excluded"] == 3


def corrupt(src: Path, dst: Path, sql: str) -> Path:
    shutil.copy(src, dst)
    con = sqlite3.connect(dst)
    con.executescript(sql)
    con.commit()
    con.close()
    return dst


@pytest.mark.parametrize("sql, why", [
    ("UPDATE archive_blob SET original = X'00' || original WHERE rowid = 1", "一致"),
    ("PRAGMA user_version=2", "版本"),
    ("PRAGMA application_id=1", "不是观羽"),
    ("CREATE VIEW v AS SELECT 1", "不认识的对象"),
    ("CREATE TRIGGER t AFTER INSERT ON ll_asset BEGIN SELECT 1; END", "不认识的对象"),
    ("CREATE TABLE extra(x)", "表不对"),
    ("UPDATE ll_asset SET missing = 1 WHERE rowid = 1", "缺失"),
    ("UPDATE archive_meta SET value = '2' WHERE key = 'version'", "版本"),
])
def test_bad_archives_are_refused_and_change_nothing(tmp_path, monkeypatch, sql, why):
    c, lib = empty(tmp_path, monkeypatch)
    bad = corrupt(GOLDEN / "fixture-v1.birdcm", tmp_path / "bad.birdcm", sql)
    r = c.post("/api/library/import/preview", files={"file": ("bad.birdcm", bad.read_bytes(), archive.MIME)}, headers=H)
    assert r.status_code == 422 and why in r.json()["detail"], r.text
    assert lib.store._db().execute("SELECT count(*) FROM ll_record").fetchone()[0] == 0
    assert not list((tmp_path / "empty" / "data" / "import-staging").glob("*.birdcm"))


def test_not_sqlite_and_hash_mismatch(tmp_path, monkeypatch):
    c, lib = empty(tmp_path, monkeypatch)
    r = c.post("/api/library/import/preview", files={"file": ("x.birdcm", b"not a database", archive.MIME)}, headers=H)
    assert r.status_code == 422
    bad = corrupt(GOLDEN / "fixture-v1.birdcm", tmp_path / "b.birdcm",
                  "UPDATE archive_blob SET original = CAST(upper(CAST(original AS TEXT)) AS BLOB) WHERE rowid = 1")
    r = c.post("/api/library/import/preview", files={"file": ("x.birdcm", bad.read_bytes(), archive.MIME)}, headers=H)
    assert r.status_code == 422 and "校验" in r.json()["detail"]


@pytest.mark.parametrize("choice, want", [(None, 5), ("file", 3)])
def test_conflicting_edit_keeps_local_unless_chosen(tmp_path, monkeypatch, choice, want):
    store, _, _ = native(tmp_path, monkeypatch)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    obs = next(o for o in lib.index().observations("2026-01-31", "2026-01-31"))
    ref = obs["source_refs"][0]
    c.post("/api/library/subject-edit", json={"source_ref": ref, "edit": {"op": "count", "value": 3}, "expected_generation": lib.status()["generation"]}, headers=H)
    lib.rebuild()
    out = tmp_path / "a.birdcm"
    out.write_bytes(c.get("/api/library/export", headers=H).content)
    c.post("/api/library/subject-edit", json={"source_ref": ref, "edit": {"op": "count", "value": 5}, "expected_generation": lib.status()["generation"]}, headers=H)
    lib.rebuild()
    p = c.post("/api/library/import/preview", files={"file": ("a.birdcm", out.read_bytes(), archive.MIME)}, headers=H).json()
    assert len(p["conflicts"]) == 1 and p["conflicts"][0]["local"]["value"] == 5 and p["conflicts"][0]["file"]["value"] == 3
    choices = {p["conflicts"][0]["id"]: choice} if choice else {}
    r = c.post("/api/library/import/apply", json={"token": p["token"], "expected_generation": lib.status()["generation"], "choices": choices},
               headers=H).json()
    assert r["added_photos"] == 0 and r["merged_photos"] == 308 and r["pending_conflicts"] == (0 if choice else 1)
    lib.rebuild()
    assert lib.index().summary("2026-01-31", "2026-01-31")["metrics"]["estimated_count"] == want     # local by default


def test_restore_needs_full_archive_and_confirmation_and_keeps_scans(tmp_path, monkeypatch):
    store, _, _ = native(tmp_path, monkeypatch)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    p = c.post("/api/library/import/preview", files={"file": ("f.birdcm", (GOLDEN / "fixture-v1.birdcm").read_bytes(), archive.MIME)},
               headers=H).json()
    g = lib.status()["generation"]
    assert c.post("/api/library/import/apply", json={"token": p["token"], "mode": "restore", "expected_generation": g}, headers=H).status_code == 422
    r = c.post("/api/library/import/apply", json={"token": p["token"], "mode": "restore", "confirm_restore": True, "expected_generation": g},
               headers=H).json()
    assert r["safety_backup"].startswith("BirdCM-before-restore")
    lib.rebuild()
    check_expected(lib.index(), load())
    assert store._db().execute("SELECT count(*) FROM scan").fetchone()[0] == 2


def test_crop_route_cuts_the_bird_and_404s_without_the_original(tmp_path, monkeypatch):
    import io
    import os
    from PIL import Image
    from birdcm.pipeline import image_paths
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    store, _, folder = native(tmp_path, monkeypatch, rescan=False)
    c, lib = client(store, tmp_path, monkeypatch)
    lib.rebuild()
    cover = lib.index().calendar(2026)["days"]["2026-01-31"]["cover"]
    p = store.photo(int(cover["id"]))
    _, prev = image_paths(p["path"], p["size"], p["mtime_ns"])
    prev.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (400, 300), (10, 120, 60)).save(prev, "JPEG")          # the cached preview the crop is cut from
    r = c.get(cover["crop"], headers=H)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert Image.open(io.BytesIO(r.content)).size == (library.CROP, library.CROP)
    assert c.get(cover["crop"], headers=H).status_code == 200                 # cached
    other = lib.index().calendar(2026)["days"]["2026-02-01"]["cover"]
    shutil.rmtree(folder)                                                     # volume gone, nothing cached
    assert c.get(other["crop"], headers=H).status_code == 404
