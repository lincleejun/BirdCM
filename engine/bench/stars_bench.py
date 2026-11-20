"""Stars against the owner's Lightroom keeps. TEST ONLY: nothing is fitted on these photos.

  uv run python bench/stars_bench.py 10061114 DB_PATH SCAN_ID         # results from a BirdCM scan (read-only)
  uv run python bench/stars_bench.py 10061114 RESULTS.jsonl           # ... or from bench/run_files.py over the folder
  uv run python bench/stars_bench.py 10161115 RESULTS.jsonl           # results from bench/run_files.py

Pre-declared grid (fixed before the first run, all of it reported): strategy "quota" with its defaults (30 % / 30 %),
strategy "select" with keep 25 %, 20 %, 10 %, and keep = the owner's own keep share of eligible photos. No other
setting is tried here; every other number in stars.Config is its default.

Keeps (read-only, bioclip-bird notes/culling-bench): 10061114 = rows.json rating > 0 (110 of 1,947 ARW);
10161115 = cmp_rows.json keep (182 of 1,779). Baselines at the same number of selected photos: random (expected),
Gardener (its verdict, then score), SuperPicky (its stars, then its 0.65 / 0.35 mix; 10161115 only).
"""
from __future__ import annotations

import json
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

from birdcm import models
from birdcm.rarity import Rarity
from birdcm.stars import rate

BENCH = Path("/Users/outman/workspace/personal/bioclip-bird/notes/culling-bench")


def load(name: str, src: str, scan: int | None):
    if name == "10161115":
        keep = {r["stem"]: bool(r["keep"]) for r in json.load(open(BENCH / "cmp_rows.json"))}
        cmp = {r["stem"]: r for r in json.load(open(BENCH / "cmp_rows.json"))}
        sp = {r["stem"]: r for r in json.load(open(BENCH / "sp_rows.json"))}
        gard = {s: (c["status"] == "keep", c["status"] != "reject", c["aes"] or 0) for s, c in cmp.items()}
        supk = {s: (r["rating"] or 0, 0.65 * (r["adj_sharpness"] or 0) / 1000 + 0.35 * (r["nima_score"] or 0) / 10) for s, r in sp.items()}
        res = {}
        for line in open(src):
            e = json.loads(line)
            res[Path(e["path"]).stem.lower()] = e["result"]
    else:
        rows = [r for r in json.load(open(BENCH / "rows.json")) if r["folder"] == name]
        keep = {r["stem"]: r["rating"] > 0 for r in rows}
        gard = {r["stem"]: (r["verdict"] == "pick", r["verdict"] != "reject", r["score"] or 0) for r in rows}
        supk = None
        res = {}
        if src.endswith(".jsonl"):                                       # bench/run_files.py over the folder
            for line in open(src):
                e = json.loads(line)
                if Path(e["path"]).stem.lower() in keep:
                    res[Path(e["path"]).stem.lower()] = e["result"]
        else:
            db = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
            for path, result in db.execute("SELECT path, result FROM photo WHERE scan_id = ?", (scan,)):
                p = Path(path)
                if p.suffix.lower() == ".arw" and p.stem.lower() in keep:
                    res[p.stem.lower()] = json.loads(result) if result else None
    stems = sorted(s for s in keep if s in res)
    return stems, keep, res, gard, supk


def burst_metrics(stems, keep, selected: set, bursts: dict, order: dict) -> dict:
    """Burst-level hit (kept bursts with any star; starred bursts holding a keep) and near hit (a keep that is starred or
    has a starred neighbour, one frame either side in capture order, in its burst)."""
    kb = {b for b, ss in bursts.items() if any(keep[x] for x in ss)}
    sb = {b for b, ss in bursts.items() if any(x in selected for x in ss)}
    near = 0
    for b, ss in bursts.items():
        seqd = sorted(ss, key=lambda x: order[x])
        for k, x in enumerate(seqd):
            if keep[x] and any(y in selected for y in seqd[max(0, k - 1):k + 2]):
                near += 1
    return {"burst_recall": round(len(kb & sb) / len(kb), 3) if kb else None, "burst_precision": round(len(kb & sb) / len(sb), 3) if sb else None,
            "near_hit": near}


def evaluate(name: str, stems, keep, res, gard, supk, table, grid=None) -> list[dict]:
    rows = [{"id": n, "result": res[s]} for n, s in enumerate(stems)]
    K = sum(keep[s] for s in stems)
    eligible = sum(1 for s in stems if res[s] and not res[s]["rejected"])
    own = round(100 * K / eligible, 1)
    if grid:
        grid = [(label, {**cfg, "keep": own if cfg.get("keep") == "own" else cfg.get("keep", 25)}) for label, cfg in grid]
    else:
        grid = [("quota 30/30", {"strategy": "quota"})] + [(f"select {k}%", {"keep": k}) for k in (25, 20, 10)] \
            + [(f"select {own}% (= owner's keep share)", {"keep": own})]
    import random
    from birdcm.stars import _seconds
    order = {s: (_seconds((res[s] or {}).get("exif", {}).get("taken_at")) or 0, s) for s in stems}
    elig_stems = [s for s in stems if res[s] and not res[s]["rejected"]]
    out = []
    for label, cfg in grid:
        r = rate(rows, cfg, rarity=table)
        st = {s: r[n]["stars"] for n, s in enumerate(stems)}
        tier = lambda m: [s for s in stems if (st[s] or 0) >= m]               # noqa: E731
        sel = tier(1)
        N = len(sel)
        row = {"setting": label, "photos": len(stems), "eligible": eligible, "keeps": K,
               "stars": dict(sorted(Counter(st.values()).items(), key=lambda x: (x[0] is None, x[0] or 0)))}
        for m, nm in ((3, "3★"), (2, "2★+"), (1, "any★")):
            t = tier(m)
            hit = sum(keep[s] for s in t)
            row[nm] = {"n": len(t), "keeps": hit, "recall": round(hit / K, 3) if K else None, "precision": round(hit / len(t), 3) if t else None}
        row["random_at_N"] = round(N * K / len(stems), 1)
        bursts_s = defaultdict(list)
        for n, s in enumerate(stems):
            bursts_s[r[n]["burst_group"]].append(s)
        row.update(burst_metrics(stems, keep, set(sel), bursts_s, order))
        rng = random.Random(0)
        sims = [burst_metrics(stems, keep, set(rng.sample(elig_stems, min(N, len(elig_stems)))), bursts_s, order) for _ in range(100)]
        row["random_burst_recall"] = round(sum(x["burst_recall"] or 0 for x in sims) / len(sims), 3)
        row["random_burst_precision"] = round(sum(x["burst_precision"] or 0 for x in sims) / len(sims), 3)
        row["random_near_hit"] = round(sum(x["near_hit"] for x in sims) / len(sims), 1)
        row["gardener_at_N"] = sum(keep[s] for s in sorted(stems, key=lambda s: gard.get(s, (0, 0, 0)), reverse=True)[:N])
        if supk:
            row["superpicky_at_N"] = sum(keep[s] for s in sorted(stems, key=lambda s: supk.get(s, (0, 0)), reverse=True)[:N])
        bursts = defaultdict(list)
        for n, s in enumerate(stems):
            bursts[r[n]["burst_group"]].append(s)
        missed = [s for s in stems if keep[s] and not (st[s] or 0) > 0]
        row["missed_keeps_in_a_starred_burst"] = sum(1 for s in missed if any((st[o] or 0) > 0 for o in bursts[r[stems.index(s)]["burst_group"]]))
        row["missed_keeps"] = len(missed)
        bursts_with_keep = [b for b, ss in bursts.items() if any(keep[x] for x in ss)]
        row["keep_bursts_with_a_star"] = f"{sum(1 for b in bursts_with_keep if any((st[x] or 0) > 0 for x in bursts[b]))}/{len(bursts_with_keep)}"

        def species(n):
            x = r[n].get("species_fix") or (rows[n]["result"] or {}).get("species") or {}
            return (x.get("label") or {}).get("sci") if x.get("level") == "species" else None
        sp_all = Counter(species(n) for n in range(len(stems)) if res[stems[n]] and not res[stems[n]]["rejected"])
        top, cnt = (sp_all.most_common(1) or [(None, 0)])[0]
        sp_st = Counter(species(stems.index(s)) for s in sel)
        row["top_species"] = {"name": top, "share_of_photos": round(cnt / eligible, 3), "share_of_stars": round(sp_st[top] / N, 3) if N else None}
        out.append(row)
    return out


def main() -> None:
    name, src = sys.argv[1], sys.argv[2]
    scan = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] != "-" else None
    stems, keep, res, gard, supk = load(name, src, scan)
    table = Rarity(str(models.paths()["rarity"]))
    grid = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
    print(json.dumps({"batch": name, "results": evaluate(name, stems, keep, res, gard, supk, table, grid)}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
