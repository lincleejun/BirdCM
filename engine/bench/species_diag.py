"""Diagnose a species call on given photos under several places: picture-only top 3, the location prior of named
species, the posterior, the confirm outcome, and the subject crop (size, which source). Read-only on the photos;
run with BIRDCM_DATA_DIR / BIRDCM_CACHE_DIR pointing at scratch dirs.

  uv run python bench/species_diag.py FILES.txt "Thalasseus maximus,Thalasseus elegans"
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from birdcm import geo  # noqa: E402
from birdcm.pipeline import SMALL_BOX, Engine  # noqa: E402

PLACES = {"none (picture only)": None,
          "California (region)": {"label": "美国 · 加利福尼亚州", "lat": 37.2, "lon": -119.5, "source": "region"},
          "Bay shore point 37.43,-122.08 (map)": {"label": "美国 · 加利福尼亚州 附近", "lat": 37.43, "lon": -122.08, "source": "map"}}


def main() -> None:
    files = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    watch = sys.argv[2].split(",")
    items = [{"id": i, "path": p, "size": (st := os.stat(p)).st_size, "mtime_ns": st.st_mtime_ns} for i, p in enumerate(files)]
    e = Engine(workers=2)
    sci = e.tower.sci
    out = {}
    try:
        for name, place in PLACES.items():
            for it, r, err in e.run(items, place):
                f = Path(it["path"]).name
                row = out.setdefault(f, {})
                if err or not r or r.get("subject") is None:
                    row[name] = {"error": err, "rejected": r and r["rejected"]}
                    continue
                sp = r["species"]
                b = r["boxes"][r["subject"]]["box"]
                k = 2048 / max(r["width"], r["height"])
                long_px = max((b[2] - b[0]) * r["width"], (b[3] - b[1]) * r["height"]) * k
                d = {"top3": [(c["sci"], c["p"]) for c in sp["top5"][:3]], "level": sp["level"],
                     "label": (sp.get("label") or {}).get("sci"), "check": sp.get("check"), "override": bool(sp.get("override")),
                     "box_long_px_2048": round(long_px), "crop_source": "decode resolution" if long_px < SMALL_BOX else "2048 frame"}
                if place:
                    pt = geo.location_point(place)
                    wide, med = e.geo.spread(pt[0], pt[1], r["exif"].get("taken_at"), pt[2], geo.location_label(place) if pt[2] == "region" else None)
                    d["prior_max_median"] = {w: (round(float(wide[sci.index(w)]), 4), round(float(med[sci.index(w)]), 4)) for w in watch}
                row[name] = d
    finally:
        e.close()
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
