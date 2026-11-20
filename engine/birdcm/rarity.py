"""How often a bird is reported where and when the photo was taken: GBIF record counts per region and month, tiered,
plus the IUCN Red List category. Reads the research's SQLite table, stdlib sqlite3 only, read-only. Two tables:

- the global one (bioclip-bird distill/rarity_global.py, `rarity-global.sqlite`): ISO 3166-1 / 3166-2 region codes,
  `months.coverage` ('tiered' own counts | 'country' its country's month | '数据不足' source_id NULL) and `shapes`,
  its own offline point -> region lookup (region_at, a port of rarity_global.region_at).
- the older US / CA / CN one (distill/rarity_pack.py): GADM codes, no coverage column, no shapes. Points go through
  geo.locate (Natural Earth outlines bundled with the engine); anywhere outside US / CA / CN reads 数据不足.

The global table wins when both are installed (table()). Tiers are the table's own (share of the region-month's bird
records: >= 0.2 % 常见, >= 0.02 % 不常见, >= 0.002 % 少见, lower or n < 5 罕见); species in the table but no record there
that month -> 无记录; name not in the table -> 未知; no place / a region-month without tiers -> 数据不足. A division that
is too thin uses its country's month: coverage 'country', note 按全国数据估计.
Counts are reports, not abundance: a common but unremarkable bird is under-reported, a showy one over-reported.

place_region() is the ONE point -> (division ISO, country ISO) mapping for the engine (rarity, eBird state / country,
the life list, evaluation labels).

IUCN categories come from data/iucn.csv, bundled with the engine (CC BY 4.0, data/iucn-LICENSE.md), not from the table's
own `species.iucn` column: one source with or without a table. SHOW_IUCN (env BIRDCM_IUCN=0) still hides them everywhere.
"""
from __future__ import annotations

import csv
import os
import sqlite3
import threading
from array import array
from collections import defaultdict
from functools import cache, lru_cache
from pathlib import Path

from birdcm import geo

TIER_ZH = {0: "无记录", 1: "罕见", 2: "少见", 3: "不常见", 4: "常见"}
SHOW_IUCN = os.environ.get("BIRDCM_IUCN", "1") != "0"
NEAR = 0.25                     # degrees: rarity_global.NEAR, a point off every polygon but this close to a vertex
COUNTRY_NOTE = "按全国数据估计"


@cache
def _iucn() -> dict[str, str]:
    with open(Path(__file__).with_name("data") / "iucn.csv", newline="", encoding="utf-8") as f:
        return {r["scientific"]: r["category"] for r in csv.DictReader(f)}


def iucn(sci: str) -> str | None:
    """The global IUCN Red List category code of an AviList species (LC NT VU EN CR EW EX DD); None: no matched
    assessment, or switched off."""
    return _iucn().get(sci) if SHOW_IUCN else None


# ---- ISO codes of our own place list (countries.csv code, regions.csv iso) ----------------------------------------

@lru_cache(maxsize=1)
def _divisions() -> list[dict]:
    with open(geo.REGIONS, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


@lru_cache(maxsize=1)
def _iso_tables() -> tuple[dict, dict]:
    """(label -> ISO, ISO -> {label, en, zh, country})."""
    to_iso, of_iso = {}, {}
    for c in geo.countries():
        to_iso[c["zh"]] = c["code"]
        of_iso[c["code"]] = {"label": c["zh"], "en": c["en"], "zh": c["zh"], "country": c["code"]}
    cc = {c["zh"]: c["code"] for c in geo.countries()}
    for r in _divisions():
        if r.get("iso") and r["country"] in cc:
            label = f'{r["country"]} · {r["region"]}'
            to_iso[label] = r["iso"]
            of_iso[r["iso"]] = {"label": label, "en": r["name_en"], "zh": r["region"], "country": cc[r["country"]]}
    return to_iso, of_iso


def label_iso(label: str | None) -> str | None:
    """A place-list label ("国家" or "国家 · 州/省", optionally "… 附近") -> its ISO code; None when unknown."""
    if not label:
        return None
    return _iso_tables()[0].get(label.replace(" 附近", "").strip())


def iso_label(code: str | None) -> str | None:
    """ISO code -> our place-list label; a code we have no label for -> None."""
    x = _iso_tables()[1].get(code or "")
    return x["label"] if x else None


def iso_info(code: str | None) -> dict | None:
    return _iso_tables()[1].get(code or "")


def region_key(lat: float, lon: float, label: str | None = None) -> tuple[str, str | None] | None:
    """(ISO 3166-1 alpha-2 country, division English name or None) by our bundled outlines (geo.locate) or a label;
    the older table's key. A point in no outline (open sea) -> None, which reads as 数据不足."""
    if not label:
        hit = geo.locate(lat, lon)
        if not hit:
            return None
        label = hit[1] or hit[0]
    code = label_iso(label)
    if not code:
        return None
    info = iso_info(code)
    return info["country"], (info["en"] if "-" in code else None)


def _locate_iso(lat: float, lon: float) -> tuple[str | None, str | None]:
    hit = geo.locate(lat, lon)
    if not hit:
        return None, None
    country, div = label_iso(hit[0]), label_iso(hit[1]) if hit[1] else None
    return div, country or (div[:2] if div else None)


def inside(x: float, y: float, rings) -> bool:
    """Even-odd over all of a region's rings (rarity_global.inside)."""
    hit = False
    for ring in rings:
        n = len(ring) // 2
        x1, y1 = ring[2 * n - 2], ring[2 * n - 1]
        for i in range(n):
            x2, y2 = ring[2 * i], ring[2 * i + 1]
            if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
                hit = not hit
            x1, y1 = x2, y2
    return hit


class Rarity:
    def __init__(self, path: str) -> None:
        self.path = str(path)
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)
        self.lock = threading.Lock()
        self.is_global = bool(self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='shapes'").fetchone())
        rows = self.db.execute("SELECT code, country, level, name_en FROM regions").fetchall()
        self.codes = {code for code, *_ in rows}
        self.country = {c: code for code, c, level, _ in rows if level == 0}           # older table: GADM codes
        self.division = {(c, en): code for code, c, level, en in rows if level == 1}
        self._at = lru_cache(maxsize=8192)(self._region_at)

    # ---- point -> region ------------------------------------------------------------------------------------------

    def region_at(self, lat: float, lon: float) -> tuple[str | None, str | None]:
        """(division ISO or None, country ISO or None): the global table's shapes; else our bundled outlines."""
        if not self.is_global:
            return _locate_iso(lat, lon)
        return self._at(float(lat), float(lon))

    def _region_at(self, lat: float, lon: float) -> tuple[str | None, str | None]:
        """Port of rarity_global.region_at: bounding boxes, even-odd rings, smallest region wins, 0.25° coast."""
        with self.lock:
            cand = self.db.execute(
                "SELECT r.code, r.level, s.pts, (SELECT sum((maxx - minx) * (maxy - miny)) FROM shapes t "
                "WHERE t.region_id = s.region_id) FROM shapes s JOIN regions r ON r.id = s.region_id "
                "WHERE minx <= ? AND maxx >= ? AND miny <= ? AND maxy >= ?",
                (lon + NEAR, lon - NEAR, lat + NEAR, lat - NEAR)).fetchall()
        rings, area = defaultdict(list), defaultdict(float)
        for code, level, pts, size in cand:
            rings[code, level].append(array("f", pts))
            area[code, level] = size
        hit = {}
        for (code, level), rs in sorted(rings.items(), key=lambda kv: -area[kv[0]]):     # smaller overwrite larger
            if inside(lon, lat, rs):
                hit[level] = code
        if not hit:
            best = min((((r[i] - lon) ** 2 + (r[i + 1] - lat) ** 2, code, level)
                        for (code, level), rs in rings.items() for r in rs for i in range(0, len(r), 2)), default=None)
            if best and best[0] <= NEAR ** 2:
                hit = {best[2]: best[1]}
                if best[2] == 1:
                    hit[0] = best[1][:2]
        if 1 in hit and 0 not in hit:
            hit[0] = hit[1][:2]
        return hit.get(1), hit.get(0)

    def resolve(self, lat, lon, label: str | None = None, code: str | None = None) -> str | None:
        """The ISO region a place reads its tiers from: an explicit region code, else a region label, else the point."""
        if code:
            return code
        if label:
            return label_iso(label)
        if lat is None or lon is None:
            return None
        div, country = self.region_at(lat, lon)
        return div or country

    # ---- the lookup -----------------------------------------------------------------------------------------------

    def _rows(self, sql: str, args: tuple) -> list:
        with self.lock:
            return self.db.execute(sql, args).fetchall()

    def lookup(self, sci: str, lat: float | None, lon: float | None, label: str | None, month: int | None,
               code: str | None = None) -> dict:
        """{tier: 0-4 | None, label, iucn, region (ISO), coverage, note}; tier None with label 数据不足 / 未知 / 时间未知."""
        region = self.resolve(lat, lon, label, code)
        sp = (self._rows("SELECT id FROM species WHERE scientific = ?", (sci,)) or [None])[0]
        out = {"tier": None, "label": "数据不足", "iucn": iucn(sci), "region": region, "coverage": None, "note": None}
        if region is None:
            return out
        if sp is None:
            return {**out, "label": "未知"}
        if not month:
            return {**out, "label": "时间未知"}
        if self.is_global:
            m = self._rows("SELECT m.source_id, m.coverage FROM months m JOIN regions r ON r.id = m.region_id "
                           "WHERE r.code = ? AND m.month = ?", (region, month))
            coverage = m[0][1] if m else None
            if not m and "-" in region:                       # a division without its own rows: its country's
                m = self._rows("SELECT m.source_id, m.coverage FROM months m JOIN regions r ON r.id = m.region_id "
                               "WHERE r.code = ? AND m.month = ?", (region[:2], month))
                coverage = "country" if m and m[0][0] is not None else (m[0][1] if m else None)
            if not m or m[0][0] is None:                       # NULL source: not enough records, never "no record"
                return {**out, "coverage": coverage or "数据不足"}
            source = m[0][0]
        else:
            info = iso_info(region)
            old = (self.division.get((region[:2], info["en"])) if info and "-" in region else None) or self.country.get(region[:2])
            if old is None:                                    # outside US / CA / CN: the older table has nothing
                return out
            m = self._rows("SELECT m.source_id, m.region_id FROM months m JOIN regions r ON r.id = m.region_id "
                           "WHERE r.code = ? AND m.month = ?", (old, month))
            if not m or m[0][0] is None:
                return out
            source, coverage = m[0][0], ("tiered" if m[0][0] == m[0][1] else "country")
        hit = self._rows("SELECT tier FROM counts WHERE region_id = ? AND month = ? AND species_id = ?", (source, month, sp[0]))
        t = hit[0][0] if hit else 0
        return {**out, "tier": t, "label": TIER_ZH[t], "coverage": coverage, "note": COUNTRY_NOTE if coverage == "country" else None}

    def names(self, code: str) -> tuple[str, str] | None:
        """(English, Chinese) name of a region code in this table."""
        r = self._rows("SELECT name_en, name_zh FROM regions WHERE code = ?", (code,))
        return (r[0][0] or code, r[0][1] or r[0][0] or code) if r else None


# ---- the installed table, opened once (Engine, scheduler, life list) -----------------------------------------------

def table_path():
    """The global table when installed, else the US / CA / CN one, else None (models.toml roles rarity-global / rarity)."""
    from birdcm import models
    for role in ("rarity-global", "rarity"):
        for e in models.manifest()["file"]:
            if e["role"] == role and (p := models.locate(e)):
                return p
    return None


_table: list = []
_table_lock = threading.Lock()


def table() -> Rarity | None:
    with _table_lock:
        if not _table:
            try:
                p = table_path()
                _table.append(Rarity(str(p)) if p else None)
            except Exception:  # noqa: BLE001 - unreadable table: no rarity, never a crash
                _table.append(None)
        return _table[0]


def region_names(code: str | None) -> tuple[str, str] | None:
    """(English, Chinese) name of an ISO region: our place list first, else the installed table."""
    if not code:
        return None
    info = iso_info(code)
    if info:
        return info["en"], info["zh"]
    t = table()
    return t.names(code) if t is not None else None


def place_region(lat: float, lon: float) -> tuple[str | None, str | None]:
    """THE point -> (division ISO or None, country ISO or None): the global table's shapes when installed, else our
    bundled Natural Earth outlines (geo.locate)."""
    t = table()
    return t.region_at(lat, lon) if t is not None else _locate_iso(lat, lon)
