import pytest

from birdcm import geometry as g


def test_focus_point_landscape_and_untrusted():
    assert g.focus_point("7008 4672 3580 1839", 1) == pytest.approx((3580 / 7008, 1839 / 4672))
    assert g.focus_point("7008 4672 3504 2336", 1) is None          # exiftool's centre default
    assert g.focus_point("7008 4672 3505 2335", 1) is None          # within a pixel of it
    assert g.focus_point("0 0 0 0", 1) is None                        # seen on 3 real ARWs
    assert g.focus_point(None, 1) is None
    assert g.focus_point("7008 4672 9000 10", 1) is None              # outside its own frame


@pytest.mark.parametrize("orientation,expect", [(1, (0.25, 0.1)), (2, (0.75, 0.1)), (3, (0.75, 0.9)), (4, (0.25, 0.9)),
                                                (5, (0.1, 0.25)), (6, (0.9, 0.25)), (7, (0.9, 0.75)), (8, (0.1, 0.75))])
def test_focus_point_rotation(orientation, expect):
    # sensor point at u=0.25 (from left), v=0.1 (from top) of a landscape frame
    assert g.focus_point("1000 800 250 80", orientation) == pytest.approx(expect)


def test_focus_unknown_orientation_untrusted():
    assert g.focus_point("1000 800 250 80", 9) is None


def test_focus_rotation_matches_pixel_rotation():
    """Rotate a real pixel grid the way decode does and check the marked pixel lands where focus_point says."""
    import numpy as np
    from PIL import Image

    from birdcm.decode import TRANSPOSE
    a = np.zeros((80, 100), np.uint8)
    a[8, 25] = 255                                                    # x=25, y=8 in a 100 x 80 sensor frame
    assert len(TRANSPOSE) == 7
    for o, t in TRANSPOSE.items():
        r = np.asarray(Image.fromarray(a).transpose(t))
        y, x = np.argwhere(r == 255)[0]
        u, v = g.focus_point("100 80 25.5 8.5", o)                    # pixel centre
        assert (x + 0.5) / r.shape[1] == pytest.approx(u, abs=0.011) and (y + 0.5) / r.shape[0] == pytest.approx(v, abs=0.011)


def test_crop_is_square_and_inside():
    c = g.crop_rect((0.4, 0.4, 0.5, 0.6), 2048, 1365)
    assert c[2] - c[0] == c[3] - c[1] and c[0] >= 0 and c[3] <= 1365


def test_crop_edge_box_shifts_inside():
    c = g.crop_rect((0.0, 0.0, 0.05, 0.05), 2048, 1365)              # tiny box in the corner: min side, shifted
    assert c[:2] == (0, 0) and c[2] - c[0] == g.MIN_CROP == c[3] - c[1]
    c = g.crop_rect((0.95, 0.9, 1.0, 1.0), 2048, 1365)
    assert c[2] == 2048 and c[3] == 1365


def test_crop_bigger_than_frame_is_clipped_then_centre_cropped():
    # a portrait frame whose bird fills it: the square is wider than the frame -> clipped, square_map centre-crops
    c = g.crop_rect((0.05, 0.05, 0.95, 0.95), 1365, 2048)
    assert c[2] - c[0] == 1365 and c[3] - c[1] < 2048 + 1
    k, left, top = g.square_map(c)
    assert left == 0 and top > 0


@pytest.mark.parametrize("w,h,box", [(2048, 1365, (0.4, 0.3, 0.6, 0.7)), (1365, 2048, (0.1, 0.0, 0.9, 1.0)),
                                     (2048, 1365, (0.97, 0.9, 1.0, 1.0)), (2048, 1365, (0.0, 0.0, 0.02, 0.03))])
def test_input_round_trip(w, h, box):
    c = g.crop_rect(box, w, h)
    for pt in [(0, 0), (112, 112), (223.5, 10), (5, 200)]:
        n = g.from_input(pt, c, w, h)
        assert 0 <= n[0] <= 1 and 0 <= n[1] <= 1
        assert g.to_input(n, c, w, h) == pytest.approx(pt, abs=1e-6)


def test_input_centre_maps_to_crop_centre():
    c = g.crop_rect((0.4, 0.3, 0.6, 0.7), 2048, 1365)
    x, y = g.from_input((112, 112), c, 2048, 1365)
    assert x * 2048 == pytest.approx((c[0] + c[2]) / 2, abs=1) and y * 1365 == pytest.approx((c[1] + c[3]) / 2, abs=1)


def test_subject_choice():
    W, H = 6000, 4000
    a, b = (0.9, (0.1, 0.1, 0.2, 0.2)), (0.5, (0.6, 0.6, 0.7, 0.7))
    assert g.choose_subject([], None, W, H) is None
    assert g.choose_subject([a, b], None, W, H) == 0                  # no focus: highest score
    assert g.choose_subject([a, b], (0.65, 0.65), W, H) == 1          # focus inside b
    assert g.choose_subject([a, b], (0.72, 0.65), W, H) == 1          # 0.02 * 6000 = 120 px <= 3 % of 6000 = 180
    assert g.choose_subject([a, b], (0.74, 0.65), W, H) == 0          # 240 px away: too far, fall back to score
    c = (0.8, (0.6, 0.6, 0.7, 0.7))                                   # same box as b, higher score: tie -> score
    assert g.choose_subject([a, b, c], (0.65, 0.65), W, H) == 2
    d = (0.95, (0.5, 0.5, 0.75, 0.75))                                # focus inside d and b: both distance 0 -> score
    assert g.choose_subject([b, d], (0.65, 0.65), W, H) == 1
    e = (0.99, (0.68, 0.5, 0.8, 0.55))                                # near but outside e, inside b: nearest wins
    assert g.choose_subject([b, e], (0.69, 0.6), W, H) == 0


def test_dedupe():
    kept = g.dedupe([(0.5, (0, 0, 1, 1)), (0.9, (0, 0, 0.95, 0.95)), (0.4, (2, 2, 3, 3))])
    assert [s for s, _ in kept] == [0.9, 0.4]
