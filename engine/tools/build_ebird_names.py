"""Build birdcm/data/ebird-names.csv: for each AviList v2026 species the Clements v2026 English name and the Cornell
Lab species code, as the AviList v2026 extended file lists them (eBird matches its own Clements/eBird taxonomy).

Input (not committed): AviList-v2026-20Oct2026-extended-version.csv (AviList Core Team 2026, CC BY 4.0,
  https://doi.org/10.2173/avilist.v2026), sha256 02663bc97888d8940eab5628ef60b951c3818d998174f8d7549ccc94fe0c85d9
Run:  uv run python tools/build_ebird_names.py AVILIST_EXTENDED.csv birdcm/data/ebird-names.csv
"""
import csv
import sys

src, out = sys.argv[1:3]
rows = []
with open(src, newline="", encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        if r["RANK"] != "species":
            continue
        rows.append((r["SCIENTIFIC NAME"].strip(), r["ENGLISH NAME: CLEMENTS v2026"].strip(), r["SPECIES CODE CORNELL LAB"].strip()))
with open(out, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["scientific", "clements_en", "ebird_code"])
    w.writerows(rows)
print(len(rows), "species;", sum(1 for _, c, _ in rows if c), "with a Clements name")
