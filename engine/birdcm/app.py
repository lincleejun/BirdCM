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

from birdcm import config, decode, models
from birdcm.pipeline import fingerprint, image_paths
from birdcm.queue import Scheduler
from birdcm.store import Store

WEB = Path(os.environ.get("BIRDCM_WEB_DIR") or Path(__file__).resolve().parents[2] / "web" / "dist")
WRITE = {"POST", "PUT", "PATCH", "DELETE"}
# ponytail: names only, enough for the setup form; representative coordinates arrive with geo.py.
REGIONS = {
    "美国": ["加利福尼亚州", "俄勒冈州", "华盛顿州", "内华达州", "亚利桑那州", "得克萨斯州", "佛罗里达州", "纽约州", "其他"],
    "加拿大": ["不列颠哥伦比亚省", "艾伯塔省", "安大略省", "魁北克省", "其他"],
    "中国": ["北京市", "上海市", "云南省", "四川省", "广东省", "青海省", "其他"],
}


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


class NewScan(BaseModel):
    folder: str
    recursive: bool = False
    region: str | None = None
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
        return REGIONS

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
        return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})

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

    if WEB.is_dir():
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
