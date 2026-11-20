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
OLD_PRESET_KEEP = {"loose": 30, "std": 25, "strict": 20, "stricter": 10}   # preset -> share of photos with a star (%)


@dataclass
class Config:
    strategy: str = "select"          # "select" (default, docs/stars.md) or "quota" (the recorded one, for comparison)
    # ---- select ----
    keep: float = 0.25                # budget: share of eligible photos that get any star (1+2+3)
    w_sharp_burst: float = 0.30       # head sharpness percentile within its burst (same scene, same ISO)
    w_sharp_species: float = 0.15     # ... within the same species (pool) across the scan
    w_eye: float = 0.10               # P(eye visible)
    w_size: float = 0.10              # bird size in frame (box area share, saturating at size_full)
    w_focus: float = 0.05             # camera focus on the head 1, on the bird 0.6, off the bird 0 (forgiven when sharp)
    w_aes_select: float = 0.15        # aesthetic percentile over the scan (quota's own is w_aes below)
    w_det: float = 0.05               # detection score
    fly_boost: float = 0.15           # added to Q for a flying bird
    rare_boost: float = 0.05          # 少见 (and 0.1 for 罕见 / 无记录) locally this month
    size_full: float = 0.04           # box area share at which size counts fully
    d_species: float = 0.999          # diminishing return per photo already starred of the same species (pool); docs/stars.md
    d_burst: float = 0.6              # ... of the same burst
    q_floor: float = 0.35             # below this Q a photo is not starred just to fill the budget
    weak_size: float = 0.005          # "weak" = eye not visible AND box share below this AND burst sharpness pct < 0.5
    q3_min: float = 0.70              # 3★: absolute conditions (all must hold)
    eye3: float = 0.7
    burst3: float = 0.75              # sharpness pct in burst at least this (best or near best)
    species3: float = 0.5             # sharpness pct in species at least this
    aes3: float = 0.5                 # aesthetic pct at least this
    size3: float = 0.01               # box share at least this
    margin3: float = 0.05             # Q above the median Q of the starred photos of its species ("鸟都差不多" -> 2★)
    q2_min: float = 0.50              # 2★: Q at least this and (eye visible or flying)
    w_burst: float = 0.15             # how long the burst is (frames, percentile over the scan's bursts): a long burst is a moment
    burst_share: float = 0.5          # a burst of n frames may take about burst_share * n stars before d_burst bites (0 = flat)
    alike: float = 0.10               # a 0★ frame whose head sharpness is within 10 % of its burst's starred frame (and aesthetic
                                      # within 0.03) is "差不多，任选其一": the owner's choice among such frames looked arbitrary
    # ---- quota ----
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
        """The scan's stored settings: {preset, keep (percent, select), p3 / p2 (percent, quota), any Config field}."""
        r = dict(ratio or {})
        known = {f.name for f in fields(cls)}
        c = cls(**{k: v for k, v in r.items() if k in known})
        if "keep" in r:
            c.keep = float(r["keep"]) / 100
        elif r.get("strategy") != "quota" and ("p3" in r or "preset" in r):
            # an older scan's settings ({preset, p3, p2}): the same preset under the new single ratio, not the old quotas
            c.strategy = "select"
            c.keep = OLD_PRESET_KEEP.get(r.get("preset"), 25) / 100
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
    if ratio.get("strategy", "select") not in ("select", "quota"):
        raise ValueError("strategy 只能是 select 或 quota")
    for k, v in ratio.items():
        if k not in known:
            raise ValueError(f"不认识的星级设置：{k}")
        if k == "strategy":
            continue
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
    unit = ("keep", "eye3", "burst3", "species3", "aes3", "q3_min", "q2_min", "q_floor", "species_min_p", "eye_vis_min",
            "outside_forgive_pct", "size3", "weak_size", "alike", "margin3", "burst_share", "fly_boost", "rare_boost",
            "fly_bonus", "head_focus_bonus", "outside_focus_malus", "exposure_malus", "min_det")
    for k in unit:
        if not 0 <= getattr(c, k) <= 1:
            raise ValueError(f"{k} 要在 0–1 之间")
    for k in ("size_full", "d_species", "d_burst"):
        if not 0 < getattr(c, k) <= 1:
            raise ValueError(f"{k} 要大于 0、不超过 1")
    for f in fields(Config):
        if f.name.startswith("w_") and getattr(c, f.name) < 0:
            raise ValueError(f"{f.name} 不能为负")
    if not any(getattr(c, f.name) > 0 for f in fields(Config) if f.name.startswith("w_") and f.name not in ("w_sharp", "w_aes")):
        raise ValueError("至少要有一个权重大于 0")
    for k in ("min_sharp", "min_sharp3", "min_aes"):
        if getattr(c, k) is not None and getattr(c, k) < 0:
            raise ValueError(f"{k} 不能为负")
    if not float(c.burst_cap).is_integer() or not 0 <= c.burst_gap <= 3600:
        raise ValueError("连拍上限要是整数，连拍间隔在 0–3600 秒")
    if not 0 <= c.keep <= 1:
        raise ValueError("留片比例在 0–100%")
    if not (0 <= c.q3 <= 1 and 0 <= c.q2 <= 1 and c.q3 + c.q2 <= 1 + 1e-9):
        raise ValueError("三星、两星比例各在 0–100%，合计不超过 100%")
    if c.w_sharp < 0 or c.w_aes < 0 or c.burst_cap < 0 or c.burst_gap < 0 or not 0 <= c.species_min_p <= 1:
        raise ValueError("权重、连拍上限、连拍间隔不能为负，鸟种把握在 0–1")
    return ratio


def defaults() -> dict:
    return asdict(Config())


def _seconds(taken_at: str | None) -> float | None:
    """The camera's wall clock in seconds, offset dropped: bursts are one body's consecutive frames, so its own clock
    is the right scale, and the machine's time zone must not matter (Codex C8)."""
    if not taken_at:
        return None
    try:
        t = datetime.fromisoformat(taken_at).replace(tzinfo=None)
    except ValueError:
        return None
    return (t - datetime(1970, 1, 1)).total_seconds()


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


def _name(res: dict, fix: dict | None = None) -> str:
    lab = ((fix or res.get("species")) or {}).get("label") or {}
    return lab.get("zh") or lab.get("en") or lab.get("sci") or "未定种"


SUPPORT_P = 0.05     # a frame's own probability for a species at least this: it votes for it in the burst


def consensus(frames: list[tuple[int, dict]]) -> dict[int, dict]:
    """One burst's (id, PhotoResult) of the photos that were not rejected -> id: corrected species, for the frames that
    disagree with a species held by a strict majority of the burst.

    A frame supports species s when s is its own confirmed species, or when its own probability for s is at least
    SUPPORT_P (a name merely present in the top five at ~0 % is no vote). Candidates are the confirmed species of the
    burst; the winner has the most support, then the larger summed probability of its supporters, then the name.
    With support > half the frames, the frames that support it but are not confirmed (genus level, 不确定) take it.
    A frame confirmed as another species keeps its own: a burst can hold two birds. Its own result stays in the
    PhotoResult."""
    named = [(i, r["species"]) for i, r in frames if r.get("species")]
    if len(named) < 2:
        return {}
    cands = {sp["label"]["sci"] for _, sp in named if sp["level"] == "species" and sp.get("label")}
    if not cands:
        return {}

    def p_of(sp: dict, sci: str) -> float | None:
        return next((c["p"] for c in sp.get("top5", []) if c["sci"] == sci), None)
    def supports(sp: dict, s: str) -> bool:
        return (sp["level"] == "species" and sp["label"]["sci"] == s) or (p_of(sp, s) or 0.0) >= SUPPORT_P
    score = {}
    for s in cands:
        sup = [sp for _, sp in named if supports(sp, s)]
        score[s] = (len(sup), sum(p_of(sp, s) or 0.0 for sp in sup))
    best = min(cands, key=lambda s: (-score[s][0], -score[s][1], s))
    if score[best][0] * 2 <= len(named):
        return {}
    src = next(sp for _, sp in named if sp["level"] == "species" and sp["label"]["sci"] == best)
    label = src["label"]
    out = {}
    for i, sp in named:
        if sp["level"] == "species" or not supports(sp, best):        # confirmed (as it or as another bird), or no evidence
            continue
        p = p_of(sp, best)
        out[i] = {"level": "species", "label": {**label, "p": round(p, 4) if p is not None else None}, "top5": sp.get("top5", []),
                  "geo": sp.get("geo", False), "consensus": {"support": score[best][0], "frames": len(named)},
                  "visual": sp.get("visual"), **{k: src[k] for k in ("check", "prior", "closer") if src.get(k)}}
    return out


def same_look(a: dict, b: dict, same_species: bool, place: float = 0.05, size: float = 0.25, diff: float = 0.25) -> bool:
    """Two frames show the same bird the same way: same species, subject centre within `place` (normalised), box
    area within `size` of each other, and their 8 x 8 grey subject thumbnails (each normalised to zero mean, unit
    spread) differ by at most `diff` on average. Missing evidence -> False (the reason then only says "评分接近")."""
    if not same_species or a.get("subject") is None or b.get("subject") is None or not a.get("look") or not b.get("look"):
        return False
    ba, bb = a["boxes"][a["subject"]]["box"], b["boxes"][b["subject"]]["box"]
    ca, cb = ((ba[0] + ba[2]) / 2, (ba[1] + ba[3]) / 2), ((bb[0] + bb[2]) / 2, (bb[1] + bb[3]) / 2)
    if abs(ca[0] - cb[0]) > place or abs(ca[1] - cb[1]) > place:
        return False
    sa, sb = (ba[2] - ba[0]) * (ba[3] - ba[1]), (bb[2] - bb[0]) * (bb[3] - bb[1])
    if min(sa, sb) <= 0 or abs(sa - sb) / max(sa, sb) > size:
        return False
    def norm(v):
        m = sum(v) / len(v)
        sd = (sum((x - m) ** 2 for x in v) / len(v)) ** 0.5 or 1.0
        return [(x - m) / sd for x in v]
    na, nb = norm(a["look"]), norm(b["look"])
    return sum(abs(x - y) for x, y in zip(na, nb)) / len(na) <= diff


def lookalikes(frames: list[tuple[int, dict]], fixes: dict[int, dict], near: float = 0.12) -> dict[int, dict]:
    """Two confirmed species of the same genus alternating inside one burst on the same bird (a look-alike pair the
    model flips between, e.g. Elegant / Royal Tern frame to frame): when one holds at least twice the frames of the
    other (and at least 3), the other's frames whose subject sits where the dominant one's does (centre within `near`
    of their median, normalised) take the dominant species, marked "lookalike". Different genera, or the other bird
    somewhere else in the frame, are left alone: a burst can hold two birds."""
    def eff(i, r):
        return fixes.get(i) or r.get("species")

    def centre(r):
        if r.get("subject") is None:
            return None
        b = r["boxes"][r["subject"]]["box"]
        return ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
    named = [(i, r, eff(i, r)) for i, r in frames if (eff(i, r) or {}).get("level") == "species" and eff(i, r).get("label")]
    count: dict[str, int] = defaultdict(int)
    for _, _, sp in named:
        count[sp["label"]["sci"]] += 1
    if len(count) < 2:
        return {}
    dom = max(count, key=lambda s: (count[s], s))
    src = next(sp for _, _, sp in named if sp["label"]["sci"] == dom)
    cs = [c for _, r, sp in named if sp["label"]["sci"] == dom and (c := centre(r))]
    if not cs:
        return {}
    mx, my = sorted(c[0] for c in cs)[len(cs) // 2], sorted(c[1] for c in cs)[len(cs) // 2]
    out = {}
    for i, r, sp in named:
        s = sp["label"]["sci"]
        if s == dom or s.split(" ")[0] != dom.split(" ")[0] or count[dom] < max(3, 2 * count[s]):
            continue
        c = centre(r)
        if c is None or abs(c[0] - mx) > near or abs(c[1] - my) > near:
            continue
        own = r.get("species") or {}
        p = next((x["p"] for x in own.get("top5", []) if x["sci"] == dom), None)
        out[i] = {"level": "species", "label": {**src["label"], "p": p}, "top5": own.get("top5", []), "geo": own.get("geo", False),
                  "consensus": {"support": count[dom], "frames": len(named)}, "lookalike": s, "visual": own.get("visual"),
                  **{k: src[k] for k in ("check", "prior", "closer") if src.get(k)}}
    return out


def manual_species(own: dict | None, sci: str | None, names: dict | None = None) -> dict:
    """The species block of a person's correction: sci None = 不确定. names: sci -> {en, zh} (for the label)."""
    top5 = (own or {}).get("top5", [])
    if sci is None:
        return {"level": "uncertain", "label": None, "top5": top5, "geo": (own or {}).get("geo", False), "manual": True}
    known = next((c for c in top5 if c["sci"] == sci), None) or {}
    n = (names or {}).get(sci, {})
    label = {"sci": sci, "en": known.get("en") or n.get("en"), "zh": known.get("zh") or n.get("zh"), "p": known.get("p")}
    return {"level": "species", "label": label, "top5": top5, "geo": (own or {}).get("geo", False), "manual": True}


def rate(rows: list[dict], ratio: dict | None, rarity=None, manual: dict[int, dict] | None = None,
         fixed: dict[int, int] | None = None) -> dict[int, dict]:
    """rows: {id, result (PhotoResult or None)} -> id: {stars, star_reason, burst_group, burst_rank, burst_size, q, star_auto}.
    manual: id -> the person's species block (manual_species); it wins over burst consensus and the photo's own.
    fixed: id -> the person's stars. Laid over the finished rating, so they take no budget and move no other photo
    (bursts keep the computed ranks); star_auto keeps what was computed (what an undo returns to)."""
    c = Config.from_ratio(ratio)
    res = {r["id"]: r.get("result") for r in rows}
    bursts = group_bursts([{"id": i, "camera": (x or {}).get("exif", {}).get("camera_id") or (x or {}).get("exif", {}).get("camera"),
                            "taken_at": (x or {}).get("exif", {}).get("taken_at")} for i, x in res.items()], c.burst_gap)
    members: dict[int, list[tuple[int, dict]]] = defaultdict(list)
    for i, x in res.items():
        if x and not x.get("rejected"):
            members[bursts[i][0]].append((i, x))
    fixes: dict[int, dict] = {}
    for frames in members.values():
        fixes.update(consensus(frames))
        fixes.update(lookalikes(frames, fixes))
    for i, sp in (manual or {}).items():                           # the person's word: manual > burst consensus > own
        if i in res and res[i] is not None:
            fixes[i] = sp
    if rarity is not None:                                         # a corrected frame shows its new species' rarity
        from birdcm.pipeline import rarity_for
        for i, fix in fixes.items():
            fix["rarity"] = rarity_for(rarity, fix, res[i])
    out = {i: {"stars": None, "star_reason": None, "q": None, "q_parts": None, "species_fix": fixes.get(i)} for i in res}
    seq = {r["id"]: n for n, r in enumerate(rows)}
    if c.strategy == "quota":
        _quota(rows, res, fixes, bursts, c, out, seq)
    else:
        _select(rows, res, fixes, bursts, c, out, seq)
    by_burst: dict[int, list[int]] = defaultdict(list)
    for i in res:
        by_burst[bursts[i][0]].append(i)
    for g, idx in by_burst.items():
        idx.sort(key=lambda i: (-(out[i]["stars"] if out[i]["stars"] is not None else -2), -(out[i]["q"] or -1), seq[i]))
        for rank, i in enumerate(idx, 1):
            out[i].update(burst_group=g, burst_rank=rank, burst_size=len(idx))
    for i, n in (fixed or {}).items():
        if i in res and res[i] is not None:                        # a failed photo has no stars to change
            out[i]["star_auto"] = {"stars": out[i]["stars"], "reason": out[i]["star_reason"]}
            out[i].update(stars=n, star_reason="主人手动设定")
    return out


def _quota(rows: list[dict], res: dict, fixes: dict, bursts: dict, c: "Config", out: dict, seq: dict) -> None:
    """The recorded strategy (strategy "quota"): Q from sharpness and aesthetic percentiles, per-species 3-star / 2-star
    quotas, burst cap. Kept for comparison."""
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
        if i in fixes:                                             # corrected by its burst: counts as that species
            return fixes[i]["label"]["sci"]
        sp = res[i].get("species") or {}
        lab = sp.get("label")
        return lab["sci"] if sp.get("level") == "species" and lab and lab["p"] >= c.species_min_p else None
    groups: dict[str | None, list[int]] = defaultdict(list)
    for i in ok:
        groups[species(i) if c.per_species else None].append(i)
    per_burst: dict[int, int] = defaultdict(int)
    for sp, idx in groups.items():
        idx.sort(key=lambda i: (-out[i]["q"], seq[i]))
        n, n3, n2 = len(idx), round(c.q3 * len(idx)), round(c.q2 * len(idx))
        who = _name(res[idx[0]], fixes.get(idx[0])) if sp else "未确认鸟种的照片中"
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


def _pctl(ids: list[int], value, alone: float = 1.0) -> dict[int, float]:
    """Percentile of each id's value among ids; a lone value gets `alone` (nothing to compare with)."""
    have = [i for i in ids if value(i) is not None]
    return dict(zip(have, percentiles([value(i) for i in have]))) if len(have) > 1 else {i: alone for i in have}


def _spend(budget: int, cand: list[int], q: dict, seq: dict, pools: dict, burst_of: dict, blen: dict, c: "Config") -> list[int]:
    """The greedy budget: repeatedly take the photo with the highest Q x d_species^(taken in its species) x
    d_burst^(taken in its burst / allow). Photos of one species in one burst share both factors, so only that group's
    best remaining photo (by Q, then capture order) can win; within a species, the species factor is common, so its
    groups are kept in a heap without it. Only the groups touched by a pick are re-keyed: O(n log n) (Codex P1; the
    old single heap re-scored every equal candidate of a species after each pick). Same order and ties as before."""
    import heapq
    taken_sp, taken_b = defaultdict(int), defaultdict(int)
    members: dict = defaultdict(list)                               # (species, burst) -> photos, best first
    for i in cand:
        members[(pools[i], burst_of[i])].append(i)
    for g in members:
        members[g].sort(key=lambda i: (-q[i], seq[i]))
    head = {g: 0 for g in members}
    in_burst: dict = defaultdict(list)
    for g in members:
        in_burst[g[1]].append(g)

    def burst_f(i: int) -> float:
        allow = max(1.0, c.burst_share * blen[burst_of[i]])
        kb = taken_b[burst_of[i]]
        return c.d_burst ** (kb / allow if c.burst_share else kb)

    def eff(i: int) -> float:                                       # the old expression, evaluated the same way
        return q[i] * c.d_species ** taken_sp[pools[i]] * burst_f(i)

    sp_heap: dict = defaultdict(list)                               # species -> heap of (-q*burst_f, seq, group, version)
    gver = defaultdict(int)
    for g, ids in members.items():
        sp_heap[g[0]].append((-q[ids[0]] * burst_f(ids[0]), seq[ids[0]], g, 0))
    for h in sp_heap.values():
        heapq.heapify(h)
    sver = defaultdict(int)

    def clean(sp):
        h = sp_heap[sp]
        while h and h[0][3] != gver[h[0][2]]:
            heapq.heappop(h)
        return h[0] if h else None

    def push_top(sp):
        sver[sp] += 1
        e = clean(sp)
        if e is not None:
            k = members[e[2]][head[e[2]]]
            heapq.heappush(top, (-eff(k), seq[k], sp, sver[sp]))
    top: list = []
    for sp in sp_heap:
        push_top(sp)
    chosen: list[int] = []
    while top and len(chosen) < budget:
        _, _, sp, v = heapq.heappop(top)
        if v != sver[sp]:
            continue
        e = clean(sp)
        if e is None:
            continue
        g = e[2]
        i = members[g][head[g]]
        chosen.append(i)
        taken_sp[sp] += 1
        taken_b[g[1]] += 1
        head[g] += 1
        touched = {sp}
        for h in in_burst[g[1]]:                                    # every group of this burst has a new burst factor
            gver[h] += 1
            if head[h] < len(members[h]):
                j = members[h][head[h]]
                heapq.heappush(sp_heap[h[0]], (-q[j] * burst_f(j), seq[j], h, gver[h]))
            touched.add(h[0])
        for t in touched:
            push_top(t)
    return chosen


def _select(rows: list[dict], res: dict, fixes: dict, bursts: dict, c: "Config", out: dict, seq: dict) -> None:
    """Strategy "select" (docs/stars.md): who gets a star is a budget spent greedily with diminishing returns per
    species and per burst; which star is decided by absolute conditions, not quotas."""
    import heapq
    elig = []
    for r in rows:
        i, x = r["id"], r.get("result")
        if x is None:
            continue
        if x.get("rejected"):
            out[i].update(stars=-1, star_reason=x.get("reject_reason") or "没有找到鸟")
        else:
            elig.append(i)
    if not elig:
        return

    def sp_of(i: int) -> dict | None:
        return fixes.get(i) or res[i].get("species")

    def pool(i: int) -> str:
        sp = sp_of(i) or {}
        lab = sp.get("label")
        if sp.get("level") == "species" and lab and (i in fixes or (lab.get("p") or 0) >= c.species_min_p):
            return lab["sci"]
        g = (lab or sp.get("genus") or {}).get("sci") if sp.get("level") == "genus" else None
        return f"genus:{g.split(' ')[0]}" if g else "未确认"
    pools = {i: pool(i) for i in elig}
    burst_of = {i: bursts[i][0] for i in elig}
    by_burst, by_pool = defaultdict(list), defaultdict(list)
    for i in elig:
        by_burst[burst_of[i]].append(i)
        by_pool[pools[i]].append(i)
    sharp = lambda i: res[i].get("sharpness")                        # noqa: E731
    pb, pbq = {}, {}                  # pb: for "best in its burst" (a lone frame is); pbq: for Q (a lone frame is neutral)
    for ids in by_burst.values():
        pb.update(_pctl(ids, sharp))
        pbq.update(_pctl(ids, sharp, alone=0.5))
    psp = {}
    for ids in by_pool.values():
        psp.update(_pctl(ids, sharp))
    pa = _pctl(elig, lambda i: res[i].get("aesthetic"))
    # a long burst is a moment the photographer kept shooting: each photo carries its burst's length percentile
    blen = {b: len(ids) for b, ids in by_burst.items()}
    bl_pct = dict(zip(blen, percentiles(list(blen.values())))) if len(blen) > 1 else {b: 0.5 for b in blen}
    fc = {i: focus_class(res[i]) for i in elig}

    def area(i: int) -> float | None:
        x = res[i]
        if x.get("subject") is None:
            return None
        b = x["boxes"][x["subject"]]["box"]
        return max(0.0, (b[2] - b[0]) * (b[3] - b[1]))
    q, parts = {}, {}
    for i in elig:
        x = res[i]
        a = area(i)
        focus = {"head": 1.0, "bird": 0.6, "outside": 0.6 if (pb.get(i) or 0) >= 0.8 else 0.0}.get(fc[i])
        det = x["boxes"][x["subject"]]["score"] if x.get("subject") is not None else None
        sig = {"sharp_burst": (pbq.get(i), c.w_sharp_burst), "sharp_species": (psp.get(i), c.w_sharp_species),
               "eye": (x.get("eye_p"), c.w_eye), "size": (None if a is None else min(1.0, math.sqrt(a / c.size_full)), c.w_size),
               "focus": (focus, c.w_focus), "aesthetic": (pa.get(i), c.w_aes_select),
               "detection": (None if det is None else min(1.0, max(0.0, (det - 0.1) / 0.6)), c.w_det),
               "burst_length": (bl_pct[burst_of[i]], c.w_burst)}
        tw = sum(w for _, w in sig.values()) or 1.0
        base = sum((0.5 if v is None else v) * w for v, w in sig.values()) / tw      # a missing signal is neutral
        fly = c.fly_boost if (x.get("p_fly") or 0) >= 0.5 else 0.0
        tier = ((fixes.get(i) or {}).get("rarity") or x.get("rarity") or {}).get("tier")
        rare = 2 * c.rare_boost if tier in (0, 1) else c.rare_boost if tier == 2 else 0.0
        q[i] = round(base + fly + rare, 4)
        parts[i] = {k: (None if v is None else round(v, 3)) for k, (v, _) in sig.items()} | {"fly": fly, "rare": rare}
        out[i].update(q=q[i], q_parts=parts[i])

    def weak(i: int) -> bool:
        x, a = res[i], area(i)
        return q[i] < c.q_floor or ((x.get("eye_p") or 0) < 0.5 and a is not None and a < c.weak_size and (pbq.get(i) or 0) <= 0.5)
    budget = round(c.keep * len(elig))
    chosen = _spend(budget, [i for i in elig if not weak(i)], q, seq, pools, burst_of, blen, c)
    picked = set(chosen)
    floor = set()
    for sp, ids in by_pool.items():                               # every confirmed species: at least its best photo
        if sp.startswith("genus:") or sp == "未确认" or picked & set(ids):
            continue
        ok = [i for i in ids if not weak(i)]                       # a weak photo is not starred even to keep its species
        if not ok:
            continue
        best = max(ok, key=lambda i: (q[i], -seq[i]))
        picked.add(best)
        floor.add(best)
    med = {sp: sorted(q[i] for i in ids if i in picked) for sp, ids in by_pool.items()}
    med = {sp: v[len(v) // 2] if v else 0.0 for sp, v in med.items()}
    best_in_burst = {}
    for b, ids in by_burst.items():
        sel = [i for i in ids if i in picked]
        if sel:
            best_in_burst[b] = max(sel, key=lambda i: (q[i], -seq[i]))
    def close_scores(i: int, j: int) -> bool:
        a, b = res[i].get("sharpness"), res[j].get("sharpness")
        ea, eb = res[i].get("aesthetic"), res[j].get("aesthetic")
        return (a is not None and b is not None and abs(a - b) <= c.alike * max(a, b)
                and (ea is None or eb is None or abs(ea - eb) <= 0.03))

    def alike(i: int, j: int) -> bool:
        """Really the same picture, not just close scores (Codex E3): same species, the bird in the same place and
        size, and the subject's 8 x 8 grey thumbnails nearly equal."""
        return close_scores(i, j) and same_look(res[i], res[j], pools[i] == pools[j])
    for i in elig:
        x = res[i]
        flying = (x.get("p_fly") or 0) >= 0.5
        name = _name(res[i], fixes.get(i))
        if i not in picked:
            other = best_in_burst.get(burst_of[i])
            why = (f"和同组 {res[other].get('file', '另一张')} 差不多，任选其一" if other is not None and alike(i, other)
                   else f"和同组 {res[other].get('file', '另一张')} 评分接近，选了那张" if other is not None and close_scores(i, other)
                   else f"同组 {res[other].get('file', '另一张')} 更好" if other is not None
                   else "整体质量不够，不为凑比例而给星" if weak(i) else "比例已满，排在后面")
            out[i].update(stars=0, star_reason=why)
            continue
        short = []
        if (x.get("eye_p") or 0) < c.eye3:
            short.append("眼睛不够清楚")
        if (pb.get(i) or 0) < c.burst3:
            short.append("同组里不是最清楚的")
        if (psp.get(i) if psp.get(i) is not None else 1.0) < c.species3:
            short.append("同种里清晰度偏低")
        if fc[i] == "outside" and (pb.get(i) or 0) < 0.8:
            short.append("对焦点不在鸟身上")
        a = area(i)
        if a is not None and a < c.size3:
            short.append("鸟太小")
        if (pa.get(i) if pa.get(i) is not None else 1.0) < c.aes3:
            short.append("构图美感一般")
        if pools[i].startswith("genus:") or pools[i] == "未确认":
            short.append("鸟种没认准")
        if best_in_burst.get(burst_of[i]) != i:
            short.append("同组已有更好的一张")
        if q[i] < c.q3_min:
            short.append("综合分不够高")
        if not short and q[i] < med.get(pools[i], 0) + c.margin3 and len([j for j in by_pool[pools[i]] if j in picked]) > 1:
            short.append(f"和其他{name}差不多")
        lead = "飞版，" if flying else ""
        if i in floor:                                             # the summary counts these: they can exceed the ratio
            out[i]["q_parts"] = {**(out[i].get("q_parts") or {}), "floor": 1}
        if not short:
            out[i].update(stars=3, star_reason=f"{lead}各方面都很好（综合 {q[i]:.2f}）")
        elif q[i] >= c.q2_min and ((x.get("eye_p") or 0) >= 0.5 or flying):
            out[i].update(stars=2, star_reason=f"{lead}值得留，但{short[0]}")
        else:
            why = ("这个鸟种在这批里最好的一张" if i in floor else
                   "当地少见，留作记录" if (parts[i]["rare"] or 0) > 0 else
                   "飞版，有瑕疵" if flying else "留作记录")
            out[i].update(stars=1, star_reason=f"{why}；{short[0]}")

