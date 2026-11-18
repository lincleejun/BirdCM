"""Run the pipeline on a list of photos (no database) and write one JSON line per photo: {path, result, error}.

  uv run python bench/run_files.py FILELIST OUT.jsonl [--region-label "美国 · 加利福尼亚州"]
Used by bench/stars_bench.py for batches that are not scanned in the app. Reads the photos only.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from birdcm import geo
from birdcm.pipeline import Engine


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("filelist")
    ap.add_argument("out")
    ap.add_argument("--region-label")
    a = ap.parse_args()
    files = [f for f in Path(a.filelist).read_text().split("\n") if f]
    region = None
    if a.region_label:
        lat, lon = geo.region_point(a.region_label)
        region = {"label": a.region_label, "lat": lat, "lon": lon, "source": "region"}
    items = []
    for i, p in enumerate(files):
        st = os.stat(p)
        items.append({"id": i, "path": p, "size": st.st_size, "mtime_ns": st.st_mtime_ns})
    e = Engine()
    with open(a.out, "w") as out:
        try:
            for it, res, err in e.run(items, region=region):
                out.write(json.dumps({"path": it["path"], "result": res, "error": err}, ensure_ascii=False) + "\n")
        finally:
            e.close()


if __name__ == "__main__":
    main()
