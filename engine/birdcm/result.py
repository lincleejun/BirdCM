"""The PhotoResult contract (PRD §5), mirrored in web/src/types.ts. Every field the finished product shows is here
now; steps still being researched leave theirs None and list themselves in `pending`, so filling them later
needs no schema change.

PhotoResult is per photo and reusable across scans (same file, same fingerprint). Stars, the star reason and the
burst group/rank are per scan and live in their own columns (store.py), never inside it.
"""
from __future__ import annotations

from typing import Literal, TypedDict

Point = list[float]                 # [x, y], normalised 0-1 in the upright original
Box = list[float]                   # [x0, y0, x1, y1], same frame


class Exif(TypedDict):
    camera: str | None
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
    geo: bool                       # location prior applied (False until geo.py exists)


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
    species: Species | None
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
    aesthetic: float | None         # 0-1 (EVA general score / 10), whole photo
    rarity: Rarity | None           # pending: rarity table
    rejected: bool                  # 淘汰: no bird, or no clear bird
    reject_reason: str | None
    pending: list[str]              # steps not run for this photo, e.g. ["geo", "rarity"]


class ScanFields(TypedDict):        # per scan, computed by stars.py at finalizing
    stars: int | None               # -1 淘汰, 0-3; None = 待定
    star_reason: str | None
    burst_group: int | None
    burst_rank: int | None
    burst_size: int | None
