"""Burst groups and stars for one scan, recomputed at `finalizing` and on a ratio change. Pure functions.

Stars are NOT implemented here yet: the rating rules (qualifying set, quota rounding, burst cap, species floor,
sharpness weight) come from the research in progress and replace `rate` below. Until then every photo gets
stars None ("待定"); 淘汰 photos (no bird) already get -1 because that part is defined by the PRD.
"""
from __future__ import annotations

from datetime import datetime

BURST_GAP = 2.0                 # seconds between consecutive frames of one burst (PRD 4.2)


def _seconds(taken_at: str | None) -> float | None:
    if not taken_at:
        return None
    try:
        return datetime.fromisoformat(taken_at).timestamp()        # offset-aware when the file had one
    except ValueError:
        return None


def group_bursts(photos: list[dict]) -> dict[int, tuple[int, int]]:
    """photos: {id, camera, taken_at}. -> id: (group number from 1, group size). Frames of one camera sorted by
    capture time (sub-seconds included) are one burst while each gap is <= 2 s; a photo without a time is its own
    group. Groups are numbered by their first frame's time, timeless photos last in input order."""
    timed = sorted(((t, p["camera"] or "", p["id"]) for p in photos if (t := _seconds(p.get("taken_at"))) is not None),
                   key=lambda x: (x[1], x[0], x[2]))
    groups: list[list[tuple[float, int]]] = []
    last: tuple[str, float] | None = None
    for t, cam, pid in timed:
        if last and last[0] == cam and t - last[1] <= BURST_GAP:
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


def rate(rows: list[dict], ratio: dict) -> dict[int, dict]:
    """rows: snapshot photo rows ({id, state, result}). -> id: ScanFields. ponytail: stars are a stub (see module doc);
    burst rank needs the star score, so it stays None too."""
    bursts = group_bursts([{"id": r["id"], "camera": (r["result"] or {}).get("exif", {}).get("camera"),
                            "taken_at": (r["result"] or {}).get("exif", {}).get("taken_at")} for r in rows])
    out = {}
    for r in rows:
        res = r["result"]
        rejected = bool(res and res.get("rejected"))
        g, size = bursts[r["id"]]
        out[r["id"]] = {"stars": -1 if rejected else None,
                        "star_reason": res.get("reject_reason") if rejected else None,
                        "burst_group": g, "burst_rank": None, "burst_size": size}
    return out
