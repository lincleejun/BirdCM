"""Strategy "select": budget, diminishing returns, absolute stars."""
import random
from collections import Counter

from birdcm.stars import rate


def photo(t, sp="Aa bb", sharp=2.0, aes=0.6, eye=0.9, area=0.03, fly=0.1, cam="A", **k):
    r = {"rejected": False, "reject_reason": None, "subject": 0, "file": f"F{t}.ARW",
         "boxes": [{"box": [0.4, 0.4, 0.4 + area ** 0.5, 0.4 + area ** 0.5], "score": 0.9}],
         "width": 6000, "height": 4000, "focus": None, "eye": [0.5, 0.45], "beak": [0.55, 0.45], "eye_visible": eye >= 0.5,
         "eye_p": eye, "beak_p": 0.9, "p_fly": fly, "sharpness": sharp, "aesthetic": aes, "rarity": None,
         "species": {"level": "species", "label": {"sci": sp, "en": sp, "zh": None, "p": 0.97}, "top5": [{"sci": sp, "p": 0.97}]},
         "exif": {"camera": cam, "taken_at": f"2026-11-01T{8 + int(t) // 3600:02d}:{int(t) % 3600 // 60:02d}:{t % 60:06.3f}-08:00"}}
    r.update(k)
    return r


def run(photos, **cfg):
    out = rate([{"id": i, "result": p} for i, p in enumerate(photos)], cfg)
    return [out[i] for i in range(len(photos))]


def stars(o):
    return Counter(x["stars"] for x in o)


def test_budget_is_a_ceiling_and_weak_photos_are_not_used_to_fill_it():
    rng = random.Random(1)
    ps = [photo(10.0 * i, sp=f"S{i % 5} x", sharp=rng.uniform(1, 4), aes=rng.uniform(0.4, 0.7)) for i in range(100)]
    o = run(ps)
    starred = sum(1 for x in o if x["stars"] and x["stars"] > 0)
    assert 25 <= starred <= 25 + 5                                       # budget (+ at most the species floors)
    weak = [photo(10.0 * i, sharp=1.0, aes=0.2, eye=0.1, area=0.001) for i in range(100)]
    o = run(weak)
    assert sum(1 for x in o if x["stars"] and x["stars"] > 0) <= 1         # only the species floor
    assert run(ps, keep=10) and sum(1 for x in run(ps, keep=10) if x["stars"] and x["stars"] > 0) <= 10 + 5


def test_dominant_species_does_not_swallow_the_budget():
    rng = random.Random(7)
    ps = []
    t = 0.0
    for b in range(200):                                                 # 1,200 photos of one species, bursts of 6
        for k in range(6):
            ps.append(photo(t, sp="Dominant x", sharp=rng.uniform(1.5, 4), aes=rng.uniform(0.45, 0.75)))
            t += 0.5
        t += 60
    for j in range(300):                                                 # 300 photos over 30 other species, single frames
        ps.append(photo(t, sp=f"Other {j % 30}", sharp=rng.uniform(1.5, 4), aes=rng.uniform(0.45, 0.75)))
        t += 60
    o = run(ps)
    starred = [i for i, x in enumerate(o) if x["stars"] and x["stars"] > 0]
    by = Counter(ps[i]["species"]["label"]["sci"] for i in starred)
    share = by["Dominant x"] / len(starred)
    assert share < 0.6 and by["Dominant x"] == max(by.values())          # largest share, far from 80 %
    assert all(by[f"Other {j}"] >= 1 for j in range(30))


def test_near_identical_burst_gives_one_or_two_stars():
    look = [(k * 37) % 256 for k in range(64)]
    burst = [photo(0.4 * k, sharp=3.0 + 0.01 * k, aes=0.65, look=look) for k in range(6)]
    rest = [photo(100.0 + 60 * j, sp=f"R{j} x", sharp=2.5, aes=0.6) for j in range(24)]
    o = run(burst + rest)
    assert 1 <= sum(1 for x in o[:6] if x["stars"] and x["stars"] > 0) <= 2
    assert any("同组" in x["star_reason"] for x in o[:6] if x["stars"] == 0)
    assert any("任选其一" in x["star_reason"] for x in o[:6] if x["stars"] == 0)          # near-identical: either will do


def test_a_scan_can_have_no_three_stars():
    ps = [photo(10.0 * i, sp=f"S{i % 4} x", eye=0.3, sharp=1.0 + i / 50) for i in range(40)]
    o = run(ps)
    assert stars(o)[3] == 0 and sum(1 for x in o if x["stars"] and x["stars"] > 0) > 0


def test_three_stars_need_everything_and_flight_weighs():
    good = photo(0, sharp=4.0, aes=0.9, eye=0.95, area=0.05, sp="Solo a")
    fly = photo(100, sharp=2.0, aes=0.5, eye=0.95, area=0.05, fly=0.9, sp="Flyer a")
    perched = photo(200, sharp=2.0, aes=0.5, eye=0.95, area=0.05, sp="Flyer a")
    o = run([good, fly, perched] + [photo(300.0 + 60 * j, sp=f"R{j} x", sharp=1.5, aes=0.4) for j in range(12)])
    assert o[0]["stars"] == 3 and "各方面" in o[0]["star_reason"]
    assert o[1]["q"] > o[2]["q"] + 0.1 and "fly" in o[1]["q_parts"]


def test_species_floor_and_determinism():
    ps = [photo(10.0 * i, sharp=3.5, aes=0.8) for i in range(30)] + [photo(1000, sp="Rare one", sharp=1.0, aes=0.3, eye=0.6)]
    o = run(ps, keep=10)
    assert o[-1]["stars"] >= 1
    assert run(ps, keep=10) == o
    assert run([photo(0, rejected=True, reject_reason="没有清楚的鸟")])[0]["stars"] == -1


def test_old_shaped_settings_migrate_to_select():
    from birdcm.stars import Config
    c = Config.from_ratio({"preset": "strict", "p3": 20, "p2": 30})
    assert c.strategy == "select" and c.keep == 0.20
    assert Config.from_ratio({"strategy": "quota", "p3": 20, "p2": 30}).strategy == "quota"
    assert Config.from_ratio(None).strategy == "select" and Config.from_ratio(None).keep == 0.25


def test_long_burst_may_take_more_than_a_short_one():
    long = [photo(0.4 * k, sharp=3.0 + 0.3 * (k % 3), aes=0.6 + 0.01 * k) for k in range(20)]
    short = [photo(100.0 + 0.4 * k, sp="Bb cc", sharp=3.0, aes=0.6) for k in range(2)]
    rest = [photo(300.0 + 60 * j, sp=f"R{j} x", sharp=2.0, aes=0.5) for j in range(18)]
    o = run(long + short + rest, keep=25)
    n_long = sum(1 for x in o[:20] if (x["stars"] or 0) > 0)
    assert n_long >= 3 and n_long > sum(1 for x in o[20:22] if (x["stars"] or 0) > 0)
    flat = run(long + short + rest, keep=25, burst_share=0, w_burst=0)
    assert sum(1 for x in flat[:20] if (x["stars"] or 0) > 0) < n_long


def test_species_floor_respects_the_weak_floor():
    """Codex E2: 20 weak photos of 20 species at 10 %: not 20/20 starred."""
    weak = [photo(60.0 * i, sp=f"S{i} x", sharp=1.0, aes=0.01, eye=0.01, area=0.00001) for i in range(20)]
    o = run(weak, keep=10)
    assert sum(1 for x in o if (x["stars"] or 0) > 0) <= 2


def test_floor_photos_are_marked_for_the_summary():
    ps = [photo(10.0 * i, sp="Big x", sharp=3.0, aes=0.7) for i in range(40)] + [photo(9000.0, sp="Lone y", sharp=1.5, aes=0.5)]
    o = run(ps, keep=10)
    assert o[40]["stars"] > 0 and o[40]["q_parts"].get("floor") == 1



def test_either_will_do_only_for_frames_that_really_look_alike():
    """Codex E3: same sharpness and aesthetic but a different picture (another pose / another place in the frame)
    is "评分接近", not "任选其一"."""
    a = [(k * 37) % 256 for k in range(64)]
    b = [255 - v for v in a]                                            # the opposite picture
    def two(look2, x2=0.4):
        p1 = photo(0.0, sharp=3.0, aes=0.65, look=a)
        p2 = photo(0.4, sharp=3.0, aes=0.65, look=look2)
        p2["boxes"] = [{"box": [x2, 0.4, x2 + 0.17, 0.57], "score": 0.9}]
        rest = [photo(100.0 + 60 * j, sp=f"R{j} x", sharp=2.5, aes=0.6) for j in range(10)]
        o = run([p1, p2] + rest, keep=10)
        return [x["star_reason"] for x in o[:2] if x["stars"] == 0]
    assert any("任选其一" in r for r in two(a))
    assert not any("任选其一" in r for r in two(b)) and any("评分接近" in r for r in two(b))
    assert not any("任选其一" in r for r in two(a, x2=0.7))             # the bird elsewhere in the frame


def test_each_strategy_reads_its_own_aesthetic_weight():
    from birdcm.stars import Config
    assert (Config().w_aes_select, Config().w_aes, Config().w_sharp) == (0.15, 0.35, 0.65)   # docs/stars.md; quota 0.65 / 0.35
    ps = [photo(10.0 * i, sharp=1 + i % 3, aes=0.4 + i / 20) for i in range(6)]
    q = lambda **cfg: [x["q"] for x in run(ps, **cfg)]                    # noqa: E731
    assert q(w_aes=0.9) == q() != q(w_aes_select=0.9)
    assert q(strategy="quota", w_aes_select=0.9) == q(strategy="quota") != q(strategy="quota", w_aes=0.9)
