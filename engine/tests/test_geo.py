import numpy as np
import pytest

from birdcm import geo


def test_week_of():
    assert geo.week_of("2026-11-14T09:25:11.767-08:00") == 42
    assert geo.week_of("2026-01-01") == 1 and geo.week_of("2026-12-31") == 48 and geo.week_of("2026-02-09") == 6
    assert geo.week_of(None) is None and geo.week_of("garbage!!!") is None and geo.week_of("2026-13-01") is None


def test_place_photo_gps_wins_then_region_then_nothing():
    assert geo.place([37.7, -122.4], "美国 · 加利福尼亚州") == (37.7, -122.4, "photo")
    lat, lon, src = geo.place(None, "美国 · 加利福尼亚州")
    assert src == "region" and 32 < lat < 42 and -125 < lon < -114
    assert geo.place(None, "中国 · 云南省")[2] == "region"
    assert geo.place(None, "美国 · 其他")[:2] == geo.place(None, "美国")[:2]         # unknown division: the country's point
    assert geo.place(None, "Atlantis") is None and geo.place(None, None) is None
    assert geo.place([95, 0], None) is None                                    # invalid GPS ignored
    assert geo.place(None, "日本")[2] == "region" and geo.place(None, "Japan")[2] == "region"


def test_location_precedence_and_validation():
    pin = {"lat": 36.6, "lon": -121.9, "label": "Monterey", "source": "map"}
    assert geo.place([10.0, 20.0], pin) == (10.0, 20.0, "photo")                # photo GPS > chosen point
    assert geo.place(None, pin) == (36.6, -121.9, "map")                         # chosen point > region centroid
    assert geo.place(None, {**pin, "source": "device"})[2] == "device"
    bad = {"lat": 120, "lon": 0, "label": "美国 · 加利福尼亚州"}                   # bad point: falls back to its label
    assert geo.place(None, bad)[2] == "region"
    assert geo.place(None, {"lat": float("nan"), "lon": 0}) is None
    assert geo.place(None, {"lat": True, "lon": 0}) is None


def test_snap_and_fingerprint_key():
    assert geo.snap(36.61, -121.92) == (36.6, -121.9)
    assert geo.snap(36.6, -121.9) == geo.snap(36.6009, -121.9009)               # a pin nudged by ~100 m: same point
    assert geo.snap(0, 180) == (0, -180.0) and geo.snap(0, -180) == (0, -180.0)  # antimeridian wraps
    assert geo.snap(90, 10)[0] == 90 and geo.snap(-90, 10)[0] == -90             # poles stay on the map
    a = geo.fingerprint_key({"lat": 36.6, "lon": -121.9, "label": "A"})
    assert a == geo.fingerprint_key({"lat": 36.601, "lon": -121.899, "label": "B", "source": "device"}) == [36.6, -121.9]
    assert geo.fingerprint_key(None) is None
    assert geo.fingerprint_key("美国 · 加利福尼亚州") == list(geo.snap(*geo.region_point("美国 · 加利福尼亚州")))


def test_catalogue_is_global():
    cat = geo.catalogue()
    assert len(cat) > 190 and all(c["zh"] and c["en"] and geo.valid(c["lat"], c["lon"]) for c in cat)
    assert {c["code"] for c in cat} >= {"US", "CN", "CA", "BR", "AU", "JP", "KE", "GB", "IN"}
    us = next(c for c in cat if c["code"] == "US")
    assert len(us["regions"]) == 51 and next(c for c in cat if c["code"] == "JP")["regions"] == []


def test_regions_table_complete():
    r = geo.regions()
    assert len(r["美国"]) == 51 and len(r["加拿大"]) == 13 and len(r["中国"]) == 31


def test_posterior_formula_and_fallbacks():
    pv = np.array([0.6, 0.3, 0.1])
    assert geo.posterior(pv, None) is pv                                        # no place: unchanged
    pg = np.array([0.0, 1.0, 0.5])                                             # species 0 absent here (or not listed)
    post = geo.posterior(pv, pg)
    want = pv * (geo.FLOOR + pg)
    assert post == pytest.approx(want / want.sum()) and post.argmax() == 1 and post[0] > 0
    assert geo.posterior(np.zeros(3), pg).sum() == 0                            # nothing to renormalise: left alone
