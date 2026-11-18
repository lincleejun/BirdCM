"""Location prior: how likely each of the 11,172 AviList species is at a place and week, from the BirdNET+ geo model
3.0 (ONNX, CC BY-NC-SA 4.0, downloaded). Ported slimly from gardener's adapters/geo.py:

  posterior = p_visual * (FLOOR + p_geo), renormalised over the whole list   (before top-5 and the naming level)

- place, in this order: the photo's own GPS; else the scan's / single photo's chosen point (from the map, the device,
  or the representative point of a chosen country or first-level division: data/countries.csv, data/regions.csv,
  hand-entered approximate centres, ±1-2°); else no prior (posterior = p_visual). Points are snapped to a 0.05° grid
  (GRID) before the prior is asked: the geo model is a smooth function of lat/lon, and within ±0.05° its values move
  by at most 0.04 (median 0.014, measured at 8 places), so a pin nudged by 100 m changes nothing, and the scan
  fingerprint uses the same snapped point.
- week: BirdNET's 48-week calendar from the capture date; no date -> the whole year (max over the 48 weeks, what the
  birdnet package does for week=None).
- species the geo model does not list (744 of 11,172; data/avilist-birdnet-geo3.csv, from gardener's AviList map):
  p_geo = 0, so they keep only FLOOR x their visual score (gardener's "zero" policy for birds). A lumped row takes the
  largest of its labels.
Not ported: gardener's split-range table and its range veto (rules.RANGE_EPS). ponytail: add them if a split pair
shows up wrong in practice.
"""
from __future__ import annotations

import csv
from functools import lru_cache
from pathlib import Path

import numpy as np

FLOOR = 0.02
DATA = Path(__file__).with_name("data")
REGIONS = DATA / "regions.csv"
COUNTRIES = DATA / "countries.csv"
GRID = 0.05
INDEX = DATA / "avilist-birdnet-geo3.csv"


def week_of(taken_at: str | None) -> int | None:
    """BirdNET's 48-week calendar: four weeks per month, days 1-8 / 9-16 / 17-24 / 25-31; None when unknown."""
    if not taken_at or len(taken_at) < 10:
        return None
    try:
        month, day = int(taken_at[5:7]), int(taken_at[8:10])
    except ValueError:
        return None
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        return None
    return (month - 1) * 4 + min(3, (day - 1) // 8) + 1


@lru_cache(maxsize=1)
def regions() -> dict[str, dict[str, tuple[float, float]]]:
    """country -> {region display name: (lat, lon)}, in file order."""
    out: dict[str, dict[str, tuple[float, float]]] = {}
    with open(REGIONS, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            out.setdefault(r["country"], {})[r["region"]] = (float(r["lat"]), float(r["lon"]))
    return out


@lru_cache(maxsize=1)
def countries() -> list[dict]:
    """Every country / territory: {code, zh, en, lat, lon}, in file order."""
    with open(COUNTRIES, newline="", encoding="utf-8") as f:
        return [{**r, "lat": float(r["lat"]), "lon": float(r["lon"])} for r in csv.DictReader(f)]


def catalogue() -> list[dict]:
    """For the location control: countries (zh, en, point) with their first-level divisions where we have them."""
    out = []
    for c in countries():
        subs = regions().get(c["zh"], {})
        out.append({**c, "regions": [{"zh": n, "lat": p[0], "lon": p[1]} for n, p in subs.items()]})
    return out


def valid(lat, lon) -> bool:
    return all(isinstance(v, (int, float)) and not isinstance(v, bool) and v == v for v in (lat, lon)) \
        and -90 <= lat <= 90 and -180 <= lon <= 180


def snap(lat: float, lon: float) -> tuple[float, float]:
    """The point on the GRID the prior is asked at; longitude wrapped into [-180, 180)."""
    lon = (lon + 180) % 360 - 180
    return round(round(lat / GRID) * GRID, 2), round(round(lon / GRID) * GRID, 2)


def region_point(label: str) -> tuple[float, float] | None:
    """A label "国家 · 州/省" or "国家" (Chinese, as the catalogue gives them) -> its representative point."""
    country, _, name = label.partition(" · ")
    country, name = country.strip(), name.strip()
    if name:
        pt = regions().get(country, {}).get(name)
        if pt:
            return pt
    return next(((c["lat"], c["lon"]) for c in countries() if country in (c["zh"], c["en"])), None)


def location_point(location) -> tuple[float, float, str] | None:
    """A scan's / single photo's location -> (lat, lon, source): a dict {lat, lon, label?, source: map|device|region}
    or a plain label string (older scans, the region list). None when it names nowhere we know."""
    if isinstance(location, dict):
        lat, lon = location.get("lat"), location.get("lon")
        if valid(lat, lon):
            return float(lat), float(lon), location.get("source") if location.get("source") in ("map", "device", "region") else "map"
        location = location.get("label")
    if isinstance(location, str) and location:
        pt = region_point(location)
        if pt:
            return pt[0], pt[1], "region"
    return None


def place(gps: list[float] | None, location=None) -> tuple[float, float, str] | None:
    """(lat, lon, source) the prior uses: photo GPS > the chosen point (map / device / region) > None."""
    if gps and len(gps) == 2 and valid(gps[0], gps[1]):
        return float(gps[0]), float(gps[1]), "photo"
    return location_point(location)


def fingerprint_key(location) -> list | None:
    """What of a scan's location changes results: its snapped point (the label and source do not)."""
    pt = location_point(location)
    return list(snap(pt[0], pt[1])) if pt else None


def posterior(p_visual: np.ndarray, p_geo: np.ndarray | None) -> np.ndarray:
    """p_visual * (FLOOR + p_geo), renormalised; no prior -> p_visual unchanged. Works row-wise on (n, species)."""
    if p_geo is None:
        return p_visual
    post = p_visual * (FLOOR + p_geo)
    total = post.sum(axis=-1, keepdims=True)
    return np.where(total > 0, post / np.where(total > 0, total, 1), p_visual)


class Geo:
    def __init__(self, model: str, scientific: list[str]) -> None:
        import onnxruntime as ort
        self.session = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
        self.input = self.session.get_inputs()[0].name
        with open(INDEX, newline="", encoding="utf-8") as f:
            idx = {r["scientific"]: [int(x) for x in r["geo3_index"].split("|") if x] for r in csv.DictReader(f)}
        rows = [idx.get(s, []) for s in scientific]
        width = max(1, *(len(r) for r in rows))
        self.index = np.full((len(rows), width), -1, np.int64)
        for i, r in enumerate(rows):
            self.index[i, :len(r)] = r

    @lru_cache(maxsize=256)  # noqa: B019 - one instance per engine; a batch is mostly one place and week
    def _probs(self, lat: float, lon: float, week: int | None) -> np.ndarray:
        weeks = [week] if week else range(1, 49)
        x = np.array([[lat, lon, w] for w in weeks], np.float32)
        p = self.session.run(None, {self.input: x})[0].max(axis=0)
        return np.where(self.index >= 0, p[np.maximum(self.index, 0)], 0.0).max(axis=1)

    def p_geo(self, lat: float, lon: float, taken_at: str | None) -> np.ndarray:
        """One value per AviList row (aligned with the names matrix), 0-1, at the snapped point."""
        return self._probs(*snap(lat, lon), week_of(taken_at))
