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
  their prior is UNKNOWN (Geo.unmapped). The posterior gives them UNKNOWN_PRIOR ("might be here, not common") instead
  of 0, and the range rule never vetoes or flags them (confirm.py). A lumped row takes the largest of its labels.
- uncertainty (2026-11-17): the prior is the MAX over where and when the photo could be. A chosen country / division:
  every point of its lattice (data/region-grid.csv, tools/build_region_grid.py, Natural Earth); a point (GPS, map,
  device): the point and its neighbours NEAR degrees away; the week and WEEKS either side (no date: all 48). A region's
  representative point alone made a coastal visitor look impossible from a mountain centroid.
Not ported: gardener's split-range table. ponytail: add it if a split pair shows up wrong in practice.
"""
from __future__ import annotations

import csv
from functools import lru_cache
from pathlib import Path

import numpy as np

FLOOR = 0.02
UNKNOWN_PRIOR = 0.05      # the prior used in the posterior for a species the geo model does not list
DATA = Path(__file__).with_name("data")
REGIONS = DATA / "regions.csv"
COUNTRIES = DATA / "countries.csv"
GRID = 0.05
INDEX = DATA / "avilist-birdnet-geo3.csv"
GRID_FILE = DATA / "region-grid.csv"
NEAR, WEEKS = 0.25, 3          # a point's neighbourhood (degrees) and the weeks either side the prior also looks at


@lru_cache(maxsize=1)
def region_grid() -> dict[str, tuple[tuple[float, float], ...]]:
    """place label ("国家" or "国家 · 州/省", as the catalogue gives them) -> points covering it."""
    out: dict[str, list] = {}
    with open(GRID_FILE, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            out.setdefault(r["place"], []).append((float(r["lat"]), float(r["lon"])))
    return {k: tuple(v) for k, v in out.items()}


BOUNDARIES = DATA / "boundaries.json"
NEAR_EDGE = 0.15          # degrees: a point just off a simplified coast still belongs to the nearest outline


@lru_cache(maxsize=1)
def _outlines() -> list[tuple[str, float, tuple, list[np.ndarray]]]:
    """(place label, area, bbox, rings as (n, 2) lon/lat arrays), smallest first so an enclave wins over its host."""
    import json
    out = []
    for key, rs in json.loads(BOUNDARIES.read_text(encoding="utf-8")).items():
        arrs = [np.array(r, float).reshape(-1, 2) for r in rs]
        allp = np.concatenate(arrs)
        bbox = (allp[:, 0].min(), allp[:, 1].min(), allp[:, 0].max(), allp[:, 1].max())
        area = sum(abs(np.dot(a[:, 0], np.roll(a[:, 1], 1)) - np.dot(a[:, 1], np.roll(a[:, 0], 1))) / 2 for a in arrs)
        out.append((key, area, bbox, arrs))
    return sorted(out, key=lambda x: x[1])


def _inside(x: float, y: float, ring: np.ndarray) -> bool:
    xs, ys = ring[:, 0], ring[:, 1]
    x2, y2 = np.roll(xs, -1), np.roll(ys, -1)
    cross = (ys > y) != (y2 > y)
    with np.errstate(divide="ignore", invalid="ignore"):
        xi = xs + (y - ys) * (x2 - xs) / (y2 - ys)
    return bool(np.count_nonzero(cross & (x < xi)) % 2)


def locate(lat: float, lon: float) -> tuple[str, str | None] | None:
    """(country label, division label or None) whose outline holds the point (Natural Earth, data/boundaries.json);
    a point just off a coast (within NEAR_EDGE of an outline's vertex) takes the nearest; else None (unknown)."""
    hits = {}
    near = None
    for key, _, (x0, y0, x1, y1), rings in _outlines():
        kind = "div" if " · " in key else "country"
        if kind in hits:
            continue
        if x0 - NEAR_EDGE <= lon <= x1 + NEAR_EDGE and y0 - NEAR_EDGE <= lat <= y1 + NEAR_EDGE:
            if x0 <= lon <= x1 and y0 <= lat <= y1 and any(_inside(lon, lat, r) for r in rings):
                hits[kind] = key
                continue
            d = min(float(((r - (lon, lat)) ** 2).sum(axis=1).min()) for r in rings) ** 0.5
            if d <= NEAR_EDGE and (near is None or d < near[0]):
                near = (d, key)
    if "div" in hits:
        return hits["div"].split(" · ")[0], hits["div"]
    if "country" in hits:
        return hits["country"], None
    if near:
        k = near[1]
        return (k.split(" · ")[0], k) if " · " in k else (k, None)
    return None


def cover(lat: float, lon: float, source: str, label: str | None = None) -> tuple[tuple[float, float], ...]:
    """The snapped points the prior is read at for a place: a region's lattice, else the point and its neighbours."""
    if source == "region" and label and label in region_grid():
        return tuple(snap(*p) for p in region_grid()[label])
    return tuple(snap(lat + a * NEAR, lon + b * NEAR) for a in (-1, 0, 1) for b in (-1, 0, 1))


def weeks_around(week: int | None) -> tuple[int, ...]:
    if not week:
        return tuple(range(1, 49))
    return tuple(sorted({(week - 1 + k) % 48 + 1 for k in range(-WEEKS, WEEKS + 1)}))


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
def _region_en() -> dict[tuple[str, str], tuple[str, str]]:
    """(country zh, division zh) -> (English name, ISO 3166-2 code)."""
    with open(REGIONS, newline="", encoding="utf-8") as f:
        return {(r["country"], r["region"]): (r["name_en"], r.get("iso") or "") for r in csv.DictReader(f)}


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
    """For the location control: countries (ISO 3166-1 code, zh, en, point) with their first-level divisions (ISO
    3166-2 code) where we have them."""
    out = []
    for c in countries():
        subs = regions().get(c["zh"], {})
        out.append({**c, "regions": [{"zh": n, "en": _region_en().get((c["zh"], n), ("", ""))[0],
                                      "code": _region_en().get((c["zh"], n), ("", ""))[1], "lat": p[0], "lon": p[1]}
                                     for n, p in subs.items()]})
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


def location_label(location) -> str | None:
    """The label of a chosen country / division (what the lattice is keyed by)."""
    if isinstance(location, dict):
        return location.get("label") if location.get("source") == "region" or not valid(location.get("lat"), location.get("lon")) else None
    return location if isinstance(location, str) else None


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


def fingerprint_key(location, old: bool = False) -> list | None:
    """What of a scan's location changes results: its snapped point and the cover the prior is read over (a region's
    lattice, or the point's neighbourhood). old=True: the key before the cover was added (equivalence check only)."""
    pt = location_point(location)
    if not pt:
        return None
    lat, lon, src = pt
    if old:
        return list(snap(lat, lon))
    label = location_label(location) if src == "region" else None
    return [*snap(lat, lon), f"region:{label}" if label and label in region_grid() else "point"]


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
        self.unmapped = (self.index < 0).all(axis=1)       # no BirdNET label: the prior is unknown, not "absent"

    def _probs(self, points: tuple, weeks: tuple) -> np.ndarray:
        """(points, AviList rows): per point, the max over the weeks."""
        x = np.array([[la, lo, w] for la, lo in points for w in weeks], np.float32)
        q = np.concatenate([self.session.run(None, {self.input: x[i:i + 4096]})[0] for i in range(0, len(x), 4096)])
        q = q.reshape(len(points), len(weeks), -1).max(axis=1)
        return np.where(self.index[None] >= 0, q[:, np.maximum(self.index, 0)], 0.0).max(axis=2)

    def p_geo(self, lat: float, lon: float, taken_at: str | None, source: str = "photo", label: str | None = None) -> np.ndarray:
        """One value per AviList row (aligned with the names matrix), 0-1: the max over the place's cover and the weeks
        around the capture date."""
        return self.spread(lat, lon, taken_at, source, label)[0]

    def spread(self, lat, lon, taken_at, source="photo", label=None) -> tuple[np.ndarray, np.ndarray]:
        """(max, median) over the place's cover (each point: max over the weeks around the date). The max says whether
        the species can be here at all; the median whether it is expected over most of the place."""
        return self._spread(cover(lat, lon, source, label), weeks_around(week_of(taken_at)))

    @lru_cache(maxsize=256)  # noqa: B019 - one instance per engine; a batch is mostly one place and week
    def _spread(self, points: tuple, weeks: tuple) -> tuple[np.ndarray, np.ndarray]:
        """Cached as the two vectors only (Codex P6: the per-point matrix was cached and the median redone per photo)."""
        q = self._probs(points, weeks)
        mx, med = q.max(axis=0), np.median(q, axis=0)
        mx.flags.writeable = med.flags.writeable = False
        return mx, med
