"""Build birdcm/data/iucn.csv: the global IUCN Red List category of each AviList v2026 species, by scientific name.

Input (not committed): the Darwin Core archive of the GBIF-hosted checklist "The IUCN Red List of Threatened Species"
  (https://doi.org/10.15468/0qnb58, GBIF dataset 19491596-35ae-4a91-9a98-85cf505f1bd3, licensed CC BY 4.0 in its
  eml.xml and GBIF registry entry): https://hosted-datasets.gbif.org/datasets/iucn/iucn-latest.zip
  Version 2026-1 (published 2026-07-28), downloaded 2026-11-19,
  sha256 2ed2c5f75667fa2dee9dc718406b5ba094fa9312e548934916b16c0c509ccb7d
Run:  uv run python tools/build_iucn.py iucn-latest.zip birdcm/data/iucn.csv

Our processing (state it wherever the table is credited, see birdcm/data/iucn-LICENSE.md):
- only class Aves, rank species, and of each only the "Global" threat status, as a category code; nothing else is kept;
- names are matched to AviList v2026 (data/ebird-names.csv), in this order, and the rule is written on every row:
    exact     the same binomial;
    synonym   a reviewed synonym in data/species-map.sqlite (GBIF Backbone name with state synonym-reviewed, or a
              Wikidata taxon synonym, alias kind 'synonym');
    genus     a genus transfer: another name Wikidata lists for the species (label or alias in species-map.sqlite)
              with the same epithet, but for its gender ending, in a different genus;
    spelling  the same genus and an epithet that differs only in its Latin gender ending;
  synonym, genus and spelling only to an IUCN name that is not an AviList species, and only one to one;
- an AviList species with no match has no row (shown without a category): mostly splits and genus transfers.
  ponytail: no family-level bridge for genus transfers; add one (AviList family + epithet) if the gaps matter.
The category belongs to the IUCN taxon of the matched name; its limits can differ from the AviList species'.
"""
import csv
import io
import sqlite3
import sys
import zipfile
from collections import defaultdict
from pathlib import Path

CODE = {"Least Concern": "LC", "Near Threatened": "NT", "Vulnerable": "VU", "Endangered": "EN",
        "Critically Endangered": "CR", "Extinct in the Wild": "EW", "Extinct": "EX", "Data Deficient": "DD"}
ENDINGS = ("us", "um", "is", "a", "e")
ROOT = Path(__file__).resolve().parents[2]


def epithet(name: str) -> str:
    e = name.split()[1]
    return next((e[:-len(s)] for s in ENDINGS if e.endswith(s)), e)


def stem(name: str) -> str:
    return name.split()[0] + " " + epithet(name)


def one_to_one(pairs) -> dict[str, str]:
    """{avilist: iucn} for the pairs where each side appears with exactly one partner."""
    a, b = defaultdict(set), defaultdict(set)
    for x, y in pairs:
        a[x].add(y), b[y].add(x)
    return {x: next(iter(ys)) for x, ys in a.items() if len(ys) == 1 and len(b[next(iter(ys))]) == 1}


src, out = sys.argv[1:3]
with zipfile.ZipFile(src) as z:
    ids = {}
    for line in io.TextIOWrapper(z.open("taxon.txt"), encoding="utf-8"):
        r = line.rstrip("\n").split("\t")
        if r[4] == "AVES" and r[10] == "species" and r[12] == "accepted":
            ids[r[0]] = f"{r[7]} {r[8]}"
    iucn = {}
    for line in io.TextIOWrapper(z.open("distribution.txt"), encoding="utf-8"):
        r = line.rstrip("\n").split("\t")
        if r[0] in ids and r[2] == "Global":
            assert ids[r[0]] not in iucn, ids[r[0]]                     # one global status per species
            iucn[ids[r[0]]] = CODE[r[5]]

with open(ROOT / "engine/birdcm/data/ebird-names.csv", newline="", encoding="utf-8") as f:
    avilist = [r["scientific"] for r in csv.DictReader(f)]
left = [s for s in avilist if s not in iucn]
free = set(iucn) - set(avilist)                                         # IUCN names no AviList species has

db = sqlite3.connect(f"file:{ROOT / 'data/species-map.sqlite'}?mode=ro", uri=True)
claims = [(s, " ".join(n.split()[:2])) for s, n in db.execute(
    "SELECT sci, gbif_name FROM species_map WHERE gbif_state = 'synonym-reviewed' AND gbif_name IS NOT NULL")]
claims += db.execute("SELECT sci, text FROM alias WHERE kind = 'synonym'").fetchall()
synonym = one_to_one({(s, n) for s, n in claims if s in set(left) and n in free})
left, free = [s for s in left if s not in synonym], free - set(synonym.values())
genus = one_to_one({(s, n) for s, n in db.execute("SELECT sci, text FROM alias WHERE kind != 'synonym'")
                    if s in set(left) and n in free and epithet(s) == epithet(n)})
left, free = [s for s in left if s not in genus], free - set(genus.values())
by_stem = defaultdict(list)
for n in free:
    by_stem[stem(n)].append(n)
spelling = one_to_one({(s, n) for s in left for n in by_stem.get(stem(s), ())})

rows = []
for s in avilist:
    name, match = (s, "exact") if s in iucn else (synonym[s], "synonym") if s in synonym else \
        (genus[s], "genus") if s in genus else (spelling[s], "spelling") if s in spelling else (None, None)
    if name:
        rows.append((s, iucn[name], match, "" if name == s else name))
with open(out, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scientific", "category", "match", "iucn_name"])
    w.writerows(rows)
count = defaultdict(int)
for r in rows:
    count[r[2]] += 1
print(len(avilist), "AviList species;", len(rows), "with a category", dict(count), "; IUCN bird species", len(iucn))
