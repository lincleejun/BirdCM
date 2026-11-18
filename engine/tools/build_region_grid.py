"""Build birdcm/data/region-grid.csv: points covering each country and first-level division of our place list, so
the location prior can be read over the whole region instead of at its representative point.

Input: Natural Earth 1:50m cultural vectors v5.1.1 (public domain, https://www.naturalearthdata.com/about/terms-of-use/),
  ne_50m_admin_0_countries.shp and ne_50m_admin_1_states_provinces.shp.
Run:  uv run --with pyshp --with shapely python tools/build_region_grid.py NE_DIR birdcm/data/region-grid.csv
Each region gets a lattice inside its polygon, spacing sqrt(area / 48) clamped to 0.25-3 degrees (so 10-60 points),
plus its representative point from our list; a region Natural Earth does not have (or too small to hold a lattice
point) keeps only its representative point.
"""
import csv
import math
import sys
from pathlib import Path

import shapefile
from shapely.geometry import Point, shape

ALIAS = {"Nei Mongol": "Inner Mongol", "Ningxia Hui": "Ningxia", "Xinjiang Uygur": "Xinjiang"}   # our name -> Natural Earth's
DATA = Path(__file__).resolve().parents[1] / "birdcm" / "data"


def lattice(geom, rep):
    a = geom.area
    s = min(3.0, max(0.25, math.sqrt(a / 48)))
    x0, y0, x1, y1 = geom.bounds
    pts = []
    y = math.floor(y0 / s) * s + s / 2
    while y < y1:
        x = math.floor(x0 / s) * s + s / 2
        while x < x1:
            if geom.contains(Point(x, y)):
                pts.append((round(y, 2), round(x, 2)))
            x += s
        y += s
    if len(pts) > 64:
        pts = pts[:: math.ceil(len(pts) / 64)]
    return [rep] + pts


def main(ne: str, out: str) -> None:
    ne = Path(ne)
    a0 = shapefile.Reader(str(ne / "ne_50m_admin_0_countries" / "ne_50m_admin_0_countries.shp"))
    a1 = shapefile.Reader(str(ne / "ne_50m_admin_1_states_provinces" / "ne_50m_admin_1_states_provinces.shp"))
    countries = {}
    for sr in a0.iterShapeRecords():
        r = sr.record.as_dict()
        for code in {r["ISO_A2"], r["ISO_A2_EH"]} - {"-99", ""}:
            countries.setdefault(code, shape(sr.shape.__geo_interface__))
    divisions = {}
    for sr in a1.iterShapeRecords():
        r = sr.record.as_dict()
        divisions[(r["iso_a2"], r["name"])] = shape(sr.shape.__geo_interface__)
    rows, missing = [], []
    with open(DATA / "countries.csv", newline="", encoding="utf-8") as f:
        cs = list(csv.DictReader(f))
    code_of = {c["zh"]: c["code"] for c in cs}
    for c in cs:
        g = countries.get(c["code"])
        pts = lattice(g, (float(c["lat"]), float(c["lon"]))) if g else [(float(c["lat"]), float(c["lon"]))]
        missing += [] if g else [c["en"]]
        rows += [(c["zh"], la, lo) for la, lo in pts]
    with open(DATA / "regions.csv", newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            g = divisions.get((code_of[r["country"]], ALIAS.get(r["name_en"], r["name_en"])))
            rep = (float(r["lat"]), float(r["lon"]))
            pts = lattice(g, rep) if g else [rep]
            missing += [] if g else [r["name_en"]]
            rows += [(f'{r["country"]} · {r["region"]}', la, lo) for la, lo in pts]
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["place", "lat", "lon"])
        w.writerows(rows)
    print(len(rows), "points; only the representative point for:", missing)


if __name__ == "__main__":
    main(*sys.argv[1:3])
