"""Stars for one scan, the photos compared with each other. Ported from bioclip-bird distill/stars.py (the recorded
strategy, notes/star-strategy.md + notes/head-sharpness.md); pure functions, recomputed at `finalizing` and whenever
the scan's star settings change.

Defaults are the recorded strategy, unchanged and NOT tuned on the owner's photos: on his two batches it was only a
little better than random (three-star keeps 9/110 vs 6.2 random, 23/182 vs 18.5; notes/head-sharpness.md 2.2).
Every number below is a field of Config, stored per scan with the ratio (PUT /api/scans/{id}/ratio).

Rules, in order (the spec design §9 asks for):
1. Qualifying set. No bird / no clear bird -> -1 (淘汰). Gates -> 0 stars: detection score < min_det, aesthetic <
   min_aes, head sharpness < min_sharp (off by default: its scale is not calibrated on this decode path). Neither eye nor
   beak visible -> 1 star. The rest qualify.
2. Q = w_sharp * sharpness percentile + w_aes * aesthetic percentile, both within the qualifying set (ties share their
   mean rank). A missing value is not zero: a photo without sharpness uses its aesthetic percentile in its place (and
   the other way round); with neither, 0.5. Then + fly_bonus when P(fly) >= 0.5, + head_focus_bonus when the camera
   focused on the head, - outside_focus_malus when it focused off the bird (forgiven when the sharpness percentile >=
   outside_forgive_pct), - exposure_malus when exposure is known bad (not measured yet: never applied).
3. Quotas per species group (identified = species level with p >= species_min_p; the rest form one group):
   n3 = round(q3 * n), n2 = round(q2 * n), Python rounding. Order: Q descending, then queue order.
4. Caps on three stars: eye not visible (< eye_vis_min), focus off the bird, sharpness < min_sharp3 (off), and at most
   burst_cap three-stars per burst. A capped photo takes a two-star slot if one is left; its three-star slot goes to
   the next photo, so the quota stays filled when it can be.
5. Species floor (after the caps): an identified species with no photo at two stars or more lifts its best qualifying
   photo to two stars; this may exceed the two-star quota by one per such species. Gated photos are never lifted.
6. Bursts: one camera's frames sorted by capture time (sub-seconds kept) with gaps <= burst_gap s; a photo without a
   time is its own burst. Rank inside a burst: stars, then Q.
"""
from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import asdict, dataclass, fields
from datetime import datetime

BURST_GAP = 2.0


@dataclass
class Config:
    q3: float = 0.30
    q2: float = 0.30
    w_sharp: float = 0.65
    w_aes: float = 0.35
    min_det: float = 0.3              # OWLv2's own scale (the recorded strategy's 50 % is another detector's)
    min_sharp: float | None = None    # off: uncalibrated on the embedded-JPEG decode
    min_sharp3: float | None = None
    min_aes: float | None = 0.35      # EVA score / 10 (the recorded 3.5 of 10)
    eye_vis_min: float = 0.5
    fly_bonus: float = 0.06
    head_focus_bonus: float = 0.04
    outside_focus_malus: float = 0.06
    outside_forgive_pct: float = 0.9
    exposure_malus: float = 0.06
    burst_cap: int = 2
    burst_gap: float = BURST_GAP
    per_species: bool = True
    species_min_p: float = 0.9

    @classmethod
    def from_ratio(cls, ratio: dict | None) -> "Config":
        """The scan's stored settings: {preset, p3, p2 (percent), any Config field to override}."""
        r = dict(ratio or {})
        known = {f.name for f in fields(cls)}
        c = cls(**{k: v for k, v in r.items() if k in known})
        if "p3" in r:
            c.q3 = float(r["p3"]) / 100
        if "p2" in r:
            c.q2 = float(r["p2"]) / 100
        return c


def validate(ratio: dict) -> dict:
    """The scan's star settings as given by a client, checked: ValueError on an unknown key, a wrong type or a value out of
    range (a bad setting must be refused at the API, not discovered by the scheduler)."""
    if not isinstance(ratio, dict):
        raise ValueError("星级设置要是一个对象")
    known = {f.name: f for f in fields(Config)} | {"p3": None, "p2": None, "preset": None}
    for k, v in ratio.items():
        if k not in known:
            raise ValueError(f"不认识的星级设置：{k}")
        if k == "preset":
            if not isinstance(v, str):
                raise ValueError("preset 要是文字")
        elif k == "per_species":
            if not isinstance(v, bool):
                raise ValueError("per_species 要是 true / false")
        elif v is None and k.startswith("min_"):
            continue
        elif isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
            raise ValueError(f"{k} 要是数字")
    c = Config.from_ratio(ratio)
    if not (0 <= c.q3 <= 1 and 0 <= c.q2 <= 1 and c.q3 + c.q2 <= 1 + 1e-9):
        raise ValueError("三星、两星比例各在 0–100%，合计不超过 100%")
    if c.w_sharp < 0 or c.w_aes < 0 or c.burst_cap < 0 or c.burst_gap < 0 or not 0 <= c.species_min_p <= 1:
        raise ValueError("权重、连拍上限、连拍间隔不能为负，鸟种把握在 0–1")
    return ratio


def defaults() -> dict:
    return asdict(Config())


def _seconds(taken_at: str | None) -> float | None:
    if not taken_at:
        return None
    try:
        return datetime.fromisoformat(taken_at).timestamp()
    except ValueError:
        return None


def group_bursts(photos: list[dict], gap: float = BURST_GAP) -> dict[int, tuple[int, int]]:
    """photos: {id, camera, taken_at} -> id: (burst number from 1, burst size)."""
    timed = sorted(((t, p.get("camera") or "", p["id"]) for p in photos if (t := _seconds(p.get("taken_at"))) is not None),
                   key=lambda x: (x[1], x[0], x[2]))
    groups: list[list[tuple[float, int]]] = []
    last: tuple[str, float] | None = None
    for t, cam, pid in timed:
        if last and last[0] == cam and t - last[1] <= gap:
            groups[-1].append((t, pid))
        else:
            groups.append([(t, pid)])
        last = (cam, t)
    groups.sort(key=lambda g: g[0])
    out: dict[int, tuple[int, int]] = {}
    for n, g in enumerate(groups, 1):
        out.update({pid: (n, len(g)) for _, pid in g})
    n = len(groups)
    for p in photos:
        if p["id"] not in out:
            n += 1
            out[p["id"]] = (n, 1)
    return out


def percentiles(values: list[float]) -> list[float]:
    """Rank percentile in [0, 1], ties share their mean rank; a single value -> 1.0."""
    order = sorted(range(len(values)), key=lambda i: values[i])
    out, i = [0.0] * len(values), 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            out[order[k]] = 1.0 if len(values) == 1 else (i + j) / 2 / (len(values) - 1)
        i = j + 1
    return out


def focus_class(res: dict) -> str | None:
    """Camera focus point vs the bird: head (within one eye-beak distance of the eye), bird (in the box grown by 5 % of
    its long side), outside; None when the focus point is not trusted or there is no subject."""
    f, s = res.get("focus"), res.get("subject")
    if not f or s is None:
        return None
    W, H = res["width"], res["height"]
    x0, y0, x1, y1 = res["boxes"][s]["box"]
    eye, beak = res.get("eye"), res.get("beak")
    if eye and beak and res.get("eye_visible"):
        d = math.hypot((eye[0] - beak[0]) * W, (eye[1] - beak[1]) * H)
        if math.hypot((f[0] - eye[0]) * W, (f[1] - eye[1]) * H) <= d:
            return "head"
    m = 0.05 * max((x1 - x0) * W, (y1 - y0) * H)
    inside = x0 * W - m <= f[0] * W <= x1 * W + m and y0 * H - m <= f[1] * H <= y1 * H + m
    return "bird" if inside else "outside"


def _name(res: dict) -> str:
    lab = (res.get("species") or {}).get("label") or {}
    return lab.get("zh") or lab.get("en") or lab.get("sci") or "未定种"


def rate(rows: list[dict], ratio: dict | None) -> dict[int, dict]:
    """rows: {id, result (PhotoResult or None)} -> id: {stars, star_reason, burst_group, burst_rank, burst_size, q}."""
    c = Config.from_ratio(ratio)
    res = {r["id"]: r.get("result") for r in rows}
    bursts = group_bursts([{"id": i, "camera": (x or {}).get("exif", {}).get("camera"),
                            "taken_at": (x or {}).get("exif", {}).get("taken_at")} for i, x in res.items()], c.burst_gap)
    out = {i: {"stars": None, "star_reason": None, "q": None} for i in res}
    ok = []
    for r in rows:
        i, x = r["id"], r.get("result")
        if x is None:                                              # failed photo: no stars, says why in its error
            continue
        if x.get("rejected"):
            out[i].update(stars=-1, star_reason=x.get("reject_reason") or "没有找到鸟")
            continue
        det = x["boxes"][x["subject"]]["score"] if x.get("subject") is not None else 0.0
        if det < c.min_det:
            out[i].update(stars=0, star_reason=f"检测把握太低（{det:.2f}），不参与排名")
        elif c.min_aes is not None and x.get("aesthetic") is not None and x["aesthetic"] < c.min_aes:
            out[i].update(stars=0, star_reason=f"美学分太低（{x['aesthetic']:.2f}），不参与排名")
        elif c.min_sharp is not None and x.get("sharpness") is not None and x["sharpness"] < c.min_sharp:
            out[i].update(stars=0, star_reason="头部清晰度太低，不参与排名")
        elif (x.get("eye_p") is not None and x.get("beak_p") is not None
              and x["eye_p"] < c.eye_vis_min and x["beak_p"] < c.eye_vis_min):
            out[i].update(stars=1, star_reason="眼睛和嘴都看不见，角度不佳")
        else:
            ok.append(i)

    def pct(key: str) -> dict[int, float]:
        have = [i for i in ok if res[i].get(key) is not None]
        return dict(zip(have, percentiles([res[i][key] for i in have])))
    ps, pa = pct("sharpness"), pct("aesthetic")
    fc = {i: focus_class(res[i]) for i in ok}
    for i in ok:
        s, a = ps.get(i), pa.get(i)
        s, a = (s if s is not None else a), (a if a is not None else s)
        q = 0.5 if s is None else c.w_sharp * s + c.w_aes * a
        x = res[i]
        q += c.fly_bonus if (x.get("p_fly") or 0) >= 0.5 else 0
        q += c.head_focus_bonus if fc[i] == "head" else 0
        q -= c.outside_focus_malus if fc[i] == "outside" and (ps.get(i) or 0) < c.outside_forgive_pct else 0
        out[i]["q"] = round(q, 6)

    def species(i: int) -> str | None:
        sp = res[i].get("species") or {}
        lab = sp.get("label")
        return lab["sci"] if sp.get("level") == "species" and lab and lab["p"] >= c.species_min_p else None
    groups: dict[str | None, list[int]] = defaultdict(list)
    for i in ok:
        groups[species(i) if c.per_species else None].append(i)
    seq = {r["id"]: n for n, r in enumerate(rows)}
    per_burst: dict[int, int] = defaultdict(int)
    for sp, idx in groups.items():
        idx.sort(key=lambda i: (-out[i]["q"], seq[i]))
        n, n3, n2 = len(idx), round(c.q3 * len(idx)), round(c.q2 * len(idx))
        who = _name(res[idx[0]]) if sp else "未确认鸟种的照片中"
        got3 = got2 = 0
        for rank, i in enumerate(idx, 1):
            x, b = res[i], bursts[i][0]
            place = f"{who}{' ' if who[-1:].isascii() else ''}第 {rank} / {n} 名"
            cap = ("看不见眼睛，最多两星" if x.get("eye_p") is not None and x["eye_p"] < c.eye_vis_min
                   else "对焦点不在鸟身上，最多两星" if fc[i] == "outside"
                   else "头部清晰度不够三星" if c.min_sharp3 is not None and x.get("sharpness") is not None and x["sharpness"] < c.min_sharp3
                   else "同一连拍组已有两张三星" if per_burst[b] >= c.burst_cap else None)
            if got3 < n3 and cap is None:
                got3 += 1
                per_burst[b] += 1
                out[i].update(stars=3, star_reason=("飞版，" if (x.get("p_fly") or 0) >= 0.5 else "") + place)
            elif got2 < n2:
                got2 += 1
                out[i].update(stars=2, star_reason=(cap + "；" if cap and got3 < n3 else "") + place)
            else:
                out[i].update(stars=1, star_reason="排名靠后，" + place)
        if sp is not None and idx and max(out[i]["stars"] for i in idx) < 2:
            out[idx[0]].update(stars=2, star_reason="保底：这个鸟种最好的一张")
    by_burst: dict[int, list[int]] = defaultdict(list)
    for i in res:
        by_burst[bursts[i][0]].append(i)
    for g, idx in by_burst.items():
        idx.sort(key=lambda i: (-(out[i]["stars"] if out[i]["stars"] is not None else -2), -(out[i]["q"] or -1), seq[i]))
        for rank, i in enumerate(idx, 1):
            out[i].update(burst_group=g, burst_rank=rank, burst_size=len(idx))
    return out
