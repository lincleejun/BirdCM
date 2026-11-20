"""Bird Value: the owner's scoreBird (birdcm/value.py, docs/bird-value.md)."""
import sqlite3
import threading
from types import SimpleNamespace

from birdcm import value


def test_tanh_score_range_and_shape():
    assert abs(value.tanh_score(0) - 1) < 1e-9 and abs(value.tanh_score(1) - 10) < 1e-9
    qs = [i / 20 for i in range(21)]
    s = [value.tanh_score(q) for q in qs]
    assert all(a < b for a, b in zip(s, s[1:]))
    assert value.tanh_score(-1) == value.tanh_score(0) and value.tanh_score(2) == value.tanh_score(1)


def test_score_paths():
    common = {"G": 0, "C": 0, "L": 0.1, "N": 0.1, "T": 0, "H": 0}
    assert value.score(common)["regional"] < 2
    # a globally common bird can still be top locally (the design's max(): regional path)
    vagrant = {"G": 0, "C": 0, "L": 1, "N": 1, "T": 1, "H": 1}
    assert value.score(vagrant)["regional"] > 9.5
    # a globally precious bird keeps its value where it is locally common (species path)
    precious = {"G": 1, "C": 1, "L": 0, "N": 0, "T": 0, "H": 0}
    assert value.score(precious)["regional"] > 9
    # no place: the species base only
    out = value.score({"G": 0.5, "C": 0.5})
    assert out["regional"] is None and out["status"] == "insufficient-data" and 1 <= out["base"] <= 10


def _table():
    db = sqlite3.connect(":memory:", check_same_thread=False)
    db.executescript("""
        CREATE TABLE regions(id INTEGER PRIMARY KEY, code TEXT, country TEXT, level INTEGER, name_en TEXT, name_zh TEXT);
        CREATE TABLE species(id INTEGER PRIMARY KEY, scientific TEXT, iucn TEXT);
        CREATE TABLE months(region_id INTEGER, month INTEGER, records INTEGER, n_species INTEGER, source_id INTEGER, coverage TEXT);
        CREATE TABLE counts(region_id INTEGER, month INTEGER, species_id INTEGER, n INTEGER, tier INTEGER);
        INSERT INTO regions VALUES (1, 'US', 'US', 0, '', ''), (2, 'US-CA', 'US', 1, '', ''), (3, 'CN', 'CN', 0, '', '');
        INSERT INTO species VALUES (1, 'Common bird', 'LC'), (2, 'Far bird', 'LC');
    """)
    for rid in (1, 2, 3):
        db.executemany("INSERT INTO months VALUES (?, ?, 100000, 0, ?, 'tiered')", [(rid, m, rid) for m in range(1, 13)])
    db.executemany("INSERT INTO counts VALUES (?, ?, 1, 5000, 4)", [(rid, m) for rid in (1, 2) for m in range(1, 13)])
    db.executemany("INSERT INTO counts VALUES (3, ?, 2, 5000, 4)", [(m,) for m in range(1, 13)])
    return SimpleNamespace(db=db, lock=threading.Lock())


def test_no_records_is_not_a_top_score():
    t = _table()
    assert value.value(t, "Common bird", "US-CA", 11)["status"] == "estimated"
    # never recorded in California: search says insufficient data, never a 9 by default
    search = value.value(t, "Far bird", "US-CA", 11)
    assert search["status"] == "insufficient-data" and search["regional"] is None
    # photographed there: valued at the floor share, but pending until the owner confirms it
    photo = value.value(t, "Far bird", "US-CA", 11, photo=True)
    assert photo["status"] == "pending" and photo["regional"] > 8
    assert value.value(t, "Unknown bird", "US-CA", 11) is None


def test_grid_cell_and_china_protection():
    t = _table()
    lat, lon = 37.32, -122.03
    t.db.executescript(f"""
        CREATE TABLE grid(cell INTEGER PRIMARY KEY, records INTEGER);
        CREATE TABLE grid_counts(cell INTEGER, species_id INTEGER, n INTEGER);
        INSERT INTO grid VALUES ({value.cell_id(lat, lon)}, 1000000);
        INSERT INTO grid_counts VALUES ({value.cell_id(lat, lon)}, 1, 3);
    """)
    # common in the state, 3 records in a million in this cell: the cell decides, so it scores high
    state = value.value(t, "Common bird", "US-CA", 11)["regional"]
    cell = value.value(t, "Common bird", "US-CA", 11, lat=lat, lon=lon)
    assert cell["regional"] > 8 > state and cell["features"]["L"] > 0.6
    # 国家一级 raises C in China only (Haliaeetus albicilla is grade 1 in data/cn_protected_birds.tsv)
    assert value.CN_GRADE["Haliaeetus albicilla"] == 1
    t.db.execute("UPDATE species SET scientific = 'Haliaeetus albicilla' WHERE id = 2")
    assert value.value(t, "Haliaeetus albicilla", "CN", 11)["features"]["C"] == 1.0
