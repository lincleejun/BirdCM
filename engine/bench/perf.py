"""Step 1.5 performance measurements (docs/perf.md). Reads photos only; writes thumbnails to BIRDCM_CACHE_DIR.

  uv run python bench/perf.py decode FILELIST --n 120                 # strategies a/b/c x processes 2/4/8 (warm cache)
  uv run python bench/perf.py gpu FILELIST --n 64                     # detector / tower batch sizes
  uv run python bench/perf.py e2e FILELIST [--workers 4 --det-batch 8 --tower-batch 32]   # full pipeline
FILELIST: one photo path per line.
"""
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import threading
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import psutil

from birdcm import decode


class Peak:
    """Peak RSS of this process tree (workers and exiftool included) and MPS driver memory, sampled every 0.25 s."""

    def __init__(self) -> None:
        self.rss = self.mps = 0
        self._stop = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self) -> None:
        me = psutil.Process()
        while not self._stop.wait(0.25):
            try:
                procs = [me, *me.children(recursive=True)]
                self.rss = max(self.rss, sum(p.memory_info().rss for p in procs if p.is_running()))
            except psutil.Error:
                pass
            try:
                import torch
                if torch.backends.mps.is_available():
                    self.mps = max(self.mps, torch.mps.driver_allocated_memory())
            except Exception:  # noqa: BLE001
                pass

    def stop(self) -> dict:
        self._stop.set()
        return {"peak_rss_gb": round(self.rss / 1e9, 2), "peak_mps_gb": round(self.mps / 1e9, 2)}


def _job(p: str, mode: str, cache: Path) -> dict:
    st = os.stat(p)
    stem = Path(p).stem
    return {"path": p, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "mode": mode,
            "thumb": str(cache / f"bench-{mode}-{stem}-t.jpg"), "preview": str(cache / f"bench-{mode}-{stem}-p.jpg")}


def head_patch(job: dict) -> int:
    """Strategy b's second stage: full-size demosaic again, return only a 256 px patch (here: the centre)."""
    import rawpy
    with rawpy.imread(job["path"]) as raw:
        px = raw.postprocess(use_camera_wb=True, half_size=False, output_bps=8)
    h, w = px.shape[:2]
    return px[h // 2 - 128:h // 2 + 128, w // 2 - 128:w // 2 + 128].copy().nbytes


def read_only(p: str) -> int:
    with open(p, "rb") as f:
        return len(f.read())


def run_pool(fn, jobs, workers) -> float:
    t = time.perf_counter()
    with ProcessPoolExecutor(workers, mp_context=mp.get_context("spawn"), initializer=decode.worker_init) as pool:
        list(pool.map(fn, jobs, chunksize=1))
    return time.perf_counter() - t


def cmd_decode(files: list[str], a) -> None:
    cache = Path(os.environ.get("BIRDCM_CACHE_DIR", "/tmp")) / "bench"
    cache.mkdir(parents=True, exist_ok=True)
    t = time.perf_counter()
    for p in files:                                   # warm the OS cache so no variant is favoured by order
        read_only(p)
    print(json.dumps({"warm_read_s": round(time.perf_counter() - t, 1), "n": len(files)}), flush=True)
    bird = a.bird_fraction
    for workers in (2, 4, 8):
        for mode in ("embedded", "half", "full"):
            peak = Peak()
            dt = run_pool(decode.decode, [_job(p, mode, cache) for p in files], workers)
            row = {"workers": workers, "mode": mode, "s": round(dt, 2), "photos_per_s": round(len(files) / dt, 2), **peak.stop()}
            if mode == "half":                        # strategy b = half for everything + full re-decode for bird photos
                k = round(len(files) * bird)
                dt2 = run_pool(head_patch, [_job(p, mode, cache) for p in files[:k]], workers)
                row["b_second_stage_s"] = round(dt2, 2)
                row["b_photos_per_s"] = round(len(files) / (dt + dt2), 2)
            print(json.dumps(row), flush=True)


def cmd_gpu(files: list[str], a) -> None:
    from birdcm import models
    from birdcm.detect import Detector
    from birdcm.geometry import crop_rect
    from birdcm.pipeline import pick_device
    from birdcm.tower import Tower
    from PIL import Image
    dev = pick_device()
    frames = [decode.decode(_job(p, "embedded", Path("/tmp")) | {"thumb": None, "preview": None})["frame"] for p in files]
    m = models.paths()
    for half in (False, True):
        det = Detector(str(m["detector:owlv2-int8"]), dev, half=half)
        det(frames[:2])
        for bs in (4, 8, 16):
            t = time.perf_counter()
            for i in range(0, len(frames), bs):
                det(frames[i:i + bs])
            dt = time.perf_counter() - t
            print(json.dumps({"stage": "detect", "half": half, "batch": bs, "photos_per_s": round(len(frames) / dt, 2)}), flush=True)
        # preprocessing alone (on device), to see whether it, not the forward pass, is the ceiling
        t = time.perf_counter()
        for i in range(0, len(frames), 8):
            det.prepare(frames[i:i + 8])
        import torch
        torch.mps.synchronize() if dev == "mps" else None
        print(json.dumps({"stage": "detect_prepare_only", "half": half, "photos_per_s": round(len(frames) / (time.perf_counter() - t), 2)}), flush=True)
        boxes = det(frames)
        del det
    tw = Tower(str(m["tower"]), str(m["names"]), str(m["parts"]), str(m["flight"]), dev)
    crops = [Image.fromarray(f).crop(crop_rect(b[0][1], f.shape[1], f.shape[0])) for f, b in zip(frames, boxes) if b]
    crops = (crops * (128 // max(1, len(crops)) + 1))[:128]
    tw(crops[:4])
    for bs in (16, 32, 64):
        t = time.perf_counter()
        for i in range(0, len(crops), bs):
            tw(crops[i:i + bs])
        print(json.dumps({"stage": "tower", "batch": bs, "crops_per_s": round(len(crops) / (time.perf_counter() - t), 2)}), flush=True)


def cmd_e2e(files: list[str], a) -> None:
    from birdcm.pipeline import Engine
    peak = Peak()
    t0 = time.perf_counter()
    e = Engine(workers=a.workers, det_batch=a.det_batch, tower_batch=a.tower_batch, det_half=a.det_half)
    load = time.perf_counter() - t0
    items = []
    for i, p in enumerate(files):
        st = os.stat(p)
        items.append({"id": i, "path": p, "size": st.st_size, "mtime_ns": st.st_mtime_ns})
    t1, first, n, ok, birds, src = time.perf_counter(), None, 0, 0, 0, {}
    for it, res, err in e.run(items):
        n += 1
        first = first or time.perf_counter() - t1
        ok += err is None
        if res:
            birds += not res["rejected"]
            src[res["source"]] = src.get(res["source"], 0) + 1
        if n % 250 == 0:
            print(json.dumps({"done": n, "s": round(time.perf_counter() - t1, 1)}), flush=True)
    dt = time.perf_counter() - t1
    e.close()
    print(json.dumps({"photos": len(files), "ok": ok, "with_bird": birds, "sources": src, "model_load_s": round(load, 1),
                      "run_s": round(dt, 1), "photos_per_s": round(len(files) / dt, 2), "first_result_s": round(first, 2),
                      "workers": a.workers, "det_batch": a.det_batch, "tower_batch": a.tower_batch, "det_half": a.det_half,
                      "stage_s": {k: round(v, 1) for k, v in e.stats.items()}, **peak.stop()}), flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["decode", "gpu", "e2e"])
    ap.add_argument("filelist")
    ap.add_argument("--n", type=int)
    ap.add_argument("--bird-fraction", type=float, default=0.9)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--det-batch", type=int, default=8)
    ap.add_argument("--tower-batch", type=int, default=32)
    ap.add_argument("--det-half", action="store_true")
    a = ap.parse_args()
    files = Path(a.filelist).read_text().split("\n")
    files = [f for f in files if f][:a.n]
    {"decode": cmd_decode, "gpu": cmd_gpu, "e2e": cmd_e2e}[a.cmd](files, a)


if __name__ == "__main__":
    main()
