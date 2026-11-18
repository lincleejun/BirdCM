"""How often a bird is reported where and when the photo was taken: GBIF record counts per region and month, tiered,
plus the IUCN Red List category. Reads the research's SQLite table (bioclip-bird distill/rarity_pack.py lookup()),
stdlib sqlite3 only, read-only.

Tiers (share = the species' records / all bird records of that region-month; a region-month with < 2,000 records uses
its country's month): >= 0.2 % 常见, >= 0.02 % 不常见, >= 0.002 % 少见, lower or n < 5 罕见; species in the table but no
record there that month -> 无记录; name not in the table -> 未知; a place outside the table's coverage -> 数据不足.
Counts are reports, not abundance: a common but unremarkable bird is under-reported, a showy one over-reported.

IUCN categories can be switched off as a whole (SHOW_IUCN, env BIRDCM_IUCN=0): their redistribution terms are unclear.
"""
from __future__ import annotations

import os
import sqlite3
import threading
from functools import lru_cache

from birdcm import geo

TIER_ZH = {0: "无记录", 1: "罕见", 2: "少见", 3: "不常见", 4: "常见"}
SHOW_IUCN = os.environ.get("BIRDCM_IUCN", "1") != "0"
NEAR_DIVISION = 6.0        # degrees: a point farther than this from every division's point is matched to countries only


def region_key(lat: float, lon: float, label: str | None = None) -> tuple[str, str | None] | None:
    """The one place -> table mapping: (ISO 3166-1 alpha-2 country, division English name or None).
    A region label picked from our list maps exactly; a point goes to the nearest division point of our table, else the
    nearest country point. ponytail: nearest representative point, not point-in-polygon; wrong near borders. Swap for
    boundaries (Natural Earth admin-1) when the global table arrives."""
    if label:
        country, _, name = label.partition(" · ")
        c = next((c for c in geo.countries() if c["zh"] == country.strip()), None)
        if c:
            sub = _division_en(c["zh"], name.strip()) if name else None
            return c["code"], sub
    best, d = None, NEAR_DIVISION ** 2
    for cz, _zh, en, la, lo in _divisions():
        x = (la - lat) ** 2 + (((lo - lon + 180) % 360 - 180) * _cos(lat)) ** 2
        if x < d:
            best, d = (cz, en), x
    if best:
        code = next(c["code"] for c in geo.countries() if c["zh"] == best[0])
        return code, best[1]
    c = min(geo.countries(), key=lambda c: (c["lat"] - lat) ** 2 + (((c["lon"] - lon + 180) % 360 - 180) * _cos(lat)) ** 2)
    return c["code"], None


def _cos(lat: float) -> float:
    import math
    return max(0.1, math.cos(math.radians(lat)))


@lru_cache(maxsize=1)
def _divisions() -> list[tuple[str, str, str, float, float]]:
    """(country zh, division zh, division en, lat, lon) from our region table."""
    import csv
    with open(geo.REGIONS, newline="", encoding="utf-8") as f:
        return [(r["country"], r["region"], r["name_en"], float(r["lat"]), float(r["lon"])) for r in csv.DictReader(f)]


def _division_en(country_zh: str, name_zh: str) -> str | None:
    return next((en for c, zh, en, *_ in _divisions() if c == country_zh and zh == name_zh), None)


class Rarity:
    def __init__(self, path: str) -> None:
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)
        self.lock = threading.Lock()
        rows = self.db.execute("SELECT code, country, level, name_en FROM regions").fetchall()
        self.country = {c: code for code, c, level, _ in rows if level == 0}
        self.division = {(c, en): code for code, c, level, en in rows if level == 1}

    def code(self, key: tuple[str, str | None] | None) -> str | None:
        if not key:
            return None
        country, sub = key
        return self.division.get((country, sub)) or self.country.get(country)

    def lookup(self, sci: str, lat: float | None, lon: float | None, label: str | None, month: int | None) -> dict:
        """{tier: 0-4 | None, label, iucn, region}; tier None with label 数据不足 / 未知 / 时间未知."""
        key = None if lat is None and not label else region_key(lat, lon, label) if lat is not None else region_key(0.0, 0.0, label)
        code = self.code(key)
        with self.lock:
            sp = self.db.execute("SELECT id, iucn FROM species WHERE scientific = ?", (sci,)).fetchone()
            iucn = (sp[1] or None) if sp and SHOW_IUCN else None
            if code is None:
                return {"tier": None, "label": "数据不足", "iucn": iucn, "region": None}
            if sp is None:
                return {"tier": None, "label": "未知", "iucn": None, "region": code}
            if not month:
                return {"tier": None, "label": "时间未知", "iucn": iucn, "region": code}
            hit = self.db.execute("""SELECT c.tier FROM months m JOIN regions r ON r.id = m.region_id
                                     JOIN counts c ON c.region_id = m.source_id AND c.month = m.month AND c.species_id = ?
                                     WHERE r.code = ? AND m.month = ?""", (sp[0], code, month)).fetchone()
        t = hit[0] if hit else 0
        return {"tier": t, "label": TIER_ZH[t], "iucn": iucn, "region": code}
