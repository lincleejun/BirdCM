"""eBird import file (Record Format) from a finished scan.

Source read 2026-11-18: eBird Help Center, "Upload Spreadsheet Data to eBird"
https://support.ebird.org/en/support/solutions/articles/48000907878-upload-spreadsheet-data-to-ebird
and "Guide to eBird Protocols" https://support.ebird.org/support/solutions/articles/48000950859 . What they say and
what this follows:
- .csv, comma-delimited, NO header row (the first row is an observation), each file at most 1 MB.
- No quotation marks anywhere and no line breaks (so no CSV quoting either: commas inside text are replaced).
- Dates month/day/year (12/27/2007); start time 24 h "08:00"; duration in minutes; distance in miles;
  "All observations reported" Y or N; country exactly 2 letters; state / province 1-3 letters.
- Count: a number, or X for present but not counted. Latitude / longitude optional, decimal degrees.
- Common name and scientific name: either or both. eBird matches its own (Clements / eBird) taxonomy; names it does
  not know are fixed by hand in the import's "Fix Species" step.
- Protocol: one word (Stationary, Traveling, Historical, Incidental). Incidental lists are never complete.
- Column order, types and limits: eBird's "Appendix A (eBird Data Fields)" PDF and the Record Format sample sheet,
  linked from that page, read 2026-11-18. 19 columns, in this order (max length / range from Appendix A):
  common name STRING(128) [common or scientific name required], genus STRING(64), species STRING(64),
  species count NUMBER(0<x<999999, anything else = present), species comments STRING(4000), location name* TEXT(254),
  latitude (-90<x<90), longitude (-180<=x<=180), observation date* MM/dd/yyyy, start time (kk:mm), state TEXT(3),
  country TEXT(2), protocol, number of observers (x>0), duration minutes (0<x<1440), all observations reported Y/N,
  distance miles (x>0), area acres (x>0), checklist (submission) comments TEXT(4000).
- Protocol values: Appendix A (an older sheet) lists casual / stationary / traveling / area; the current upload page
  says protocols "should be one word (e.g., Stationary, Traveling, Historical, or Incidental)". The current page's
  terms are used: Incidental (default) and Stationary.

Checklists: one per calendar day (camera clock) and place. The place is the scan's location; photos with their own GPS
are grouped by a 0.01 degree cell (about 1 km). A chosen region gives no coordinates (its centre is not where the
birds were): eBird asks for the location in its "Fix Locations" step.
Protocol default Incidental, all observations N: photos show what was photographed, not a complete count, and the
time between the first and last photo is not the birding effort. Stationary can be chosen (duration = that span).
"""
from __future__ import annotations

import csv
import math
from collections import defaultdict
from datetime import datetime
from functools import lru_cache
from pathlib import Path

from birdcm import geo

DATA = Path(__file__).with_name("data")
NAMES = DATA / "ebird-names.csv"
MAX_BYTES = 1_000_000
PROTOCOLS = ("Incidental", "Stationary")


@lru_cache(maxsize=1)
def clements() -> dict[str, tuple[str, str]]:
    """scientific (AviList v2026) -> (Clements v2026 English name or "", Cornell Lab species code), from AviList's
    extended file (tools/build_ebird_names.py)."""
    with open(NAMES, newline="", encoding="utf-8") as f:
        return {r["scientific"]: (r["clements_en"], r["ebird_code"]) for r in csv.DictReader(f)}


def clean(v, limit: int = 4000) -> str:
    """One field as eBird accepts it: no quotation marks, no line breaks, no commas (there is no quoting), at most
    `limit` characters (Appendix A)."""
    s = "" if v is None else str(v)
    return " ".join(s.replace('"', "").replace(",", " ").split())[:limit]


LIMITS = [128, 64, 64, 6, 4000, 254, 12, 12, 10, 5, 3, 2, 16, 4, 4, 1, 8, 8, 4000]   # per column (Appendix A)


@lru_cache(maxsize=1)
def _codes() -> tuple[dict, dict]:
    countries = {c["zh"]: c for c in geo.countries()}
    with open(geo.REGIONS, newline="", encoding="utf-8") as f:
        regions = {f'{r["country"]} · {r["region"]}': r for r in csv.DictReader(f)}
    return countries, regions


def place_codes(label: str | None) -> tuple[str, str, str]:
    """A place label ("国家" or "国家 · 州/省") -> (location name in English, state/province code, country code)."""
    countries, regions = _codes()
    if not label:
        return "", "", ""
    country = countries.get(label.split(" · ")[0].strip())
    if not country:
        return "", "", ""
    reg = regions.get(label.replace(" 附近", "").strip())
    if reg:
        return f'{reg["name_en"]} {country["code"]}', reg["iso"].split("-", 1)[-1] if reg.get("iso") else "", country["code"]
    return country["en"], "", country["code"]


def point_codes(lat: float, lon: float) -> tuple[str, str, str]:
    """A point -> (location name in English, state/province code, country code), through the one point -> region
    mapping (rarity.place_region: the global table's shapes when installed, else the bundled outlines)."""
    from birdcm import rarity
    div, country = rarity.place_region(lat, lon)
    label = rarity.iso_label(div) or rarity.iso_label(country)
    if label and (not div or rarity.iso_label(div)):
        return place_codes(label)
    if not country:
        return "", "", ""
    en = (rarity.region_names(div or country) or (div or country,))[0]
    return (f"{en} {country}" if div else en), (div.split("-", 1)[1] if div else ""), country


def _effective(p: dict) -> dict | None:
    """The photo's burst-corrected species when confirmed; a rejected photo counts when its own species is confirmed."""
    r = p.get("result")
    if not r:
        return None
    sp = p.get("species_fix") or r.get("species")
    return sp if sp and sp.get("level") in ("species", "genus") and sp.get("label") else None


def _time(r: dict) -> datetime | None:
    t = (r.get("exif") or {}).get("taken_at")
    try:
        return datetime.fromisoformat(t).replace(tzinfo=None) if t else None
    except ValueError:
        return None


def plan(photos: list[dict], location) -> dict:
    """What a scan offers: per species (confirmed, and genus-only), photo count, stars, the largest number of boxes
    naming it in one frame, eBird name match; and the checklists (day x place) the photos fall into."""
    names = clements()
    out: dict[str, dict] = {}
    for p in photos:
        sp = _effective(p)
        if not sp:
            continue
        r = p["result"]
        lab = sp["label"]
        key = lab["sci"]
        e = out.setdefault(key, {"sci": key, "level": sp["level"], "zh": lab.get("zh"), "en": lab.get("en"),
                                 "photos": 0, "stars": 0, "files": [], "max_in_frame": 0, "rare": False, "lookalike": False})
        e["photos"] += 1
        e["stars"] += 1 if (p.get("stars") or 0) > 0 else 0
        e["files"].append(Path(p["path"]).name)
        e["rare"] |= sp.get("check") == "rare"
        e["lookalike"] |= bool(sp.get("lookalike"))
        n = sum(1 for b in r.get("boxes") or [] if b.get("clear") is not False
                and ((b.get("species") or {}).get("label") or {}).get("sci") == key)
        e["max_in_frame"] = max(e["max_in_frame"], n or (1 if not r.get("rejected") else 0))
    for key, e in out.items():
        cl, code = names.get(key, ("", ""))
        e["ebird_en"] = cl
        e["ebird_code"] = code
        e["name_check"] = ("genus" if e["level"] == "genus" else "not_in_ebird" if not cl
                           else "differs" if cl != (e["en"] or "") else "")
    return {"species": sorted(out.values(), key=lambda e: (e["level"] != "species", -e["photos"], e["sci"])),
            "checklists": checklists(photos, location)}


def checklists(photos: list[dict], location, keep: set[str] | None = None) -> list[dict]:
    """Day x place groups: {key, date, start, minutes, label, lat, lon, state, country, photos: [...]}."""
    from birdcm.geo import location_point, location_label
    pt = location_point(location)
    label = (location.get("label") if isinstance(location, dict) else location) if location else None
    src = pt[2] if pt else None
    groups: dict = defaultdict(list)
    for p in photos:
        sp = _effective(p)
        if not sp or (keep is not None and sp["label"]["sci"] not in keep):
            continue
        r = p["result"]
        t = _time(r)
        if t is None:
            continue
        gps = (r.get("exif") or {}).get("gps")
        if gps:
            cell = ("gps", round(gps[0], 2), round(gps[1], 2))
        else:
            cell = ("scan",)
        groups[(t.date(), cell)].append((t, p, gps))
    out = []
    for (day, cell), items in sorted(groups.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
        times = sorted(t for t, _, _ in items)
        if cell[0] == "gps":
            lat = min(89.99999, max(-89.99999, sum(g[0] for _, _, g in items) / len(items)))
            lon = sum(g[1] for _, _, g in items) / len(items)
            name, state, country = point_codes(lat, lon)
            name = f"{name} {lat:.4f} {lon:.4f}".strip()
        else:
            lat = lon = None
            name, state, country = place_codes(location_label(location) if src == "region" else label)
            if pt and src != "region":
                lat, lon = pt[0], pt[1]
                if (codes := point_codes(lat, lon))[2]:
                    name, state, country = codes
                name = f"{name} {lat:.4f} {lon:.4f}".strip()
        out.append({"key": f"{day.isoformat()}|{cell}", "date": day.strftime("%m/%d/%Y"), "start": times[0].strftime("%H:%M"),
                    "minutes": max(1, math.ceil((times[-1] - times[0]).total_seconds() / 60)),
                    "name": name or "BirdCM location", "lat": lat, "lon": lon, "state": state, "country": country,
                    "photos": [p for _, p, _ in items]})
    return out


def record_csv(photos: list[dict], location, species: list[str], counts: dict[str, str] | None = None,
               comments: dict[str, str] | None = None, protocol: str = "Incidental", with_files: bool = False) -> str:
    """The Record Format file (no header): one row per species per checklist."""
    if protocol not in PROTOCOLS:
        raise ValueError(f"protocol 只能是 {' / '.join(PROTOCOLS)}")
    keep = set(species)
    names = clements()
    lines = []
    for cl in checklists(photos, location, keep):
        per: dict[str, list[dict]] = defaultdict(list)
        for p in cl["photos"]:
            per[_effective(p)["label"]["sci"]].append(p)
        for sci in sorted(per):
            genus_only = sci.endswith(" sp.")
            genus, _, epithet = sci.partition(" ")
            common = "" if genus_only else names.get(sci, ("", ""))[0] or (_effective(per[sci][0])["label"].get("en") or "")
            n = (counts or {}).get(sci) or "X"
            if n.upper() != "X" and not (n.isdigit() and 0 < int(n) < 999999):
                raise ValueError(f"{sci} 的数量要是 1–999998 的整数或 X")
            note = (comments or {}).get(sci) or ""
            if with_files:
                note = (note + " " if note else "") + "photos: " + " ".join(Path(p["path"]).name for p in per[sci])
            row = [common, genus, epithet, n, note, cl["name"],
                   "" if cl["lat"] is None else f"{cl['lat']:.5f}", "" if cl["lon"] is None else f"{cl['lon']:.5f}",
                   cl["date"], cl["start"], cl["state"], cl["country"], protocol,
                   "1" if protocol == "Stationary" else "", str(min(cl["minutes"], 1439)) if protocol == "Stationary" else "", "N",
                   "", "", f"From BirdCM photo review ({len(cl['photos'])} photos); not a complete count"]
            lines.append(line(row))
    return finish(lines)


def line(row: list) -> str:
    """One Record Format row: 19 fields, each cleaned to its Appendix A limit, comma-joined, no quoting."""
    return ",".join(clean(v, n) for v, n in zip(row, LIMITS))


def finish(lines: list[str]) -> str:
    """LF after every row; refused (never cut) above eBird's 1 MB."""
    text = "\n".join(lines) + ("\n" if lines else "")
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise ValueError("文件超过 eBird 的 1 MB 上限：请少选几种或分几次导出")
    return text


LIFELIST_NOTE = "From BirdCM photo review; not a complete count"


def lifelist_checklists(ix, frm=None, to=None, species: set[str] | None = None) -> list[dict]:
    """The life list's checklists: one per (local day, place bucket) of eligible observations (§8.1). A point bucket's
    coordinates are those of its first evidence (capture wall time, photo hash, subject id); a region or no place has
    none (eBird's Fix Locations step). Start time = earliest capture wall time on a photo-dated row, else blank."""
    from birdcm import rarity
    out: dict[tuple, dict] = {}
    for g in ix.groups_in(frm, to):
        if species is not None and g["sci"] not in species:
            continue
        cl = out.setdefault((g["day"], g["place_key"]), {"groups": [], "rows": []})
        cl["groups"].append(g)
        cl["rows"] += g["rows"]
    res = []
    for (day, pk), cl in sorted(out.items()):
        rows = sorted(cl["rows"], key=lambda r: (r["capture_wall"] or "", r["asset_hash"], r["subject_id"]))
        first = rows[0]
        lat = lon = None
        if first["lat"] is not None:
            lat, lon = min(89.99999, max(-89.99999, first["lat"])), first["lon"]
            name, state, country = point_codes(lat, lon)
            name = f"{name} {lat:.4f} {lon:.4f}".strip()
        elif first["region_code"]:
            code = first["region_code"]
            nm = rarity.region_names(code)
            name = (nm[0] if nm else code) + (f" {code[:2]}" if "-" in code else "")
            state, country = (code.split("-", 1)[1] if "-" in code else ""), code[:2]
        else:
            name, state, country = "", "", ""
        timed = [r["capture_wall"] for r in rows if r["date_source"] in ("photo", "user") and r["capture_wall"] and len(r["capture_wall"]) >= 16]
        y, m, d = day.split("-")
        res.append({"key": f"{day}|{pk}", "day": day, "place_key": pk, "date": f"{m}/{d}/{y}", "start": min(timed)[11:16] if timed else "",
                    "name": name or "BirdCM location", "lat": lat, "lon": lon, "state": state, "country": country,
                    "fallback": any(r["date_source"].startswith("identified") for r in rows), "groups": cl["groups"]})
    return res


def lifelist_csv(ix, frm=None, to=None, species: list[str] | None = None, counts: dict[str, str] | None = None,
                 use_estimates: bool = False, fallback: str = "refuse") -> str:
    """The life list as a Record Format file: one row per species per checklist, Incidental, complete N, count X unless
    estimates are asked for or a count is given (1-999998 or X) per species. fallback: rows whose capture date is the
    identification date: refuse (ValueError until reviewed) | include | exclude."""
    names = clements()
    keep = set(species) if species is not None else None
    lines = []
    cls = lifelist_checklists(ix, frm, to, keep)
    if fallback == "refuse" and any(c["fallback"] for c in cls):
        raise ValueError("有照片没有拍摄日期（按首次识别日期统计）：请先核对，选择包含或排除这些记录")
    for cl in cls:
        if cl["fallback"] and fallback == "exclude":
            continue
        for g in sorted(cl["groups"], key=lambda g: g["sci"]):
            sci = g["sci"]
            genus, _, epithet = sci.partition(" ")
            n = (counts or {}).get(sci) or (str(g["estimate"]) if use_estimates else "X")
            if n.upper() != "X" and not (n.isdigit() and 0 < int(n) < 999999):
                raise ValueError(f"{sci} 的数量要是 1–999998 的整数或 X")
            note = LIFELIST_NOTE + ("; capture date missing (identification date used)" if cl["fallback"] else "")
            lines.append(line([names.get(sci, ("", ""))[0], genus, epithet, "X" if n.upper() == "X" else n, "", cl["name"],
                               "" if cl["lat"] is None else f"{cl['lat']:.5f}", "" if cl["lon"] is None else f"{cl['lon']:.5f}",
                               cl["date"], cl["start"], cl["state"], cl["country"], "Incidental", "", "", "N", "", "", note]))
    return finish(lines)
