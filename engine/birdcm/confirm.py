"""Whether a species can be confirmed where and when the photo was taken, from the location prior read over the
place's uncertainty (geo.Geo.spread: a chosen region's whole lattice, a point's neighbourhood, +-3 weeks).

Per look (one box), after the tower, on the posterior's first name:
- expected somewhere in the place this season (max prior >= EPS): the naming rule decides; when it does not live
  over most of the place (median prior < TAU) a confirmed species is flagged "rare" (可能的稀有记录, 请核对):
  scarce here, but possible. On the evaluation set this flag fell on 2 of 935 confirmed photos, both wrong.
- not expected anywhere in the place this season (max prior < EPS): not confirmed (genus or 不确定); the look says
  why ("override": the picture's first name, and a congener that does live here when the top five has one).
  Strong visual evidence does not rescue it: on the evaluation set a visual top-1 >= 0.80 against a prior < EPS was
  right 0 times in 31 (docs/eval.md), so there is no such exception.
Candidates keep the posterior's order; nothing is moved to the top. Burst agreement comes afterwards (stars.consensus).
"""
from __future__ import annotations

from birdcm.tower import level_of

EPS = 0.01          # prior below this: not expected (gardener's range EPS)
TAU = 0.05          # prior at least this: the species "lives here" (a congener to suggest; the median for the flag)


def decide(look: dict, wide, typical) -> dict:
    """look: the tower's output for one box (mutated and returned). wide / typical: the place's max / median prior,
    aligned with the names; None = no place."""
    ids = look.pop("_ids", None)
    if ids is None or wide is None:
        return look
    i = ids[0]
    if wide[i] != wide[i]:                          # NaN: the geo model does not list this species (prior unknown)
        look["prior"] = {"unknown": True}
        return look
    look["prior"] = {"max": round(float(wide[i]), 4), "median": round(float(typical[i]), 4)}
    if wide[i] >= EPS:
        if look["level"] == "species" and typical[i] < TAU:
            look["check"] = "rare"
        return look
    gen = look["top5"][0]["sci"].split(" ")[0]
    local = next((c for c, j in zip(look["top5"][1:], ids[1:]) if c["sci"].split(" ")[0] == gen and wide[j] >= TAU), None)  # NaN: no
    look["override"] = {"why": "range", "visual": look["top5"][0], "local": local}
    if look["level"] == "species":
        g = look["genus"]
        look["level"] = level_of(0.0, 0.0, g["p"])
        look["label"] = g if look["level"] == "genus" else None
    return look
