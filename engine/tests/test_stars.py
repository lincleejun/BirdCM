"""stars.py: the research module's self-check, on PhotoResult-shaped rows, plus the spec points of design §9."""
from birdcm.stars import Config, group_bursts, percentiles, rate


def res(t, sharp, aes, sp="Aa bb", **k):
    r = {"rejected": False, "reject_reason": None, "subject": 0, "boxes": [{"box": [0.4, 0.4, 0.6, 0.6], "score": 0.9}],
         "width": 6000, "height": 4000, "focus": None, "eye": [0.5, 0.45], "beak": [0.55, 0.45], "eye_visible": True,
         "eye_p": 0.9, "beak_p": 0.9, "p_fly": 0.1, "sharpness": sharp, "aesthetic": aes,
         "species": {"level": "species", "label": {"sci": sp, "en": sp, "zh": None, "p": 0.95}} if sp else None,
         "exif": {"camera": "A", "taken_at": None if t is None else f"2026-11-01T10:{int(t) // 60:02d}:{t % 60:06.3f}-08:00"}}
    r.update(k)
    return r


def run(results, **cfg):
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
    assert "连拍组" in o[7]["star_reason"]
    assert len({o[i]["burst_group"] for i in range(5, 10)}) == 1 and o[9]["burst_rank"] == 1


def test_species_floor_and_gates():
    rs = [res(10.0 * i, 10 + i, 0.5 + i / 100) for i in range(10)]
    rs += [res(200, 0.1, 0.4, sp="Cc dd"), res(210, 9, 0.9, sp="Ee ff", boxes=[{"box": [0, 0, 1, 1], "score": 0.1}])]
    o = run(rs)
    assert o[10]["stars"] == 2 and "保底" in o[10]["star_reason"]
    assert o[11]["stars"] == 0 and "检测把握" in o[11]["star_reason"]


def test_caps_and_rejects():
    rs = [res(10.0 * i, i, 0.4 + i / 100) for i in range(10)]
    rs[9]["eye_p"] = 0.2
    rs[8]["focus"] = [0.95, 0.05]                                    # far off the bird
    rs.append(res(500, None, None, rejected=True, reject_reason="没有清楚的鸟"))
    o = run(rs)
    assert o[9]["stars"] == 2 and "眼睛" in o[9]["star_reason"]
    assert o[8]["stars"] == 2 and "对焦点" in o[8]["star_reason"]
    assert stars(o)[5:8] == [3, 3, 3] and o[10]["stars"] == -1 and o[10]["star_reason"] == "没有清楚的鸟"


def test_gates_aes_and_no_eye_beak():
    o = run([res(0, 5, 0.2), res(10, 5, 0.5, eye_p=0.1, beak_p=0.1), res(20, 5, 0.5)])
    assert stars(o)[:2] == [0, 1] and "美学" in o[0]["star_reason"] and "角度" in o[1]["star_reason"]
    o = run([res(0, 0.5, 0.5), res(10, 5, 0.5)], min_sharp=1)
    assert o[0]["stars"] == 0 and "清晰度" in o[0]["star_reason"]


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
    assert stars(o).count(3) == 1 and stars(o).count(2) == 2 and "未确认鸟种" in o[9]["star_reason"]
    o = run([res(10.0 * i, i, 0.5 + i / 100, species={"level": "species", "label": {"sci": "X y", "en": "X", "zh": None, "p": 0.6}, "top5": []})
             for i in range(4)])
    assert "未确认" in o[0]["star_reason"]                              # p < 0.9: not counted as identified


def test_deterministic_and_failed_rows():
    rs = [res(10.0 * i, i % 3, 0.5 + i / 100) for i in range(12)]
    assert run(rs) == run([dict(r) for r in rs])
    out = rate([{"id": 1, "result": None}], {})
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
