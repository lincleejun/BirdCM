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
        some = any(b.get("species") and b["species"]["top5"][0]["sci"] == truth for b in boxes)
        c["oracle_top1"] += some
        c["subject_right_when_some_box_right"] += some and t1
    pct = lambda k, d=n: round(100 * c[k] / d, 2) if d else None      # noqa: E731
    out = {**c, **{f"{k}_pct": pct(k) for k in ("bird_found", "kept", "rejected_by_gate", "top1", "top5", "oracle_top1", "failed")}}
    out["subject_choice_pct"] = pct("subject_right_when_some_box_right", c["oracle_top1"])
    mammals = [r for r in rows if r["kind"] == "mammal"]
    if mammals:
        rej = sum(1 for r in mammals if r["result"] is None or r["result"]["rejected"])
        out.update(mammal_photos=len(mammals), mammal_rejected=rej, mammal_rejected_pct=round(100 * rej / len(mammals), 2))
    return out


def run(groundtruth: str, photos: str, kinds: tuple[str, ...] = ("bird",), limit: int | None = None,
        out: str | None = None, workers: int = 4) -> dict:
    from birdcm.pipeline import Engine
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
        items.append({"id": i, "path": str(p), "size": st.st_size, "mtime_ns": st.st_mtime_ns})
    e = Engine(workers=workers)
    t0 = time.perf_counter()
    got = {}
    try:
        for it, res, err in e.run(items):
            got[it["id"]] = (res, err)
    finally:
        e.close()
    rows = [{"kind": r["kind"], "truth": r["scientific"], "path": r["path"],
             "result": got.get(i, (None, "missing"))[0], "error": got.get(i, (None, "missing"))[1]} for i, r in enumerate(gt)]
    report = {**score(rows), "missing_files": len(missing), "seconds": round(time.perf_counter() - t0, 1),
              "location_prior": False, "fingerprint": e.fingerprint(None)}
    names = set(e.tower.sci)
    report["truth_not_in_names"] = sum(1 for r in gt if r["kind"] == "bird" and r["scientific"] not in names)
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w") as f:
            json.dump({"report": report, "rows": [{k: v for k, v in r.items() if k != "result"} |
                                                   {"top5": [c["sci"] for c in ((r["result"] or {}).get("species") or {}).get("top5", [])],
                                                    "rejected": (r["result"] or {}).get("rejected"),
                                                    "reject_reason": (r["result"] or {}).get("reject_reason"),
                                                    "boxes": len((r["result"] or {}).get("boxes") or [])} for r in rows]},
                      f, ensure_ascii=False, indent=0)
    return report
