"""Choose the naming rule on the evaluation set only (never the owner's photos), on the FINAL pipeline's output.

  uv run python bench/calibrate.py EVAL_JSON [NAMES_NPZ]     # rows from `birdcm eval --out`; names default: the installed list

Rule (as the app applies it): species when the posterior's first name has p1 >= P and its location prior over the
place (max) >= EPS (or the prior is unknown / there is no place); else genus when the best genus sum >= G; else
不确定. Target: precision among confirmed species >= TARGET at the highest coverage; the same target for genus.

Honesty (Codex C5 / C6):
- names: the full AviList list is required (a missing argument used to shrink the allowed set to ONE species);
  rows whose truth is not in the list are scored through evaluate.CANONICAL, others left out and counted.
- 5-fold cross-validation with folds by species (a species is never on both sides). P, EPS and G are chosen
  TOGETHER on each training part; the held-out parts are pooled for the reported precision / coverage, with a
  Wilson 95 % interval. The final rule is then chosen on all photos and reported separately as "fit on all"
  (optimistic: the same photos chose it). There is no blind test set yet; the report says so.
"""
from __future__ import annotations

import json
import math
import sys
import zlib

import numpy as np

TARGET = 0.97
PS = np.round(np.arange(0.50, 0.99, 0.02), 2)
EPSS = (0.005, 0.01, 0.02)
GS = np.round(np.arange(0.50, 0.99, 0.02), 2)


def wilson(k: int, n: int, z: float = 1.96) -> list[float] | None:
    if not n:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(c - h, 4), round(c + h, 4)]


def load(path: str, names: set[str]):
    from birdcm.evaluate import CANONICAL
    raw = [r for r in json.load(open(path))["rows"] if r["kind"] == "bird"]
    rows, left_out = [], 0
    for r in raw:
        truth = CANONICAL.get(r["truth"], r["truth"])
        if truth not in names:
            left_out += 1
            continue
        if not r["top5"] or r["rejected"]:
            continue
        rows.append({**r, "truth": truth})
    if not rows:
        raise SystemExit("no usable rows: is EVAL_JSON from `birdcm eval --out`?")
    p1 = np.array([r["top5p"][0] for r in rows])
    ok = np.array([r["top5"][0] == r["truth"] for r in rows])
    pr = np.array([(r.get("prior") or {}).get("max", np.inf) if not (r.get("prior") or {}).get("unknown") else np.inf
                   for r in rows], float)                                        # no prior / unknown: never vetoed
    gp = np.array([r["genus_p"] or 0 for r in rows])
    gok = np.array([(r["genus"] or "").split(" ")[0] == r["truth"].split(" ")[0] for r in rows])
    fold = np.array([zlib.crc32(r["truth"].encode()) % 5 for r in rows])
    return rows, p1, ok, pr, gp, gok, fold, left_out


def pick(p1, ok, pr, gp, gok, idx):
    """(P, EPS, G) with the highest species coverage at precision >= TARGET, then G likewise on the rest."""
    best = None
    for E in EPSS:
        for P in PS:
            c = idx & (p1 >= P) & (pr >= E)
            if c.sum() < 20:
                continue
            prec, cov = ok[c].mean(), c.sum() / idx.sum()
            if prec >= TARGET and (best is None or cov > best[2] + 1e-12):
                best = (float(P), float(E), float(cov))
    if best is None:
        raise SystemExit("no (P, EPS) reaches the target precision on a training part")
    P, E, _ = best
    rest = idx & ~((p1 >= P) & (pr >= E))
    G = None
    for g in GS:
        c = rest & (gp >= g)
        if c.sum() >= 20 and gok[c].mean() >= TARGET:
            G = float(g)
            break
    return P, E, G if G is not None else float(GS[-1])


def main() -> None:
    if len(sys.argv) > 2:
        names = set(map(str, np.load(sys.argv[2])["scientific"]))
    else:
        from birdcm import models
        names = set(map(str, np.load(models.paths()["names"])["scientific"]))
    rows, p1, ok, pr, gp, gok, fold, left_out = load(sys.argv[1], names)
    out = {"photos_used": len(rows), "left_out_truth_not_in_list": left_out, "target_precision": TARGET, "folds": []}
    hc = hok = gc = gokn = 0
    for k in range(5):
        tr, te = fold != k, fold == k
        if not te.any() or not tr.any():
            raise SystemExit(f"fold {k} is empty")
        P, E, G = pick(p1, ok, pr, gp, gok, tr)
        sp = te & (p1 >= P) & (pr >= E)
        ge = te & ~sp & (gp >= G)
        hc, hok, gc, gokn = hc + sp.sum(), hok + ok[sp].sum(), gc + ge.sum(), gokn + gok[ge].sum()
        out["folds"].append({"fold": k, "P": P, "EPS": E, "G": G, "held_out_species_coverage": round(float(sp.sum() / te.sum()), 4),
                             "held_out_species_precision": round(float(ok[sp].mean()), 4) if sp.any() else None})
    out["held_out_pooled"] = {"species_coverage": round(float(hc / len(rows)), 4), "species_precision": round(float(hok / hc), 4),
                              "species_precision_ci95": wilson(int(hok), int(hc)),
                              "genus_coverage": round(float(gc / len(rows)), 4),
                              "genus_precision": round(float(gokn / gc), 4) if gc else None, "genus_precision_ci95": wilson(int(gokn), int(gc))}
    every = np.ones(len(rows), bool)
    P, E, G = pick(p1, ok, pr, gp, gok, every)
    sp = (p1 >= P) & (pr >= E)
    ge = ~sp & (gp >= G)
    out["fit_on_all"] = {"P": P, "EPS": E, "G": G, "species_coverage": round(float(sp.mean()), 4),
                         "species_precision": round(float(ok[sp].mean()), 4), "genus_coverage": round(float(ge.mean()), 4),
                         "genus_precision": round(float(gok[ge].mean()), 4) if ge.any() else None,
                         "note": "chosen and scored on the same photos: optimistic"}
    from birdcm import confirm, tower
    cur = (p1 >= tower.SPECIES_P) & (pr >= confirm.EPS)
    cg = ~cur & (gp >= tower.GENUS_P)
    out["current_rule"] = {"P": tower.SPECIES_P, "EPS": confirm.EPS, "G": tower.GENUS_P,
                           "species_coverage": round(float(cur.mean()), 4), "species_precision": round(float(ok[cur].mean()), 4),
                           "species_precision_ci95": wilson(int(ok[cur].sum()), int(cur.sum())),
                           "genus_coverage": round(float(cg.mean()), 4), "genus_precision": round(float(gok[cg].mean()), 4) if cg.any() else None}
    out["blind_test"] = "none yet: every photo here has been used to choose thresholds at some point"
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
