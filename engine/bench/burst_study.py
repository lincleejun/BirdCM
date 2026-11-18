"""What distinguishes the frames the owner kept from their burst-mates? (analysis for docs/stars.md; reads only)

  uv run python bench/burst_study.py 10061114 DB_PATH SCAN_ID CACHE_DIR
  uv run python bench/burst_study.py 10161115 RESULTS.jsonl - CACHE_DIR

Paired within bursts, so scene, light and species are held constant: for every burst with at least one kept and one
unkept frame (both not rejected), every (kept, unkept) pair counts once; a signal's within-burst AUC is the share of
pairs where the kept frame has the larger value (ties 1/2). 0.5 = no information.
Image signals come from the cached 512 px thumbnails BirdCM already wrote (never the photo folder).
"""
from __future__ import annotations

import json
import math
import os
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
from PIL import Image

from birdcm import config
from birdcm.pipeline import image_paths
from birdcm.stars import _seconds, focus_class, group_bursts

BENCH = Path("/Users/outman/workspace/personal/bioclip-bird/notes/culling-bench")


def load(name, src, scan):
    if name == "10161115":
        keep = {r["stem"]: bool(r["keep"]) for r in json.load(open(BENCH / "cmp_rows.json"))}
        res = {}
        for line in open(src):
            e = json.loads(line)
            res[Path(e["path"]).stem.lower()] = (e["path"], e["result"])
    else:
        keep = {r["stem"]: r["rating"] > 0 for r in json.load(open(BENCH / "rows.json")) if r["folder"] == name}
        db = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        res = {}
        for path, result in db.execute("SELECT path, result FROM photo WHERE scan_id = ?", (int(scan),)):
            p = Path(path)
            if p.suffix.lower() == ".arw" and p.stem.lower() in keep:
                res[p.stem.lower()] = (path, json.loads(result) if result else None)
    return keep, res


def thumb_gray(path: str) -> np.ndarray | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    t, _ = image_paths(path, st.st_size, st.st_mtime_ns)
    if not t.exists():
        return None
    return np.asarray(Image.open(t).convert("L"), np.float32) / 255


def features(path: str, r: dict, g: np.ndarray | None) -> dict:
    s = r["boxes"][r["subject"]] if r.get("subject") is not None else None
    f = {"sharpness": r.get("sharpness"), "eye_p": r.get("eye_p"), "beak_p": r.get("beak_p"), "p_fly": r.get("p_fly"),
         "aesthetic": r.get("aesthetic"), "max_cos": (r.get("species") or {}).get("max_cos"),
         "top1_p": ((r.get("species") or {}).get("top5") or [{}])[0].get("p")}
    if s:
        x0, y0, x1, y1 = s["box"]
        W, H = r["width"], r["height"]
        f.update(det=s["score"], area=(x1 - x0) * (y1 - y0), aspect=((x1 - x0) * W) / max(1e-6, (y1 - y0) * H),
                 edge_cut=float(min(x0, y0, 1 - x1, 1 - y1) < 0.01), center_dist=-math.hypot((x0 + x1) / 2 - 0.5, (y0 + y1) / 2 - 0.5),
                 n_boxes=len(r["boxes"]))
        both = [b for b in r["boxes"] if b is s]
        if s.get("eye") and s.get("beak"):
            dx, dy = (s["beak"][0] - s["eye"][0]) * W, (s["beak"][1] - s["eye"][1]) * H
            f["eye_beak_len"] = math.hypot(dx, dy) / max((x1 - x0) * W, (y1 - y0) * H)      # long = profile, short = facing
        if r.get("focus") and s.get("eye"):
            f["focus_to_eye"] = -math.hypot((r["focus"][0] - s["eye"][0]) * W, (r["focus"][1] - s["eye"][1]) * H) / max(W, H)
        fc = focus_class(r)
        f["focus_head"] = None if fc is None else float(fc == "head")
        if g is not None:
            h, w = g.shape
            bx = g[int(y0 * h):max(int(y0 * h) + 1, int(y1 * h)), int(x0 * w):max(int(x0 * w) + 1, int(x1 * w))]
            f["clip_hi"] = float((bx > 0.98).mean())
            f["clip_lo"] = float((bx < 0.02).mean())
            gy, gx = np.gradient(g)
            e = np.hypot(gx, gy)
            m = np.ones_like(e, bool)
            m[int(y0 * h):int(y1 * h) + 1, int(x0 * w):int(x1 * w) + 1] = False
            f["bg_clean"] = -float(e[m].mean()) if m.any() else None
            crop = Image.fromarray((bx * 255).astype(np.uint8)).resize((24, 24), Image.Resampling.BILINEAR) if bx.size > 4 else None
            f["_crop"] = None if crop is None else (np.asarray(crop, np.float32) / 255).ravel()
    return f


def dist(a, b) -> float | None:
    if a is None or b is None:
        return None
    a, b = a - a.mean(), b - b.mean()
    return float(np.linalg.norm(a - b) / (np.linalg.norm(a) + np.linalg.norm(b) + 1e-6))


def main() -> None:
    name, src, scan, cache = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    os.environ["BIRDCM_CACHE_DIR"] = cache
    keep, res = load(name, src, scan)
    stems = sorted(s for s in keep if s in res and res[s][1])
    photos = [{"id": n, "camera": res[s][1]["exif"].get("camera"), "taken_at": res[s][1]["exif"].get("taken_at")} for n, s in enumerate(stems)]
    bursts = group_bursts(photos)
    by = defaultdict(list)
    for n, s in enumerate(stems):
        by[bursts[n][0]].append(n)
    F = {}
    for n, s in enumerate(stems):
        r = res[s][1]
        F[n] = features(res[s][0], r, thumb_gray(res[s][0])) if not r["rejected"] else None
    # burst-relative signals: sharpness rank, position, time since previous, change from neighbours
    for b, ids in by.items():
        ids.sort(key=lambda n: (_seconds(res[stems[n]][1]["exif"].get("taken_at")) or 0, n))
        live = [n for n in ids if F[n]]
        for k, n in enumerate(ids):
            if not F[n]:
                continue
            F[n]["pos_first"] = float(k == 0)
            F[n]["pos_last"] = float(k == len(ids) - 1)
            F[n]["pos_rel"] = k / max(1, len(ids) - 1)
            t = _seconds(res[stems[n]][1]["exif"].get("taken_at"))
            tp = _seconds(res[stems[ids[k - 1]]][1]["exif"].get("taken_at")) if k else None
            F[n]["gap_prev"] = (t - tp) if t is not None and tp is not None else None
            nb = [ids[j] for j in (k - 1, k + 1) if 0 <= j < len(ids) and F[ids[j]]]
            ds = [d for d in (dist(F[n].get("_crop"), F[m].get("_crop")) for m in nb) if d is not None]
            F[n]["change_from_neighbours"] = min(ds) if ds else None
        vals = [F[n]["sharpness"] for n in live if F[n].get("sharpness") is not None]
        for n in live:
            v = F[n].get("sharpness")
            F[n]["sharp_rank"] = None if v is None or len(vals) < 2 else sum(x < v for x in vals) / (len(vals) - 1)
    keys = sorted({k for f in F.values() if f for k in f if not k.startswith("_")})
    auc = {}
    for k in keys:
        win = pairs = 0
        bursts_used = 0
        for ids in by.values():
            kept = [F[n][k] for n in ids if F[n] and keep[stems[n]] and F[n].get(k) is not None]
            not_ = [F[n][k] for n in ids if F[n] and not keep[stems[n]] and F[n].get(k) is not None]
            if kept and not_:
                bursts_used += 1
                for a in kept:
                    for c in not_:
                        pairs += 1
                        win += 1.0 if a > c else 0.5 if a == c else 0.0
        if pairs:
            auc[k] = {"auc": round(win / pairs, 3), "pairs": pairs, "bursts": bursts_used}
    # the same, each burst weighted once (a 17-keep burst must not decide alone)
    for k in keys:
        per = []
        for ids in by.values():
            kept = [F[n][k] for n in ids if F[n] and keep[stems[n]] and F[n].get(k) is not None]
            not_ = [F[n][k] for n in ids if F[n] and not keep[stems[n]] and F[n].get(k) is not None]
            if kept and not_:
                per.append(np.mean([1.0 if a > c else 0.5 if a == c else 0.0 for a in kept for c in not_]))
        if k in auc and per:
            auc[k]["auc_per_burst"] = round(float(np.mean(per)), 3)
    # which bursts get a keep at all (burst-level signals, each burst once)
    blev = {}
    bfeat = []
    for ids in by.values():
        live = [n for n in ids if F[n]]
        if not live:
            continue
        t = [_seconds(res[stems[n]][1]["exif"].get("taken_at")) for n in ids]
        t = [x for x in t if x is not None]
        g = lambda k, fn=max: fn([F[n][k] for n in live if F[n].get(k) is not None] or [None]) if any(F[n].get(k) is not None for n in live) else None  # noqa: E731
        bfeat.append((any(keep[stems[n]] for n in live), {"frames": len(live), "duration": (max(t) - min(t)) if len(t) > 1 else 0.0,
                      "max_sharp": g("sharpness"), "max_aes": g("aesthetic"), "max_area": g("area"), "max_eye_p": g("eye_p"),
                      "max_fly": g("p_fly"), "max_change": g("change_from_neighbours"), "mean_aes": g("aesthetic", lambda v: sum(v) / len(v))}))
    for k in bfeat[0][1]:
        pos = [f[k] for y, f in bfeat if y and f[k] is not None]
        neg = [f[k] for y, f in bfeat if not y and f[k] is not None]
        if pos and neg:
            blev[k] = round(float(np.mean([1.0 if a > c else 0.5 if a == c else 0.0 for a in pos for c in neg])), 3)
    # how the owner spreads keeps
    sizes, spread = [], []
    for ids in by.values():
        live = [n for n in ids if F[n]]
        kk = [n for n in live if keep[stems[n]]]
        if kk:
            sizes.append((len(live), len(kk)))
            idx = sorted(live.index(n) for n in kk)
            spread.append(idx)
    adj = sum(1 for idx in spread for a, b in zip(idx, idx[1:]) if b - a == 1)
    gaps = sum(len(idx) - 1 for idx in spread)
    # near-duplicate neighbours split keep / not keep: the ceiling of exact hits among near-identical frames
    nd = []
    for ids in by.values():
        live = [n for n in ids if F[n]]
        for a, b in zip(live, live[1:]):
            d = dist(F[a].get("_crop"), F[b].get("_crop"))
            if d is not None:
                nd.append((d, keep[stems[a]] != keep[stems[b]], keep[stems[a]] or keep[stems[b]]))
    nd.sort()
    q = np.quantile([d for d, *_ in nd], [0.25, 0.5]) if nd else [0, 0]
    near = [x for x in nd if x[0] <= q[0]]
    near_with_keep = [x for x in near if x[2]]
    report = {
        "batch": name, "photos": len(stems), "keeps": sum(keep[s] for s in stems), "bursts": len(by),
        "bursts_with_keep": len(spread),
        "keeps_per_kept_burst": dict(sorted(Counter(k for _, k in sizes).items())),
        "kept_burst_size_vs_keeps": {"median_size": float(np.median([s for s, _ in sizes])), "median_keeps": float(np.median([k for _, k in sizes])),
                                     "share_of_frames_kept": round(sum(k for _, k in sizes) / sum(s for s, _ in sizes), 3)},
        "multiple_keeps_adjacent": f"{adj}/{gaps} consecutive keep pairs are next to each other in the burst",
        "near_duplicate_neighbours": {"threshold": round(float(q[0]), 4), "pairs": len(near), "with_a_keep": len(near_with_keep),
                                      "split_keep_unkeep": sum(1 for x in near_with_keep if x[1])},
        "within_burst_auc": dict(sorted(auc.items(), key=lambda kv: -abs(kv[1].get("auc_per_burst", 0.5) - 0.5))),
        "burst_level_auc": dict(sorted(blev.items(), key=lambda kv: -abs(kv[1] - 0.5))),
    }
    print(json.dumps(report, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
