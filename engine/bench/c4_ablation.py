"""Codex C4: does cropping small birds from the 2048 frame lose species detail? Same subject box, three sources:
the 2048 frame (what the app uses), the decode-resolution image it already has (embedded JPEG at DCT scale, ~3504
px for a 7008 px ARW), and the full embedded JPEG. Image-only species (no location prior).

  uv run python bench/c4_ablation.py SCAN_ID [N_PER_BUCKET]

The evaluation set cannot answer this: all its photos are <= 2048 px, so the frame IS full resolution there. This
uses the owner's photos (read-only), which have no ground truth: it reports how often the first name changes, the
mean first-name probability, and the extra cost, by subject size in frame pixels. Accuracy is not measured.
"""
import io
import json
import os
import random
import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from birdcm import config, decode, geometry, models  # noqa: E402

BUCKETS = [(0, 64), (64, 128), (128, 256), (256, 99999)]


def main() -> None:
    sid = int(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    db = sqlite3.connect(f"file:{config.data_dir() / 'birdcm.db'}?mode=ro", uri=True)
    rows = []
    for path, res in db.execute("SELECT path, result FROM photo WHERE scan_id = ? AND result IS NOT NULL", (sid,)):
        r = json.loads(res)
        if r["rejected"] or r.get("subject") is None:
            continue
        b = r["boxes"][r["subject"]]["box"]
        k = 2048 / max(r["width"], r["height"])
        long_px = max((b[2] - b[0]) * r["width"], (b[3] - b[1]) * r["height"]) * k
        rows.append((path, b, long_px))
    rng = random.Random(0)
    picked = []
    for lo, hi in BUCKETS:
        sel = [x for x in rows if lo <= x[2] < hi]
        picked += [(x, (lo, hi)) for x in rng.sample(sel, min(n, len(sel)))]
    from birdcm.pipeline import pick_device
    from birdcm.tower import Tower
    p = models.paths()
    tower = Tower(str(p["tower"]), str(p["names"]), str(p["parts"]), str(p["flight"]), pick_device())
    stats = defaultdict(lambda: defaultdict(list))
    for (path, box, _), bucket in picked:
        t0 = time.perf_counter()
        im, w, h, _, _ = decode.load_upright(Path(path))                       # decode resolution (DCT-scaled)
        frame = decode._fit(im, decode.FRAME)
        t1 = time.perf_counter()
        import rawpy
        with rawpy.imread(path) as raw:
            full = Image.open(io.BytesIO(raw.extract_thumb().data)).convert("RGB")
        t2 = time.perf_counter()
        crops = {}
        for name, src in (("frame", frame), ("decode", im), ("full", full)):
            rect = geometry.crop_rect(box, src.width, src.height)
            crops[name] = geometry.pad_crop(src, rect)
        looks = dict(zip(crops, tower(list(crops.values()))))
        s = stats[bucket]
        s["n"].append(1)
        for name in ("frame", "decode", "full"):
            s[f"p1_{name}"].append(looks[name]["top5"][0]["p"])
        s["same_decode"].append(looks["decode"]["top5"][0]["sci"] == looks["frame"]["top5"][0]["sci"])
        s["same_full"].append(looks["full"]["top5"][0]["sci"] == looks["frame"]["top5"][0]["sci"])
        s["confirm_frame"].append(looks["frame"]["top5"][0]["p"] >= 0.94)
        s["confirm_full"].append(looks["full"]["top5"][0]["p"] >= 0.94)
        s["t_full_decode_s"].append(t2 - t1)
        s["crop_px_frame"].append(crops["frame"].width)
    out = {}
    for (lo, hi), s in sorted(stats.items()):
        out[f"{lo}-{hi if hi < 99999 else ''} px"] = {
            "photos": len(s["n"]), "subject_crop_px_in_frame": int(np.median(s["crop_px_frame"])),
            "mean_p1_frame": round(float(np.mean(s["p1_frame"])), 3), "mean_p1_decode": round(float(np.mean(s["p1_decode"])), 3),
            "mean_p1_full": round(float(np.mean(s["p1_full"])), 3),
            "same_first_name_decode": round(float(np.mean(s["same_decode"])), 3), "same_first_name_full": round(float(np.mean(s["same_full"])), 3),
            "p1>=0.94_frame": round(float(np.mean(s["confirm_frame"])), 3), "p1>=0.94_full": round(float(np.mean(s["confirm_full"])), 3),
            "extra_full_decode_s": round(float(np.median(s["t_full_decode_s"])), 3)}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    main()
