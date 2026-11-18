"""FastAPI: the local API, the SSE event stream and the built web UI, on 127.0.0.1 only."""
from __future__ import annotations

import asyncio
import contextlib
import multiprocessing as mp
import sqlite3
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import webbrowser
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from birdcm import config, decode, geo, models, stars
from birdcm.pipeline import fingerprint, image_paths
from birdcm.queue import Scheduler
from birdcm.store import Store

WEB = Path(os.environ.get("BIRDCM_WEB_DIR") or Path(__file__).resolve().parents[2] / "web" / "dist")
WRITE = {"POST", "PUT", "PATCH", "DELETE"}


MAX_UPLOAD = 300 << 20           # bytes, one uploaded photo
MAX_PIXELS = 120_000_000         # decoded pixels, one uploaded photo


def check_pixels(path: Path) -> None:
    """Refuse a JPEG / PNG larger than MAX_PIXELS (Pillow reads only the header). RAW files are not opened here (LibRaw
    runs in the worker processes only); MAX_UPLOAD bounds them."""
    if path.suffix.lower() in decode.RAW_EXT:
        return
    from PIL import Image
    try:
        with Image.open(path) as im:
            n = im.width * im.height
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"打不开这张照片：{e}") from None
    if n > MAX_PIXELS:
        raise ValueError(f"照片太大（{n / 1e6:.0f} MP），上限 {MAX_PIXELS / 1e6:.0f} MP")


def check_location(loc) -> None:
    """A location from a client: a label, or {lat, lon, label?, source?} with a real point."""
    if loc is None or isinstance(loc, str):
        return
    if not geo.valid(loc.get("lat"), loc.get("lon")) or loc.get("source", "map") not in ("map", "device", "region"):
        raise ValueError("位置要有合法的经纬度（纬度 −90–90，经度 −180–180），来源是 map / device / region")
    if not isinstance(loc.get("label", ""), str) or len(loc.get("label", "")) > 200:
        raise ValueError("位置名称要是文字")


def slim_result(res: dict | None, subject: int | None) -> dict | None:
    """What the history list needs of a result: the shown bird's name and the photo's time and GPS."""
    if not res:
        return None
    i = subject if subject is not None else res.get("subject")
    b = res["boxes"][i] if i is not None and i < len(res.get("boxes") or []) else None
    return {"species": b["species"] if b else None, "rejected": res["rejected"], "reject_reason": res["reject_reason"],
            "taken_at": res["exif"].get("taken_at"), "gps": res["exif"].get("gps")}


class Guard:
    """Pure ASGI: exact Host allow-list; an Origin, when sent, must be exactly this app; writes need the session
    token. Static files and the event stream pass through untouched once allowed."""

    def __init__(self, app, port: int, token: str) -> None:
        self.app, self.token = app, token
        self.hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        self.origins = {f"http://{h}" for h in self.hosts}

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket"):
            h = {k.decode("latin-1"): v.decode("latin-1") for k, v in scope["headers"]}
            why = None
            if h.get("host") not in self.hosts:
                why = "bad host"
            elif "origin" in h and h["origin"] not in self.origins:
                why = "bad origin"
            elif scope.get("method") in WRITE and not secrets.compare_digest(h.get("x-birdcm-token", ""), self.token):
                why = "missing or wrong session token"
            if why:
                await send({"type": "http.response.start", "status": 403, "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": why.encode()})
                return
        await self.app(scope, receive, send)


class Previews:
    """Thumbnail + preview of a photo the scan has not reached, made in its own small process pool (a RAW that crashes
    LibRaw takes a worker, not the server), with a timeout and one decode per photo however many requests ask."""

    TIMEOUT = 30.0

    def __init__(self) -> None:
        self.lock, self.pool, self.busy = threading.Lock(), None, {}

    def make(self, job: dict) -> None:
        from concurrent.futures.process import BrokenProcessPool
        with self.lock:
            fut = self.busy.get(job["path"])
            if fut is None:
                if self.pool is None:
                    self.pool = ProcessPoolExecutor(2, mp_context=mp.get_context("spawn"), initializer=decode.worker_init)
                fut = self.busy[job["path"]] = self.pool.submit(decode.decode, job)
                fut.add_done_callback(lambda _f, k=job["path"]: self.busy.pop(k, None))
        try:
            fut.result(timeout=self.TIMEOUT)
        except (TimeoutError, BrokenProcessPool):
            self._reset()
            raise

    def _reset(self) -> None:
        with self.lock:
            if self.pool:
                for proc in list(getattr(self.pool, "_processes", {}).values()):
                    proc.kill()
                self.pool.shutdown(wait=False, cancel_futures=True)
            self.pool, self.busy = None, {}

    def close(self) -> None:
        if self.pool:
            self.pool.shutdown(wait=False, cancel_futures=True)


def sse_cursor(last_event_id: str | None, after: int | None) -> int:
    """Reconnects carry Last-Event-ID (the browser's own); first connects carry ?after=. Header wins."""
    try:
        return int(last_event_id)
    except (TypeError, ValueError):
        return int(after or 0)


def sse(e: dict) -> str:
    return f"id: {e['n']}\nevent: {e['kind']}\ndata: {json.dumps(e['data'], ensure_ascii=False)}\n\n"


class Identify(BaseModel):
    box: list[float] | None = None          # normalised x0, y0, x1, y1 the person drew; [0, 0, 1, 1] = whole photo
    region: str | dict | None = None
    subject: int | None = None              # only switch the shown bird, no recompute


class NewScan(BaseModel):
    folder: str
    recursive: bool = False
    region: str | dict | None = None        # {lat, lon, label, source: map|device|region} or a label
    ratio: dict = {"preset": "std", "p3": 30, "p2": 30}


def create_app(port: int = 8765, token: str | None = None, store: Store | None = None,
               engine_factory=None, start_scheduler: bool = True) -> FastAPI:
    token = token or secrets.token_urlsafe(24)
    store = store or Store(config.data_dir() / "birdcm.db")
    exif = decode.ExifTool()
    if engine_factory is None:
        def engine_factory():
            from birdcm.pipeline import Engine
            return Engine(exif=exif)
    sched = Scheduler(store, engine_factory)
    previews = Previews()

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        if start_scheduler:
            sched.start()
        yield
        sched.close()
        previews.close()
        exif.close()

    api = FastAPI(title="BirdCM", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    api.state.store, api.state.scheduler, api.state.token = store, sched, token

    def get_scan(sid: int) -> dict:
        s = store.scan(sid)
        if not s:
            raise HTTPException(404, "没有这个扫描")
        return s

    @api.get("/api/session")
    def session():
        return {"token": token}

    @api.get("/api/models")
    def models_status():
        return {**models.status(), "exiftool": decode.ExifTool.available(), "engine_error": sched.engine_error}

    @api.get("/api/regions")
    def regions():
        return geo.catalogue()

    @api.post("/api/pick-folder")
    def pick_folder():
        if sys.platform != "darwin":
            raise HTTPException(501, "只在 macOS 上能弹出选择窗口，请直接输入路径")
        r = subprocess.run(["osascript", "-e", 'POSIX path of (choose folder with prompt "选择照片文件夹")'],
                           capture_output=True, text=True, timeout=600)
        return {"folder": r.stdout.strip().rstrip("/") or None}

    @api.post("/api/scans")
    def new_scan(body: NewScan):
        folder = Path(body.folder).expanduser()
        if not folder.is_absolute() or not folder.is_dir():
            raise HTTPException(400, f"不是文件夹：{body.folder}")
        folder = folder.resolve()
        try:
            config.check_own_dirs(folder)
            stars.validate(body.ratio)
            check_location(body.region)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        try:
            files = [(str(p), (st := p.stat()).st_size, st.st_mtime_ns) for p in decode.list_photos(folder, body.recursive)]
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        sid = store.create_scan(str(folder), body.recursive, body.region, body.ratio, fingerprint(body.region), files)
        sched.wake.set()
        return {"id": sid, "photos": len(files)}

    @api.get("/api/scans")
    def list_scans():
        return store.scans()

    @api.get("/api/scans/{sid}")
    def snapshot(sid: int):
        snap = store.snapshot(sid)
        if not snap:
            raise HTTPException(404, "没有这个扫描")
        return snap

    @api.get("/api/scans/{sid}/events")
    async def events(sid: int, request: Request, after: int | None = None):
        get_scan(sid)
        cursor = sse_cursor(request.headers.get("last-event-id"), after)

        async def stream():
            nonlocal cursor
            quiet = time.monotonic()
            yield "retry: 2000\n\n"
            while not await request.is_disconnected():
                evs = await run_in_threadpool(store.events_after, sid, cursor)
                for e in evs:
                    cursor = e["n"]
                    yield sse(e)
                if evs:
                    quiet = time.monotonic()
                    continue
                if time.monotonic() - quiet > 15:
                    quiet = time.monotonic()
                    yield ": ping\n\n"
                await asyncio.sleep(0.3)
        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-store"})

    @api.post("/api/scans/{sid}/stop")
    def stop(sid: int):
        get_scan(sid)
        return {"state": store.stop(sid)}

    @api.post("/api/scans/{sid}/resume")
    def resume(sid: int):
        get_scan(sid)
        state = store.resume(sid)
        sched.wake.set()
        return {"state": state}

    @api.put("/api/scans/{sid}/ratio")
    def ratio(sid: int, body: dict):
        get_scan(sid)
        try:
            stars.validate(body)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        store.set_ratio(sid, body)
        sched.rerate(sid)
        return {"ok": True}

    def photo_file(pid: int, which: int) -> FileResponse:
        p = store.photo(pid)
        if not p:
            raise HTTPException(404, "没有这张照片")
        thumb, preview = image_paths(p["path"], p["size"], p["mtime_ns"])
        path = (thumb, preview)[which]
        if not path.exists():                  # not processed yet: make it now, in a worker process (crash / timeout safe)
            try:
                previews.make({"path": p["path"], "size": p["size"], "mtime_ns": p["mtime_ns"],
                               "thumb": str(thumb), "preview": str(preview)})
            except Exception as e:  # noqa: BLE001
                raise HTTPException(404, f"无法生成预览：{e}") from None
        return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, no-cache"})

    @api.get("/api/photos/{pid}/thumb")
    def thumb(pid: int):
        return photo_file(pid, 0)

    @api.get("/api/photos/{pid}/preview")
    def preview(pid: int):
        return photo_file(pid, 1)

    @api.get("/api/photos/{pid}/exif")
    def photo_exif(pid: int):
        """Shooting info of a photo not processed yet (selected while queued)."""
        p = store.photo(pid)
        if not p:
            raise HTTPException(404, "没有这张照片")
        if p["result"]:
            return p["result"]["exif"]
        try:
            return exif.read([p["path"]]).get(p["path"], {})
        except Exception as e:  # noqa: BLE001
            raise HTTPException(503, str(e)) from None

    # ---- single photos ------------------------------------------------------------------------------------------

    singles_dir = config.data_dir() / "singles"

    def stored_path(rec: dict) -> Path:
        return singles_dir / rec["stored"]

    def run_single(sid: int, region: str | None, boxes: list | None) -> dict:
        rec = store.single(sid)
        path = str(stored_path(rec))
        try:
            res = sched.submit(lambda e: e.identify(path, region, boxes)).result(timeout=600)
            store.update_single(sid, result=res, subject=res["subject"], boxes=boxes, region=region, error=None)
        except Exception as e:  # noqa: BLE001 - kept with the entry; the person can retry
            store.update_single(sid, error=f"{type(e).__name__}: {e}"[:500], boxes=boxes, region=region)
        return store.single(sid)

    @api.post("/api/singles")
    async def upload(request: Request):
        try:
            declared = int(request.headers.get("content-length", ""))
        except ValueError:
            raise HTTPException(411, "需要 Content-Length") from None
        if declared > MAX_UPLOAD + (1 << 16):           # before the form is parsed (and spooled to a temp file)
            raise HTTPException(413, f"照片超过 {MAX_UPLOAD >> 20} MB")
        form = await request.form(max_files=1, max_fields=4)
        f = form.get("file")
        if f is None or not hasattr(f, "read"):
            raise HTTPException(400, "没有收到照片")
        ext = Path(f.filename or "").suffix.lower()
        if ext not in decode.SCAN_EXT | {".png"}:
            raise HTTPException(400, "只支持 ARW、DNG、JPG、PNG")
        singles_dir.mkdir(parents=True, exist_ok=True)
        stored = f"{secrets.token_hex(12)}{ext}"                       # our own name, never the uploaded one
        size = 0
        with open(singles_dir / stored, "wb") as out:
            while chunk := await f.read(1 << 20):
                size += len(chunk)
                if size > MAX_UPLOAD:
                    out.close()
                    (singles_dir / stored).unlink(missing_ok=True)
                    raise HTTPException(413, f"照片超过 {MAX_UPLOAD >> 20} MB")
                out.write(chunk)
        try:
            check_pixels(singles_dir / stored)
        except ValueError as e:
            (singles_dir / stored).unlink(missing_ok=True)
            raise HTTPException(400, str(e)) from None
        region = form.get("region") or None
        region = region if isinstance(region, str) else None
        if region and region.startswith("{"):          # a location object sent as JSON text in the form
            try:
                region = json.loads(region)
                check_location(region)
            except ValueError:
                (singles_dir / stored).unlink(missing_ok=True)
                raise HTTPException(400, "位置格式不对") from None
        sid = store.add_single(stored, Path(f.filename or "照片").name[:200], region)
        return await run_in_threadpool(run_single, sid, region, None)

    @api.post("/api/singles/{sid}/identify")
    def reidentify(sid: int, body: Identify):
        rec = store.single(sid)
        if not rec:
            raise HTTPException(404, "没有这条记录")
        if body.box is None and body.region is None and body.subject is not None:
            n = len((rec["result"] or {}).get("boxes") or [])
            if not 0 <= body.subject < n:
                raise HTTPException(400, "没有这只鸟")
            store.update_single(sid, subject=body.subject)
            return store.single(sid)
        try:
            check_location(body.region)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        box = body.box
        if box is not None and not (len(box) == 4 and 0 <= box[0] < box[2] <= 1 and 0 <= box[1] < box[3] <= 1):
            raise HTTPException(400, "框的坐标不对")
        return run_single(sid, body.region if body.region is not None else rec["region"], [box] if box else rec["boxes"])

    @api.get("/api/singles")
    def list_singles():
        return [{k: r[k] for k in ("id", "name", "created_at", "region", "subject", "error")} |
                {"result": slim_result(r["result"], r["subject"])} for r in store.singles()]

    @api.get("/api/singles/{sid}")
    def get_single(sid: int):
        rec = store.single(sid)
        if not rec:
            raise HTTPException(404, "没有这条记录")
        return rec

    @api.get("/api/singles/{sid}/image")
    def single_image(sid: int, size: str = "preview"):
        rec = store.single(sid)
        if not rec:
            raise HTTPException(404, "没有这条记录")
        path = stored_path(rec)
        st = path.stat()
        thumb, preview = image_paths(str(path), st.st_size, st.st_mtime_ns)
        out = thumb if size == "thumb" else preview
        if not out.exists():
            previews.make({"path": str(path), "size": st.st_size, "mtime_ns": st.st_mtime_ns, "thumb": str(thumb), "preview": str(preview)})
        return FileResponse(out, media_type="image/jpeg", headers={"Cache-Control": "private, no-cache"})

    def remove(names: list[str]) -> None:
        for n in names:
            p = singles_dir / n
            if p.is_file():
                st = p.stat()
                for c in image_paths(str(p), st.st_size, st.st_mtime_ns):
                    c.unlink(missing_ok=True)
                p.unlink()

    @api.delete("/api/singles/{sid}")
    def delete_single(sid: int):
        names = store.delete_singles(sid)
        if not names:
            raise HTTPException(404, "没有这条记录")
        remove(names)
        return {"deleted": len(names)}

    @api.delete("/api/singles")
    def clear_singles():
        names = store.delete_singles()
        remove(names)
        return {"deleted": len(names)}

    if WEB.is_dir():
        @api.get("/", include_in_schema=False)
        def index():                           # never cached: it names the hashed assets of the current build
            return FileResponse(WEB / "index.html", headers={"Cache-Control": "no-cache"})
        api.mount("/", StaticFiles(directory=WEB, html=True), name="web")
    return Guard(api, port, token), api


def preflight() -> None:
    """Before anything is created or written: an env change could have moved our dirs into a scanned photo folder.
    Reads the existing database read-only (nothing is created when there is none)."""
    db = config.data_dir() / "birdcm.db"
    if db.is_file():
        con = sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True)
        try:
            folders = [r[0] for r in con.execute("SELECT folder FROM scan")]
        finally:
            con.close()
        for f in folders:
            config.check_own_dirs(f)


def serve(port: int = 8765, open_browser: bool = True) -> int:
    import uvicorn
    preflight()
    for d in (config.data_dir(), config.cache_dir()):
        d.mkdir(parents=True, exist_ok=True)
    guarded, api = create_app(port)
    if not decode.ExifTool.available():
        print("警告：找不到 exiftool，拍摄信息和对焦点会是空的。`brew install exiftool` 安装。", file=sys.stderr)
    st = models.status()
    if not st["ready"]:
        print(f"缺模型文件：{', '.join(st['missing'])}。运行 `{st['fetch']}`。", file=sys.stderr)
    url = f"http://127.0.0.1:{port}/"
    if not WEB.is_dir():
        print(f"没有找到界面文件 {WEB}；先在 web/ 里运行 `npm install && npm run build`。", file=sys.stderr)
    if open_browser:
        threading.Timer(1.5, webbrowser.open, (url,)).start()
    print(f"观羽 BirdCM: {url}", flush=True)
    uvicorn.run(guarded, host="127.0.0.1", port=port, log_level="warning")
    return 0
