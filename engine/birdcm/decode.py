"""Decode (worker processes) and shooting info (one managed exiftool).

Decode strategy (docs/perf.md): a RAW's full-size embedded JPEG (Sony JpgFromRaw, 7008 x 4672 on the A7 IV) is
read and DCT-scaled to half size; only a RAW without a usable embedded JPEG is demosaiced (rawpy, half size).
This module must stay free of torch: decode workers import it (spawn) and should start fast and small.
"""
from __future__ import annotations

import io
import json
import os
import select
import shutil
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

RAW_EXT = {".arw", ".dng"}
SCAN_EXT = RAW_EXT | {".jpg", ".jpeg"}
FRAME = 2048            # detection / crop frame, long edge
THUMB = 512
EMBEDDED_MIN = 2048     # an embedded JPEG smaller than this (long edge) is not used; demosaic instead
# LibRaw sizes.flip -> EXIF orientation
FLIP_TO_ORIENTATION = {0: 1, 3: 3, 5: 8, 6: 6}
TRANSPOSE = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180, 4: Image.Transpose.FLIP_TOP_BOTTOM,
             5: Image.Transpose.TRANSPOSE, 6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE,
             8: Image.Transpose.ROTATE_90}       # EXIF orientation -> the transpose that makes the pixels upright


class FileChanged(Exception):
    pass


def worker_init() -> None:
    """Decode workers: one native thread each (the pool is the parallelism). A worker leaves when its server is gone:
    the pool's pipes are shared between siblings, so a worker of a killed server would otherwise wait forever."""
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
        os.environ[k] = "1"
    orphan_watch()


def orphan_watch(every: float = 2.0) -> None:
    """Exit this process once its parent has died (re-parented to launchd / init)."""
    parent = os.getppid()

    def watch():
        while True:
            time.sleep(every)
            if os.getppid() != parent:
                os._exit(0)
    threading.Thread(target=watch, daemon=True, name="orphan-watch").start()


def safe_arg(path: str) -> bool:
    """A path exiftool may receive: absolute, no CR / LF / NUL."""
    return path.startswith("/") and not any(c in path for c in "\r\n\0")


# Lightroom writes these next to a RAW as a 1:1 derivative of the same shot (denoise, super resolution, raw details).
# HDR / panorama merges are several shots and stay separate photos.
VARIANT_SUFFIXES = ("-enhanced-nr", "-enhanced-sr", "-enhanced-rd", "-enhanced")


def pair_variants(paths: list[Path], read_exif=None) -> tuple[list[Path], dict[str, list[str]]]:
    """Split derived DNGs off their original: -> (shots, {original path: [variant paths]}). A DNG named
    <stem><suffix>.dng beside a RAW named <stem>.* is a variant when, given read_exif(paths) -> {path: exif}, both have
    the same capture time (to the second) and camera; without read_exif the names alone decide."""
    raws = {(p.parent, p.stem.lower()): p for p in paths if p.suffix.lower() in RAW_EXT}
    pairs = {}
    for p in paths:
        stem = p.stem.lower()
        if p.suffix.lower() != ".dng":
            continue
        suf = next((x for x in VARIANT_SUFFIXES if stem.endswith(x)), None)
        main = suf and raws.get((p.parent, stem[: -len(suf)]))
        if main and main != p:
            pairs[p] = main
    if pairs and read_exif:
        ex = read_exif([str(x) for x in {*pairs, *pairs.values()}])
        def same(a, b):
            ea, eb = ex.get(str(a)) or {}, ex.get(str(b)) or {}
            ta, tb = (ea.get("taken_at") or "")[:19], (eb.get("taken_at") or "")[:19]
            return ta == tb and ea.get("camera") == eb.get("camera") and bool(ta)
        pairs = {v: m for v, m in pairs.items() if same(v, m)}
    variants: dict[str, list[str]] = {}
    for v, m in sorted(pairs.items()):
        variants.setdefault(str(m), []).append(str(v))
    return [p for p in paths if p not in pairs], variants


def list_photos(folder: str | Path, recursive: bool = False) -> list[Path]:
    """Supported photos in a folder (top level unless recursive), sorted by path; hidden files and dirs skipped.
    Raises ValueError when a photo's path has a line break (it could inject exiftool options)."""
    root = Path(folder).expanduser().resolve()
    if not root.is_dir():
        raise NotADirectoryError(f"不是文件夹：{root}")
    it = root.rglob("*") if recursive else root.iterdir()
    out = sorted(p for p in it if p.suffix.lower() in SCAN_EXT and p.is_file()
                 and not any(part.startswith(".") for part in p.relative_to(root).parts))
    bad = [str(p) for p in out if not safe_arg(str(p))]
    if bad:
        raise ValueError(f"这些照片的文件名里有换行，请先改名再扫描：{bad[:3]!r}")
    return out


def _fit(im: Image.Image, edge: int) -> Image.Image:
    k = edge / max(im.size)
    return im if k >= 1 else im.resize((round(im.width * k), round(im.height * k)), Image.Resampling.BILINEAR, reducing_gap=2.0)


def _jpeg(data: bytes, want: int) -> Image.Image:
    im = Image.open(io.BytesIO(data))
    im.draft("RGB", (want, want))       # DCT scaling: decode at 1/2, 1/4 ... while the long edge stays >= want
    return im.convert("RGB")


def load_upright(path: Path, mode: str = "embedded") -> tuple[Image.Image, int, int, int, str]:
    """(image, full upright width, full upright height, orientation, source). The image is the decoded frame at
    whatever size the source gives cheaply (>= FRAME long edge when available); width/height are the full
    upright size its coordinates refer to. mode: embedded (default; falls back to half), half, full."""
    if path.suffix.lower() not in RAW_EXT:
        with Image.open(path) as im:
            orientation = int(im.getexif().get(0x0112, 1) or 1)
            full = im.size
            im.draft("RGB", (FRAME, FRAME))
            upright = ImageOps.exif_transpose(im).convert("RGB")
        w, h = full if orientation not in (5, 6, 7, 8) else full[::-1]
        return upright, w, h, orientation, "jpeg"
    import rawpy

    with rawpy.imread(str(path)) as raw:
        orientation = FLIP_TO_ORIENTATION.get(raw.sizes.flip, 1)
        if mode == "embedded":
            try:
                thumb = raw.extract_thumb()
            except Exception:  # noqa: BLE001 - no thumbnail: demosaic
                thumb = None
            if thumb is not None and thumb.format == rawpy.ThumbFormat.JPEG:
                with Image.open(io.BytesIO(thumb.data)) as probe:
                    size = probe.size
                if max(size) >= EMBEDDED_MIN:
                    im = _jpeg(thumb.data, FRAME)
                    if orientation in TRANSPOSE:
                        im = im.transpose(TRANSPOSE[orientation])
                    w, h = size if orientation not in (5, 6, 7, 8) else size[::-1]
                    return im, w, h, orientation, "embedded"
            mode = "half"
        w, h = raw.sizes.width, raw.sizes.height
        px = raw.postprocess(use_camera_wb=True, half_size=mode == "half", output_bps=8)
    if orientation in (5, 6, 7, 8):
        w, h = h, w
    return Image.fromarray(px), w, h, orientation, mode       # LibRaw already rotated the pixels


def decode(job: dict) -> dict:
    """Worker entry. job: path, size, mtime_ns (the signature listed at scan time), thumb, preview (cache paths
    to write), mode. Returns the 2048 frame as an array plus sizes and timings; never the full-size pixels."""
    path = Path(job["path"])
    t0 = time.perf_counter()
    try:
        st = path.stat()
    except FileNotFoundError:
        raise FileChanged("文件已不存在") from None
    if (st.st_size, st.st_mtime_ns) != (job["size"], job["mtime_ns"]):
        raise FileChanged("文件在列出之后被修改过")
    im, w, h, orientation, source = load_upright(path, job.get("mode", "embedded"))
    t1 = time.perf_counter()
    frame = _fit(im, FRAME)
    for key, img in (("thumb", _fit(frame, THUMB)), ("preview", frame)):
        if job.get(key):
            out = Path(job[key])
            out.parent.mkdir(parents=True, exist_ok=True)
            tmp = out.with_name(f"{out.name}.{os.getpid()}.{threading.get_ident()}.tmp")   # concurrent writers
            img.save(tmp, "JPEG", quality=82 if key == "thumb" else 85)
            tmp.replace(out)
    gray = np.asarray(im.convert("L")) if job.get("gray") else None      # detail-resolution grey for head sharpness
    t2 = time.perf_counter()
    return {"frame": np.array(frame), "gray": gray, "width": w, "height": h, "orientation": orientation, "source": source,
            "t_decode": t1 - t0, "t_save": t2 - t1, "pid": os.getpid()}


def upright_jpeg(data: bytes, orientation: int) -> bytes:
    """A JPEG turned upright: the same bytes when it already is (orientation 1), else decoded, turned and re-encoded."""
    if orientation not in TRANSPOSE:
        return data
    out = io.BytesIO()
    Image.open(io.BytesIO(data)).convert("RGB").transpose(TRANSPOSE[orientation]).save(out, "JPEG", quality=92)
    return out.getvalue()


def full_jpeg(job: dict) -> bytes:
    """Worker entry for the 100 % view: the photo at full size, upright, as JPEG bytes, from the same source
    load_upright uses (so the normalised marks land on the same pixels). A RAW gives its embedded full-size JPEG
    (~30 ms, the bytes as they are when upright); a RAW without one is demosaiced at full size. Nothing is cached."""
    path = Path(job["path"])
    try:
        st = path.stat()
    except FileNotFoundError:
        raise FileChanged("文件已不存在") from None
    if (st.st_size, st.st_mtime_ns) != (job["size"], job["mtime_ns"]):
        raise FileChanged("文件在列出之后被修改过")
    if path.suffix.lower() not in RAW_EXT:
        with Image.open(path) as im:
            orientation = int(im.getexif().get(0x0112, 1) or 1)
        return upright_jpeg(path.read_bytes(), orientation)
    import rawpy

    with rawpy.imread(str(path)) as raw:
        orientation = FLIP_TO_ORIENTATION.get(raw.sizes.flip, 1)
        try:
            thumb = raw.extract_thumb()
        except Exception:  # noqa: BLE001 - no thumbnail: demosaic
            thumb = None
        if thumb is not None and thumb.format == rawpy.ThumbFormat.JPEG:
            with Image.open(io.BytesIO(thumb.data)) as probe:
                big = max(probe.size) >= EMBEDDED_MIN
            if big:
                return upright_jpeg(thumb.data, orientation)
        px = raw.postprocess(use_camera_wb=True, output_bps=8)     # LibRaw rotates the pixels itself
    out = io.BytesIO()
    Image.fromarray(px).save(out, "JPEG", quality=92)
    return out.getvalue()


# ---- shooting info ---------------------------------------------------------------------------------------------

TAGS = ["-Make", "-Model", "-LensModel", "-LensID", "-FocalLength#", "-FNumber#", "-ExposureTime#", "-ISO#",
        "-ExposureCompensation#", "-FocusMode", "-AFAreaMode", "-DateTimeOriginal", "-SubSecTimeOriginal",
        "-OffsetTimeOriginal", "-GPSLatitude#", "-GPSLongitude#", "-FocusLocation#", "-Orientation#",
        "-SerialNumber", "-InternalSerialNumber"]


class ExifTool:
    """One `exiftool -stay_open` process: serial requests under a lock, numbered responses, a timeout, restart
    after a failure. stderr is discarded (a warning must not fill a pipe nobody reads)."""

    def __init__(self, timeout: float = 30.0) -> None:
        self.timeout, self.proc, self.n, self.lock = timeout, None, 0, threading.Lock()

    @staticmethod
    def available() -> bool:
        return shutil.which("exiftool") is not None

    def _start(self) -> None:
        if not self.available():
            raise RuntimeError("找不到 exiftool。macOS 上运行 `brew install exiftool` 安装后再试。")
        self.proc = subprocess.Popen(["exiftool", "-stay_open", "True", "-@", "-"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        # exiftool -stay_open does not exit when its stdin closes: a tiny watcher ends it if this process dies without
        # closing it (crash, SIGKILL). It exits by itself once either is gone.
        subprocess.Popen(["/bin/sh", "-c", f"while kill -0 {os.getpid()} 2>/dev/null && kill -0 {self.proc.pid} 2>/dev/null; "
                          f"do sleep 2; done; kill {self.proc.pid} 2>/dev/null"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def close(self) -> None:
        with self.lock:
            self._stop()

    def _stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.write(b"-stay_open\nFalse\n")
                self.proc.stdin.flush()
                self.proc.wait(2)
            except Exception:  # noqa: BLE001
                self.proc.kill()
        self.proc = None

    def _ask(self, args: list[str]) -> bytes:
        if self.proc is None or self.proc.poll() is not None:
            self._start()
        self.n += 1
        mark = f"{{ready{self.n}}}".encode()
        self.proc.stdin.write(("\n".join(args) + f"\n-execute{self.n}\n").encode())
        self.proc.stdin.flush()
        fd, out, end = self.proc.stdout.fileno(), b"", time.monotonic() + self.timeout
        while mark not in out:
            left = end - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                self._stop()
                raise TimeoutError("exiftool 超时")
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                self._stop()
                raise RuntimeError("exiftool 退出了")
            out += chunk
        return out[:out.index(mark)]

    def run(self, args: list[str]) -> bytes:
        """One exiftool command (one argument per item); its stdout."""
        with self.lock:
            return self._ask(args)

    def read(self, paths: list[str]) -> dict[str, dict]:
        """path -> parsed shooting info ({} for a file exiftool could not read)."""
        if not paths:
            return {}
        for p in paths:                     # one argument per line on the -@ protocol: a newline would inject options
            if not safe_arg(p):
                raise ValueError(f"文件名含换行或不是绝对路径，拒绝交给 exiftool：{p!r}")
        with self.lock:
            raw = self._ask(["-j", "-charset", "filename=utf8", *TAGS, *paths])
        rows = json.loads(raw or b"[]")
        return {r["SourceFile"]: parse_exif(r) for r in rows}


def _num(v) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def shutter_text(t: float | None) -> str | None:
    if not t:
        return None
    return f"1/{round(1 / t)}" if t < 0.5 else f"{t:g}"


def parse_exif(r: dict) -> dict:
    make, model = str(r.get("Make") or "").strip(), str(r.get("Model") or "").strip()
    camera = model if model.lower().startswith(make.lower()) else " ".join(x for x in (make, model) if x)
    lens = r.get("LensModel") or (r.get("LensID") if isinstance(r.get("LensID"), str) else None)
    focus = " · ".join(str(x) for x in (r.get("FocusMode"), r.get("AFAreaMode")) if x not in (None, ""))
    taken = None
    if (dto := str(r.get("DateTimeOriginal") or "")) and dto[:4].isdigit() and not dto.startswith("0000"):
        taken = f"{dto[0:4]}-{dto[5:7]}-{dto[8:10]}T{dto[11:19]}"
        if (sub := str(r.get("SubSecTimeOriginal") or "").strip()).isdigit():
            taken += "." + sub
        if off := str(r.get("OffsetTimeOriginal") or "").strip():
            taken += off
    lat, lon = _num(r.get("GPSLatitude")), _num(r.get("GPSLongitude"))
    gps = [lat, lon] if lat is not None and lon is not None and (lat, lon) != (0, 0) else None
    return {"camera": camera or None, "lens": lens, "focal_mm": _num(r.get("FocalLength")),
            "aperture": _num(r.get("FNumber")), "shutter": shutter_text(_num(r.get("ExposureTime"))),
            "iso": _num(r.get("ISO")), "ev": _num(r.get("ExposureCompensation")), "focus_mode": focus or None,
            "taken_at": taken, "gps": gps, "focus_raw": r.get("FocusLocation"),
            # the body, not the model: two bodies of one model must not share bursts
            "camera_id": " ".join(str(x) for x in (model or None, r.get("SerialNumber") or r.get("InternalSerialNumber")) if x) or None,
            "orientation": int(_num(r.get("Orientation")) or 1)}
