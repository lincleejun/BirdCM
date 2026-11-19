"""Build data/species-map.sqlite: the one offline mapping from each AviList v2026 species to Wikidata (QID, zh/en
Wikipedia article, Commons image file), iNaturalist, GBIF and eBird ids, with a match state and evidence per source,
plus aliases with their source and licence (docs/design-species-search.md §5). The app never guesses an id at run time:
what is not here (or not in an accepted state) is "资料未对应".

Input: engine/birdcm/data/ebird-names.csv (the 11,172 AviList v2026 species, their Clements English name and Cornell
code, from the AviList extended file, CC BY 4.0) and engine/birdcm/data/zh-names.csv (IOC 15.2 Chinese, CC BY 3.0).

Network (maintainer only, never at run time; generic User-Agent, serial, throttled, resumable: every answer is kept in
WORK and a re-run only asks for what is missing):
  Wikidata Query Service  100 names per query, >= 2 s apart (WDQS: 60 s processing per minute, 5 parallel)
  GBIF v2 species match   batch POST, 200 names a request, >= 2 s apart (design §2.2: 1 request a second)
  iNaturalist v1 taxa     30 ids per request, 1 request a second (iNat recommended practices)

Run from engine/:
  uv run python tools/build_species_map.py fetch WORK          # all three; or fetch-wikidata / fetch-gbif / fetch-inat
  uv run python tools/build_species_map.py build WORK ../data/species-map.sqlite ../docs/species-map-report.md
"""
from __future__ import annotations

import csv
import hashlib
import json
import os
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
    """The batch form of /v2/species/match (up to 1000 queries a request; 200 here), one request at a time. The
    matching service's metadata (which checklist it answers from) is kept for the manifest."""
    pace = Paced(2.0)
    (work / "gbif-meta.json").write_text(json.dumps(http("https://api.gbif.org/v2/species/match/metadata")["mainIndex"]))
    out = work / "gbif.jsonl"
    done = jsonl(out)
    todo = [s["sci"] for s in species() if s["sci"] not in done]
    for i in range(0, len(todo), 200):
        batch = todo[i:i + 200]
        pace()
        body = json.dumps([{"scientificName": n, "kingdom": "Animalia", "class": "Aves"} for n in batch]).encode()
        res = http("https://api.gbif.org/v2/species/match", body, {"Content-Type": "application/json"})
        assert len(res) == len(batch)
        for n, r in zip(batch, res):
            append(out, n, r)
        print(f"gbif {i + len(batch)}/{len(todo)}", file=sys.stderr)


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


# ---- the rules ---------------------------------------------------------------------------------------------------------
TAXON = {"Q16521", "Q23038290", "Q98961713"}          # taxon, fossil taxon, extinct taxon


def items(rows: list[dict]) -> list[dict]:
    """One candidate per item (a query row per name / revision): multi-valued claims as sets; only real taxon items of
    species rank inside Aves."""
    by = {}
    for r in rows:
        q = r["item"].rsplit("/", 1)[1]
        if not q.startswith("Q"):
            continue                                              # lexeme senses also carry P225
        c = by.setdefault(q, {"qid": q, "names": set(), "ebird": set(), "inat": set(), "gbif": set(), "gbif26": set(), "syns": set(),
                              "ranks": set(), "insts": set(), "aves": False, "rev": 0, "image": None, "zh": None, "en": None})
        c["names"].add(r.get("name", ""))
        for k, f in (("ebird", "ebirds"), ("inat", "inats"), ("gbif", "gbifs"), ("gbif26", "gbif26s"), ("syns", "syns"),
                     ("ranks", "ranks"), ("insts", "insts")):
            c[k] |= {x for x in r.get(f, "").split("|") if x}
        c["aves"] |= r.get("aves") == "true"
        c["rev"] = max(c["rev"], int(r.get("rev") or 0))
        c["image"] = c["image"] or r.get("image")
        c["zh"], c["en"] = c["zh"] or r.get("zhwiki"), c["en"] or r.get("enwiki")
    return [c for c in by.values() if c["aves"] and "Q7432" in c["ranks"] and c["insts"] & TAXON]


def epithet(n: str) -> str:
    return n.split()[-1] if n else ""


def decide_wd(sp: dict, named: list[dict], by_code: list[dict], by_syn: list[dict]) -> tuple[str, dict | None, str]:
    """(state, item, note) for Wikidata. Accepted only when one item is this species by name (or, for a genus transfer
    or a recorded synonym, by eBird code / P1420) and nothing says the concept differs."""
    sci, code = sp["sci"], sp["ebird"]
    if sci in NARROWER:
        return "narrower", (named[0] if len(named) == 1 else None), "人工复核：" + NARROWER[sci]
    if len(named) > 1:
        pick = [c for c in named if code and code in c["ebird"]]
        if len(pick) == 1:
            return "exact-reviewed", pick[0], f"同名 {len(named)} 个条目，按 eBird 代码 {code} 选定 {pick[0]['qid']}"
        return "ambiguous", None, "同名多个条目：" + ", ".join(c["qid"] for c in named)
    if len(named) == 1:
        it = named[0]
        other = [c for c in by_code if c["qid"] != it["qid"]]
        if other:
            return "ambiguous", None, f"学名条目 {it['qid']} 与带 eBird 代码 {code} 的条目 {other[0]['qid']} 不同"
        if code and it["ebird"] and code not in it["ebird"]:
            return "split-lump", it, f"eBird 代码不同：AviList {code}，Wikidata {'/'.join(sorted(it['ebird']))}（分类概念可能有拆分/合并）"
        return "exact-reviewed", it, ""
    cands = {c["qid"]: c for c in by_syn + by_code}
    if not cands:
        return "unmapped", None, "Wikidata 没有这个学名、这个 eBird 代码或这个异名的物种条目"
    if len(cands) > 1:
        return "ambiguous", None, "异名 / eBird 代码指向多个条目：" + ", ".join(cands)
    it = next(iter(cands.values()))
    name = sorted(it["names"])[0]
    if code and it["ebird"] and code not in it["ebird"]:
        return "split-lump", it, f"条目学名 {name}，eBird 代码不同（AviList {code}）"
    if it in by_syn:
        return "synonym-reviewed", it, f"Wikidata 条目学名 {name}，其 P1420 异名列出 {sci}"
    if any(epithet(n) == epithet(sci) for n in it["names"]):
        return "synonym-reviewed", it, f"属变更：Wikidata 条目学名 {name}，eBird 代码 {code} 相同"
    return "ambiguous", None, f"只有 eBird 代码 {code} 指向 {it['qid']}（{name}），学名不同"


def decide_inat(sci: str, wd_state: str, it: dict | None, inat: dict) -> tuple[str, int | None, str, str, str]:
    """(state, id, source name, rank, note): the iNat id Wikidata gives, checked against iNat's own record."""
    if it is None or not it["inat"]:
        return "unmapped", None, "", "", "Wikidata 条目没有 iNaturalist ID" if it else "没有已核验的 Wikidata 条目"
    recs = [inat.get(x) for x in sorted(it["inat"], key=int)]
    live = [r for r in recs if r and r.get("is_active")]
    if not live:
        return "retired", None, "", "", "iNaturalist ID 已停用或不存在：" + ", ".join(sorted(it["inat"]))
    sp = [r for r in live if r["rank"] == "species"]
    exact = [r for r in sp if r["name"] == sci]
    if wd_state not in ACCEPT:
        r = (exact or sp or live)[0]
        return wd_state, r["id"], r["name"], r["rank"], "沿用 Wikidata 条目的概念状态"
    if len(exact) == 1:
        return "exact-reviewed", exact[0]["id"], sci, "species", ""
    if len(sp) == 1 and epithet(sp[0]["name"]) == epithet(sci):
        return "synonym-reviewed", sp[0]["id"], sp[0]["name"], "species", f"iNaturalist 用 {sp[0]['name']}（属不同）"
    if len(sp) == 0 and len(live) == 1:
        r = live[0]
        state = "narrower" if r["rank"] in ("subspecies", "variety", "form") else "broader"
        return state, r["id"], r["name"], r["rank"], f"iNaturalist 的对应单元是 {r['rank']} {r['name']}"
    return "ambiguous", None, "", "", "iNaturalist 候选：" + ", ".join(f"{r['id']} {r['name']} ({r['rank']})" for r in live)


def decide_gbif(sci: str, r: dict) -> tuple[str, str | None, str, str, str]:
    """(state, key, source name, rank, note) from /v2/species/match: an exact species match inside Aves, or a synonym
    whose accepted species keeps the epithet (a genus transfer). Fuzzy and higher-rank answers are never ids."""
    u, acc = r.get("usage") or {}, r.get("acceptedUsage") or {}
    mt = (r.get("diagnostics") or {}).get("matchType")
    aves = any(c.get("name") == "Aves" for c in r.get("classification") or [])
    if mt in (None, "NONE", "HIGHERRANK") or not aves:
        return "unmapped", None, "", "", f"GBIF 匹配结果：{mt}"
    if mt != "EXACT":
        return "ambiguous", None, u.get("canonicalName", ""), u.get("rank", ""), f"GBIF 只给出 {mt} 候选 {u.get('canonicalName')}（{u.get('key')}）"
    if u.get("rank") != "SPECIES" or u.get("canonicalName") != sci:
        return "ambiguous", None, u.get("canonicalName", ""), u.get("rank", ""), "GBIF 精确匹配的不是这个种名"
    if not r.get("synonym"):
        return "exact-reviewed", u["key"], sci, "SPECIES", ""
    if acc.get("rank") == "SPECIES" and acc.get("specificEpithet") == epithet(sci):
        return "synonym-reviewed", acc["key"], acc.get("canonicalName", ""), "SPECIES", f"GBIF 把 {sci} 作为 {acc.get('canonicalName')} 的异名（属变更）"
    state = "narrower" if acc.get("rank") in ("SUBSPECIES", "VARIETY", "FORM") else "split-lump"
    return state, acc.get("key"), acc.get("canonicalName", ""), acc.get("rank", ""), f"GBIF 把 {sci} 作为 {acc.get('rank')} {acc.get('canonicalName')} 的异名"


ZH_HANS, ZH_HANT = {"zh-hans", "zh-cn", "zh-sg", "zh-my"}, {"zh-hant", "zh-tw", "zh-hk", "zh-mo"}


def script(lang: str) -> str:
    return "zh-Hans" if lang in ZH_HANS else "zh-Hant" if lang in ZH_HANT else lang


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


SQL = """
CREATE TABLE manifest (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE species_map (
  sci TEXT PRIMARY KEY, ebird_code TEXT,
  wd_state TEXT NOT NULL, wd_qid TEXT, wd_rev INTEGER, wd_note TEXT,
  inat_state TEXT NOT NULL, inat_id INTEGER, inat_name TEXT, inat_rank TEXT, inat_note TEXT,
  gbif_state TEXT NOT NULL, gbif_key TEXT, gbif_legacy_key INTEGER, gbif_name TEXT, gbif_rank TEXT, gbif_note TEXT,
  gbif_wd_agree INTEGER, gbif_2026_id TEXT, commons_file TEXT
) WITHOUT ROWID;
CREATE TABLE article (sci TEXT NOT NULL, lang TEXT NOT NULL, title TEXT NOT NULL, qid TEXT NOT NULL,
  PRIMARY KEY (sci, lang)) WITHOUT ROWID;
CREATE TABLE alias (sci TEXT NOT NULL, text TEXT NOT NULL, norm TEXT NOT NULL, lang TEXT NOT NULL, kind TEXT NOT NULL,
  source TEXT NOT NULL, licence TEXT NOT NULL);
CREATE INDEX alias_norm ON alias (norm);
CREATE INDEX alias_sci ON alias (sci);
CREATE INDEX map_qid ON species_map (wd_qid);
CREATE INDEX map_inat ON species_map (inat_id);
"""


def build(work: Path, out: Path, report: Path) -> None:
    sps = species()
    zh_rows = {r["scientific"]: r for r in csv.DictReader(open(DATA / "zh-names.csv", newline="", encoding="utf-8"))}
    wd_name, wd_code, wd_syn = (jsonl(work / f"wd-{k}.jsonl") for k in ("name", "ebird", "syn"))
    labels, inat, gbif = jsonl(work / "wd-labels.jsonl"), jsonl(work / "inat.jsonl"), jsonl(work / "gbif.jsonl")
    gmeta = json.loads((work / "gbif-meta.json").read_text())
    missing = [s["sci"] for s in sps if s["sci"] not in wd_name or s["sci"] not in gbif]
    assert not missing, f"fetch first: {len(missing)} species have no answer yet"
    rows, arts, aliases = [], [], []
    for sp in sps:
        sci = sp["sci"]
        state, it, note = decide_wd(sp, items(wd_name[sci]), items(wd_code.get(sp["ebird"], [])) if sp["ebird"] else [],
                                    items(wd_syn.get(sci, [])))
        i_state, i_id, i_name, i_rank, i_note = decide_inat(sci, state, it, inat)
        g_state, g_key, g_name, g_rank, g_note = decide_gbif(sci, gbif[sci])
        if g_key and it and it["gbif"]:
            if g_key not in it["gbif"]:
                g_note = (g_note + "；" if g_note else "") + f"Wikidata P846 为 {'/'.join(sorted(it['gbif']))}"
        img = it and it["image"] and urllib.parse.unquote(it["image"].split("Special:FilePath/", 1)[1])
        rows.append({"sci": sci, "ebird_code": sp["ebird"] or None, "wd_state": state,
                     "wd_qid": it["qid"] if it and state not in ("ambiguous", "unmapped") else None, "wd_rev": it["rev"] if it else None,
                     "wd_note": note or None, "inat_state": i_state, "inat_id": i_id, "inat_name": i_name if i_name != sci else None, "inat_rank": i_rank or None,
                     "inat_note": i_note or None, "gbif_state": g_state, 
                     "gbif_key": g_key, "gbif_legacy_key": int(g_key) if g_key and g_key.isdigit() else None, "gbif_name": g_name if g_name != sci else None,
                     "gbif_rank": g_rank or None, "gbif_note": g_note or None,
                     "gbif_2026_id": "|".join(sorted(it["gbif26"])) or None if it else None,
                     "gbif_wd_agree": (g_key in it["gbif"]) if g_key and it and it["gbif"] else None, "commons_file": img or None, "_it": it})
    # one source item / key for two AviList species: the source concept is wider, so neither gets content
    for col, state_col in (("wd_qid", "wd_state"), ("inat_id", "inat_state"), ("gbif_key", "gbif_state")):
        seen = defaultdict(list)
        for r in rows:
            if r[state_col] in ACCEPT and r[col]:
                seen[r[col]].append(r)
        for k, rs in seen.items():
            if len(rs) > 1:
                for r in rs:
                    r[state_col] = "split-lump"
                    r[col.split("_")[0] + "_note"] = f"同一来源 ID {k} 对应 {len(rs)} 个 AviList 种：" + ", ".join(x["sci"] for x in rs)
    for r in rows:
        it, sci = r.pop("_it"), r["sci"]
        if r["wd_qid"]:
            for lang in ("zh", "en"):
                if it[lang]:
                    arts.append((sci, lang, it[lang], it["qid"]))
        seen = {norm(sci)} | ({norm(zh_rows[sci]["zh"])} if sci in zh_rows else set())

        def add(text, lang, kind, source, lic):
            if text and norm(text) not in seen:
                seen.add(norm(text))
                aliases.append((sci, text, norm(text), lang, kind, source, lic))
        z = zh_rows.get(sci)
        if z and z["zh_hant"]:
            add(z["zh_hant"], "zh-Hant", "name", z["source"], "CC BY 3.0" if z["source"].startswith("IOC") else "CC0 1.0")
        if r["wd_state"] in ACCEPT:
            for kind, text, lang in labels.get(it["qid"], []):
                if lang in (*ZH_LANGS, "en"):
                    add(text, script(lang), "name" if kind == "label" else "alias", f"Wikidata {it['qid']}", "CC0 1.0")
            for s in sorted(it["syns"]):
                add(s, "la", "synonym", f"Wikidata {it['qid']} P1420", "CC0 1.0")
    clem = [(sp["sci"], sp["en"]) for sp in sps if sp["en"]]      # the Clements English name where no alias has it
    have = {(a[0], a[2]) for a in aliases}
    for sci, en in clem:
        if (sci, norm(en)) not in have:
            aliases.append((sci, en, norm(en), "en", "clements", "Clements v2026 (AviList v2026 extended)", "CC BY 4.0"))
    # the package
    tmp = out.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript(SQL)
    cols = list(rows[0])
    db.executemany(f"INSERT INTO species_map ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", [tuple(r[c] for c in cols) for r in rows])
    db.executemany("INSERT INTO article VALUES (?,?,?,?)", arts)
    db.executemany("INSERT INTO alias VALUES (?,?,?,?,?,?,?)", sorted(aliases))
    when = lambda f: datetime.fromtimestamp((work / f).stat().st_mtime, timezone.utc).strftime("%Y-%m-%d")
    manifest = {
        "schema_version": SCHEMA_VERSION, "avilist_version": AVILIST, "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "accepted_states": sorted(ACCEPT),
        "inputs": {f: sha256(DATA / f) for f in ("ebird-names.csv", "zh-names.csv")},
        "sources": [
            {"name": "Wikidata", "url": "https://query.wikidata.org/", "retrieved": when("wd-name.jsonl"), "licence": "CC0 1.0",
             "use": "QID, P225/P105/P31/P171 checks, P3444 eBird, P3151 iNat, P846/P14607 GBIF, P1420 synonyms, P18 image file, zh/en sitelinks, labels"},
            {"name": "GBIF species match v2", "url": "https://api.gbif.org/v2/species/match", "retrieved": when("gbif.jsonl"),
             "licence": "GBIF Backbone Taxonomy, CC BY 4.0 (ids and names only)", "dataset_key": gmeta["datasetKey"], "dataset": gmeta.get("datasetTitle")},
            {"name": "iNaturalist API v1 taxa", "url": "https://api.inaturalist.org/v1/taxa", "retrieved": when("inat.jsonl"),
             "licence": "ids, names and ranks only (facts); terms https://www.inaturalist.org/pages/terms"},
            {"name": AVILIST, "url": "https://doi.org/10.2173/avilist.v2026", "licence": "CC BY 4.0", "use": "species keys, Cornell codes, Clements names"},
            {"name": "IOC World Bird List 15.2 (Chinese)", "url": "https://www.worldbirdnames.org/", "licence": "CC BY 3.0", "use": "traditional Chinese aliases"},
        ],
    }
    db.executemany("INSERT INTO manifest VALUES (?, ?)", [(k, json.dumps(v, ensure_ascii=False)) for k, v in manifest.items()])
    db.commit()
    db.execute("VACUUM")
    db.close()
    os.replace(tmp, out)
    write_report(rows, arts, aliases, manifest, out, report)


def write_report(rows, arts, aliases, manifest, out: Path, report: Path) -> None:
    n = len(rows)
    pct = lambda k: f"{k} ({k / n:.1%})"
    acc = lambda col: sum(1 for r in rows if r[col] in ACCEPT)
    states = ["exact-reviewed", "synonym-reviewed", "broader", "narrower", "split-lump", "ambiguous", "unmapped", "retired"]
    langs = Counter(a[1] for a in arts)
    wd_ok = {r["sci"] for r in rows if r["wd_state"] in ACCEPT}
    zh_ok = sum(1 for a in arts if a[1] == "zh" and a[0] in wd_ok)
    en_ok = sum(1 for a in arts if a[1] == "en" and a[0] in wd_ok)
    either = len({a[0] for a in arts if a[0] in wd_ok})
    img_ok = sum(1 for r in rows if r["wd_state"] in ACCEPT and r["commons_file"])
    L = [f"# 物种映射覆盖报告（{manifest['avilist_version']}）", "",
         f"由 `engine/tools/build_species_map.py` 生成于 {manifest['generated']}；包 `{out.name}` {out.stat().st_size / 1e6:.2f} MB"
         f"（上限 15 MB），{n} 行（每个 AviList 种恰一行）。只有 `exact-reviewed` / `synonym-reviewed` 会让应用补内容或深链；其余状态"
         "保持本地页正常、不补任何在线内容。“reviewed” 指通过了下列构建规则，规则外的例外由人工列表决定（见文末）。", "",
         "## 每个来源的状态", "", "| 状态 | Wikidata | iNaturalist | GBIF |", "|---|---:|---:|---:|"]
    for s in states:
        L.append(f"| {s} | {sum(1 for r in rows if r['wd_state'] == s)} | {sum(1 for r in rows if r['inat_state'] == s)} | "
                 f"{sum(1 for r in rows if r['gbif_state'] == s)} |")
    L += ["", "## 可用覆盖", "",
          f"- Wikidata QID（可补内容）：{pct(acc('wd_state'))}",
          f"- 中文维基条目：{pct(zh_ok)}；英文维基条目：{pct(en_ok)}；至少一种（简介可显示）：{pct(either)}；"
          f"缺中文而回退英文：{either - zh_ok}",
          f"- Commons 参考图文件（P18，运行时再逐文件过许可）：{pct(img_ok)}",
          f"- iNaturalist taxon ID：{pct(acc('inat_state'))}",
          f"- GBIF key：{pct(acc('gbif_state'))}；GBIF 与 Wikidata P846 一致："
          f"{sum(1 for r in rows if r['gbif_wd_agree'] is True)}，不一致：{sum(1 for r in rows if r['gbif_wd_agree'] is False)}",
          f"- eBird 代码（来自 AviList，本身即权威）：{pct(sum(1 for r in rows if r['ebird_code']))}",
          f"- GBIF 2026 新 ID（Wikidata P14607）：{sum(1 for r in rows if r['gbif_2026_id'])}",
          f"- 别名：{len(aliases)} 条（" + "，".join(f"{k} {v}" for k, v in Counter(a[3] for a in aliases).most_common()) + "）；来源："
          + "，".join(f"{k} {v}" for k, v in Counter(a[5].split(" Q")[0] if a[5].startswith("Wikidata Q") else a[5] for a in aliases).most_common()), "",
          "## 规则", "",
          "- **Wikidata**：P225 学名完全相同、P105 = 种、P31 为分类单元（含化石/灭绝）、P171 链上有鸟纲 Q5113，且只有一个这样的条目。"
          "同名多条时只在恰好一条带 AviList 的 eBird 代码时选它。没有同名条目时，只接受唯一一个在 P1420 异名里列出这个学名、"
          "或带同一 eBird 代码且种加词相同（属变更）的条目。条目的 eBird 代码与 AviList 不同记为 `split-lump`；"
          "学名条目与 eBird 代码条目不是同一个记为 `ambiguous`。同一 QID 对应两个 AviList 种时两边都记 `split-lump`。",
          "- **iNaturalist**：只用已接受 Wikidata 条目的 P3151，再用 iNat 自己的记录核对：活跃、种级、学名相同（或只有属不同）。属级/亚种级记 broader/narrower，停用记 retired。",
          "- **GBIF**：`/v2/species/match`（鸟纲提示）只接受 EXACT + SPECIES + 同名；同物异名且接受名种加词相同（属变更）记 synonym-reviewed，"
          "接受名为亚种记 narrower；FUZZY/VARIANT 只记候选、不填 ID；HIGHERRANK/NONE 记 unmapped。"
          f"datasetKey = `{manifest['sources'][1]['dataset_key']}`（{manifest['sources'][1].get('dataset')}），taxonKey 为字符串（datasetKey 记在 manifest，一包一个）。", ""]
    for title, col, state_set in (("Wikidata 未映射（unmapped）", "wd", {"unmapped"}), ("Wikidata 不确定（ambiguous）", "wd", {"ambiguous"}),
                                  ("Wikidata 概念不同（split-lump / narrower / broader）", "wd", {"split-lump", "narrower", "broader"}),
                                  ("GBIF 不确定（ambiguous）", "gbif", {"ambiguous"}),
                                  ("iNaturalist 不确定或停用", "inat", {"ambiguous", "retired"})):
        sel = [r for r in rows if r[f"{col}_state"] in state_set]
        L += [f"## {title}：{len(sel)}", ""]
        L += [f"- *{r['sci']}*：{r[f'{col}_note'] or ''}" for r in sel] or ["（无）"]
        L.append("")
    L += ["## 人工复核清单", ""]
    by = {r["sci"]: r for r in rows}
    for sci, why in ((k, v) for k, v in {**NARROWER, **REVIEW}.items() if k in by):
        r = by[sci]
        L.append(f"- *{sci}*：{why} → Wikidata `{r['wd_state']}` {r['wd_qid'] or ''}，iNat `{r['inat_state']}`，GBIF `{r['gbif_state']}`")
    L += ["", "## 来源与许可", ""]
    L += [f"- {s['name']}（{s['url']}）：{s['licence']}" + (f"，取于 {s['retrieved']}" if s.get("retrieved") else "") for s in manifest["sources"]]
    report.write_text("\n".join(L) + "\n", encoding="utf-8")
    print("\n".join(L[:30]))


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
