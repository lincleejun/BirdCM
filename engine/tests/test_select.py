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
    burst = [photo(0.4 * k, sharp=3.0 + 0.01 * k, aes=0.65) for k in range(6)]
    rest = [photo(100.0 + 60 * j, sp=f"R{j} x", sharp=2.5, aes=0.6) for j in range(24)]
    o = run(burst + rest)
    assert 1 <= sum(1 for x in o[:6] if x["stars"] and x["stars"] > 0) <= 2
    assert any("同组" in x["star_reason"] for x in o[:6] if x["stars"] == 0)


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
