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
    e.detector = lambda frames: [[(0.9, (0.1, 0.1, 0.5, 0.5))] for _ in frames]
    look = {"top5": [{"sci": "A b", "en": "A", "zh": None, "p": 0.9}] * 5, "level": "species",
            "label": {"sci": "A b", "en": "A", "zh": None, "p": 0.9}, "beak": [10, 10], "eyes": [[20, 20], [30, 30]],
            "p_beak": 0.9, "p_eyes": [0.8, 0.1], "p_fly": 0.2}
    e.tower = lambda crops: [look for _ in crops]
    e._sync = lambda: None
    return e


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
