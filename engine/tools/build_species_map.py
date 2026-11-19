"""Build data/species-map.sqlite: the one offline mapping from each AviList v2026 species to Wikidata (QID, zh/en
Wikipedia article, Commons image file), iNaturalist, GBIF and eBird ids, with a match state and evidence per source,
plus aliases with their source and licence (docs/design-species-search.md §5). The app never guesses an id at run time:
what is not here (or not in an accepted state) is "资料未对应".

Input: engine/birdcm/data/ebird-names.csv (the 11,172 AviList v2026 species, their Clements English name and Cornell
code, from the AviList extended file, CC BY 4.0) and engine/birdcm/data/zh-names.csv (IOC 15.2 Chinese, CC BY 3.0).

Network (maintainer only, never at run time; generic User-Agent, serial, throttled, resumable: every answer is kept in
WORK and a re-run only asks for what is missing):
  Wikidata Query Service  100 names per query, >= 2 s apart (WDQS: 60 s processing per minute, 5 parallel)
  GBIF v2 species match   1 request a second (design §2.2)
  iNaturalist v1 taxa     30 ids per request, 1 request a second (iNat recommended practices)

Run from engine/:
  uv run python tools/build_species_map.py fetch WORK          # all three; or fetch-wikidata / fetch-gbif / fetch-inat
  uv run python tools/build_species_map.py build WORK ../data/species-map.sqlite ../docs/species-map-report.md
"""
from __future__ import annotations

import csv
import hashlib
import json
import sqlite3
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

UA = "BirdCM-build/0.1 (https://github.com/lincleejun/BirdCM)"
DATA = Path(__file__).resolve().parents[1] / "birdcm" / "data"
AVILIST = "AviList v2026"
GBIF_BACKBONE = "d7dddbf4-2cf0-4f39-9b2a-bb099caae6f1"      # the checklist /v2/species/match answers from by default
ACCEPT = {"exact-reviewed", "synonym-reviewed"}              # the states the app may attach content to
SCHEMA_VERSION = 1

# Concept exceptions reviewed by hand (the same lumps as tools/build_zh_names.py, NOTICE.md): AviList's species is wider
# than the Wikidata / iNat / GBIF species of the same name, so no source page is "this species".
NARROWER = {
    "Porphyrio porphyrio": "AviList Purple Swamphen lumps porphyrio + poliocephalus + others; sources keep Western Swamphen",
    "Taeniopygia guttata": "AviList Zebra Finch lumps guttata + castanotis; sources keep them apart",
    "Pericrocotus flammeus": "AviList Scarlet Minivet includes speciosus",
    "Aegithalos iouschistos": "AviList Black-browed Bushtit lumps bonvaloti",
    "Glaucidium gnoma": "AviList Northern Pygmy Owl lumps californicum",
    "Piranga flava": "AviList Hepatic Tanager lumps hepatica",
}
REVIEW = {   # listed in the report for a person to check; the rules still decide the state
    "Butorides striata": "IOC Chinese names of striata / virescens look swapped (zh-names.csv); check the sitelinks",
    "Butorides virescens": "IOC Chinese names of striata / virescens look swapped (zh-names.csv); check the sitelinks",
}
ZH_LANGS = ("zh", "zh-hans", "zh-cn", "zh-sg", "zh-hant", "zh-tw", "zh-hk", "zh-mo")


def norm(s: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", s).casefold().split())


def species() -> list[dict]:
    with open(DATA / "ebird-names.csv", newline="", encoding="utf-8") as f:
        return [{"sci": r["scientific"], "en": r["clements_en"], "ebird": r["ebird_code"]} for r in csv.DictReader(f)]


def http(url: str, data: bytes | None = None, headers: dict | None = None, tries: int = 5):
    """GET / POST with the build User-Agent; honours Retry-After on 429 / 503, backs off on other transient errors."""
    for i in range(tries):
        req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or i == tries - 1:
                raise
            wait = float(e.headers.get("Retry-After") or 5 * 3 ** i)
        except (urllib.error.URLError, TimeoutError):
            if i == tries - 1:
                raise
            wait = 5 * 3 ** i
        print(f"  retry in {wait:.0f}s", file=sys.stderr)
        time.sleep(wait)


class Paced:
    def __init__(self, gap: float):
        self.gap, self.last = gap, 0.0

    def __call__(self):
        w = self.gap - (time.monotonic() - self.last)
        if w > 0:
            time.sleep(w)
        self.last = time.monotonic()


def jsonl(path: Path) -> dict:
    out = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                k, v = json.loads(line)
                out[k] = v
    return out


def append(path: Path, k, v) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps([k, v], ensure_ascii=False) + "\n")


# ---- Wikidata ---------------------------------------------------------------------------------------------------------
WDQS = "https://query.wikidata.org/sparql"


def sparql(q: str, pace: Paced) -> list[dict]:
    pace()
    body = urllib.parse.urlencode({"query": q}).encode()
    res = http(WDQS, body, {"Accept": "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded"})
    return [{**{k: v["value"] for k, v in r.items()}, **{k + "_lang": v["xml:lang"] for k, v in r.items() if "xml:lang" in v}}
            for r in res["results"]["bindings"]]


def taxon(r: dict) -> bool:
    """A real taxon item (Q16521), not a synonym / unavailable-combination item that only carries the old name."""
    return "Q16521" in r.get("insts", "").split("|")


def item_query(match: str, values: list[str]) -> str:
    """One row per candidate item; multi-valued claims are joined with |."""
    vals = " ".join(json.dumps(v) for v in values)
    return f"""SELECT ?key ?item ?name ?rev ?aves
  (GROUP_CONCAT(DISTINCT STRAFTER(STR(?rank), "entity/"); separator="|") AS ?ranks)
  (GROUP_CONCAT(DISTINCT ?ebird; separator="|") AS ?ebirds) (GROUP_CONCAT(DISTINCT ?inat; separator="|") AS ?inats)
  (GROUP_CONCAT(DISTINCT ?gbif; separator="|") AS ?gbifs) (GROUP_CONCAT(DISTINCT ?gbif26; separator="|") AS ?gbif26s)
  (GROUP_CONCAT(DISTINCT ?syn; separator="|") AS ?syns) (MIN(STR(?img)) AS ?image)
  (GROUP_CONCAT(DISTINCT STRAFTER(STR(?inst), "entity/"); separator="|") AS ?insts)
  (SAMPLE(?zh) AS ?zhwiki) (SAMPLE(?en) AS ?enwiki) WHERE {{
  VALUES ?key {{ {vals} }}
  {match}
  OPTIONAL {{ ?item wdt:P225 ?name }}
  OPTIONAL {{ ?item wdt:P105 ?rank }}
  OPTIONAL {{ ?item wdt:P3444 ?ebird }}
  OPTIONAL {{ ?item wdt:P3151 ?inat }}
  OPTIONAL {{ ?item wdt:P846 ?gbif }}
  OPTIONAL {{ ?item wdt:P14607 ?gbif26 }}
  OPTIONAL {{ ?item wdt:P31 ?inst }}
  OPTIONAL {{ ?item wdt:P1420 ?si . ?si wdt:P225 ?syn }}
  OPTIONAL {{ ?item wdt:P18 ?img }}
  OPTIONAL {{ ?zl schema:about ?item; schema:isPartOf <https://zh.wikipedia.org/>; schema:name ?zh }}
  OPTIONAL {{ ?el schema:about ?item; schema:isPartOf <https://en.wikipedia.org/>; schema:name ?en }}
  OPTIONAL {{ ?item schema:version ?rev }}
  BIND(EXISTS {{ ?item wdt:P171* wd:Q5113 }} AS ?aves)
}} GROUP BY ?key ?item ?name ?rev ?aves"""


def label_query(qids: list[str]) -> str:
    vals = " ".join(f"wd:{q}" for q in qids)
    langs = ", ".join(json.dumps(x) for x in (*ZH_LANGS, "en"))
    return f"""SELECT ?item ?kind ?text WHERE {{
  VALUES ?item {{ {vals} }}
  {{ ?item rdfs:label ?text . BIND("label" AS ?kind) }} UNION {{ ?item skos:altLabel ?text . BIND("alt" AS ?kind) }}
  FILTER(LANG(?text) IN ({langs}))
}}"""


def fetch_wikidata(work: Path) -> None:
    pace = Paced(2.0)
    out = work / "wd-name.jsonl"
    done = jsonl(out)
    names = [s["sci"] for s in species() if s["sci"] not in done]
    for i in range(0, len(names), 100):
        batch = names[i:i + 100]
        rows = sparql(item_query("?item wdt:P225 ?key .", batch), pace)
        got = defaultdict(list)
        for r in rows:
            got[r["key"]].append(r)
        for n in batch:
            append(out, n, got.get(n, []))
        print(f"wikidata names {i + len(batch)}/{len(names)}", file=sys.stderr)
    # the items carrying our eBird code (a concept check for every species), and for names with no taxon item the
    # items listing our name as a taxon synonym (P1420 is item-valued: the synonym item's P225)
    name_hits = jsonl(out)
    missing = [s for s in species() if not any(taxon(r) for r in name_hits.get(s["sci"], []))]
    for kind, match, key, among in (("ebird", "?item wdt:P3444 ?key .", "ebird", species()),     # every code: concept check
                                    ("syn", "?item wdt:P1420 ?si . ?si wdt:P225 ?key .", "sci", missing)):
        path = work / f"wd-{kind}.jsonl"
        done = jsonl(path)
        todo = sorted({s[key] for s in among if s[key]} - set(done))
        for i in range(0, len(todo), 100):
            batch = todo[i:i + 100]
            got = defaultdict(list)
            for r in sparql(item_query(match, batch), pace):
                got[r["key"]].append(r)
            for n in batch:
                append(path, n, got.get(n, []))
            print(f"wikidata {kind} {i + len(batch)}/{len(todo)}", file=sys.stderr)
    # labels and aliases of every item found
    path = work / "wd-labels.jsonl"
    done = jsonl(path)
    qids = sorted({r["item"].rsplit("/", 1)[1] for f in ("wd-name", "wd-ebird", "wd-syn") for rs in jsonl(work / f"{f}.jsonl").values()
                   for r in rs} - set(done))
    for i in range(0, len(qids), 200):
        batch = qids[i:i + 200]
        got = defaultdict(list)
        for r in sparql(label_query(batch), pace):
            got[r["item"].rsplit("/", 1)[1]].append([r["kind"], r["text"], r.get("text_lang", "")])
        for q in batch:
            append(path, q, got.get(q, []))
        print(f"wikidata labels {i + len(batch)}/{len(qids)}", file=sys.stderr)


# ---- GBIF / iNat -----------------------------------------------------------------------------------------------------
def fetch_gbif(work: Path) -> None:
    pace = Paced(1.0)
    out = work / "gbif.jsonl"
    done = jsonl(out)
    todo = [s["sci"] for s in species() if s["sci"] not in done]
    for i, n in enumerate(todo):
        pace()
        q = urllib.parse.urlencode({"scientificName": n, "kingdom": "Animalia", "class": "Aves"})
        append(out, n, http(f"https://api.gbif.org/v2/species/match?{q}"))
        if i % 200 == 0:
            print(f"gbif {i}/{len(todo)}", file=sys.stderr)


def fetch_inat(work: Path) -> None:
    pace = Paced(1.0)
    out = work / "inat.jsonl"
    done = jsonl(out)
    ids = sorted({x for f in ("wd-name", "wd-ebird", "wd-syn") for rs in jsonl(work / f"{f}.jsonl").values() for r in rs
                  for x in r.get("inats", "").split("|") if x.isdigit()} - set(done), key=int)
    for i in range(0, len(ids), 30):
        batch = ids[i:i + 30]
        pace()
        res = http(f"https://api.inaturalist.org/v1/taxa/{','.join(batch)}?per_page=30")
        got = {str(t["id"]): {k: t.get(k) for k in ("id", "name", "rank", "is_active", "iconic_taxon_name")} for t in res["results"]}
        for x in batch:
            append(out, x, got.get(x))
        print(f"inat {i + len(batch)}/{len(ids)}", file=sys.stderr)


if __name__ == "__main__":
    cmd, work = sys.argv[1], Path(sys.argv[2])
    work.mkdir(parents=True, exist_ok=True)
    steps = {"fetch-wikidata": [fetch_wikidata], "fetch-gbif": [fetch_gbif], "fetch-inat": [fetch_inat],
             "fetch": [fetch_wikidata, fetch_inat, fetch_gbif]}
    if cmd == "build":
        build(work, Path(sys.argv[3]), Path(sys.argv[4]))
    else:
        for f in steps[cmd]:
            f(work)
