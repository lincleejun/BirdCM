"""Choose the "confirmed to species" rule on the evaluation set only (never the owner's photos).

  uv run python bench/calibrate.py EVAL_JSON          # rows written by `birdcm eval --out` (location prior on)

Rule: species when p1 >= P and p1 - p2 >= M (posterior, after the location prior); else genus when the best genus sum
>= G; else 不确定. Target: precision among confirmed species >= 97 %, coverage as high as possible.
Choice by 5-fold cross-validation with folds by species (a species is never on both sides): on each training part,
pick the (P, M) with the highest coverage whose precision is >= the target; report the held-out precision and
coverage; the final rule is the one picked on all photos. Same for G on genus-level precision.
Rows whose truth name is not in the AviList list (a label typo in the list) are left out of the choice.
"""
from __future__ import annotations

import json
import sys
import zlib

import numpy as np

TARGET = 0.97
PS = np.round(np.arange(0.30, 0.99, 0.02), 2)
MS = np.round(np.arange(0.0, 0.81, 0.05), 2)
GS = np.round(np.arange(0.30, 0.99, 0.02), 2)


def load(path: str, names: set[str]):
    rows = [r for r in json.load(open(path))["rows"] if r["kind"] == "bird" and r["truth"] in names
            and r["top5"] and not r["rejected"]]
    p1 = np.array([r["top5p"][0] for r in rows])
    p2 = np.array([r["top5p"][1] for r in rows])
    ok = np.array([r["top5"][0] == r["truth"] for r in rows])
    gp = np.array([r["genus_p"] or 0 for r in rows])
    gok = np.array([(r["genus"] or "").split(" ")[0] == r["truth"].split(" ")[0] for r in rows])
    fold = np.array([zlib.crc32(r["truth"].encode()) % 5 for r in rows])
    return rows, p1, p2, ok, gp, gok, fold


def pick(p1, p2, ok, idx):
    best = None
    for P in PS:
        for M in MS:
            c = idx & (p1 >= P) & (p1 - p2 >= M)
            if c.sum() < 20:
                continue
            prec, cov = ok[c].mean(), c.sum() / idx.sum()
            if prec >= TARGET and (best is None or cov > best[2] or (cov == best[2] and (P, M) < best[:2])):
                best = (float(P), float(M), float(cov), float(prec))
    return best


def pick_g(gp, gok, idx):
    best = None
    for G in GS:
        c = idx & (gp >= G)
        if c.sum() < 20:
            continue
        prec, cov = gok[c].mean(), c.sum() / idx.sum()
        if prec >= TARGET and (best is None or cov > best[1]):
            best = (float(G), float(cov), float(prec))
    return best


def main() -> None:
    names = set(map(str, np.load(sys.argv[2])["scientific"])) if len(sys.argv) > 2 else None
    rows, p1, p2, ok, gp, gok, fold = load(sys.argv[1], names or {json.load(open(sys.argv[1]))["rows"][0]["truth"]} | set())
    every = np.ones(len(rows), bool)
    out = {"photos": len(rows), "top1_among_them": round(float(ok.mean()), 4), "target_precision": TARGET, "cv": []}
    held_c = held_ok = 0
    for k in range(5):
        tr, te = fold != k, fold == k
        P, M, *_ = pick(p1, p2, ok, tr)
        c = te & (p1 >= P) & (p1 - p2 >= M)
        held_c += c.sum()
        held_ok += ok[c].sum()
        out["cv"].append({"fold": k, "P": P, "M": M, "held_out_coverage": round(float(c.sum() / te.sum()), 4),
                          "held_out_precision": round(float(ok[c].mean()), 4)})
    out["cv_pooled"] = {"coverage": round(float(held_c / len(rows)), 4), "precision": round(float(held_ok / held_c), 4)}
    P, M, cov, prec = pick(p1, p2, ok, every)
    out["chosen"] = {"P": P, "M": M, "coverage": round(cov, 4), "precision": round(prec, 4)}
    rest = every & ~((p1 >= P) & (p1 - p2 >= M))
    G, gcov, gprec = pick_g(gp, gok, rest)
    out["genus_on_the_rest"] = {"G": G, "coverage_of_rest": round(gcov, 4), "precision": round(gprec, 4)}
    # the curve (all photos, M = chosen) for the doc
    out["curve"] = [{"P": float(p), "coverage": round(float(((p1 >= p) & (p1 - p2 >= M)).mean()), 4),
                     "precision": round(float(ok[(p1 >= p) & (p1 - p2 >= M)].mean()), 4)} for p in PS[::3]]
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
