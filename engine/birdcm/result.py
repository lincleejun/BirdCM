"""The PhotoResult contract (PRD §5), mirrored in web/src/types.ts. Every field the finished product shows is here
now; steps still being researched leave theirs None and list themselves in `pending`, so filling them later
needs no schema change.

PhotoResult is per photo and reusable across scans (same file, same fingerprint). Stars, the star reason and the
burst group/rank are per scan and live in their own columns (store.py), never inside it.
"""
from __future__ import annotations

from typing import NotRequired, Literal, TypedDict

Point = list[float]                 # [x, y], normalised 0-1 in the upright original
Box = list[float]                   # [x0, y0, x1, y1], same frame


class Exif(TypedDict):
    camera: str | None
    camera_id: NotRequired[str | None]  # model + serial number: the body (bursts never span two bodies)
    lens: str | None
    focal_mm: float | None
    aperture: float | None
    shutter: str | None             # "1/1000"
    iso: float | None
    ev: float | None
    focus_mode: str | None          # "AF-C · Tracking"
    taken_at: str | None            # ISO 8601 with sub-seconds and offset when the file has them
    gps: list[float] | None         # [lat, lon]


class Name(TypedDict):
    sci: str
    en: str | None
    zh: str | None                  # None when the CC0 table has no Chinese name: show English
    p: float


class Species(TypedDict):
    level: Literal["species", "genus", "uncertain"]
    label: Name | None              # what to show; None when uncertain
    top5: list[Name]
    geo: bool                       # location prior applied
    genus: Name | None              # the genus with the largest summed probability ("Xxx sp.")
    max_cos: float | None           # best cosine of the image vector to any name
    visual: NotRequired[dict]       # the picture alone (before the prior): Name + margin to the second
    check: NotRequired[str]         # "rare": confirmed, but not expected over most of the place this season (请核对)
    override: NotRequired[dict]     # {why: "range", visual: Name, local: Name | None}: not confirmed because the first
                                    # name is not expected here this season; local = a congener of the top five that is
    prior: NotRequired[dict]        # the first name's prior over the place: {max, median}
    closer: NotRequired[dict]       # a look-alike congener (top five, >= 1 %) the place expects at least twice as much: 请核对


class Detection(TypedDict):        # every box the tower looked at (at most 5, strongest first)
    box: Box
    score: float                    # detector score (1.0 for a box the person drew)
    clear: bool | None              # clear-bird gate; None without its head file
    species: Species                # this box's own naming (for switching between birds)
    eye: Point | None               # eye / beak / flight only when clear
    eye_p: float | None
    beak: Point | None
    beak_p: float | None
    p_fly: float | None


class Region(TypedDict):
    name: str | None                # "美国 · 加利福尼亚州"
    source: Literal["photo", "scan"] | None   # photo GPS or the scan's chosen region
    gps: list[float] | None
    prior: dict | None              # {lat, lon, source: photo|region, week} the location prior used; None = no prior


class Rarity(TypedDict):
    tier: int                       # 0 常见, 1 不常见, 2 少见, 3 罕见 (local, this month)
    iucn: str | None


class PhotoResult(TypedDict):
    file: str
    width: int                      # upright original size the coordinates refer to
    height: int
    orientation: int
    source: str                     # embedded | half | full | jpeg (how the frame was decoded)
    exif: Exif
    region: Region
    focus: Point | None             # trusted camera focus point; None when missing / default centre
    boxes: list[Detection]
    subject: int | None             # index into boxes; chosen among the clear ones
    look: NotRequired[list[int] | None]  # the subject as an 8 x 8 grey thumbnail (64 values): frame-to-frame likeness
    species: Species | None         # also for a rejected photo (its likeliest box), when any box was looked at
    eye: Point | None               # the more visible eye
    eye_p: float | None             # its P(visible)
    eye_visible: bool | None
    beak: Point | None
    beak_p: float | None
    flying: bool | None
    p_fly: float | None
    clear: bool | None              # the subject passed the clear-bird gate (False: boxes but none clear)
    sharpness: float | None         # head sharpness, grad ratio (~1 blurred, larger crisper); uncalibrated scale
    sharpness_region: str | None    # eye | head | box
    sharpness_window: Box | None    # where it was measured
    clip_hi: NotRequired[float | None]   # share of the subject's core blown (all channels >= 254); absent in results before v10
    clip_lo: NotRequired[float | None]   # ... crushed (all channels <= 3); stars.py turns both into exposure_malus
    aesthetic: float | None         # 0-1 (EVA general score / 10), whole photo
    rarity: Rarity | None           # pending: rarity table
    rejected: bool                  # 淘汰: no bird, or no clear bird
    reject_reason: str | None
    pending: list[str]              # steps not run for this photo, e.g. ["geo", "rarity"]


class ScanFields(TypedDict):        # per scan, computed by stars.py at finalizing
    stars: int | None               # -1 淘汰, 0-3; None = 待定
    star_reason: str | None
    star_auto: dict | None          # set when the person chose the stars: the computed {stars, reason}
    burst_group: int | None
    burst_rank: int | None
    burst_size: int | None
