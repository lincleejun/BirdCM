"""The original module's self-check, kept with the port."""
import cv2
import numpy as np

from birdcm.sharpness import head_sharpness


def test_blur_order_noise_contrast_regions():
    rng = np.random.default_rng(1)
    base = np.zeros((400, 400), np.float32)
    cv2.circle(base, (200, 200), 30, 200, -1)
    cv2.circle(base, (200, 200), 12, 20, -1)
    base += (rng.random((400, 400)) > 0.97) * 120
    base = cv2.GaussianBlur(base, (0, 0), 0.6)
    box, eye, beak = (100, 100, 300, 300), (200, 200), (260, 230)
    s = {b: head_sharpness(cv2.GaussianBlur(base, (0, 0), b) if b else base, box, eye, 0.9, beak)["score"] for b in (0, 1, 2, 3)}
    assert s[0] > s[1] > s[2] > s[3]
    noisy = {b: head_sharpness((cv2.GaussianBlur(base, (0, 0), b) if b else base) + rng.normal(0, 8, base.shape), box, eye, 0.9, beak)["score"]
             for b in (0, 2)}
    assert noisy[2] < s[1] and abs(noisy[0] - s[0]) < 0.1 * s[0]
    assert abs(head_sharpness(base * 0.4 + 50, box, eye, 0.9, beak)["score"] - s[0]) < 0.1 * s[0]
    assert head_sharpness(base, box, eye, 0.1, beak)["region"] == "head"
    assert head_sharpness(base, box, None, 0.0, None)["region"] == "box"
