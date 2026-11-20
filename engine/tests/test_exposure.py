"""R5 exposure: the subject's blown / crushed share (pipeline.clipping) and its malus in both star strategies."""
import numpy as np

from birdcm.pipeline import clipping
from birdcm.stars import Config, exposure, rate

from test_select import photo
from birdcm.i18n import text  # star reasons are codes: rendered in Chinese (conftest)

BOX = [0.25, 0.25, 0.75, 0.75]


def frame(bird: np.ndarray) -> np.ndarray:
    """A 400 x 400 grey-blue background with `bird` (H x W x 3) pasted over BOX."""
    f = np.full((400, 400, 3), (90, 110, 140), np.uint8)
    f[100:300, 100:300] = bird
    return f


def white_bird(rng, top: int) -> np.ndarray:
    """White plumage: bright with feather texture, never above `top`."""
    base = 238 + 10 * np.sin(np.arange(200)[:, None] / 3.0) + rng.normal(0, 3, (200, 200))
    return np.clip(np.repeat(base[..., None], 3, 2), 0, top).astype(np.uint8)


def test_well_exposed_white_bird_is_not_marked():
    hi, lo = clipping(frame(white_bird(np.random.default_rng(0), 253)), BOX)
    assert hi == 0 and lo == 0
    assert exposure({"clip_hi": hi, "clip_lo": lo}, Config()) is None


def test_bright_white_bird_with_a_few_clipped_specks_is_not_marked():
    hi, _ = clipping(frame(white_bird(np.random.default_rng(1), 255)), BOX)     # noise reaches 255 here and there
    assert 0 < hi < Config().clip_hi_max
    assert exposure({"clip_hi": hi}, Config()) is None


def test_large_flat_255_is_blown():
    b = white_bird(np.random.default_rng(2), 253)
    b[40:160, 40:160] = 255                                                   # the bird's middle burnt out
    hi, lo = clipping(frame(b), BOX)
    assert hi > 0.5 and lo == 0
    assert text(exposure({"clip_hi": hi, "clip_lo": lo}, Config())) == "高光溢出"


def test_one_channel_clipped_colour_is_not_blown():
    b = np.zeros((200, 200, 3), np.uint8)
    b[...] = (255, 40, 30)                                                    # a saturated red bird
    assert clipping(frame(b), BOX)[0] == 0


def test_large_dead_black_is_crushed():
    b = np.full((200, 200, 3), 60, np.uint8)
    b[30:170, 30:170] = 1
    hi, lo = clipping(frame(b), BOX)
    assert lo > 0.5 and hi == 0
    assert text(exposure({"clip_hi": hi, "clip_lo": lo}, Config())) == "暗部死黑"


def test_background_in_the_box_corners_counts_little():
    f = frame(white_bird(np.random.default_rng(3), 253))
    f[100:140, 100:140] = 255                                                 # blown sky in one corner of the box
    assert clipping(f, BOX)[0] == 0


def test_malus_and_reason_in_both_strategies_and_old_results_untouched():
    ps = [photo(10.0 * i, sp=f"S{i} x", sharp=3.0, aes=0.6) for i in range(8)]
    ps[0]["clip_hi"] = 0.4                                                     # blown
    ps[1]["clip_lo"] = 0.6                                                     # crushed
    ps[2].update(clip_hi=0.01, clip_lo=0.02)                                   # measured, fine
    # ps[3:] have no measurement at all (a result scanned before pipeline 10)
    rows = [{"id": i, "result": p} for i, p in enumerate(ps)]
    sel = rate(rows, {"keep": 100})
    assert sel[0]["q"] < sel[2]["q"] and sel[1]["q"] < sel[2]["q"]
    assert sel[2]["q"] == sel[3]["q"] and sel[3]["q_parts"]["exposure"] == 0
    assert sel[0]["q_parts"]["exposure"] == -Config().exposure_malus
    assert "高光溢出" in text(sel[0]["star_reason"]) and "暗部死黑" in text(sel[1]["star_reason"])
    assert sel[0]["stars"] < 3 and sel[1]["stars"] < 3
    assert not any(w in text(sel[i]["star_reason"]) for i in range(2, 8) for w in ("高光溢出", "暗部死黑"))
    quo = rate(rows, {"strategy": "quota"})
    assert quo[0]["q"] < quo[2]["q"] and quo[2]["q"] == quo[3]["q"]
    assert "高光溢出" in text(quo[0]["star_reason"]) and "暗部死黑" in text(quo[1]["star_reason"])
    off = rate(rows, {"keep": 100, "exposure_malus": 0})
    assert off[0]["q"] == off[2]["q"]
