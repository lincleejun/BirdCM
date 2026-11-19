"""Place names for points: "Orange County · Inner Bolsa Bay" instead of "33.70, -118.05" (owner, 2026-11-18).

Offline at once: the region the point is in (rarity.place_region, the one point -> region mapping), in English
("California · United States"). Online once per rounded point (0.01°, about 1 km): OpenStreetMap Nominatim's reverse
geocoding in English, its natural-feature / POI layer at zoom 14 (a valley, a bay, a creek; never a street address),
cached in the engine database (table place_name: derived, rebuildable, no part of any export). The lookups run on one
background thread, one at a time, at most one a second shared with the place search (app.places_search), so a page
never waits; it shows the offline name until the online one is cached. Only the rounded coordinates leave the machine.
Setting: online.json "places" (用网络显示地名), default on; off = no requests, cached names still shown.
"""
from __future__ import annotations

import json
import threading
import time
import urllib.parse
import urllib.request
from collections import deque

REVERSE = "https://nominatim.openstreetmap.org/reverse"
UA = "BirdCM/0.1 (open-source local bird photo culling app)"
LOCK = threading.Lock()                     # one Nominatim request at a time, search and reverse alike
LAST = [0.0]                                # monotonic time of the last request start
GAP = 1.0                                   # seconds between requests (Nominatim usage policy)
PAUSE = 60.0                                # after a network error: the queue is dropped, nothing asked for a minute
FEATURES = {"natural", "waterway", "leisure", "boundary", "tourism", "landuse", "water"}
LOCALITY = ("city", "town", "village", "hamlet", "municipality", "district", "county")
AREA = ("state", "province", "region", "country")


def key(lat: float, lon: float) -> str:
    return f"{round(float(lat), 2):.2f},{round(float(lon), 2):.2f}"


def offline(lat: float, lon: float) -> str | None:
    """The region the point is in, English: "California · United States"; None on open sea."""
    from birdcm import rarity
    div, country = rarity.place_region(lat, lon)
    return region_text(div, country)


def region_text(div: str | None, country: str | None = None) -> str | None:
    from birdcm import rarity
    country = country or (div[:2] if div else None)
    names = [(rarity.region_names(c) or (None,))[0] for c in (div, country) if c]
    return " · ".join(dict.fromkeys(n for n in names if n)) or None


def compose(js: dict | None) -> str | None:
    """Nominatim jsonv2 -> "locality · feature" ("state · feature" without a locality, "locality · state" without a feature), names as returned (English
    where OSM has one, else the local name). Only whitelisted address parts: never a road, house number or postcode.
    No result (open sea: {"error": ...}) -> None."""
    if not isinstance(js, dict) or "error" in js:
        return None
    a = js.get("address") or {}
    feature = js.get("name") if js.get("category") in FEATURES else None
    locality = next((a[k] for k in LOCALITY if a.get(k)), None)
    area = next((a[k] for k in AREA if a.get(k)), None)
    return " · ".join(p for p in dict.fromkeys((locality or area, feature or area)) if p) or None


def request(k: str) -> urllib.request.Request:
    lat, lon = k.split(",")
    q = urllib.parse.urlencode({"format": "jsonv2", "lat": lat, "lon": lon, "zoom": 14, "layer": "natural,poi",
                                "addressdetails": 1, "accept-language": "en"})
    return urllib.request.Request(f"{REVERSE}?{q}", headers={"User-Agent": UA})


def _fetch(req: urllib.request.Request) -> dict:
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.load(r)


class Names:
    """The cache table and the one background lookup thread (started by the app's lifespan only, so tests and tools
    never reach the network unless they call step() with their own fetch)."""

    def __init__(self, store, fetch=_fetch, clock=time.monotonic, sleep=time.sleep) -> None:
        self.store, self.fetch, self.clock, self.sleep = store, fetch, clock, sleep
        self.todo: deque[str] = deque()
        self.cv = threading.Condition()
        self.running = False

    def cached(self, k: str) -> tuple[str | None] | None:
        try:
            r = self.store._db().execute("SELECT label FROM place_name WHERE key = ?", (k,)).fetchone()
        except Exception:  # noqa: BLE001 - a closed / older database: no cache, the offline name stands
            return None
        return (r[0],) if r else None

    def name(self, lat: float, lon: float) -> dict:
        """{label, online, pending}: the cached online name, else the offline one (and the point queued)."""
        from birdcm import online
        k = key(lat, lon)
        hit = self.cached(k)
        if hit and hit[0]:
            return {"label": hit[0], "online": True, "pending": False}
        pending = False
        if hit is None and self.running and online.settings()["places"]:
            with self.cv:
                if k not in self.todo and len(self.todo) < 1000:
                    self.todo.append(k)
                    self.cv.notify()
                pending = True
        return {"label": offline(lat, lon), "online": False, "pending": pending}

    def step(self) -> None:
        """Ask Nominatim about the oldest queued point (paced); a result or "nothing here" is cached, an error drops
        the queue and pauses (the points are queued again when shown)."""
        with self.cv:
            if not self.todo:
                return
            k = self.todo[0]
        try:
            with LOCK:
                wait = GAP - (self.clock() - LAST[0])
                if wait > 0:
                    self.sleep(wait)
                LAST[0] = self.clock()
                label = compose(self.fetch(request(k)))
            self.store._write(lambda db: db.execute("INSERT OR REPLACE INTO place_name VALUES (?, ?, ?)", (k, label, time.time())))
            with self.cv:
                if self.todo and self.todo[0] == k:
                    self.todo.popleft()
        except Exception:  # noqa: BLE001 - offline, 429, timeout: not cached as "nothing here"
            with self.cv:
                self.todo.clear()
            self.sleep(PAUSE)

    def start(self) -> None:
        if self.running:
            return
        self.running = True

        def loop():
            while True:
                with self.cv:
                    while not self.todo:
                        self.cv.wait()
                self.step()
        threading.Thread(target=loop, name="place-names", daemon=True).start()


_names: list[Names] = []


def use(store) -> Names:
    """The app's instance (one engine database per process)."""
    _names[:] = [Names(store)]
    return _names[0]


def name(lat: float, lon: float) -> dict:
    return _names[0].name(lat, lon) if _names else {"label": offline(lat, lon), "online": False, "pending": False}


def cached_label(lat: float, lon: float) -> str | None:
    hit = _names[0].cached(key(lat, lon)) if _names else None
    return hit[0] if hit else None


def clear(store) -> None:
    store._write(lambda db: db.execute("DELETE FROM place_name"))
