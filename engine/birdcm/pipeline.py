"""Photos in, PhotoResults out: decode (process pool) -> detect + tower (this thread, the only model thread) ->
result. One entry, Engine.run(items, should_stop), shared by `birdcm scan` and the queue.

Shape: decode jobs are submitted ahead (at most 2 x workers in flight, the back-pressure); finished frames are
collected into a GPU batch (full, or 200 ms after its first frame, or nothing else coming); exiftool reads run on
one helper thread ahead of the GPU. Every wait has a timeout and checks should_stop. On stop: no new submissions,
the batch already on the GPU finishes and is yielded, decoded-but-not-run frames and in-flight decodes are dropped.
"""
from __future__ import annotations

import hashlib
import json
import multiprocessing as mp
import os
import time
from collections import deque
from collections.abc import Callable, Iterator
from concurrent.futures import FIRST_COMPLETED, Future, ProcessPoolExecutor, ThreadPoolExecutor, wait
from concurrent.futures.process import BrokenProcessPool
from pathlib import Path

from PIL import Image

from birdcm import config, decode, geometry, models
from birdcm.result import PENDING, PhotoResult

PIPELINE_VERSION = 1            # bump when any step's output changes: old results stop being reused
SETTINGS = {"frame": decode.FRAME, "embedded_min": decode.EMBEDDED_MIN, "min_crop": geometry.MIN_CROP,
            "context": geometry.CONTEXT, "af_near": geometry.AF_NEAR}
DECODE_TIMEOUT = 120.0          # seconds one decode may run before its pool is killed and the file isolated
GPU_WAIT = 0.2                  # a partial GPU batch waits at most this long for more frames
EXIF_CHUNK = 16


def fingerprint(region: str | None) -> str:
    """Models, pipeline version, settings and the effective region: a stored result is reused only when this and
    the file's (size, mtime) match."""
    from birdcm import detect, tower
    cfg = {**SETTINGS, "det": [detect.FLOOR, detect.SECOND, detect.SECOND_TOP],
           "level": [tower.SPECIES_P, tower.SPECIES_MARGIN, tower.GENUS_P]}
    s = json.dumps([models.digest(), PIPELINE_VERSION, cfg, region], sort_keys=True)
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def image_paths(path: str, size: int, mtime_ns: int) -> tuple[Path, Path]:
    """(thumbnail, preview) cache files of one photo version, under the cache dir only."""
    key = hashlib.sha1(f"{path}|{size}|{mtime_ns}".encode()).hexdigest()
    d = config.cache_dir() / "img" / key[:2]
    return d / f"{key}-t.jpg", d / f"{key}-p.jpg"


def pick_device() -> str:
    import torch
    return "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"


def _oom(e: Exception) -> bool:
    return "out of memory" in str(e).lower()


def split_on_oom(fn: Callable[[list], list], xs: list) -> list:
    """fn(xs), halving the batch on out-of-memory; a single item that still runs out raises."""
    try:
        return fn(xs)
    except RuntimeError as e:
        if not _oom(e) or len(xs) == 1:
            raise
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
        h = len(xs) // 2
        return split_on_oom(fn, xs[:h]) + split_on_oom(fn, xs[h:])


class Engine:
    def __init__(self, workers: int = 4, det_batch: int = 8, tower_batch: int = 32, device: str | None = None,
                 mode: str = "embedded", det_half: bool = False) -> None:
        from birdcm.detect import Detector
        from birdcm.tower import Tower
        p = models.paths()
        self.device = device or pick_device()
        self.detector = Detector(str(p["detector:owlv2-int8"]), self.device, half=det_half)
        self.tower = Tower(str(p["tower"]), str(p["names"]), str(p["parts"]), str(p["flight"]), self.device)
        self.exif = decode.ExifTool()
        self.workers, self.det_batch, self.tower_batch, self.mode = workers, det_batch, tower_batch, mode
        self.stats: dict[str, float] = {}
        self._pool: ProcessPoolExecutor | None = None

    def close(self) -> None:
        if self._pool:
            self._pool.shutdown(cancel_futures=True)
            self._pool = None
        self.exif.close()

    def _new_pool(self) -> ProcessPoolExecutor:
        if self._pool:
            for proc in list(getattr(self._pool, "_processes", {}).values()):
                proc.kill()
            self._pool.shutdown(wait=False, cancel_futures=True)
        self._pool = ProcessPoolExecutor(self.workers, mp_context=mp.get_context("spawn"), initializer=decode.worker_init)
        return self._pool

    def _add(self, key: str, dt: float) -> None:
        self.stats[key] = self.stats.get(key, 0.0) + dt

    def run(self, items: list[dict], region: str | None = None, should_stop: Callable[[], bool] = lambda: False
            ) -> Iterator[tuple[dict, PhotoResult | None, str | None]]:
        """items: {id, path, size, mtime_ns}. Yields (item, result, None) or (item, None, error) per photo, in
        completion order. Stops early (see module doc) when should_stop() turns true."""
        pool = self._pool or self._new_pool()
        exif_exec = ThreadPoolExecutor(1)
        exif_futs: dict[str, Future] = {}
        todo, suspects = deque(items), deque()
        inflight: dict[Future, tuple[dict, float]] = {}
        ready: list[tuple[dict, dict]] = []
        first_ready, isolating = 0.0, False
        try:
            while todo or suspects or inflight or ready:
                if should_stop():
                    return
                # submit: normal work keeps 2 x workers in flight; after a pool crash, suspects go one at a time
                while (suspects and not inflight) or (not suspects and todo and len(inflight) < 2 * self.workers):
                    isolating = bool(suspects)
                    it = (suspects or todo).popleft()
                    if it["path"] not in exif_futs:
                        chunk = [it["path"], *[t["path"] for t in list(todo)[:EXIF_CHUNK - 1] if t["path"] not in exif_futs]]
                        fut = exif_exec.submit(self._read_exif, chunk)
                        exif_futs.update({c: fut for c in chunk})
                    thumb, preview = image_paths(it["path"], it["size"], it["mtime_ns"])
                    job = {"path": it["path"], "size": it["size"], "mtime_ns": it["mtime_ns"], "thumb": str(thumb),
                           "preview": str(preview), "mode": self.mode}
                    inflight[pool.submit(decode.decode, job)] = (it, time.monotonic())
                    if suspects:
                        break
                if inflight:
                    t = time.perf_counter()
                    done, _ = wait(list(inflight), timeout=0.05 if ready else 0.25, return_when=FIRST_COMPLETED)
                    self._add("wait_decode", time.perf_counter() - t)
                    crashed = False
                    for f in done:
                        it, _t0 = inflight.pop(f)
                        try:
                            d = f.result()
                        except BrokenProcessPool:
                            crashed = True
                            inflight[f] = (it, _t0)       # handled with the rest below
                            continue
                        except Exception as e:  # noqa: BLE001 - one bad file fails alone
                            yield it, None, _err(e)
                            continue
                        self._add("decode", d["t_decode"])
                        self._add("save", d["t_save"])
                        if not ready:
                            first_ready = time.monotonic()
                        ready.append((it, d))
                    stuck = {id(inflight[f][0]) for f, (_, t0) in inflight.items() if time.monotonic() - t0 > DECODE_TIMEOUT}
                    if crashed or stuck:
                        # A crash with several decodes in flight can't be pinned on one: they all become suspects
                        # and run again one at a time; a suspect that crashes alone is the bad file.
                        victims = [it for it, _ in inflight.values()]
                        inflight.clear()
                        pool = self._new_pool()
                        for it in victims:
                            if id(it) in stuck:
                                yield it, None, "解码超时（文件可能已损坏）"
                            elif isolating:
                                yield it, None, "解码进程崩溃（文件可能已损坏）"
                            else:
                                suspects.append(it)
                if ready and (len(ready) >= self.det_batch or not (todo or suspects or inflight)
                              or time.monotonic() - first_ready > GPU_WAIT):
                    batch, ready = ready[:self.det_batch], ready[self.det_batch:]
                    first_ready = time.monotonic()
                    yield from self._gpu(batch, exif_futs, region)
        finally:
            for f in inflight:
                f.cancel()
            exif_exec.shutdown(wait=False, cancel_futures=True)

    def _read_exif(self, paths: list[str]) -> dict[str, dict]:
        t = time.perf_counter()
        try:
            return self.exif.read(paths)
        except Exception:  # noqa: BLE001 - missing shooting info degrades to empty fields, never fails a photo
            return {}
        finally:
            self._add("exif", time.perf_counter() - t)

    def _gpu(self, batch: list[tuple[dict, dict]], exif_futs: dict[str, Future], region: str | None
             ) -> Iterator[tuple[dict, PhotoResult | None, str | None]]:
        t = time.perf_counter()
        try:
            dets = split_on_oom(self.detector, [d["frame"] for _, d in batch])
        except Exception as e:  # noqa: BLE001 - a model failure fails these photos, not the scan
            for it, _ in batch:
                yield it, None, _err(e)
            return
        self._sync()
        self._add("detect", time.perf_counter() - t)
        t = time.perf_counter()
        rows, crops = [], []
        for (it, d), boxes in zip(batch, dets):
            try:
                exif = exif_futs.pop(it["path"]).result(timeout=60).get(it["path"], {})
            except Exception:  # noqa: BLE001
                exif = {}
            focus = geometry.focus_point(exif.get("focus_raw"), d["orientation"])
            subject = geometry.choose_subject(boxes, focus, d["width"], d["height"])
            frame = d["frame"]
            fh, fw = frame.shape[:2]
            crop = geometry.crop_rect(boxes[subject][1], fw, fh) if subject is not None else None
            if crop:
                crops.append(Image.fromarray(frame).crop(crop))
            rows.append((it, d, exif, focus, boxes, subject, crop))
        self._add("post", time.perf_counter() - t)
        t = time.perf_counter()
        try:
            looks = [r for i in range(0, len(crops), self.tower_batch)
                     for r in split_on_oom(self.tower, crops[i:i + self.tower_batch])]
        except Exception as e:  # noqa: BLE001
            for it, *_ in rows:
                yield it, None, _err(e)
            return
        self._sync()
        self._add("tower", time.perf_counter() - t)
        looks.reverse()
        for it, d, exif, focus, boxes, subject, crop in rows:
            look = looks.pop() if crop else None
            yield it, build(it, d, exif, focus, boxes, subject, crop, look, region), None

    def _sync(self) -> None:
        import torch
        if self.device == "mps":
            torch.mps.synchronize()


def _err(e: Exception) -> str:
    if isinstance(e, decode.FileChanged):
        return str(e)
    return f"{type(e).__name__}: {e}"[:500]


def build(it: dict, d: dict, exif: dict, focus, boxes, subject, crop, look, region: str | None) -> PhotoResult:
    fh, fw = d["frame"].shape[:2]
    to = (lambda pt: [round(v, 5) for v in geometry.from_input(pt, crop, fw, fh)]) if crop else None
    species = eye = eye_p = beak = beak_p = None
    flying = p_fly = eye_visible = None
    if look:
        species = {"level": look["level"], "label": look["label"], "top5": look["top5"], "geo": False}
        k = 0 if look["p_eyes"][0] >= look["p_eyes"][1] else 1
        eye, eye_p = to(look["eyes"][k]), round(look["p_eyes"][k], 4)
        eye_visible = eye_p >= 0.5
        beak, beak_p = to(look["beak"]), round(look["p_beak"], 4)
        p_fly = round(look["p_fly"], 4)
        flying = p_fly >= 0.5
    ex = {k: exif.get(k) for k in ("camera", "lens", "focal_mm", "aperture", "shutter", "iso", "ev", "focus_mode", "taken_at", "gps")}
    return {
        "file": os.path.basename(it["path"]), "width": d["width"], "height": d["height"],
        "orientation": d["orientation"], "source": d["source"], "exif": ex,
        "region": {"name": region, "source": "photo" if ex["gps"] else ("scan" if region else None), "gps": ex["gps"]},
        "focus": [round(v, 5) for v in focus] if focus else None,
        "boxes": [{"box": [round(v, 5) for v in b], "score": round(s, 4)} for s, b in boxes],
        "subject": subject, "species": species, "eye": eye, "eye_p": eye_p, "eye_visible": eye_visible,
        "beak": beak, "beak_p": beak_p, "flying": flying, "p_fly": p_fly,
        "clear": None, "sharpness": None, "aesthetic": None, "rarity": None,
        "rejected": subject is None, "reject_reason": "没有找到鸟" if subject is None else None,
        "pending": list(PENDING),
    }
