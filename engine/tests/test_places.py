"""Place names (places.py): label composition from recorded Nominatim answers, the offline region name, the cache,
the 1/s pace, the setting. No network: fetch is a stub over fixtures/nominatim/ (recorded 2026-11-18, zoom 14,
layer=natural,poi, accept-language=en)."""
import json
from pathlib import Path

import pytest

from birdcm import places, rarity
from birdcm.store import Store

FIX = Path(__file__).parent / "fixtures" / "nominatim"


def fx(name: str) -> dict:
    return json.loads((FIX / f"{name}.json").read_text())


def test_compose_from_recorded_answers():
    assert places.compose(fx("bolsa-bay")) == "Orange County · Inner Bolsa Bay"           # county, natural water
    assert places.compose(fx("cupertino-stevens-creek")) == "Cupertino · Stevens Creek"   # city, waterway
    assert places.compose(fx("hong-kong")) == "Hong Kong · Glenealy Ravine"
    assert places.compose(fx("hunan-local-name")) == "Hunan · 浏阳河"          # no English name in OSM: the local one as is
    assert places.compose(fx("ocean")) is None                                 # {"error": "Unable to geocode"}
    # a road answer: the road is never used, the locality and state are
    assert places.compose(fx("road-only")) == "New York"                     # city New York, state New York: once


def test_compose_missing_fields():
    assert places.compose({"category": "natural", "name": "Great Basin", "address": {"county": "Eureka County"}}) == "Eureka County · Great Basin"
    assert places.compose({"category": "highway", "name": "Main St", "address": {"road": "Main St", "state": "Nevada"}}) == "Nevada"
    assert places.compose({"category": "amenity", "name": "Cafe", "address": {"house_number": "1", "postcode": "1"}}) is None
    assert places.compose({"address": {"country": "Japan"}}) == "Japan"
    assert places.compose(None) is None and places.compose([]) is None


def test_offline_region_name_is_english(monkeypatch):
    monkeypatch.setattr(rarity, "table", lambda: None)                         # the bundled outlines
    assert places.offline(36.6, -121.9) == "California · United States"
    assert places.offline(35.7, 139.7) == "Japan"
    assert places.offline(20.0, -150.0) is None                                # open sea
    assert places.region_text("US-CA") == "California · United States" and places.region_text(None) is None


@pytest.fixture
def names(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setattr(rarity, "table", lambda: None)
    seen, slept, now = [], [], [100.0]
    answers = {"33.70,-118.05": fx("bolsa-bay"), "0.00,-150.00": fx("ocean")}

    def fetch(req):
        seen.append((now[0], req.full_url, req.get_header("User-agent")))
        k = next((k for k in answers if f"lat={k.split(',')[0]}&lon={k.split(',')[1]}" in req.full_url), None)
        if k is None:
            raise OSError("offline")
        return answers[k]

    def sleep(s):
        slept.append(s)
        now[0] += s
    monkeypatch.setattr(places, "LAST", [0.0])
    n = places.Names(Store(tmp_path / "data" / "t.db"), fetch=fetch, clock=lambda: now[0], sleep=sleep)
    n.running = True                                                           # queue, but no thread: tests call step()
    return n, seen, slept


def test_cache_once_per_rounded_point_and_pace(names):
    n, seen, slept = names
    first = n.name(33.7012, -118.0498)
    assert first == {"label": "California · United States", "online": False, "pending": True}   # offline at once
    assert n.name(33.6988, -118.0461)["pending"] and len(n.todo) == 1          # same ~1 km cell: queued once
    n.name(0.001, -149.999)
    n.step()
    n.step()
    assert len(seen) == 2 and seen[1][0] - seen[0][0] >= places.GAP            # one a second
    assert "lat=33.70&lon=-118.05" in seen[0][1] and "accept-language=en" in seen[0][1] and "zoom=14" in seen[0][1]
    assert seen[0][2].startswith("BirdCM/")                                    # a generic UA, no personal details
    assert n.name(33.70, -118.05) == {"label": "Orange County · Inner Bolsa Bay", "online": True, "pending": False}
    assert n.name(0.0, -150.0) == {"label": None, "online": False, "pending": False}   # "nothing here" cached too
    n.step()
    assert len(seen) == 2                                                      # nothing asked twice


def test_network_error_not_cached_and_pauses(names):
    n, seen, slept = names
    n.name(10.0, 10.0)
    n.name(33.70, -118.05)
    n.step()                                                                   # offline: queue dropped, a pause
    assert not n.todo and slept[-1] == places.PAUSE and n.cached("10.00,10.00") is None
    assert n.name(10.0, 10.0)["pending"]                                       # asked again when shown again


def test_setting_off_asks_nothing_but_shows_cached(names):
    from birdcm import online
    n, seen, _ = names
    n.name(33.70, -118.05)
    n.step()
    online.set_settings(places=False)
    assert online.settings()["places"] is False
    assert n.name(0.0, -150.0)["pending"] is False and not n.todo
    assert n.name(33.70, -118.05)["label"] == "Orange County · Inner Bolsa Bay"
    places.clear(n.store)
    assert n.name(33.70, -118.05) == {"label": "California · United States", "online": False, "pending": False}


def test_not_running_never_queues(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    n = places.Names(Store(tmp_path / "t.db"), fetch=lambda req: pytest.fail("network"))
    assert n.name(33.70, -118.05)["pending"] is False and not n.todo


def test_api_place_name_region_point_and_setting(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from birdcm.app import create_app
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setattr(rarity, "table", lambda: None)
    store = Store(tmp_path / "data" / "t.db")
    guarded, _ = create_app(8798, token="tok", store=store, start_scheduler=False)       # no worker: nothing asked
    c, h = TestClient(guarded, base_url="http://127.0.0.1:8798"), {"host": "127.0.0.1:8798"}
    assert c.get("/api/places/name?lat=36.6&lon=-121.9", headers=h).json() == {"label": "California · United States", "online": False, "pending": False}
    assert c.get("/api/places/name?code=US-CA", headers=h).json()["label"] == "California · United States"
    assert c.get("/api/places/name", params={"label": "美国 · 加利福尼亚州"}, headers=h).json()["label"] == "California · United States"
    assert c.get("/api/places/name?lat=99&lon=0", headers=h).status_code == 422
    store._write(lambda db: db.execute("INSERT INTO place_name VALUES ('36.60,-121.90', 'Monterey · Monterey Bay', 0)"))
    assert c.get("/api/places/name?lat=36.6&lon=-121.9", headers=h).json()["label"] == "Monterey · Monterey Bay"
    w = {**h, "x-birdcm-token": "tok"}
    assert c.post("/api/online/settings", json={"places": False}, headers=w).json()["places"] is False
    assert c.post("/api/online/settings", json={"places": "no"}, headers=w).status_code == 422
    c.delete("/api/online/cache", headers=w)                                    # the cached names go with the cache
    assert c.get("/api/places/name?lat=36.6&lon=-121.9", headers=h).json()["label"] == "California · United States"
