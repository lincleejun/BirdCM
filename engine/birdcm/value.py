"""Bird Value (owner's design, 2026-11-19: docs/bird-value.md): the owner's scoreBird, fitted to the owner's cases, 1-10.

  species base   = tanh_score((1 - W_C) G + W_C C)                            no place: search
  regional value = tanh_score(max(0.95 R + 0.05 base, 0.90 base + 0.10 R))     place + month
  R              = 0.75 L + 0.10 N + 0.05 T + 0.10 H
  tanh_score(q)  = 1 + 9 (tanh(k(q - c)) - tanh(-kc)) / (tanh(k(1 - c)) - tanh(-kc))
Fitted (bench/bird_score/cases.py --fit, value_distribution.py): k = 3, c = 0.30 (design's demo 0.65),
W_C = 0.4 (design 0.3: else a protected bird where it is common, the Dalian white-tailed eagle, cannot reach 6),
TO_FREQ = 100.

Features, 0-1, from the installed GBIF table (rarity.py):
  G  global rarity: the species' share where it is easiest to see this month (any country or division with >= 2000
     records and >= 5 of it), as a frequency
  C  IUCN (LC 0, NT .25, VU .5, EN .75, CR 1), from the bundled data/iucn.csv; no category or switched off -> 0;
     in China also 国家重点保护 (一级 1, 二级 .5; data/cn_protected_birds.tsv), the higher one
  L  local rarity: the point's 0.5° cell (US, CN: the table's grid) all-year share, else the division's (else
     country's), as a frequency
  N  wider rarity: the division's all-year share with a cell, else the country's
  T  season anomaly: how far this month's share in the division falls below its all-year share (log10 ratio / 3)
  H  history: few records ever in the local area (1 - log10(n + 1) / 4)
A record share is turned into a checklist-like frequency by x TO_FREQ, then L = -log10(max(f, 1e-5)) / 5 as in
the design.

No records of the species in the place is not a top score (design §7): search -> 'insufficient-data' (no regional
value); a photo -> the value with the place's floor share (1 record) and status 'pending' until the owner confirms it.
Lifer status never changes the value. Values are stored unrounded; shown with two decimals.
"""
from __future__ import annotations

import math
from pathlib import Path

from birdcm import rarity

MODEL_VERSION = "bird-value-v1"
K, C = 3.0, 0.30
W_C = 0.4                             # protection's share of the species base (design: 0.7 G + 0.3 C)
TO_FREQ = 100
FLOOR = 1e-5
IUCN = {"LC": 0.0, "NT": 0.25, "VU": 0.5, "EN": 0.75, "CR": 1.0}
CN_PROTECTION = {1: 1.0, 2: 0.5}      # 国家一级 / 二级, in China only


def clamp(x: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, x))


def tanh_score(q: float) -> float:
    lo, hi = math.tanh(-K * C), math.tanh(K * (1 - C))
    return 1 + 9 * (math.tanh(K * (clamp(q) - C)) - lo) / (hi - lo)


def scarcity(share: float) -> float:
    """A record share -> 0 (everywhere) .. 1 (one in 100,000 checklists or rarer)."""
    return clamp(-math.log10(max(min(1.0, TO_FREQ * share), FLOOR)) / 5)


def score(f: dict) -> dict:
    """f: G, C (required), L, N, T, H (all or none). The design's scoreBird, unrounded."""
    base_raw = (1 - W_C) * clamp(f["G"]) + W_C * clamp(f["C"])
    out = {"model": MODEL_VERSION, "base": tanh_score(base_raw), "regional": None}
    if f.get("L") is None:
        return out | {"status": "insufficient-data"}
    r = 0.75 * clamp(f["L"]) + 0.10 * clamp(f["N"]) + 0.05 * clamp(f["T"]) + 0.10 * clamp(f["H"])
    combined = max(0.95 * r + 0.05 * base_raw, 0.90 * base_raw + 0.10 * r)
    return out | {"regional": tanh_score(combined), "status": "estimated"}


# ---- features from the installed table ------------------------------------------------------------------------------

def _share(db, region_id: int, species_id: int, months) -> tuple[int, int]:
    q = ",".join(str(int(m)) for m in months)
    tot = db.execute(f"SELECT SUM(records) FROM months WHERE region_id = ? AND month IN ({q})", (region_id,)).fetchone()[0] or 0
    n = db.execute(f"SELECT SUM(n) FROM counts WHERE region_id = ? AND species_id = ? AND month IN ({q})",
                   (region_id, species_id)).fetchone()[0] or 0
    return n, tot


def cell_id(lat: float, lon: float) -> int:
    """The 0.5° grid cell of the rarity table's `grid` tables (bioclip-bird distill/rarity_grid.py)."""
    return int((lat + 90) * 2) * 720 + int((lon + 180) * 2)


def _cn_grades() -> dict[str, int]:
    path = Path(__file__).parent / "data" / "cn_protected_birds.tsv"
    rows = [l.rstrip("\n").split("\t") for l in path.open(encoding="utf-8") if not l.startswith("#")][1:]
    return {s: int(g) for s, g in rows}


CN_GRADE = _cn_grades()


def features(table, sci: str, region: str | None, month: int | None, photo: bool = False,
             lat: float | None = None, lon: float | None = None) -> dict | None:
    """The design's features for a species at an ISO region (division or country) and month; None: species unknown.
    With a point inside the grid (US, CN), L and H come from its 0.5° cell and N from the division.
    `photo`: a sighting, so no records in the place still gets a value (the floor share), marked pending."""
    with table.lock:
        db = table.db
        sp = db.execute("SELECT id FROM species WHERE scientific = ?", (sci,)).fetchone()
        if not sp:
            return None
        s = sp[0]
        f = {"C": IUCN.get(rarity.iucn(sci) or "", 0.0)}
        best = db.execute("SELECT MAX(1.0 * c.n / m.records) FROM counts c JOIN months m ON m.region_id = c.region_id "
                          "AND m.month = c.month WHERE c.species_id = ? AND c.n >= 5 AND m.records >= 2000"
                          + (" AND c.month = ?" if month else ""), (s, month) if month else (s,)).fetchone()[0]
        f["G"] = scarcity(best) if best else 1.0
        ids = dict(db.execute("SELECT code, id FROM regions WHERE code IN (?, ?)", (region or "", (region or "")[:2])))
        if not region or not month or region not in ids:
            return f
        if region[:2] == "CN" and sci in CN_GRADE:      # a regional protection status (design: C includes it)
            f["C"] = max(f["C"], CN_PROTECTION[CN_GRADE[sci]])
        year = range(1, 13)
        ny, ty = _share(db, ids[region], s, year)
        nm, tm = _share(db, ids[region], s, [month])
        cn, ct = _share(db, ids.get(region[:2], ids[region]), s, year)
        cell = None
        if lat is not None and lon is not None and db.execute(
                "SELECT 1 FROM sqlite_master WHERE name = 'grid'").fetchone():
            c = cell_id(lat, lon)
            tot = (db.execute("SELECT records FROM grid WHERE cell = ?", (c,)).fetchone() or [0])[0]
            if tot >= 2000:
                n = (db.execute("SELECT n FROM grid_counts WHERE cell = ? AND species_id = ?", (c, s)).fetchone() or [0])[0]
                cell = n, tot
    if cell:      # local = the cell, wider = the division
        (nl, tl), (nw, tw) = cell, (ny, ty)
    else:         # local = the division, wider = the country
        (nl, tl), (nw, tw) = (ny, ty), (cn, ct)
    if tl < 2000 or (nl == 0 and not photo):
        return f | {"evidence": "insufficient"}
    sy = (ny or 1) / ty if ty else 0.0
    sm = nm / tm if tm else 0.0
    return f | {"L": scarcity((nl or 1) / tl), "N": scarcity((nw or 1) / tw) if tw else scarcity((nl or 1) / tl),
                "T": clamp(math.log10((sy + 1e-7) / (sm + 1e-7)) / 3) if ty else 0.0,
                "H": clamp(1 - math.log10(nl + 1) / 4), "pending": nl == 0, "n_local": nl, "cell": bool(cell)}


def value(table, sci: str, region: str | None, month: int | None, photo: bool = False,
          lat: float | None = None, lon: float | None = None) -> dict | None:
    f = features(table, sci, region, month, photo, lat, lon)
    if f is None:
        return None
    out = score(f)
    if out["status"] == "estimated" and f.get("pending"):
        out["status"] = "pending"
    return out | {"features": {k: f[k] for k in ("G", "C", "L", "N", "T", "H") if k in f}}
