"""Rebuild engine/birdcm/data/zh-names.csv (Chinese bird names for the AviList v2026 species).

Inputs (none of them is committed here):
  ioc.xlsx       IOC World Bird List Multilingual Version v15.2, "Multiling IOC 15.2.xlsx" from
                 https://www.worldbirdnames.org/new/ioc-lists/master-list-2/ (CC BY 3.0), sha256
                 fb130d0d2431867ca7cf562de385651ea0f7c7515c28d685e715199c97cd5d82
  names.npz      bioclip-2.5-vith14-avilist-2026-names.npz from the model release (fields "scientific", "common")
  old.csv        the earlier Wikidata name table, for the two Wikidata rows and the log:
                 git show 294454d^:engine/birdcm/data/names-zh.csv > old.csv
Run:  uv run --with openpyxl python tools/build_zh_names.py ioc.xlsx names.npz old.csv birdcm/data/zh-names.csv report-dir/
It writes the table and report-dir/log.csv (how each species got its name). See NOTICE.md for sources and the
reviewed lumps.
"""
import sys, csv, openpyxl, numpy as np, collections, unicodedata
ioc_x, npz, old_csv, out, rep = sys.argv[1:6]
rows = list(openpyxl.load_workbook(ioc_x, read_only=True)["List"].iter_rows(values_only=True))
ix = {k: i for i, k in enumerate(rows[0])}
clean = lambda v: unicodedata.normalize("NFC", str(v)).strip() if v and str(v).strip() else ""
ioc = {}
for r in rows[1:]:
    s = clean(r[ix["IOC_15.2"]])
    if len(s.split()) == 2:
        ioc[s] = (clean(r[ix["English"]]), clean(r[ix["Chinese"]]), clean(r[ix["Chinese (Traditional)"]]))
z = np.load(npz)
sci = [str(s) for s in z["scientific"]]; en = [str(s) for s in z["common"]]
avis = set(sci)
old = {r["scientific"]: r["zh"] for r in csv.DictReader(open(old_csv, encoding="utf-8"))}
by_en = collections.defaultdict(list)
for s, v in ioc.items():
    if s not in avis: by_en[v[0].lower()].append(s)
# Concept fixes, each reviewed by hand (CN / US / CA lists): AviList's species is broader than the IOC species of the
# same name, so it takes the IOC name of the constituent the AviList English name (or the China checklist) refers to.
TAKE = {"Pericrocotus flammeus": "Pericrocotus speciosus",   # AviList Scarlet Minivet incl. speciosus; China's bird
        "Porphyrio porphyrio": "Porphyrio poliocephalus",    # AviList Purple Swamphen (lump); China's bird 紫水鸡
        "Aegithalos iouschistos": "Aegithalos bonvaloti",    # AviList Black-browed Bushtit (lump)
        "Glaucidium gnoma": "Glaucidium californicum",       # AviList Northern Pygmy Owl (lump)
        "Piranga flava": "Piranga hepatica",                 # AviList Hepatic Tanager (lump)
        "Taeniopygia guttata": "Taeniopygia castanotis"}     # AviList Zebra Finch (lump); US/CA birds are castanotis
WIKI = {"Butorides virescens"}     # IOC 南美绿鹭 for the North American Green Heron: looks swapped with striata
DROP = {"Butorides striata"}       # IOC 北美绿鹭 for the South American bird: looks swapped; no other source for the narrow concept
hant = lambda v: v.split("〔")[0].strip()
table, log = [], []
for s, e in zip(sci, en):
    hit, how = None, ""
    if s in DROP:
        log.append(("dropped", s, e, s, "", old.get(s, ""))); continue
    if s in TAKE:
        hit, how = TAKE[s], "take"
    elif s in WIKI:
        pass
    elif s in ioc and ioc[s][1]:
        hit, how = s, "ioc"
    elif s not in ioc:
        c = by_en.get(e.lower(), [])
        if len(c) == 1 and ioc[c[0]][1]:
            hit, how = c[0], "ioc-en"          # same English name, IOC sci not an AviList species: genus transfer / respelling
    if hit:
        _, zh, zht = ioc[hit]
        table.append((s, zh, hant(zht), "IOC 15.2" if how == "ioc" else f"IOC 15.2 ({hit})"))
        log.append((how, s, e, hit, zh, old.get(s, "")))
    elif old.get(s):
        table.append((s, old[s], "", "Wikidata"))
        log.append(("wikidata", s, e, "", old[s], old[s]))
    else:
        log.append(("none", s, e, "", "", ""))
table.sort()
with open(out, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f, lineterminator="\n"); w.writerow(["scientific", "zh", "zh_hant", "source"]); w.writerows(table)
with open(rep + "/log.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f); w.writerow(["how", "sci", "en", "ioc_sci", "zh", "old_zh"]); w.writerows(log)
c = collections.Counter(l[0] for l in log); print(c, "rows", len(table))
