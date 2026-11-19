"""Bird Value (owner's design, 2026-11-19: docs/bird-value.md): the owner's scoreBird with its constants, 1-10.

  species base   = tanh_score(0.7 G + 0.3 C)                                  no place: search
  regional value = tanh_score(max(0.95 R + 0.05 base, 0.90 base + 0.10 R))     place + month
  R              = 0.75 L + 0.10 N + 0.05 T + 0.10 H
  tanh_score(q)  = 1 + 9 (tanh(k(q - c)) - tanh(-kc)) / (tanh(k(1 - c)) - tanh(-kc)),  k = 3, c = 0.65

Features, 0-1, from the installed GBIF table (rarity.py):
  G  global rarity: the species' share where it is easiest to see this month (any country or division with >= 2000
     records and >= 5 of it), as a frequency
  C  IUCN (LC 0, NT .25, VU .5, EN .75, CR 1); None in public builds (no IUCN data) -> 0
  L  local rarity: the division's (else country's) all-year share, as a frequency
  N  wider rarity: the country's all-year share
  T  season anomaly: how far this month's share falls below the all-year share (log10 ratio / 3)
  H  history: few records ever in the division (1 - log10(n + 1) / 4)
A record share is turned into a checklist-like frequency by x TO_FREQ (GBIF shares run ~1.5 decades below eBird
checklist frequency), then L = -log10(max(f, 1e-5)) / 5 as in the design.

No records of the species in the region is not a top score (design §7): search -> 'insufficient-data' (no regional
value); a photo -> the value with the region's floor share (1 record) and status 'pending' until the owner confirms it.
Lifer status never changes the value. Values are stored unrounded; shown with two decimals.
"""
from __future__ import annotations

import math

from birdcm.rarity import SHOW_IUCN

MODEL_VERSION = "bird-value-v1"
K, C = 3.0, 0.65
TO_FREQ = 30
FLOOR = 1e-5
IUCN = {"LC": 0.0, "NT": 0.25, "VU": 0.5, "EN": 0.75, "CR": 1.0}


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
    base_raw = 0.7 * clamp(f["G"]) + 0.3 * clamp(f["C"])
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


def features(table, sci: str, region: str | None, month: int | None, photo: bool = False) -> dict | None:
    """The design's features for a species at an ISO region (division or country) and month; None: species unknown.
    `photo`: a sighting, so no records in the region still gets a value (the floor share), marked pending."""
    with table.lock:
        db = table.db
        sp = db.execute("SELECT id, iucn FROM species WHERE scientific = ?", (sci,)).fetchone()
        if not sp:
            return None
        s, iucn = sp
        f = {"C": IUCN.get(iucn or "", 0.0) if SHOW_IUCN else 0.0}
        best = db.execute("SELECT MAX(1.0 * c.n / m.records) FROM counts c JOIN months m ON m.region_id = c.region_id "
                          "AND m.month = c.month WHERE c.species_id = ? AND c.n >= 5 AND m.records >= 2000"
                          + (" AND c.month = ?" if month else ""), (s, month) if month else (s,)).fetchone()[0]
        f["G"] = scarcity(best) if best else 1.0
        ids = dict(db.execute("SELECT code, id FROM regions WHERE code IN (?, ?)", (region or "", (region or "")[:2])))
        if not region or not month or region not in ids:
            return f
        year = range(1, 13)
        ny, ty = _share(db, ids[region], s, year)
        nm, tm = _share(db, ids[region], s, [month])
        cn, ct = _share(db, ids.get(region[:2], ids[region]), s, year)
    if ty < 2000 or (ny == 0 and not photo):
        return f | {"evidence": "insufficient"}
    pending = ny == 0
    sy = (ny or 1) / ty
    sm = nm / tm if tm else 0.0
    return f | {"L": scarcity(sy), "N": scarcity((cn or 1) / ct) if ct else scarcity(sy),
                "T": clamp(math.log10((sy + 1e-7) / (sm + 1e-7)) / 3), "H": clamp(1 - math.log10(ny + 1) / 4),
                "pending": pending, "n_year": ny}


def value(table, sci: str, region: str | None, month: int | None, photo: bool = False) -> dict | None:
    f = features(table, sci, region, month, photo)
    if f is None:
        return None
    out = score(f)
    if out["status"] == "estimated" and f.get("pending"):
        out["status"] = "pending"
    return out | {"features": {k: f[k] for k in ("G", "C", "L", "N", "T", "H") if k in f}}
