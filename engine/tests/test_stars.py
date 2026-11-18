from birdcm.stars import group_bursts, rate


def p(i, t, cam="A"):
    return {"id": i, "camera": cam, "taken_at": t}


def test_bursts_by_gap_camera_and_subseconds():
    g = group_bursts([
        p(1, "2026-11-01T10:20:00.306-08:00"), p(2, "2026-11-01T10:20:02.306-08:00"),   # exactly 2 s: same burst
        p(3, "2026-11-01T10:20:04.307-08:00"),                                            # 2.001 s: new burst
        p(4, "2026-11-01T10:20:00.900-08:00", cam="B"),                                   # other camera
        p(5, None), p(6, "garbage"),                                                      # no time: own groups
        p(7, "2026-11-01T10:20:01.000-08:00"),                                            # out of order: sorted in
    ])
    assert g[1][0] == g[7][0] == g[2][0] and g[1][1] == 3
    assert g[3][0] != g[1][0] and g[3][1] == 1
    assert g[4][0] not in (g[1][0], g[3][0])
    assert g[5][1] == g[6][1] == 1 and len({g[5][0], g[6][0], g[1][0], g[3][0], g[4][0]}) == 5
    assert max(n for n, _ in g.values()) == 5 and g[5][0] == 4                            # timeless last, in order


def test_rate_stub_marks_rejects_only():
    rows = [{"id": 1, "result": {"rejected": True, "reject_reason": "没有找到鸟", "exif": {}}},
            {"id": 2, "result": {"rejected": False, "exif": {}}}, {"id": 3, "result": None}]
    r = rate(rows, {})
    assert r[1]["stars"] == -1 and r[1]["star_reason"] == "没有找到鸟"
    assert r[2]["stars"] is None and r[3]["stars"] is None
