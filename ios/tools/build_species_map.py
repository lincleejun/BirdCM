#!/usr/bin/env python3
"""data/species-map.sqlite -> ios/BirdCM/Resources/species-map.json: only what the iOS species reference reads
(BirdCM/Reference.swift, the same rules as engine/birdcm/online.py). The aliases, revisions and provenance stay in the
sqlite (8.7 MB); this is about 1.9 MB (0.5 MB compressed).

One object per AviList scientific name, keys only when set:
  s  Wikidata match state (exact-reviewed / synonym-reviewed / broader / narrower / split-lump / ambiguous / unmapped)
  q  QID   n  concept note   zh / en  Wikipedia article titles   f  Commons file (Wikidata P18)
  i  iNaturalist taxon id, g  GBIF legacy key: only when that source's own state is accepted

Run from the repository root after tools/build_species_map.py: python3 ios/tools/build_species_map.py
"""
import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ACCEPT = {"exact-reviewed", "synonym-reviewed"}


def build(src: Path) -> dict:
    db = sqlite3.connect(f"{src.as_uri()}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    out = {}
    for r in db.execute("SELECT * FROM species_map ORDER BY sci"):
        e = {"s": r["wd_state"], "q": r["wd_qid"], "n": r["wd_note"], "f": r["commons_file"],
             "i": r["inat_id"] if r["inat_state"] in ACCEPT else None,
             "g": r["gbif_legacy_key"] if r["gbif_state"] in ACCEPT else None}
        out[r["sci"]] = e
    for a in db.execute("SELECT sci, lang, title FROM article WHERE lang IN ('zh', 'en')"):
        if a["sci"] in out:
            out[a["sci"]][a["lang"]] = a["title"]
    return {sci: {k: v for k, v in e.items() if v not in (None, "")} for sci, e in out.items()}


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "data" / "species-map.sqlite"
    dst = ROOT / "ios" / "BirdCM" / "Resources" / "species-map.json"
    m = build(src)
    dst.write_text(json.dumps(m, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n", encoding="utf-8")
    print(f"{dst}: {len(m)} species, {dst.stat().st_size / 1e6:.2f} MB")
