"""Head sharpness (ported from bioclip-bird distill/sharpness.py, grad_ratio only). numpy + OpenCV, deterministic.

  head_sharpness(gray, box, eye=None, eye_vis=0.0, beak=None) -> {"score", "region", "noise", "window"}

gray: 2-D array (0-255) holding the bird; box (x0, y0, x1, y1), eye and beak (x, y) in gray's pixels.
region: "eye" when eye_vis >= 0.5, "head" (between the predicted eye and beak) otherwise, "box" when the points are
missing or implausible. score = gradient ratio: mean squared Sobel gradient over that of the Gaussian(2)-smoothed
window, on the most structured quarter of pixels, the image's own noise energy subtracted from both (noise sigma
estimated from the whole of `gray`: the ISO normalisation). ~1 = blurred, larger = crisper.

Calibration: chosen and thresholded (1.6) on CUB and gardener's half-size RAW demosaic. BirdCM measures on the camera's
embedded JPEG at half size (in-camera sharpening and noise reduction), so the scale differs and NO threshold is
calibrated here: the score is stored and used only as a within-batch percentile (docs/deviations.md).
"""
from __future__ import annotations

import cv2
import numpy as np

IMMERKAER = np.array([[1, -2, 1], [-2, 4, -2], [1, -2, 1]], np.float32)
B = cv2.BORDER_REFLECT


def noise_sigma(gray: np.ndarray) -> float:
    r = cv2.filter2D(np.asarray(gray, np.float32), -1, IMMERKAER, borderType=B)[1:-1, 1:-1]
    return float(np.median(np.abs(r)) / 0.6745 / 6)


def _grads(w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    gx, gy = cv2.Sobel(w, cv2.CV_32F, 1, 0, ksize=3, borderType=B), cv2.Sobel(w, cv2.CV_32F, 0, 1, ksize=3, borderType=B)
    s = cv2.GaussianBlur(w, (0, 0), 2.0, borderType=B)
    sx, sy = cv2.Sobel(s, cv2.CV_32F, 1, 0, ksize=3, borderType=B), cv2.Sobel(s, cv2.CV_32F, 0, 1, ksize=3, borderType=B)
    return gx * gx + gy * gy, sx * sx + sy * sy


GAIN_GRAD_SMOOTH = float(_grads(np.random.default_rng(0).standard_normal((512, 512)).astype(np.float32))[1][8:-8, 8:-8].mean())


def grad_ratio(w: np.ndarray, sigma: float, top: float = 0.25) -> float:
    e, es = _grads(w)
    e, es = e[1:-1, 1:-1].ravel(), es[1:-1, 1:-1].ravel()
    k = max(1, int(es.size * top))
    idx = np.argpartition(es, -k)[-k:]
    num = e[idx].mean() - 24 * sigma ** 2
    den = es[idx].mean() - GAIN_GRAD_SMOOTH * sigma ** 2
    return float(max(num, 0.0) / (max(den, 0.0) + 1.0 + GAIN_GRAD_SMOOTH * sigma ** 2))


def window(shape: tuple[int, int], cx: float, cy: float, side: float) -> tuple[int, int, int, int]:
    h, w = shape
    s = max(8, int(round(side)))
    x0 = int(np.clip(round(cx - s / 2), 0, max(0, w - s)))
    y0 = int(np.clip(round(cy - s / 2), 0, max(0, h - s)))
    return x0, y0, min(w, x0 + s), min(h, y0 + s)


def region(box, eye=None, eye_vis: float = 0.0, beak=None) -> tuple[str, float, float, float]:
    x0, y0, x1, y1 = box
    L = max(x1 - x0, y1 - y0, 1.0)
    d = float(np.hypot(eye[0] - beak[0], eye[1] - beak[1])) if eye is not None and beak is not None else 0.0
    if not 0.03 * L <= d <= 0.6 * L:
        if eye is not None and eye_vis >= 0.5:
            return "eye", eye[0], eye[1], float(np.clip(0.2 * L, 24, 192))
        return "box", (x0 + x1) / 2, (y0 + y1) / 2, float(min(x1 - x0, y1 - y0))
    if eye_vis >= 0.5:
        return "eye", eye[0], eye[1], float(np.clip(d, 24, 192))
    return "head", (eye[0] + beak[0]) / 2, (eye[1] + beak[1]) / 2, float(np.clip(1.5 * d, 32, 384))


def head_sharpness(gray: np.ndarray, box, eye=None, eye_vis: float = 0.0, beak=None) -> dict:
    g = np.asarray(gray, np.float32)
    if g.ndim == 3:
        g = cv2.cvtColor(g, cv2.COLOR_RGB2GRAY)
    reg, cx, cy, side = region(box, eye, eye_vis, beak)
    x0, y0, x1, y1 = win = window(g.shape, cx, cy, side)
    sigma = noise_sigma(g)
    return {"score": round(grad_ratio(g[y0:y1, x0:x1], sigma), 6), "region": reg, "noise": round(sigma, 4), "window": win}
