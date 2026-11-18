"""The life list's derived index (docs/design-lifelist.md §3, §7; §10 'Exact deterministic fixture' and
'Desktop derivation')."""
import json
import threading
from datetime import datetime

import pytest

from birdcm import library
from lifelist_fixture import load, native, result, scan


def check_expected(ix, fx):
    for sc in fx["expected"]["scopes"]:
        m = ix.summary(sc["from"], sc["to"])
        got = {k: m["metrics"][k] for k in ("species", "observations", "estimated_count", "new_species", "active_days",
                                            "photos", "pending_subjects", "no_bird_photos")}
        want = {k: sc[k] for k in got}
        assert got == want, sc["name"]
        assert m["species_keys"] == sc["species_keys"], sc["name"]
    assert ix.first_day == fx["expected"]["first_seen"]
    groups = sorted([json.loads(g["key"]) + [g["estimate"], len(g["frames"])] for g in ix.groups.values()])
    assert groups == sorted(fx["expected"]["groups"])
    assert ix.summary()["coverage"]["fallback_date_photos"] == fx["expected"]["fallback_date_photos"]


def test_shared_vectors():
    v = load()["vectors"]
    for lat, lon, code, want in v["place_key"]:
        assert library.place_key(lat, lon, code) == want, (lat, lon)
    for text, day, off in v["local_day"]:
        got = library.parse_wall(text)
        assert (got[2] if got else None) == day and (got[1] if got else None) == off, text
    for sci, day, pk, want in v["group_key"]:
        assert library.group_key(sci, day, pk) == want


def test_fixture_as_native_scans(tmp_path, monkeypatch):
    fx = load()
    store, lib, _ = native(tmp_path, monkeypatch)
    lib.rebuild()
    check_expected(lib.index(), fx)


@pytest.mark.parametrize("tz", ["America/Los_Angeles", "Asia/Tokyo"])
def test_fixture_does_not_depend_on_this_machines_zone(tmp_path, monkeypatch, tz):
    import time
    monkeypatch.setenv("TZ", tz)
    time.tzset()
    try:
        store, lib, _ = native(tmp_path, monkeypatch)
        lib.rebuild()
        check_expected(lib.index(), load())
    finally:
        monkeypatch.delenv("TZ")
        time.tzset()


def test_rescan_and_rebuild_from_empty_are_identical(tmp_path, monkeypatch):
    store, lib, folder = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    before = lib.index().summary()
    rows = lib.index().rows
    store._write(lambda db: db.execute("DELETE FROM ll_evidence"))     # the index is disposable
    lib.rebuild()
    assert [{k: r[k] for k in r if k != "updated_utc"} for r in lib.index().rows] == \
           [{k: r[k] for k in r if k != "updated_utc"} for r in rows]
    files = [(p["path"], p["size"], p["mtime_ns"]) for p in store.snapshot(1)["photos"]]
    res = {p["path"]: p["result"] for p in store.snapshot(1)["photos"]}
    scan(store, str(folder), files, res, 1.8e9)                         # same folder again: same counts
    lib.rebuild()
    assert lib.index().summary() == before
    n_photo = store._db().execute("SELECT count(*) FROM photo").fetchone()[0]
    assert n_photo == 2 * 308                                           # source rows never multiplied by the index


def test_failed_or_running_rescan_keeps_the_last_completed(tmp_path, monkeypatch):
    store, lib, folder = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    before = lib.index().summary()["metrics"]
    files = [(p["path"], p["size"], p["mtime_ns"]) for p in store.snapshot(1)["photos"]][:5]
    res = {p["path"]: p["result"] for p in store.snapshot(1)["photos"]}
    scan(store, str(folder), files, res, 1.8e9, state="failed")
    scan(store, str(folder), files, res, 1.8e9, state="running")
    lib.rebuild()
    assert lib.index().summary()["metrics"] == before
    scan(store, str(folder), files, res, 1.8e9)                        # a completed re-scan with 5 files left
    lib.rebuild()
    assert lib.index().summary()["metrics"]["photos"] == 5             # removed files leave the life list


def test_parent_and_child_scopes_and_singles_count_each_photo_once(tmp_path, monkeypatch):
    store, lib, folder = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    before = lib.index().summary()["metrics"]
    snap = store.snapshot(1)["photos"]
    files = [(p["path"], p["size"], p["mtime_ns"]) for p in snap]
    res = {p["path"]: p["result"] for p in snap}
    scan(store, str(folder), files, res, 1.8e9, recursive=True)        # an overlapping scope of the same files
    # a copy of one photo (same bytes, other path) as a single photo
    sd = tmp_path / "singles"
    sd.mkdir()
    (sd / "copy.jpg").write_bytes(open(snap[0]["path"], "rb").read())
    sid = store.add_single("copy.jpg", "copy.jpg", None)
    store.update_single(sid, result=snap[0]["result"], subject=0)
    lib.rebuild()
    assert lib.index().summary()["metrics"] == before


def test_corrections_outrank_the_model_and_rejected_quality(tmp_path, monkeypatch):
    fx = load()
    store, lib, folder = native(tmp_path, monkeypatch, rescan=False)
    snap = {p["path"].rsplit("/", 1)[1]: p for p in store.snapshot(1)["photos"]}
    # the no-bird photo: the person says it is a Great Egret (a rejected photo with a human correction counts)
    store.set_corrections([snap["no-bird-nov18-1.jpg"]["id"]], fx["species"]["B"], "one")
    # the genus photo: corrected to a species; the uncertain one: explicitly 不确定 (NULL correction) stays pending
    store.set_corrections([snap["genus-jan1-1.jpg"]["id"]], fx["species"]["A"], "one")
    store.set_corrections([snap["uncertain-jan1-1.jpg"]["id"]], None, "one")
    # the two-bird December frame: the first frame's subject box corrected to B -> 1 A + 1 B that day
    store.set_corrections([snap["A-P-dec31-1.jpg"]["id"]], fx["species"]["B"], "one")
    lib.rebuild()
    ix = lib.index()
    dec = ix.summary("2025-12-01", "2025-12-31")["metrics"]
    assert (dec["species"], dec["observations"], dec["estimated_count"]) == (2, 2, 2)
    nov = ix.summary("2026-11-01", "2026-11-30")["metrics"]
    assert nov["species"] == 2 and nov["no_bird_photos"] == 0
    jan = ix.summary("2026-01-01", "2026-01-31")["metrics"]
    assert jan["pending_subjects"] == 1                               # genus resolved, uncertain still pending
    assert ix.first_day[fx["species"]["B"]] == "2025-12-31"            # first seen moves back with the correction


def test_subject_edits_count_exclude_and_group_override(tmp_path, monkeypatch):
    store, lib, _ = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    ix = lib.index()
    dec = next(g for g in ix.groups.values() if g["day"] == "2025-12-31")
    r = dec["rows"][0]
    edit = library.check_edit({"op": "count", "value": 5}, {})
    store._write(lambda db: library.write_subject_edit(db, r["asset_hash"], r["subject_id"], edit, json.loads(r["box_json"])))
    lib.rebuild()
    assert lib.index().summary("2025-12-01", "2025-12-31")["metrics"]["estimated_count"] == 6   # 5 + 1 in that frame
    burst = next(g for g in lib.index().groups.values() if g["day"] == "2026-01-01" and g["sci"] == "Sterna hirundo")
    top = burst["rows"][0]
    store._write(lambda db: library.write_subject_edit(db, top["asset_hash"], top["subject_id"],
                                                       library.check_edit({"op": "count", "value": 4}, {}), None))
    lib.rebuild()
    burst = lib.index().groups[burst["key"]]
    assert burst["estimate"] == 4                                     # the largest frame, not a sum of 300
    store._write(lambda db: library.write_subject_edit(db, top["asset_hash"], top["subject_id"],
                                                       library.check_edit({"op": "exclude", "value": True}, {}), None))
    lib.rebuild()
    assert lib.index().groups[burst["key"]]["estimate"] == 1           # removing the highest frame lowers the max
    store._write(lambda db: library.write_group_edit(db, burst["key"], 3))
    assert lib.index().groups[burst["key"]]["estimate"] == 3 and lib.index().groups[burst["key"]]["estimate_source"] == "edit"
    with pytest.raises(ValueError):
        library.check_edit({"op": "count", "value": 0}, {})
    with pytest.raises(ValueError):
        library.check_edit({"op": "species", "state": "species", "key": "Nope"}, {"A b": {}})


def test_photo_wide_date_and_place_edits_regroup(tmp_path, monkeypatch):
    store, lib, _ = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    nov = next(g for g in lib.index().groups.values() if g["day"] == "2026-11-18")
    h = nov["rows"][0]["asset_hash"]
    store._write(lambda db: library.write_subject_edit(db, h, "photo", library.check_edit(
        {"op": "date", "value": {"wall": "2026-01-31T10:00:00", "offset_min": -480}}, {}), None))
    store._write(lambda db: library.write_subject_edit(db, h, "photo", library.check_edit(
        {"op": "place", "value": {"source": "map", "lat": 10.145, "lon": 20.145, "label": "Q", "region_code": None}}, {}), None))
    lib.rebuild()
    ix = lib.index()
    assert ix.summary("2026-11-01", "2026-11-30")["metrics"]["observations"] == 0
    assert ix.summary("2026-01-01", "2026-01-31")["metrics"]["observations"] == 3      # merged into A/Q Jan 31
    q = next(g for g in ix.groups.values() if g["day"] == "2026-01-31")
    assert len(q["frames"]) == 2 and ix.summary()["coverage"]["fallback_date_photos"] == 0


def test_mutation_during_rebuild_keeps_dirty_and_failed_swap_rolls_back(tmp_path, monkeypatch):
    store, lib, _ = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    gen = lib.status()["generation"]
    real = lib._derive

    def slow(src, hashes):
        store._write(library.touch)                                    # a correction lands while we derive
        return real(src, hashes)
    monkeypatch.setattr(lib, "_derive", slow)
    lib.rebuild()
    st = lib.status()
    assert st["generation"] == gen + 1 and st["updating"]               # swapped, but still dirty: rebuild again
    monkeypatch.setattr(lib, "_derive", lambda s, h: [{**c, "source_kind": "bogus"} for c in real(s, h)])
    with pytest.raises(Exception):
        lib.rebuild()                                                   # CHECK constraint: the swap rolls back
    assert lib.status()["generation"] == gen + 1 and len(lib.index().rows) == 308 + 309      # photos + subjects


def test_unmounted_volume_keeps_cached_hashes(tmp_path, monkeypatch):
    store, lib, folder = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    before = lib.index().summary()["metrics"]
    import shutil
    shutil.move(str(folder), str(tmp_path / "gone"))                    # the volume is not mounted
    store._write(library.touch)
    lib.rebuild()
    assert lib.index().summary()["metrics"] == before


def test_originals_untouched(tmp_path, monkeypatch):
    store, lib, folder = native(tmp_path, monkeypatch, rescan=False)
    before = {f.name: (f.stat().st_mtime_ns, f.read_bytes()) for f in folder.iterdir()}
    lib.rebuild()
    assert {f.name: (f.stat().st_mtime_ns, f.read_bytes()) for f in folder.iterdir()} == before


def test_store_marks_dirty_and_keeps_a_future_schema(tmp_path):
    from birdcm.store import Store
    s = Store(tmp_path / "a.db")
    db = s._db()
    assert db.execute("PRAGMA user_version").fetchone()[0] == 1 and library.meta(db, "dirty") == "1"
    db.execute("PRAGMA user_version=2")
    s2 = Store(tmp_path / "a.db")
    assert not s2.library_ok and s2._db().execute("PRAGMA user_version").fetchone()[0] == 2


def test_calendar_cover_is_the_latest_eligible_bird(tmp_path, monkeypatch):
    rows = [{"eligible": 1, "capture_wall": "2026-01-01T08:00:00", "asset_hash": "b", "subject_id": "1"},
            {"eligible": 1, "capture_wall": "2026-01-01T09:00:00", "asset_hash": "a", "subject_id": "1"},
            {"eligible": 1, "capture_wall": "2026-01-01T09:00:00", "asset_hash": "a", "subject_id": "2"},
            {"eligible": 0, "capture_wall": "2026-01-01T23:00:00", "asset_hash": "z", "subject_id": "9"},
            {"eligible": 1, "capture_wall": None, "asset_hash": "zz", "subject_id": "9"}]
    assert library.cover_of(rows) is rows[2]                         # wall time, then hash, then subject id
    store, lib, _ = native(tmp_path, monkeypatch, rescan=False)
    lib.rebuild()
    cal = lib.index().calendar(2026)
    jan1 = cal["days"]["2026-01-01"]
    assert (jan1["observations"], jan1["species"]) == (2, 2)
    assert jan1["cover"]["sci"] == "Ardea alba" and jan1["cover"]["crop"].startswith("/api/library/crop?")   # 00:30 > 00:02
    assert cal["months"][0]["species"] == 2 and cal["months"][0]["observations"] == 3 and cal["months"][2]["cover"] is None
    assert cal["days"]["2026-11-18"]["cover"]["sci"] == "Sterna hirundo"   # a fallback-dated bird (no wall time) still covers
