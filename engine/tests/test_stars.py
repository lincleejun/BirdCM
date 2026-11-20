"""stars.py: the research module's self-check, on PhotoResult-shaped rows, plus the spec points of design §9."""
from birdcm.stars import Config, group_bursts, percentiles, rate
from birdcm.i18n import text  # star reasons are codes: rendered in Chinese (conftest)


def res(t, sharp, aes, sp="Aa bb", **k):
    r = {"rejected": False, "reject_reason": None, "subject": 0, "boxes": [{"box": [0.4, 0.4, 0.6, 0.6], "score": 0.9}],
         "width": 6000, "height": 4000, "focus": None, "eye": [0.5, 0.45], "beak": [0.55, 0.45], "eye_visible": True,
         "eye_p": 0.9, "beak_p": 0.9, "p_fly": 0.1, "sharpness": sharp, "aesthetic": aes,
         "species": {"level": "species", "label": {"sci": sp, "en": sp, "zh": None, "p": 0.95}} if sp else None,
         "exif": {"camera": "A", "taken_at": None if t is None else f"2026-11-01T10:{int(t) // 60:02d}:{t % 60:06.3f}-08:00"}}
    r.update(k)
    return r


def run(results, **cfg):
    cfg.setdefault("strategy", "quota")                    # these tests pin the recorded strategy; select has its own
    rows = [{"id": i, "result": r} for i, r in enumerate(results)]
    out = rate(rows, cfg)
    return [out[i] for i in range(len(rows))]


def stars(o):
    return [x["stars"] for x in o]


def test_quota_order():
    assert stars(run([res(10.0 * i, i, 0.4 + i / 100) for i in range(10)])) == [1, 1, 1, 1, 2, 2, 2, 3, 3, 3]


def test_burst_cap_passes_slot_on():
    o = run([res(100 + 0.5 * i if i >= 5 else 10.0 * i, i, 0.4 + i / 100) for i in range(10)])
    assert stars(o) == [1, 1, 1, 1, 3, 2, 2, 2, 3, 3]
    assert "连拍组" in text(o[7]["star_reason"])
    assert len({o[i]["burst_group"] for i in range(5, 10)}) == 1 and o[9]["burst_rank"] == 1


def test_species_floor_and_gates():
    rs = [res(10.0 * i, 10 + i, 0.5 + i / 100) for i in range(10)]
    rs += [res(200, 0.1, 0.4, sp="Cc dd"), res(210, 9, 0.9, sp="Ee ff", boxes=[{"box": [0, 0, 1, 1], "score": 0.1}])]
    o = run(rs)
    assert o[10]["stars"] == 2 and "保底" in text(o[10]["star_reason"])
    assert o[11]["stars"] == 0 and "检测把握" in text(o[11]["star_reason"])


def test_caps_and_rejects():
    rs = [res(10.0 * i, i, 0.4 + i / 100) for i in range(10)]
    rs[9]["eye_p"] = 0.2
    rs[8]["focus"] = [0.95, 0.05]                                    # far off the bird
    rs.append(res(500, None, None, rejected=True, reject_reason="没有清楚的鸟"))
    o = run(rs)
    assert o[9]["stars"] == 2 and "眼睛" in text(o[9]["star_reason"])
    assert o[8]["stars"] == 2 and "对焦点" in text(o[8]["star_reason"])
    assert stars(o)[5:8] == [3, 3, 3] and o[10]["stars"] == -1 and text(o[10]["star_reason"]) == "没有清楚的鸟"


def test_gates_aes_and_no_eye_beak():
    o = run([res(0, 5, 0.2), res(10, 5, 0.5, eye_p=0.1, beak_p=0.1), res(20, 5, 0.5)])
    assert stars(o)[:2] == [0, 1] and "美学" in text(o[0]["star_reason"]) and "角度" in text(o[1]["star_reason"])
    o = run([res(0, 0.5, 0.5), res(10, 5, 0.5)], min_sharp=1)
    assert o[0]["stars"] == 0 and "清晰度" in text(o[0]["star_reason"])


def test_composite_and_missing_sharpness():
    o = run([res(0, 1, 0.4), res(10, 0, 0.5, p_fly=0.9)], min_aes=None)
    assert o[0]["q"] == 0.65 and o[1]["q"] == 0.41
    o = run([res(0, None, 0.9), res(10, 1, 0.4), res(20, 2, 0.5)], min_aes=None)
    assert o[0]["q"] == 1.0                                            # missing sharpness uses its aesthetic percentile
    o = run([res(0, None, None)], min_aes=None)
    assert o[0]["q"] == 0.5


def test_head_focus_bonus():
    o = run([res(0, 1, 0.5, focus=[0.5, 0.45]), res(10, 1, 0.5)], min_aes=None)
    assert o[0]["q"] == round(o[1]["q"] + 0.04, 6)


def test_ratio_config_and_unidentified_group():
    assert Config.from_ratio({"preset": "strict", "p3": 20, "p2": 30, "burst_cap": 9, "bogus": 1}).q3 == 0.2
    assert Config.from_ratio({"burst_cap": 9}).burst_cap == 9
    o = run([res(10.0 * i, i, 0.5 + i / 100, sp=None) for i in range(10)], p3=10, p2=20)
    assert stars(o).count(3) == 1 and stars(o).count(2) == 2 and "未确认鸟种" in text(o[9]["star_reason"])
    o = run([res(10.0 * i, i, 0.5 + i / 100, species={"level": "species", "label": {"sci": "X y", "en": "X", "zh": None, "p": 0.6}, "top5": []})
             for i in range(4)])
    assert "未确认" in text(o[0]["star_reason"])                              # p < 0.9: not counted as identified


def test_deterministic_and_failed_rows():
    rs = [res(10.0 * i, i % 3, 0.5 + i / 100) for i in range(12)]
    assert run(rs) == run([dict(r) for r in rs])
    out = rate([{"id": 1, "result": None}], {"strategy": "quota"})
    assert out[1]["stars"] is None and out[1]["burst_size"] == 1


def test_bursts_by_gap_camera_and_subseconds():
    p = lambda i, t, cam="A": {"id": i, "camera": cam, "taken_at": t}   # noqa: E731
    g = group_bursts([p(1, "2026-11-01T10:20:00.306-08:00"), p(2, "2026-11-01T10:20:02.306-08:00"),
                      p(3, "2026-11-01T10:20:04.307-08:00"), p(4, "2026-11-01T10:20:00.900-08:00", cam="B"),
                      p(5, None), p(6, "garbage"), p(7, "2026-11-01T10:20:01.000-08:00")])
    assert g[1][0] == g[7][0] == g[2][0] and g[1][1] == 3 and g[3][0] != g[1][0]
    assert g[4][0] not in (g[1][0], g[3][0]) and g[5][1] == g[6][1] == 1 and g[5][0] == 4


def test_percentiles():
    assert percentiles([3, 1, 1, 2]) == [1.0, 1 / 6, 1 / 6, 2 / 3]


def test_validate_star_settings():
    import pytest

    from birdcm.stars import validate
    assert validate({"preset": "std", "p3": 30, "p2": 30, "burst_cap": 3, "min_sharp": None, "per_species": False})
    for bad in ({"p3": "x"}, {"p3": 80, "p2": 30}, {"burst_cap": -1}, {"nope": 1}, {"per_species": 1},
                {"w_sharp": float("nan")}, {"min_aes": True},
                {"size_full": 0}, {"d_burst": -0.1}, {"eye3": 2}, {"w_eye": -1}, {"keep": 150}, {"d_species": 0}):
        with pytest.raises(ValueError):
            validate(bad)


def sp(sci, p, level="species", top=()):
    top5 = [{"sci": sci, "en": sci, "zh": None, "p": p}] + [{"sci": s, "en": s, "zh": None, "p": q} for s, q in top]
    return {"level": level, "label": {"sci": sci, "en": sci, "zh": None, "p": p} if level != "uncertain" else None, "top5": top5}


def burst(*species, t0=0.0):
    return [res(t0 + 0.5 * k, 1, 0.5, species=s) for k, s in enumerate(species)]


def test_consensus_majority_corrects_the_odd_frame():
    rs = burst(sp("Pyrocephalus rubinus", 0.97), sp("Pyrocephalus rubinus", 0.95),
               sp("Xenopsaris albinucha", 0.81, level="uncertain", top=[("Pyrocephalus rubinus", 0.1)]))
    o = run(rs)
    assert o[0]["species_fix"] is None and o[1]["species_fix"] is None
    fix = o[2]["species_fix"]
    assert fix["label"]["sci"] == "Pyrocephalus rubinus" and fix["label"]["p"] == 0.1 and fix["consensus"]["support"] == 3
    assert rs[2]["species"]["top5"][0]["sci"] == "Xenopsaris albinucha"         # the frame's own result is kept


def test_consensus_genus_and_uncertain_frames_adopt_it_only_with_evidence():
    o = run(burst(sp("A b", 0.97), sp("A b", 0.96), sp("A b", 0.98), sp("A sp.", 0.95, level="genus", top=[("A b", 0.3)]),
                  sp("Z z", 0.4, level="uncertain")))
    assert o[3]["species_fix"]["label"]["sci"] == "A b"                        # 4 of 5 support it
    assert o[4]["species_fix"] is None                                         # A b is not among its own candidates
    o = run(burst(sp("A b", 0.97), sp("A b", 0.96), sp("A sp.", 0.95, level="genus"), sp("Z z", 0.4, level="uncertain")))
    assert all(x["species_fix"] is None for x in o)                            # 2 of 4 is not a majority


def test_consensus_zero_probability_is_no_vote():
    """Codex E1: one frame A, two frames B that list A at 0 %: B keeps its majority, nothing is overturned."""
    o = run(burst(sp("A a", 0.97), sp("B b", 0.97, top=[("A a", 0.0)]), sp("B b", 0.96, top=[("A a", 0.0)])))
    assert o[1]["species_fix"] is None and o[2]["species_fix"] is None
    assert o[0]["species_fix"] is None                                         # a confirmed other bird is not overwritten


def test_consensus_keeps_a_confirmed_other_bird():
    """Owner's DSC05095-97: a Hooded Merganser (confirmed 0.9965, Surf Scoter 0.3 %) and a Surf Scoter in one burst;
    the merganser frame must not become a scoter, the unconfirmed frame goes with its own best (the merganser)."""
    o = run(burst(sp("Lophodytes cucullatus", 0.6757, level="uncertain", top=[("Melanitta perspicillata", 0.3182)]),
                  sp("Lophodytes cucullatus", 0.9965, top=[("Melanitta perspicillata", 0.0031)]),
                  sp("Melanitta perspicillata", 1.0)))
    assert o[1]["species_fix"] is None and o[2]["species_fix"] is None
    assert o[0]["species_fix"]["label"]["sci"] == "Lophodytes cucullatus"


def test_consensus_needs_a_strict_majority():
    o = run(burst(sp("A b", 0.97), sp("C d", 0.97)))                           # 1 vs 1 of 2: no majority
    assert all(x["species_fix"] is None for x in o)
    o = run(burst(sp("A b", 0.97), sp("C d", 0.97), sp("E f", 0.5, level="uncertain")))
    assert all(x["species_fix"] is None for x in o)


def test_consensus_tie_broken_by_summed_probability():
    o = run(burst(sp("A b", 0.97), sp("C d", 0.99), sp("Q q", 0.3, level="uncertain", top=[("A b", 0.3), ("C d", 0.35)])))
    assert o[0]["species_fix"] is None and o[1]["species_fix"] is None         # confirmed frames keep their bird
    assert o[2]["species_fix"]["label"]["sci"] == "C d"                         # support 2 each; C d sums 1.34 > 1.27


def test_consensus_skips_rejected_and_single_frames_and_feeds_quotas():
    rs = burst(sp("A b", 0.97), sp("A b", 0.96), sp("C d", 0.5, level="uncertain", top=[("A b", 0.4)]))
    rs.append(res(1.5, 1, 0.5, rejected=True, reject_reason="没有清楚的鸟", species=None))
    rs.append(res(500.0, 1, 0.5, species=sp("C d", 0.97)))                    # its own burst: unchanged
    o = run(rs)
    assert o[2]["species_fix"]["label"]["sci"] == "A b" and o[3]["species_fix"] is None and o[4]["species_fix"] is None
    assert o[3]["stars"] == -1 and o[4]["stars"] >= 2                          # C d keeps its floor from its own burst


def test_consensus_carries_the_rare_flag_to_corrected_frames():
    tk = lambda: {**sp("Tyrannus melancholicus", 1.0), "check": "rare", "prior": {"max": 0.15, "median": 0.016}}  # noqa: E731
    odd = sp("Tyrannus sp.", 0.99, level="genus", top=[("Tyrannus melancholicus", 0.13)])
    odd["top5"][0] = {"sci": "Tyrannus couchii", "en": "x", "zh": None, "p": 0.87}
    o = run(burst(tk(), tk(), tk(), odd))
    assert o[3]["species_fix"]["label"]["sci"] == "Tyrannus melancholicus" and o[3]["species_fix"]["check"] == "rare"
    assert o[3]["species_fix"]["prior"] == {"max": 0.15, "median": 0.016}       # Codex I4: the evidence travels with the flag



def at(spx, x):
    """A result whose subject box is centred at (x, 0.5)."""
    return spx, x


def burst_at(*items, t0=0.0):
    out = []
    for k, (spx, x) in enumerate(items):
        r = res(t0 + 0.5 * k, 1, 0.5, species=spx)
        r["boxes"] = [{"box": [x - 0.05, 0.45, x + 0.05, 0.55], "score": 0.9}]
        r["subject"] = 0
        out.append(r)
    return out


def test_lookalike_pair_flipping_on_one_bird_takes_the_dominant():
    """Owner's group 16: one tern on one post, Royal 10 frames / Elegant 2, alternating at 0.99 each."""
    E, R = "Thalasseus elegans", "Thalasseus maximus"
    seq = [R, R, R, R, E, R, R, R, R, R, E, R]
    o = run(burst_at(*[(sp(s, 0.99, top=[(E if s == R else R, 0.01)]), 0.5) for s in seq]))
    fixed = [x["species_fix"] for x in o]
    assert fixed[4]["label"]["sci"] == R and fixed[4]["lookalike"] == E and fixed[10]["label"]["sci"] == R
    assert all(f is None for k, f in enumerate(fixed) if k not in (4, 10))


def test_lookalike_rule_leaves_other_birds_and_other_genera():
    E, R = "Thalasseus elegans", "Thalasseus maximus"
    # the minority bird sits elsewhere in the frame: a second bird, not a flip
    o = run(burst_at(*[(sp(R, 0.99), 0.3)] * 6, (sp(E, 0.99), 0.8)))
    assert o[6]["species_fix"] is None
    # different genera (the merganser / scoter case): untouched
    o = run(burst_at(*[(sp("Melanitta perspicillata", 1.0), 0.5)] * 6, (sp("Lophodytes cucullatus", 0.99), 0.5)))
    assert o[6]["species_fix"] is None
    # not clearly dominant (4 vs 4): untouched
    o = run(burst_at(*[(sp(R, 0.99), 0.5)] * 4, *[(sp(E, 0.99), 0.5)] * 4))
    assert all(x["species_fix"] is None for x in o)



def test_bursts_follow_the_body_and_ignore_the_machine_time_zone(monkeypatch):
    """Codex C8: two bodies of one model must not share a burst; a time with and without its offset is the same
    moment on the camera's clock whatever the machine's time zone."""
    import time
    from birdcm.stars import group_bursts
    a = [{"id": 1, "camera": "ILCE-7M4 111", "taken_at": "2026-11-14T10:00:00"},
         {"id": 2, "camera": "ILCE-7M4 222", "taken_at": "2026-11-14T10:00:00.5"}]
    g = group_bursts(a)
    assert g[1][0] != g[2][0]
    b = [{"id": 1, "camera": "X", "taken_at": "2026-11-14T10:00:00"}, {"id": 2, "camera": "X", "taken_at": "2026-11-14T10:00:01-08:00"}]
    for tz in ("America/Los_Angeles", "UTC", "Asia/Shanghai"):
        monkeypatch.setenv("TZ", tz)
        time.tzset()
        g = group_bursts(b)
        assert g[1][0] == g[2][0], tz
    monkeypatch.delenv("TZ")
    time.tzset()


def test_parse_exif_keeps_the_body_serial():
    from birdcm.decode import parse_exif
    e = parse_exif({"Make": "SONY", "Model": "ILCE-7M4", "SerialNumber": "05226932"})
    assert e["camera_id"] == "ILCE-7M4 05226932"
