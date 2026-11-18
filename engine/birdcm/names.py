"""Chinese bird names (data/zh-names.csv: scientific, zh, zh_hant, source; see NOTICE.md). Joined when results are read,
not baked in: a stored result keeps whatever zh it was computed with, and relabel() overwrites it from this table, so a
new table needs a restart, never a re-scan."""
from __future__ import annotations

import csv
from functools import cache
from pathlib import Path

ZH = Path(__file__).with_name("data") / "zh-names.csv"


@cache
def zh() -> dict[str, str]:
    with open(ZH, newline="", encoding="utf-8") as f:
        return {r["scientific"]: r["zh"] for r in csv.DictReader(f) if r["zh"]}


def relabel(v):
    """Every name {sci, zh, ...} inside a stored result gets zh from the table (None when it has none); genus names
    ("Xxx sp.") are left as they are."""
    if isinstance(v, dict):
        if "sci" in v and "zh" in v and isinstance(v["sci"], str) and not v["sci"].endswith(" sp."):
            v["zh"] = zh().get(v["sci"])
        for x in v.values():
            relabel(x)
    elif isinstance(v, list):
        for x in v:
            relabel(x)
    return v
