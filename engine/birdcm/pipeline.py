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
from itertools import islice
from collections.abc import Callable, Iterator
from concurrent.futures import FIRST_COMPLETED, Future, ProcessPoolExecutor, ThreadPoolExecutor, wait
from concurrent.futures.process import BrokenProcessPool
from pathlib import Path

from PIL import Image

import numpy as np

from birdcm import config, confirm, decode, geo, geometry, models
from birdcm import rarity as rarity_mod
from birdcm.result import PhotoResult
from birdcm.sharpness import head_sharpness
from birdcm import i18n
from birdcm.i18n import MSG

SMALL_BOX = 128                 # a subject box shorter than this (2048-frame px) is cropped from the decode resolution
PIPELINE_VERSION = 10           # bump when any step's output changes: old results stop being reused
SETTINGS = {"frame": decode.FRAME, "embedded_min": decode.EMBEDDED_MIN, "min_crop": geometry.MIN_CROP,
            "context": geometry.CONTEXT, "af_near": geometry.AF_NEAR, "max_boxes": 5}
DECODE_TIMEOUT = 120.0          # seconds one decode may run before its pool is killed and the file isolated
GPU_WAIT = 0.2                  # a partial GPU batch waits at most this long for more frames
EXIF_CHUNK = 16
MAX_BOXES = 5            # boxes looked at per photo (strongest first); ponytail: raise if flocks matter


# Data hashes of earlier releases whose results are the same as now (only display-only inputs changed): a stored
# fingerprint made with one of these is moved to the current one instead of marking the scan stale.
# d8d5a4e6f3379b0a: the old Wikidata Chinese-name table was still hashed in (names are joined at read time since IOC 15.2).
EQUIVALENT_DATA = ("d8d5a4e6f3379b0a",
                   "44540bd88e9a7f22")   # before regions.csv gained its ISO 3166-2 column (for eBird export; same results)
# Location keys before the prior's cover was in them (Codex C1): pipeline 4 already read a region's lattice, so a
# region scan made then has the same results; a point scan too (its neighbourhood). Moved, not marked stale.
EQUIVALENT_OLD_KEY = True


def fingerprint(region, model_digest: str | None = None, data: str | None = None, old_key: bool = False) -> str:
    """Models (role -> sha256), bundled data (regions; Chinese names are joined at read time, names.py, so not here),
    pipeline version, settings and the effective region: a
    stored result is reused only when this and the file's (size, mtime) match. An Engine passes the digest of the
    manifest it actually loaded (Engine.fingerprint)."""
    from birdcm import detect, tower
    cfg = {**SETTINGS, "det": [detect.FLOOR, detect.SECOND, detect.SECOND_TOP],
           "level": [tower.SPECIES_P, tower.SPECIES_MARGIN, tower.GENUS_P]}
    data = data or hashlib.sha256(b"".join(f.read_bytes() for f in (geo.REGIONS, geo.COUNTRIES, geo.INDEX, geo.GRID_FILE, geo.BOUNDARIES))).hexdigest()[:16]
    from birdcm import rarity
    cfg["iucn"] = rarity.SHOW_IUCN
    cfg["geo_grid"] = geo.GRID
    cfg["geo_floor"] = geo.FLOOR
    from birdcm import confirm
    cfg["confirm"] = [confirm.EPS, confirm.TAU, confirm.LOOK_P, confirm.LOOK_RATIO, geo.NEAR, geo.WEEKS, geo.UNKNOWN_PRIOR, geo.NEAR_EDGE]
    s = json.dumps([model_digest or models.digest(), data, PIPELINE_VERSION, cfg, geo.fingerprint_key(region, old_key)], sort_keys=True)
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


def per_item(fn: Callable[[list], list], xs: list) -> list:
    """fn over a batch, one result per item: when the batch fails (out of memory or anything else) it is halved until
    the failing items stand alone; those get their exception, every other item its result."""
    if not xs:
        return []
    try:
        return list(fn(xs))
    except Exception as e:  # noqa: BLE001
        if len(xs) == 1:
            return [e]
        if _oom(e):
            import torch
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        h = len(xs) // 2
        return per_item(fn, xs[:h]) + per_item(fn, xs[h:])


class Engine:
    def __init__(self, workers: int = 4, det_batch: int = 8, tower_batch: int = 32, device: str | None = None,
                 mode: str = "embedded", det_half: bool = True,
                 exif: decode.ExifTool | None = None) -> None:
        from birdcm.detect import Detector
        from birdcm.tower import Tower
        self.model_digest = models.digest()          # taken with the paths: the fingerprint of what is loaded
        p = models.paths()
        self.device = device or pick_device()
        self.detector = Detector(str(p["detector:owlv2-int8"]), self.device, half=det_half and self.device != "cpu")
        self.tower = Tower(str(p["tower"]), str(p["names"]), str(p["parts"]), str(p["flight"]), self.device,
                           clear=str(p["clear"]) if "clear" in p else None,           # optional files: models.OPTIONAL_EFFECT
                           aesthetic=str(p["aesthetic"]) if "aesthetic" in p else None)
        self.geo = geo.Geo(str(p["geo"]), self.tower.sci)
        self.rarity = rarity_mod.table()                # the global table when installed, else US / CA / CN
        self.exif, self._own_exif = exif or decode.ExifTool(), exif is None
        self.workers, self.det_batch, self.tower_batch, self.mode = workers, det_batch, tower_batch, mode
        self.stats: dict[str, float] = {}
        self.decode_fn = decode.decode          # a module-level function (spawned workers import it); tests swap it
        self._pool: ProcessPoolExecutor | None = None

    def fingerprint(self, region) -> str:
        return fingerprint(region, self.model_digest)

    def warm(self) -> None:
        """One grey frame through every model (GPU kernels set up before the first real photo) and the decode workers
        started (each submit starts one while none is idle)."""
        frame = np.full((decode.FRAME * 2 // 3, decode.FRAME, 3), 128, np.uint8)
        self.detector([frame])
        self.tower([Image.fromarray(frame[:448, :448])])
        self.tower.aesthetic([frame])
        self._sync()
        pool = self._pool or self._new_pool()
        for f in [pool.submit(os.getpid) for _ in range(self.workers)]:
            f.result(timeout=DECODE_TIMEOUT)

    def close(self) -> None:
        if self._pool:
            self._pool.shutdown(cancel_futures=True)
            self._pool = None
        if self._own_exif:
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

    def run(self, items: list[dict], region: str | None = None, should_stop: Callable[[], bool] = lambda: False,
            on_submit: Callable[[dict], None] | None = None, between: Callable[[], None] | None = None
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
                if between:                        # batch boundary: single photos waiting go first
                    between()
                    pool = self._pool or self._new_pool()
                broken = crashed = False
                stuck: set[int] = set()
                # submit: normal work keeps 2 x workers in flight; after a pool crash, suspects go one at a time
                while (suspects and not inflight) or (not suspects and todo and len(inflight) < 2 * self.workers):
                    isolating = bool(suspects)
                    it = (suspects or todo).popleft()
                    if it["path"] not in exif_futs:
                        chunk = [it["path"], *[t["path"] for t in islice(todo, EXIF_CHUNK - 1) if t["path"] not in exif_futs]]
                        fut = exif_exec.submit(self._read_exif, chunk)
                        exif_futs.update({c: fut for c in chunk})
                    thumb, preview = image_paths(it["path"], it["size"], it["mtime_ns"])
                    job = {"path": it["path"], "size": it["size"], "mtime_ns": it["mtime_ns"], "thumb": str(thumb),
                           "preview": str(preview), "mode": self.mode, "gray": True}
                    try:
                        fut = pool.submit(self.decode_fn, job)
                    except BrokenProcessPool:             # a worker died while we were on the GPU
                        (suspects if isolating else todo).appendleft(it)
                        broken = True
                        break
                    inflight[fut] = (it, time.monotonic())
                    if on_submit:
                        on_submit(it)
                    if suspects:
                        break
                if inflight:
                    t = time.perf_counter()
                    done, _ = wait(list(inflight), timeout=0.05 if ready else 0.25, return_when=FIRST_COMPLETED)
                    self._add("wait_decode", time.perf_counter() - t)
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
                if crashed or stuck or broken:
                    # A crash with several decodes in flight can't be pinned on one: they all become suspects
                    # and run again one at a time; a suspect that crashes alone is the bad file.
                    victims = [it for it, _ in inflight.values()]
                    inflight.clear()
                    pool = self._new_pool()
                    for it in victims:
                        if id(it) in stuck:
                            yield it, None, MSG["pipeline.decode_timeout"][0]       # stored: Chinese, shown via i18n.text
                        elif isolating:
                            yield it, None, MSG["pipeline.decode_crash"][0]
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

    def identify(self, path: str, region: str | None = None, boxes: list[list[float]] | None = None) -> PhotoResult:
        """One photo now (the single-photo view): same decode worker pool, same GPU path. boxes: normalised boxes the
        person drew (or [[0, 0, 1, 1]] for the whole photo); they skip the detector and the clear-bird gate."""
        st = os.stat(path)
        thumb, preview = image_paths(path, st.st_size, st.st_mtime_ns)
        job = {"path": path, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "thumb": str(thumb), "preview": str(preview),
               "mode": self.mode, "gray": True}
        try:
            d = (self._pool or self._new_pool()).submit(self.decode_fn, job).result(timeout=DECODE_TIMEOUT)
        except (BrokenProcessPool, TimeoutError):
            self._new_pool()
            raise RuntimeError(i18n.t("pipeline.decode_failed")) from None
        done: Future = Future()
        done.set_result(self._read_exif([path]))
        it = {"id": None, "path": path, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "boxes": boxes}
        _, res, err = next(self._gpu([(it, d)], {path: done}, region))
        if err:
            raise RuntimeError(err)
        return res

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
        """Detect, look at every box (species, heads, clear-bird gate), choose the subject among the clear boxes, then
        head sharpness (CPU, on the detail-resolution grey) and the whole-photo aesthetic pass. Failures are per photo."""
        t = time.perf_counter()
        forced = [it.get("boxes") for it, _ in batch]
        need = [d["frame"] for (it, d), f in zip(batch, forced) if f is None]
        found = iter(per_item(self.detector, need))
        dets = [[(1.0, tuple(b)) for b in f] if f is not None else next(found) for f in forced]
        self._sync()
        self._add("detect", time.perf_counter() - t)
        t = time.perf_counter()
        rows, crops = [], []
        for (it, d), boxes in zip(batch, dets):
            if isinstance(boxes, Exception):
                rows.append((it, d, boxes))
                continue
            try:
                exif = exif_futs.pop(it["path"]).result(timeout=60).get(it["path"], {})
            except Exception:  # noqa: BLE001
                exif = {}
            if it.get("gps") is not None or it.get("taken_at"):          # the evaluation list's own place and date
                exif = {**exif, "gps": it.get("gps") or exif.get("gps"), "taken_at": it.get("taken_at") or exif.get("taken_at")}
            if it.get("no_gps"):                                            # evaluation: use the region, not the photo's GPS
                exif = {**exif, "gps": None}
            boxes = boxes[:MAX_BOXES]
            fh, fw = d["frame"].shape[:2]
            im = Image.fromarray(d["frame"])
            sources = [(im, fw, fh)] * len(boxes)
            small = [k for k, (_, b) in enumerate(boxes) if max((b[2] - b[0]) * fw, (b[3] - b[1]) * fh) < SMALL_BOX]
            if small and d.get("source") in ("embedded", "jpeg") and max(d["width"], d["height"]) > max(fw, fh):
                # a small bird: crop it from the decode-resolution image instead of the 2048 frame (Codex C4,
                # bench/c4_ablation.py); costs one more JPEG decode (~0.05 s) for these photos only
                try:
                    big = decode.load_upright(Path(it["path"]))[0]
                    for k in small:
                        sources[k] = (big, big.width, big.height)
                except Exception:  # noqa: BLE001 - keep the frame crop
                    pass
            rects = [(geometry.crop_rect(b, sw, sh), sw, sh) for (_, b), (_, sw, sh) in zip(boxes, sources)]
            first = len(crops)
            where = self._place(exif, region)
            crops += [(geometry.pad_crop(src, r), where["p_geo"] if where else None) for (r, _, _), (src, _, _) in zip(rects, sources)]
            rows.append((it, d, (exif, boxes, rects, first, where)))
        looks = [r for i in range(0, len(crops), self.tower_batch) for r in per_item(self.tower, crops[i:i + self.tower_batch])]
        for it, d, x in rows:                                  # the range rule, with the place's spread (confirm.py)
            if isinstance(x, Exception):
                continue
            _, boxes, _, first, where = x
            for k in range(first, first + len(boxes)):
                if not isinstance(looks[k], Exception):
                    confirm.decide(looks[k], where and where["wide"], where and where["typical"])
        self._sync()
        self._add("tower", time.perf_counter() - t)
        t = time.perf_counter()
        built = []
        for it, d, x in rows:
            if isinstance(x, Exception):
                built.append((it, None, _err(x)))
                continue
            exif, boxes, rects, first, where = x
            mine = looks[first:first + len(boxes)]
            bad = next((m for m in mine if isinstance(m, Exception)), None)
            if bad is not None:
                built.append((it, None, _err(bad)))
                continue
            try:
                built.append((it, build(it, d, exif, boxes, rects, mine, region, gate=it.get("boxes") is None, where=where), None))
            except Exception as e:  # noqa: BLE001
                built.append((it, None, _err(e)))
        self._add("post", time.perf_counter() - t)
        t = time.perf_counter()
        for _, r, _ in built:
            if r and r["species"]:
                r["rarity"] = self.rarity_of(r["species"], r)
                r["pending"] = [x for x in r["pending"] if x != "rarity"]
        keep = [(n, r) for n, (_, r, _) in enumerate(built) if r and not r["rejected"]]
        frames = [batch[n][1]["frame"] for n, _ in keep]
        scores = [s for i in range(0, len(frames), self.tower_batch) for s in per_item(self.tower.aesthetic, frames[i:i + self.tower_batch])]
        for (n, r), sc in zip(keep, scores):
            if not isinstance(sc, Exception) and sc is not None:
                r["aesthetic"] = sc
                r["pending"] = [p for p in r["pending"] if p != "aesthetic"]
        self._sync()
        self._add("aesthetic", time.perf_counter() - t)
        yield from built

    def rarity_of(self, species: dict, r: dict) -> dict | None:
        return rarity_for(getattr(self, "rarity", None), species, r)

    def _place(self, exif: dict, region: str | None) -> dict | None:
        """Where and when the prior looks: photo GPS, else the scan's region; with the capture week. None = no prior."""
        if self.geo is None:
            return None
        pl = geo.place(exif.get("gps"), region)
        if pl is None:
            return None
        lat, lon, src = pl
        label = geo.location_label(region) if src == "region" else None
        wide, typical = self.geo.spread(lat, lon, exif.get("taken_at"), src, label)
        um = getattr(self.geo, "unmapped", None)
        post, wide_k, typ_k = wide, wide, typical
        if um is not None and um.any():                    # unknown prior: neutral-ish in the posterior, NaN for the rule
            post = np.where(um, geo.UNKNOWN_PRIOR, wide)
            wide_k, typ_k = np.where(um, np.nan, wide), np.where(um, np.nan, typical)
        return {"lat": round(lat, 5), "lon": round(lon, 5), "source": src, "week": geo.week_of(exif.get("taken_at")),
                "p_geo": post, "wide": wide_k, "typical": typ_k}

    def _sync(self) -> None:
        import torch
        if self.device == "mps":
            torch.mps.synchronize()


def rarity_for(table, species: dict | None, r: dict) -> dict | None:
    """Rarity of a confirmed species at the photo's place (the prior's point, else the scan's region label) and month."""
    if not species or species.get("level") != "species" or not species.get("label"):
        return None
    if table is None:                                  # the rarity table is not installed: still the IUCN category
        return {"tier": None, "label": "数据不足", "iucn": rarity_mod.iucn(species["label"]["sci"]), "region": None}
    reg = r.get("region") or {}
    pr = reg.get("prior") or {}                       # no place: still the IUCN category, rarity 数据不足
    label = reg.get("name") if pr.get("source") in (None, "region") else None
    taken = (r.get("exif") or {}).get("taken_at") or ""
    month = int(taken[5:7]) if len(taken) >= 7 and taken[5:7].isdigit() else None
    return table.lookup(species["label"]["sci"], pr.get("lat"), pr.get("lon"), label, month, reg.get("code") if label else None)


def _err(e: Exception) -> str:
    if isinstance(e, decode.FileChanged):
        return str(e)
    return f"{type(e).__name__}: {e}"[:500]


def build(it: dict, d: dict, exif: dict, boxes: list, rects: list, looks: list, region: str | None,
          gate: bool = True, where: dict | None = None) -> PhotoResult:
    """One photo's result from its boxes and the tower's look at each. gate=False (boxes the person drew or "use the
    whole photo") keeps every box even when the clear-bird gate says no."""
    fh, fw = d["frame"].shape[:2]
    W, H = d["width"], d["height"]
    focus = geometry.focus_point(exif.get("focus_raw"), d["orientation"])

    def to(pt, rect):                                    # rect: (crop, width, height of the image it was cut from)
        return [round(min(1.0, max(0.0, v)), 5) for v in geometry.from_input(pt, rect[0], rect[1], rect[2])]
    dets = []
    for (score, b), rect, lk in zip(boxes, rects, looks):
        k = 0 if lk["p_eyes"][0] >= lk["p_eyes"][1] else 1
        clear = lk["clear"] is not False
        dets.append({"box": [round(v, 5) for v in b], "score": round(score, 4), "clear": lk["clear"],
                     "species": {"level": lk["level"], "label": lk["label"], "top5": lk["top5"], "geo": where is not None,
                                 "genus": lk.get("genus"), "max_cos": lk.get("max_cos"), "visual": lk.get("visual"),
                                 **{k: lk[k] for k in ("check", "override", "prior", "closer") if k in lk}},
                     # eyes, beak and flight only for a clear bird (the gate exists because they are noise otherwise)
                     "eye": to(lk["eyes"][k], rect) if clear else None, "eye_p": round(lk["p_eyes"][k], 4) if clear else None,
                     "beak": to(lk["beak"], rect) if clear else None, "beak_p": round(lk["p_beak"], 4) if clear else None,
                     "p_fly": round(lk["p_fly"], 4) if clear else None})
    usable = [i for i, x in enumerate(dets) if x["clear"] is not False or not gate]
    pick = geometry.choose_subject([(dets[i]["score"], dets[i]["box"]) for i in usable], focus, W, H)
    subject = usable[pick] if pick is not None else None
    s = dets[subject] if subject is not None else None
    # a rejected photo still says what the bird is (rejection is about keeping the photo, not about the bird):
    # the box the subject rule would pick among all of them
    gone = None
    if s is None and dets:
        k = geometry.choose_subject([(x["score"], x["box"]) for x in dets], focus, W, H)
        gone = dets[k]["species"] if k is not None else None
    sharp = None
    if s and d.get("gray") is not None and s["eye"] is not None:
        sharp = head_sharpness_of(d["gray"], s)
    look = None
    if s:                                   # a tiny grey thumbnail of the subject: "are these two frames alike" (stars.py)
        x0, y0, x1, y1 = s["box"]
        cut = Image.fromarray(d["frame"]).crop((int(x0 * fw), int(y0 * fh), max(int(x0 * fw) + 1, int(x1 * fw)), max(int(y0 * fh) + 1, int(y1 * fh))))
        look = list(cut.convert("L").resize((8, 8), Image.Resampling.BOX).tobytes())
    clip = clipping(d["frame"], s["box"]) if s else None
    ex = {k: exif.get(k) for k in ("camera", "camera_id", "lens", "focal_mm", "aperture", "shutter", "iso", "ev", "focus_mode", "taken_at", "gps")}
    reason = None if s else MSG["stars.no_clear_bird" if dets else "stars.no_bird"][0]     # stored: Chinese, shown via i18n.text
    return {
        "file": os.path.basename(it["path"]), "width": W, "height": H, "orientation": d["orientation"],
        "source": d["source"], "exif": ex,
        "region": {"name": region.get("label") if isinstance(region, dict) else region,
                   "code": (region.get("code") if isinstance(region, dict) else None) or rarity_mod.label_iso(geo.location_label(region)),
                   "source": "photo" if ex["gps"] else ("scan" if region else None), "gps": ex["gps"],
                   "prior": {k: where[k] for k in ("lat", "lon", "source", "week")} if where else None},
        "focus": [round(v, 5) for v in focus] if focus else None, "boxes": dets, "subject": subject,
        "species": s["species"] if s else gone,
        "eye": s["eye"] if s else None, "eye_p": s["eye_p"] if s else None,
        "eye_visible": (s["eye_p"] >= 0.5) if s and s["eye_p"] is not None else None,
        "beak": s["beak"] if s else None, "beak_p": s["beak_p"] if s else None,
        "flying": (s["p_fly"] >= 0.5) if s and s["p_fly"] is not None else None, "p_fly": s["p_fly"] if s else None,
        "clear": s["clear"] if s else (False if dets else None),
        "sharpness": sharp["score"] if sharp else None, "sharpness_region": sharp["region"] if sharp else None,
        "sharpness_window": sharp["window"] if sharp else None,
        "clip_hi": clip[0] if clip else None, "clip_lo": clip[1] if clip else None,
        "aesthetic": None, "rarity": None, "look": look,
        "rejected": s is None, "reject_reason": reason,
        "pending": (["aesthetic"] if s else []) + ([] if where else ["geo"]) + ["rarity"],
    }


CLIP_HI, CLIP_LO = 254, 3     # a pixel is blown when all three channels are >= CLIP_HI, crushed when all are <= CLIP_LO


def clipping(frame: np.ndarray, box: list[float]) -> tuple[float, float]:
    """(blown, crushed): share of the subject's core that is clipped white / black, on the 2048 frame the detector saw.
    Core = the box's middle 60 % each way, so the sky or water in its corners counts little. All three channels must
    clip: a well exposed white bird has up to 7 % of its core at 250-253 but under 2 % at 254-255 (docs/stars.md,
    曝光检测); a saturated colour clips one channel only. Measured on the camera's JPEG: a highlight the RAW still holds can read as blown here."""
    fh, fw = frame.shape[:2]
    x0, y0, x1, y1 = box
    mx, my = 0.2 * (x1 - x0), 0.2 * (y1 - y0)
    c = frame[int((y0 + my) * fh):max(int((y0 + my) * fh) + 1, int((y1 - my) * fh)),
              int((x0 + mx) * fw):max(int((x0 + mx) * fw) + 1, int((x1 - mx) * fw))]
    if not c.size:
        return 0.0, 0.0
    return round(float((c.min(2) >= CLIP_HI).mean()), 4), round(float((c.max(2) <= CLIP_LO).mean()), 4)


def head_sharpness_of(gray, det: dict) -> dict:
    """Head sharpness of one bird on the detail-resolution grey: the box plus 10 % is cut out first (the noise is
    estimated on that cut, the same for every photo), points mapped into it. window is returned normalised."""
    gh, gw = gray.shape[:2]
    x0, y0, x1, y1 = det["box"]
    mx, my = (x1 - x0) * 0.1, (y1 - y0) * 0.1
    cx0, cy0 = max(0, int((x0 - mx) * gw)), max(0, int((y0 - my) * gh))
    cx1, cy1 = min(gw, int((x1 + mx) * gw) + 1), min(gh, int((y1 + my) * gh) + 1)
    cut = gray[cy0:cy1, cx0:cx1]
    px = lambda p: (p[0] * gw - cx0, p[1] * gh - cy0)                       # noqa: E731
    r = head_sharpness(cut, (x0 * gw - cx0, y0 * gh - cy0, x1 * gw - cx0, y1 * gh - cy0), px(det["eye"]),
                       det["eye_p"] or 0.0, px(det["beak"]) if det["beak"] else None)
    a, b, c, e = r["window"]
    r["window"] = [round((a + cx0) / gw, 5), round((b + cy0) / gh, 5), round((c + cx0) / gw, 5), round((e + cy0) / gh, 5)]
    return r
