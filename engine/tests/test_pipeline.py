"""Engine.run without models: a decode worker that crashes on one file must fail only that file."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import crashy  # noqa: E402

from birdcm.pipeline import Engine  # noqa: E402


class NoExif:
    def read(self, paths):
        return {}

    def close(self):
        pass


def fake_engine():
    e = Engine.__new__(Engine)
    e.workers, e.det_batch, e.tower_batch, e.mode, e.device = 2, 4, 8, "embedded", "cpu"
    e.stats, e._pool, e.exif, e._own_exif = {}, None, NoExif(), False
    e.decode_fn = crashy.decode
    e.geo = None
    e.detector = lambda frames: [[(0.9, (0.1, 0.1, 0.5, 0.5))] for _ in frames]
    e.tower = FakeTower()
    e._sync = lambda: None
    return e


LOOK = {"top5": [{"sci": "A b", "en": "A", "zh": None, "p": 0.9}] * 5, "level": "species",
        "label": {"sci": "A b", "en": "A", "zh": None, "p": 0.9}, "beak": [10, 10], "eyes": [[20, 20], [30, 30]],
        "p_beak": 0.9, "p_eyes": [0.8, 0.1], "p_fly": 0.2, "clear": True}


class FakeTower:
    """Looks at crops; a crop whose first pixel value is in `oom` runs out of memory every time, alone or in a batch."""

    def __init__(self, oom=(), clear=True):
        self.oom, self.clear, self.calls = set(oom), clear, 0

    def __call__(self, crops):
        crops = [c[0] if isinstance(c, tuple) else c for c in crops]       # (crop, p_geo) as the engine passes them
        self.calls += 1
        if any(c.getpixel((0, 0))[0] in self.oom for c in crops):
            raise RuntimeError("MPS backend out of memory")
        return [{**LOOK, "clear": self.clear} for _ in crops]

    def aesthetic(self, frames):
        return [0.5 for _ in frames]


def items(names):
    return [{"id": i, "path": f"/x/{n}", "size": 1, "mtime_ns": 1} for i, n in enumerate(names)]


def test_crash_isolates_bad_file_and_engine_survives(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path))
    e = fake_engine()
    try:
        names = [f"ok{i}" for i in range(6)] + ["bad"] + [f"ok{i}" for i in range(6, 12)]
        out = {it["path"]: (res, err) for it, res, err in e.run(items(names))}
        assert len(out) == 13
        assert out["/x/bad"][0] is None and "崩溃" in out["/x/bad"][1]
        assert all(res and not err for p, (res, err) in out.items() if p != "/x/bad")
        again = list(e.run(items(["ok20", "ok21"])))                     # same Engine, rebuilt pool
        assert [err for _, _, err in again] == [None, None]
    finally:
        e.close()


def test_stop_drops_unstarted_work(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path))
    e = fake_engine()
    try:
        got, t = [], time.monotonic()
        for it, res, err in e.run(items([f"ok{i}" for i in range(40)]), should_stop=lambda: len(got) >= 4):
            got.append(it["id"])
        assert 4 <= len(got) < 40 and time.monotonic() - t < 30
    finally:
        e.close()


def test_one_persistent_oom_fails_only_its_photo(tmp_path, monkeypatch):
    """Box widths differ per photo, so the crops differ; the one whose crop always runs out of memory fails alone."""
    import numpy as np

    from birdcm.pipeline import per_item
    e = fake_engine()
    e._sync = lambda: None
    widths = [0.1, 0.2, 0.3, 0.4]
    e.detector = lambda frames: [[(0.9, (0.0, 0.0, widths[int(f[0, 0, 0])], 0.5))] for f in frames]
    batch = []
    for k in range(4):
        f = np.full((600, 900, 3), k, np.uint8)
        batch.append(({"id": k, "path": f"/x/{k}", "size": 1, "mtime_ns": 1},
                      {"frame": f, "gray": None, "width": 900, "height": 600, "orientation": 1, "source": "fake"}))
    e.tower = FakeTower(oom={2})                                                 # photo 2's crop always runs out
    futs = {}
    for it, _ in batch:
        from concurrent.futures import Future
        futs[it["path"]] = Future()
        futs[it["path"]].set_result({})
    out = list(e._gpu(batch, futs, None))
    assert [err is None for _, _, err in out] == [True, True, False, True]
    assert "out of memory" in out[2][2]
    assert per_item(lambda xs: [x * 2 for x in xs], [1, 2, 3]) == [2, 4, 6]
    r = per_item(lambda xs: (_ for _ in ()).throw(RuntimeError("out of memory")) if 2 in xs else [x for x in xs], [1, 2, 3])
    assert r[0] == 1 and isinstance(r[1], RuntimeError) and r[2] == 3


def test_detector_oom_isolated_too(tmp_path):
    import numpy as np
    from concurrent.futures import Future
    e = fake_engine()

    def det(frames):
        if any(f[0, 0, 0] == 9 for f in frames):
            raise RuntimeError("CUDA out of memory")
        return [[(0.9, (0.1, 0.1, 0.5, 0.5))] for _ in frames]
    e.detector = det
    batch, futs = [], {}
    for k in (1, 9, 3):
        f = np.zeros((60, 90, 3), np.uint8)
        f[0, 0, 0] = k
        batch.append(({"id": k, "path": f"/x/{k}", "size": 1, "mtime_ns": 1},
                      {"frame": f, "gray": None, "width": 900, "height": 600, "orientation": 1, "source": "fake"}))
        futs[f"/x/{k}"] = Future()
        futs[f"/x/{k}"].set_result({})
    out = list(e._gpu(batch, futs, None))
    assert [err is None for _, _, err in out] == [True, False, True]
    assert out[0][1]["aesthetic"] == 0.5 and out[0][1]["subject"] == 0


def test_clear_gate_rejects_and_forced_box_bypasses(tmp_path):
    import numpy as np
    from concurrent.futures import Future
    e = fake_engine()
    e.tower = FakeTower(clear=False)
    f = np.zeros((60, 90, 3), np.uint8)
    d = {"frame": f, "gray": None, "width": 900, "height": 600, "orientation": 1, "source": "fake"}
    fut = Future()
    fut.set_result({})
    _, r, _ = next(e._gpu([({"id": 1, "path": "/x/1", "size": 1, "mtime_ns": 1}, d)], {"/x/1": fut}, None))
    assert r["rejected"] and r["reject_reason"] == "没有清楚的鸟" and r["eye"] is None and r["boxes"][0]["eye"] is None
    assert r["species"] is not None and r["species"] == r["boxes"][0]["species"]       # still names the bird
    fut2 = Future()
    fut2.set_result({})
    _, r, _ = next(e._gpu([({"id": 1, "path": "/x/1", "size": 1, "mtime_ns": 1, "boxes": [[0, 0, 1, 1]]}, d)], {"/x/1": fut2}, None))
    assert not r["rejected"] and r["subject"] == 0 and r["boxes"][0]["score"] == 1.0
