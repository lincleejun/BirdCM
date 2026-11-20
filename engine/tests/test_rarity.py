import json
import sqlite3
import struct
from pathlib import Path

import pytest

from birdcm import rarity

DB = Path("/Users/outman/workspace/personal/bioclip-bird/release/rarity-us-ca-cn.sqlite")
GLOBAL = Path("/Users/outman/workspace/personal/bioclip-bird/release/rarity-global.sqlite")
FIX = Path(__file__).with_name("fixtures")


def test_region_key_label_and_point():
    assert rarity.region_key(0, 0, "美国 · 加利福尼亚州") == ("US", "California")
    assert rarity.region_key(0, 0, "日本") == ("JP", None)
    assert rarity.region_key(36.6, -121.9) == ("US", "California")           # Monterey
    assert rarity.region_key(39.9, 116.4) == ("CN", "Beijing")
    assert rarity.region_key(35.7, 139.7)[0] == "JP"                          # no divisions for Japan: country point


def test_place_list_iso_codes():
    assert rarity.label_iso("美国 · 加利福尼亚州") == "US-CA" and rarity.label_iso("日本") == "JP"
    assert rarity.label_iso("美国 · 加利福尼亚州 附近") == "US-CA" and rarity.label_iso("nowhere") is None
    assert rarity.iso_label("CN-BJ") == "中国 · 北京市"
    from birdcm import geo
    us = next(c for c in geo.catalogue() if c["code"] == "US")
    assert next(r for r in us["regions"] if r["en"] == "Alaska")["code"] == "US-AK"


@pytest.mark.skipif(not DB.is_file(), reason="rarity table not here")
def test_lookup_against_the_research_self_check():
    r = rarity.Rarity(str(DB))
    assert not r.is_global
    assert r.lookup("Anas platyrhynchos", 36.6, -121.9, None, 11)["label"] == "常见"
    assert r.lookup("Not a bird", 36.6, -121.9, None, 11)["label"] == "未知"
    assert r.lookup("Anas platyrhynchos", 35.7, 139.7, None, 11)["label"] == "数据不足"     # Japan: not in this table
    nowhere = r.lookup("Anas platyrhynchos", None, None, None, 11)
    assert nowhere["label"] == "数据不足" and nowhere["iucn"] == "LC"           # IUCN is global: shown without a place
    assert r.lookup("Anas platyrhynchos", 36.6, -121.9, None, None)["label"] == "时间未知"
    x = r.lookup("Passer montanus", None, None, "中国 · 北京市", 5)
    assert x["label"] == "常见" and x["region"] == "CN-BJ" and x["iucn"] == "LC"     # ISO codes in both tables
    assert r.lookup("Passer montanus", None, None, None, 5, code="CN-BJ")["label"] == "常见"


def test_region_at_port_matches_the_reference_points():
    """The iOS fixture's subset of the global shapes and its reference answers (made with rarity_global.region_at)."""
    r = rarity.Rarity(str(FIX / "rarity-global-test.sqlite"))
    assert r.is_global
    for p in json.loads((FIX / "global-region-reference.json").read_text()):
        assert r.region_at(p["lat"], p["lon"]) == (p["division"], p["country"]), p
    # US-CA in November: the species is in the table, the region-month has no tiers -> 数据不足, never 无记录 / rare
    x = r.lookup("Anas platyrhynchos", 33.7, -118.06, None, 11)
    assert x["label"] == "数据不足" and x["tier"] is None and x["region"] == "US-CA" and x["coverage"] == "数据不足"


POINTS = [  # bioclip-bird distill/rarity_global.py self-check: (lat, lon, division, country)
    (37.77, -122.42, "US-CA", "US"), (40.71, -74.0, "US-NY", "US"), (43.65, -79.38, "CA-ON", "CA"),
    (39.90, 116.40, "CN-BJ", "CN"), (31.23, 121.47, "CN-SH", "CN"), (-33.87, 151.21, "AU-NSW", "AU"),
    (-23.55, -46.63, "BR-SP", "BR"), (28.61, 77.21, "IN-DL", "IN"), (55.75, 37.62, "RU-MOW", "RU"),
    (-33.92, 18.42, "ZA-WC", "ZA"), (51.51, -0.13, None, "GB"), (48.86, 2.35, None, "FR"), (35.68, 139.69, None, "JP"),
    (19.43, -99.13, None, "MX"), (25.03, 121.57, None, "TW"), (22.32, 114.17, None, "HK"), (0.0, -30.0, None, None),
    (-21.11, 55.53, None, "RE"), (4.93, -52.33, None, "GF"), (78.22, 15.65, None, "SJ"), (59.91, 10.75, None, "NO"),
]


@pytest.mark.skipif(not GLOBAL.is_file(), reason="global rarity table not here")
def test_global_table_self_check_points():
    r = rarity.Rarity(str(GLOBAL))
    for lat, lon, div, country in POINTS:
        assert r.region_at(lat, lon) == (div, country), (lat, lon)
    assert r.lookup("Anas platyrhynchos", 37.77, -122.42, None, 11)["label"] == "常见"
    assert r.lookup("Anas platyrhynchos", None, None, "日本", 11)["region"] == "JP"


def ring(x0, y0, x1, y1) -> bytes:
    return struct.pack("<10f", x0, y0, x1, y0, x1, y1, x0, y1, x0, y0)


def synthetic(path: Path) -> Path:
    """A tiny global-format table: country XA with a tiered division XA-AA and a thin one XA-BB, country XB too thin."""
    db = sqlite3.connect(path)
    db.executescript("""
    CREATE TABLE regions(id INTEGER PRIMARY KEY, code TEXT UNIQUE, country TEXT, level INTEGER, name_en TEXT, name_zh TEXT);
    CREATE TABLE species(id INTEGER PRIMARY KEY, scientific TEXT UNIQUE, iucn TEXT);
    CREATE TABLE months(region_id INTEGER, month INTEGER, records INTEGER, n_species INTEGER, source_id INTEGER, coverage TEXT,
                        PRIMARY KEY(region_id, month)) WITHOUT ROWID;
    CREATE TABLE counts(region_id INTEGER, month INTEGER, species_id INTEGER, n INTEGER, tier INTEGER,
                        PRIMARY KEY(region_id, month, species_id)) WITHOUT ROWID;
    CREATE TABLE shapes(region_id INTEGER, minx REAL, miny REAL, maxx REAL, maxy REAL, pts BLOB);
    INSERT INTO regions VALUES (0,'XA','XA',0,'Xa','甲'),(1,'XA-AA','XA',1,'Aa','甲甲'),(2,'XA-BB','XA',1,'Bb','甲乙'),
                               (3,'XB','XB',0,'Xb','乙'),(4,'XA-CC','XA',1,'Cc','甲丙');
    INSERT INTO species VALUES (0,'Sterna hirundo','LC'),(1,'Ardea alba','VU');
    INSERT INTO months VALUES (0,1,9000,10,0,'tiered'),(1,1,5000,10,1,'tiered'),(2,1,10,2,0,'country'),(3,1,5,1,NULL,'数据不足');
    INSERT INTO counts VALUES (0,1,0,900,4),(0,1,1,1,1),(1,1,0,3,1);
    """)
    for rid, box in [(0, (0, 0, 10, 10)), (1, (0, 0, 5, 10)), (2, (5, 0, 10, 5)), (4, (5, 5, 10, 10)), (3, (20, 0, 30, 10))]:
        db.execute("INSERT INTO shapes VALUES (?,?,?,?,?,?)", (rid, *box, ring(*box)))
    db.commit()
    db.close()
    return path


def test_global_lookup_coverage_and_country_fallback(tmp_path):
    r = rarity.Rarity(str(synthetic(tmp_path / "g.sqlite")))
    assert r.region_at(5, 2) == ("XA-AA", "XA") and r.region_at(2, 7) == ("XA-BB", "XA") and r.region_at(5, 25) == (None, "XB")
    assert r.region_at(5.1, 10.1)[1] == "XA"                                # just off the coast: nearest vertex
    assert r.region_at(50, 50) == (None, None)
    own = r.lookup("Sterna hirundo", 5, 2, None, 1)
    assert own["label"] == "罕见" and own["coverage"] == "tiered" and own["note"] is None and own["region"] == "XA-AA"
    thin = r.lookup("Sterna hirundo", 2, 7, None, 1)                       # XA-BB: its country's month
    assert thin["label"] == "常见" and thin["coverage"] == "country" and thin["note"] == "按全国数据估计"
    norows = r.lookup("Sterna hirundo", 7, 7, None, 1)                    # XA-CC has no month rows: country fallback
    assert norows["label"] == "常见" and norows["note"] == "按全国数据估计"
    none = r.lookup("Sterna hirundo", 5, 25, None, 1)                       # XB: NULL source = 数据不足, not 无记录
    assert none["label"] == "数据不足" and none["tier"] is None
    assert r.lookup("Ardea alba", 5, 2, None, 1)["label"] == "无记录"         # in the table, no record there
    assert r.lookup("Nope nope", 5, 2, None, 1)["label"] == "未知"
    assert r.lookup("Ardea alba", None, None, None, 1, code="XA")["label"] == "罕见"
    assert r.lookup("Ardea alba", None, None, None, 1)["iucn"] == "LC"         # the bundled iucn.csv, not the table's VU


def test_place_region_falls_back_to_bundled_outlines(monkeypatch):
    monkeypatch.setattr(rarity, "table", lambda: None)
    assert rarity.place_region(36.6, -121.9) == ("US-CA", "US")
    assert rarity.place_region(35.7, 139.7) == (None, "JP")
    assert rarity.place_region(20.0, -150.0) == (None, None)


def test_global_table_is_preferred_and_digest_neutral(tmp_path, monkeypatch):
    """The manifest's global entry: absent -> the fingerprint is what it was before the entry existed; present -> it
    wins over the US/CA/CN table and does change the fingerprint (scans made before go stale)."""
    import hashlib
    from birdcm import models
    g = synthetic(tmp_path / "rarity-global.sqlite")
    sha, size = hashlib.sha256(g.read_bytes()).hexdigest(), g.stat().st_size
    base = '''
[[file]]
name = "rarity-us-ca-cn.sqlite"
role = "rarity"
optional = true
url = "https://example.invalid/r"
sha256 = "%s"
bytes = 1
''' % ("0" * 64)
    extra = f'''
[[file]]
name = "rarity-global.sqlite"
role = "rarity-global"
optional = true
neutral_when_absent = true
url = "https://example.invalid/g"
sha256 = "{sha}"
bytes = {size}
'''
    man = tmp_path / "models.toml"
    monkeypatch.setattr(models, "MANIFEST", man)
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setenv("BIRDCM_MODEL_DIR", str(tmp_path / "empty"))
    man.write_text(base)
    before = models.digest()
    man.write_text(base + extra)
    assert models.digest() == before                                          # absent: neutral
    assert rarity.table_path() is None
    monkeypatch.setenv("BIRDCM_MODEL_DIR", str(tmp_path))
    assert models.digest() != before                                          # installed: results differ, truthfully
    assert rarity.table_path() == g
    st = models.status()
    assert all(o["role"] != "rarity" for o in st["optional_missing"])        # the old table is not "missing" now


def test_iucn_is_the_bundled_table_and_can_be_switched_off(monkeypatch):
    assert rarity.iucn("Nipponia nippon") == "EN" and rarity.iucn("Passer montanus") == "LC"
    assert rarity.iucn("Antigone vipio") == "VU"                                # matched through its IUCN name Grus vipio
    assert rarity.iucn("Nope nope") is None
    from birdcm import pipeline                                                 # no rarity table installed: still shown
    sp = {"level": "species", "label": {"sci": "Nipponia nippon"}}
    assert pipeline.rarity_for(None, sp, {}) == {"tier": None, "label": "数据不足", "iucn": "EN", "region": None}
    assert set(rarity._iucn().values()) <= {"LC", "NT", "VU", "EN", "CR", "EW", "EX", "DD"}
    monkeypatch.setattr(rarity, "SHOW_IUCN", False)
    assert rarity.iucn("Nipponia nippon") is None
