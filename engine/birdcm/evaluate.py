"""`birdcm eval`: the real pipeline over an evaluation list, fixed denominators.

groundtruth.csv (bioclip-bird eval/): path, scientific, kind (bird | mammal), ... The photos are read where they lie
(read-only). Every bird photo counts in every denominator: a photo that fails to decode, has no box, or whose
subject has no species is a miss.

Reported (birds):
  bird_found       the detector gave at least one box (before the clear-bird gate)
  kept             not rejected (a clear box remained)
  rejected_by_gate boxes found but none passed the clear-bird gate (true birds lost to the gate)
  top1 / top5      the subject's image-only species (no location prior) / its top five contain the truth
  oracle_top1      some looked-at box's top-1 is the truth (what a perfect subject choice could reach)
  subject_choice   top1 / oracle_top1 restricted to photos where some box was right: did we pick that box
Mammals (when present): share rejected (the product does not name mammals; a mammal kept is a false bird).
"""
from __future__ import annotations

import csv
import json
import time
from pathlib import Path


def score(rows: list[dict]) -> dict:
    """rows: {kind, truth, result (PhotoResult | None), error}. -> the report (counts and shares)."""
    birds = [r for r in rows if r["kind"] == "bird"]
    n = len(birds)

    c = {"bird_photos": n, "bird_found": 0, "kept": 0, "rejected_by_gate": 0, "top1": 0, "top5": 0, "oracle_top1": 0,
         "subject_right_when_some_box_right": 0, "failed": 0}
    for r in birds:
        res, truth = r["result"], r["truth"]
        if res is None:
            c["failed"] += 1
            continue
        boxes = res.get("boxes") or []
        c["bird_found"] += bool(boxes)
        c["kept"] += not res["rejected"]
        c["rejected_by_gate"] += bool(boxes) and res["rejected"]
        sp = res.get("species") if not res["rejected"] else None
        t1 = bool(sp) and sp["top5"][0]["sci"] == truth
        c["top1"] += t1
        c["top5"] += bool(sp) and any(x["sci"] == truth for x in sp["top5"])
        local = ((sp or {}).get("override") or {}).get("local")          # the congener that lives here, when a rule said so
        c["best_guess"] = c.get("best_guess", 0) + (bool(sp) and (local or sp["top5"][0])["sci"] == truth)
        if sp and sp.get("check") == "rare":
            c["flag_rare"] = c.get("flag_rare", 0) + 1
            c["flag_rare_right"] = c.get("flag_rare_right", 0) + (sp["label"]["sci"] == truth)
        lvl = sp.get("level") if sp else None
        c[f"level_{lvl or 'none'}"] = c.get(f"level_{lvl or 'none'}", 0) + 1
        if lvl == "species":
            c["species_right"] = c.get("species_right", 0) + (sp["label"]["sci"] == truth)
        if lvl == "genus":
            c["genus_right"] = c.get("genus_right", 0) + (sp["label"]["sci"].split(" ")[0] == truth.split(" ")[0])
        some = any(b.get("species") and b["species"]["top5"][0]["sci"] == truth for b in boxes)
        c["oracle_top1"] += some
        c["subject_right_when_some_box_right"] += some and t1
    pct = lambda k, d=n: round(100 * c.get(k, 0) / d, 2) if d else None      # noqa: E731
    out = {**c, **{f"{k}_pct": pct(k) for k in ("bird_found", "kept", "rejected_by_gate", "top1", "top5", "oracle_top1", "failed", "best_guess")}}
    out["subject_choice_pct"] = pct("subject_right_when_some_box_right", c["oracle_top1"])
    for k in ("level_species", "level_genus", "level_uncertain", "level_none"):
        out[f"{k}_pct"] = pct(k) if k in c else 0.0
    out["precision_confirmed_species_pct"] = pct("species_right", c.get("level_species", 0)) if c.get("level_species") else None
    out["precision_genus_pct"] = pct("genus_right", c.get("level_genus", 0)) if c.get("level_genus") else None
    mammals = [r for r in rows if r["kind"] == "mammal"]
    if mammals:
        rej = sum(1 for r in mammals if r["result"] is None or r["result"]["rejected"])
        out.update(mammal_photos=len(mammals), mammal_rejected=rej, mammal_rejected_pct=round(100 * rej / len(mammals), 2))
    return out


def region_label(lat: float, lon: float) -> str | None:
    """The place-list label ("国家 · 州/省" or "国家") of the division or country around a point."""
    from birdcm import geo, rarity
    key = rarity.region_key(lat, lon)
    if not key:
        return None
    c = next((c for c in geo.countries() if c["code"] == key[0]), None)
    if not c:
        return None
    sub = next((zh for cz, zh, en, *_ in rarity._divisions() if cz == c["zh"] and en == key[1]), None) if key[1] else None
    return f'{c["zh"]} · {sub}' if sub else c["zh"]


def run(groundtruth: str, photos: str, kinds: tuple[str, ...] = ("bird",), limit: int | None = None,
        out: str | None = None, workers: int = 4, prior: bool = True, place: str = "point") -> dict:
    """place: "point" = each photo's own coordinates (as gardener's eval); "region" = the division / country that
    contains them, as when a person picks a region instead of a point (the prior is read over the region's lattice)."""
    from birdcm import config
    from birdcm.pipeline import Engine
    config.check_own_dirs(photos)                      # thumbnails go to the cache dir: never inside the photos
    with open(groundtruth, newline="") as f:
        gt = [r for r in csv.DictReader(f) if r["kind"] in kinds][:limit]
    base = Path(photos)
    items, missing = [], []
    for i, r in enumerate(gt):
        p = base / r["path"].removeprefix("photos/")
        if not p.is_file():
            missing.append(str(p))
            continue
        st = p.stat()
        it = {"id": i, "path": str(p), "size": st.st_size, "mtime_ns": st.st_mtime_ns}
        if prior and r.get("lat") and r.get("lon"):                  # the list's own place and date, as gardener's eval
            it.update(gps=[float(r["lat"]), float(r["lon"])], taken_at=r.get("taken_at") or None)
            if place == "region":
                it.update(gps=None, no_gps=True, label=region_label(float(r["lat"]), float(r["lon"])))
        items.append(it)
    e = Engine(workers=workers)
    t0 = time.perf_counter()
    got = {}
    try:
        groups: dict = {}
        for it in items:
            groups.setdefault(it.get("label"), []).append(it)
        for label, its in groups.items():
            for it, res, err in e.run(its, {"label": label, "source": "region"} if label else None):
                got[it["id"]] = (res, err)
    finally:
        e.close()
    rows = [{"kind": r["kind"], "truth": r["scientific"], "path": r["path"],
             "result": got.get(i, (None, "missing"))[0], "error": got.get(i, (None, "missing"))[1]} for i, r in enumerate(gt)]
    report = {**score(rows), "missing_files": len(missing), "seconds": round(time.perf_counter() - t0, 1),
              "location_prior": prior, "fingerprint": e.fingerprint(None)}
    names = set(e.tower.sci)
    report["truth_not_in_names"] = sum(1 for r in gt if r["kind"] == "bird" and r["scientific"] not in names)
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w") as f:
            json.dump({"report": report, "rows": [{k: v for k, v in r.items() if k != "result"} |
                                                   {"top5": [c["sci"] for c in ((r["result"] or {}).get("species") or {}).get("top5", [])],
                                                    "top5p": [c["p"] for c in ((r["result"] or {}).get("species") or {}).get("top5", [])],
                                                    "level": ((r["result"] or {}).get("species") or {}).get("level"),
                                                    "genus": (((r["result"] or {}).get("species") or {}).get("genus") or {}).get("sci"),
                                                    "genus_p": (((r["result"] or {}).get("species") or {}).get("genus") or {}).get("p"),
                                                    "max_cos": ((r["result"] or {}).get("species") or {}).get("max_cos"),
                                                    "visual": (((r["result"] or {}).get("species") or {}).get("visual") or {}),
                                                    "prior": ((r["result"] or {}).get("species") or {}).get("prior"),
                                                    "check": ((r["result"] or {}).get("species") or {}).get("check"),
                                                    "override": ((r["result"] or {}).get("species") or {}).get("override"),
                                                    "label": ((((r["result"] or {}).get("species") or {}).get("label")) or {}).get("sci"),
                                                    "rejected": (r["result"] or {}).get("rejected"),
                                                    "reject_reason": (r["result"] or {}).get("reject_reason"),
                                                    "boxes": len((r["result"] or {}).get("boxes") or [])} for r in rows]},
                      f, ensure_ascii=False, indent=0)
    return report
