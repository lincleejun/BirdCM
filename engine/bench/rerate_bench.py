"""Codex P1: re-rating time against scan size. Synthetic rows (one box each); a hard case where every photo is the
same species with equal scores, and a mixed one.  uv run python bench/rerate_bench.py"""
import json
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from birdcm.stars import rate  # noqa: E402
from test_select import photo  # noqa: E402


def rows(n: int, same: bool) -> list[dict]:
    rng = random.Random(n)
    out = []
    for i in range(n):
        t = 2.0 * i if i % 8 else 2.0 * i + 30          # bursts of about 8
        sp = "Aa bb" if same else f"S{rng.randrange(40)} x"
        sharp = 3.0 if same else rng.uniform(1, 4)
        aes = 0.6 if same else rng.uniform(0.4, 0.75)
        out.append({"id": i, "result": photo(t, sp=sp, sharp=sharp, aes=aes)})
    return out


if __name__ == "__main__":
    res = {}
    for kind in ("same species, equal scores", "40 species, random scores"):
        for n in (1000, 2000, 5000, 10000):
            rs = rows(n, kind.startswith("same"))
            t = time.perf_counter()
            out = rate(rs, {"keep": 20})
            res.setdefault(kind, {})[n] = round(time.perf_counter() - t, 2)
            if "--dump" in sys.argv:
                Path(f"/tmp/rerate-{kind[:4]}-{n}.json").write_text(json.dumps({k: v["stars"] for k, v in out.items()}))
    print(json.dumps(res, indent=1))
