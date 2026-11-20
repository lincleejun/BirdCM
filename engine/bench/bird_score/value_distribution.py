"""Bird Value over every species recorded in a few 0.5° cells: how many species, and what share of sightings
(weighted by GBIF records), reach 6 / 8 / 9.

  uv run python bench/bird_score/value_distribution.py TABLE
"""
import sys

from birdcm import rarity, value

# (label, lat, lon, month)
PLACES = [("Cupertino", 37.32, -122.03, 11), ("San Diego 内陆", 33.2, -117.1, 5), ("纽约", 40.78, -73.97, 5),
          ("Austin", 30.3, -97.7, 4), ("北京", 39.95, 116.4, 11), ("上海", 31.2, 121.5, 5), ("大连", 39.1, 121.7, 12)]


def place_features(t, lat, lon, month):
    """[(features, records)] for every species in the point's cell."""
    div, country = t.region_at(lat, lon)
    rows = t.db.execute("SELECT s.scientific, g.n FROM grid_counts g JOIN species s ON s.id = g.species_id "
                        "WHERE g.cell = ?", (value.cell_id(lat, lon),)).fetchall()
    out = [(value.features(t, sci, div or country, month, False, lat, lon), n) for sci, n in rows]
    return [(f, n) for f, n in out if f and f.get("L") is not None]


def summary(scored):
    """scored: [(value, records)] -> (species >=6, >=8, >=9, % sightings >=6, >=9)."""
    tot = sum(n for _, n in scored) or 1
    sp = lambda k: sum(1 for v, _ in scored if v >= k)
    w = lambda k: 100 * sum(n for v, n in scored if v >= k) / tot
    return len(scored), sp(6), sp(8), sp(9), w(6), w(9)


if __name__ == "__main__":
    t = rarity.Rarity(sys.argv[1])
    for label, lat, lon, m in PLACES:
        fs = place_features(t, lat, lon, m)
        if not fs:
            print(f"{label}: no cell data")
            continue
        n, a, b, c, w6, w9 = summary([(value.score(f)["regional"], k) for f, k in fs])
        print(f"{label:14s} {m:2d}月  species {n:4d} | ≥6 {a:3d} ≥8 {b:3d} ≥9 {c:3d} | sightings ≥6 {w6:.2f}% ≥9 {w9:.3f}%")
