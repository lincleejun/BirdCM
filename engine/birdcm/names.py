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


@cache
def catalogue() -> dict[str, dict]:
    """Every AviList species: sci -> {en, zh} (English from the installed name list, Chinese from the table); {} when
    the name list is not installed."""
    import numpy as np
    from birdcm import models
    try:
        z = np.load(models.paths()["names"])
    except Exception:  # noqa: BLE001 - no models: corrections can still use names already in the scan
        return {}
    cn = zh()
    return {str(s): {"en": str(e), "zh": cn.get(str(s))} for s, e in zip(z["scientific"], z["common"])}


def search(q: str, limit: int = 30) -> list[dict]:
    """Species whose Chinese, English or Latin name contains q (any case); exact and prefix matches first."""
    q = q.strip().lower()
    if not q:
        return []
    hits = []
    for sci, n in catalogue().items():
        keys = [sci.lower(), (n["en"] or "").lower(), n["zh"] or ""]
        if any(q in k for k in keys):
            rank = 0 if q in keys else 1 if any(k.startswith(q) for k in keys) else 2
            hits.append((rank, sci, n))
    hits.sort(key=lambda h: (h[0], h[1]))
    return [{"sci": s, "en": n["en"], "zh": n["zh"]} for _, s, n in hits[:limit]]
