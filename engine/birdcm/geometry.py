"""Coordinates. Every box and point is stored normalised (0-1) in the upright original photo, with the
upright original size beside it; the 2048 frame, the square crop, the 224 model input and the browser all
convert from that. Pure functions, unit-tested."""
from __future__ import annotations

import math

MIN_CROP = 320          # crop side in frame pixels, never smaller (a 40 px bird at 224 is a smudge)
CONTEXT = 0.1           # box grown by 10 % per side before squaring (gardener's crop rule; the heads were trained on it)
SIZE = 224              # tower input
AF_NEAR = 0.03          # focus point within 3 % of the long side of a box picks that box


def focus_point(raw: str | None, orientation: int) -> tuple[float, float] | None:
    """Sony FocusLocation "W H X Y" (sensor frame, landscape) -> normalised upright (x, y), or None when it
    cannot be trusted: missing, malformed, outside its frame, or the centre default exiftool documents for
    "no focus location" (within one pixel of W/2, H/2)."""
    try:
        w, h, x, y = (float(v) for v in str(raw).split())
    except (TypeError, ValueError):
        return None
    if w <= 0 or h <= 0 or not (0 <= x <= w and 0 <= y <= h):
        return None
    if abs(x - w / 2) <= 1 and abs(y - h / 2) <= 1:
        return None
    u, v = x / w, y / h
    return {1: (u, v), 2: (1 - u, v), 3: (1 - u, 1 - v), 4: (u, 1 - v), 5: (v, u), 6: (1 - v, u), 7: (1 - v, 1 - u),
            8: (v, 1 - u)}.get(orientation)                    # an unknown orientation: not trusted


def crop_rect(box: tuple[float, float, float, float], width: int, height: int,
              min_side: int = MIN_CROP) -> tuple[int, int, int, int]:
    """Normalised box -> a SQUARE crop in a width x height frame's pixels: box + 10 % context, squared, at least
    min_side, shifted to stay inside the frame along an axis where the frame is long enough; where it is not (a bird
    filling a portrait frame), the square reaches past the frame and the caller pads (pad_crop): the whole box always
    reaches the model, nothing is centre-cropped away (Codex C3)."""
    x0, y0, x1, y1 = box[0] * width, box[1] * height, box[2] * width, box[3] * height
    bw, bh = x1 - x0, y1 - y0
    x0, y0, x1, y1 = x0 - bw * CONTEXT, y0 - bh * CONTEXT, x1 + bw * CONTEXT, y1 + bh * CONTEXT
    side = round(max(x1 - x0, y1 - y0, float(min_side)))

    def place(c: float, size: int) -> int:
        lo = round(c - side / 2)
        return lo if side > size else min(max(0, lo), size - side)
    left, top = place((x0 + x1) / 2, width), place((y0 + y1) / 2, height)
    return left, top, left + side, top + side


def pad_crop(im, rect):
    """Cut rect from a PIL image; the part outside the frame is filled with the crop's mean colour, not black."""
    from PIL import Image, ImageStat
    x0, y0, x1, y1 = rect
    inside = (max(0, x0), max(0, y0), min(im.width, x1), min(im.height, y1))
    if inside == tuple(rect):
        return im.crop(rect)
    part = im.crop(inside)
    canvas = Image.new(im.mode, (x1 - x0, y1 - y0), tuple(int(v) for v in ImageStat.Stat(part).mean))
    canvas.paste(part, (inside[0] - x0, inside[1] - y0))
    return canvas


def square_map(crop: tuple[int, int, int, int]) -> tuple[float, int, int]:
    """How square() turns a crop into the 224 input: scale k (shortest side -> 224), then centre-crop offsets
    (left, top) in the scaled crop. A crop clipped by a small frame is not square: its long side loses the
    centre-crop margins."""
    cw, ch = crop[2] - crop[0], crop[3] - crop[1]
    k = SIZE / min(cw, ch)
    return k, (round(cw * k) - SIZE) // 2, (round(ch * k) - SIZE) // 2


def from_input(pt: tuple[float, float], crop: tuple[int, int, int, int], width: int, height: int) -> tuple[float, float]:
    """A point in the 224 input -> normalised upright coordinates (via the frame the crop was cut from)."""
    k, left, top = square_map(crop)
    return (crop[0] + (pt[0] + left) / k) / width, (crop[1] + (pt[1] + top) / k) / height


def to_input(pt: tuple[float, float], crop: tuple[int, int, int, int], width: int, height: int) -> tuple[float, float]:
    """Inverse of from_input (tests and drawing)."""
    k, left, top = square_map(crop)
    return (pt[0] * width - crop[0]) * k - left, (pt[1] * height - crop[1]) * k - top


def iou(a, b) -> float:
    x0, y0, x1, y1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, x1 - x0) * max(0.0, y1 - y0)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def dedupe(boxes: list[tuple[float, tuple]], same: float = 0.5) -> list[tuple[float, tuple]]:
    """[(score, box)] strongest first, dropping any box overlapping a kept one by IoU >= same (OWLv2 does no NMS)."""
    kept: list[tuple[float, tuple]] = []
    for s, b in sorted(boxes, key=lambda d: -d[0]):
        if all(iou(b, k) < same for _, k in kept):
            kept.append((s, b))
    return kept


def box_distance(pt: tuple[float, float], box, width: int, height: int) -> float:
    """Pixel distance from a point to a box (0 inside), both normalised, measured in the upright original."""
    dx = max(box[0] - pt[0], 0.0, pt[0] - box[2]) * width
    dy = max(box[1] - pt[1], 0.0, pt[1] - box[3]) * height
    return math.hypot(dx, dy)


def choose_subject(boxes: list[tuple[float, tuple]], focus: tuple[float, float] | None, width: int, height: int) -> int | None:
    """Index of the subject among [(score, box)]: the box the trusted focus point is in or within 3 % of the long
    side of (nearest first, then the higher score); otherwise the highest score. None without boxes."""
    if not boxes:
        return None
    if focus is not None:
        limit = AF_NEAR * max(width, height)
        near = [(box_distance(focus, b, width, height), -s, i) for i, (s, b) in enumerate(boxes)]
        near = [n for n in near if n[0] <= limit]
        if near:
            return min(near)[2]
    return max(range(len(boxes)), key=lambda i: boxes[i][0])
