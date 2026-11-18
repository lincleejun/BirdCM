import csv

from birdcm import names


def test_table_covers_avilist_and_known_names():
    rows = list(csv.DictReader(open(names.ZH, encoding="utf-8")))
    assert len(rows) > 11000 and all(r["zh"] and r["source"] for r in rows)
    assert len({r["scientific"] for r in rows}) == len(rows) and len({r["zh"] for r in rows}) == len(rows)
    t = names.zh()
    assert t["Oreoscoptes montanus"] == "高山弯嘴嘲鸫"
    assert t["Certhia americana"] == "美洲旋木雀"
    assert t["Pericrocotus flammeus"] == "赤红山椒鸟"
    assert "Butorides striata" not in t


def test_relabel_overwrites_baked_names_but_not_genus():
    r = {"species": {"label": {"sci": "Oreoscoptes montanus", "zh": None},
                     "top5": [{"sci": "Certhia americana", "zh": "棕短脚鸡"}, {"sci": "Nope nope", "zh": "旧"}],
                     "genus": {"sci": "Certhia sp.", "zh": None}}}
    s = names.relabel(r)["species"]
    assert s["label"]["zh"] == "高山弯嘴嘲鸫"
    assert [c["zh"] for c in s["top5"]] == ["美洲旋木雀", None]
    assert s["genus"]["zh"] is None
