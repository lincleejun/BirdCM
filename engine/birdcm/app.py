"""FastAPI: the local API, the SSE event stream and the built web UI, on 127.0.0.1 only."""
from __future__ import annotations

import asyncio
import contextlib
import multiprocessing as mp
import sqlite3
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import webbrowser
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from birdcm import archive, config, decode, geo, library, models, places, stars
from birdcm.pipeline import EQUIVALENT_DATA, EQUIVALENT_OLD_KEY, fingerprint, image_paths
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
    code = loc.get("code")
    if code is not None and not (isinstance(code, str) and re.fullmatch(r"[A-Z]{2}(-[A-Z0-9]{1,3})?", code)):
        raise ValueError("地区代码要是 ISO 3166 代码（如 US、US-CA）")


def slim_result(res: dict | None, subject: int | None) -> dict | None:
    """What the history list needs of a result: the shown bird's name and the photo's time, GPS and place name."""
    if not res:
        return None
    i = subject if subject is not None else res.get("subject")
    b = res["boxes"][i] if i is not None and i < len(res.get("boxes") or []) else None
    return {"species": b["species"] if b else res.get("species"), "rejected": res["rejected"], "reject_reason": res["reject_reason"],
            "taken_at": res["exif"].get("taken_at"), "gps": (g := res["exif"].get("gps")),
            "place": places.name(*g)["label"] if g and len(g) == 2 and geo.valid(*g) else None}


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


class EbirdBody(BaseModel):
    species: list[str]
    counts: dict[str, str] = {}
    comments: dict[str, str] = {}
    protocol: str = "Incidental"
    with_files: bool = False
    ids: list[int] | None = None              # only these photos (the current filter)


class Correction(BaseModel):
    photo_id: int
    scope: str = "one"                        # one | burst | same (every photo of the scan named like this one)
    sci: str | None = None                    # the right species; None = 不确定
    undo: bool = False                        # remove the corrections of this scope instead


class StarFix(BaseModel):
    photo_ids: list[int]                      # one photo, or many in one request (multi-select)
    stars: int | None = None                  # -1 淘汰, 0-3; None = back to the computed stars


class SingleCorrection(BaseModel):
    sci: str | None = None
    undo: bool = False



class CountBody(BaseModel):
    group_key: str
    count: int | None = None
    expected_generation: int


class SubjectEditBody(BaseModel):
    source_ref: dict
    edit: dict
    expected_generation: int


class ApplyBody(BaseModel):
    token: str
    mode: str = "merge"
    choices: dict[str, str] = {}
    expected_generation: int
    confirm_restore: bool = False


class LifeEbird(BaseModel):
    species: list[str] | None = None
    counts: dict[str, str] = {}
    use_estimates: bool = False
    fallback: str = "refuse"
    start: str | None = None                          # from / to (inclusive) local days
    end: str | None = None


class NewScan(BaseModel):
    folder: str
    recursive: bool = False
    region: str | dict | None = None        # {lat, lon, label, source: map|device|region} or a label
    ratio: dict = {"preset": "std", "p3": 30, "p2": 30}


# OpenStreetMap Nominatim, per its usage policy: an identifying User-Agent (no personal details), at most one request a
# second (shared with the place names, places.py), no autocomplete (the page only asks on Enter), answers cached.
# ponytail: in-memory cache, gone on restart.
NOMINATIM = "https://nominatim.openstreetmap.org/search"
_places_cache: dict[str, list] = {}


def places_search(q: str, fetch=None) -> list[dict]:
    import urllib.parse, urllib.request
    key = q.lower()
    with places.LOCK:                                        # serialises requests, so the 1/s spacing holds across threads
        if key in _places_cache:
            return _places_cache[key]
        wait = places.GAP - (time.monotonic() - places.LAST[0])
        if wait > 0:
            time.sleep(wait)
        places.LAST[0] = time.monotonic()
        url = NOMINATIM + "?" + urllib.parse.urlencode({"format": "jsonv2", "limit": 6, "accept-language": "zh,en", "q": q})
        req = urllib.request.Request(url, headers={"User-Agent": places.UA})
        if fetch is None:
            with urllib.request.urlopen(req, timeout=8) as r:
                rows = json.load(r)
        else:
            rows = fetch(req)
        out = [{"label": x["display_name"], "lat": float(x["lat"]), "lon": float(x["lon"])} for x in rows]
        _places_cache[key] = out
        if len(_places_cache) > 50:
            _places_cache.pop(next(iter(_places_cache)))
        return out


def verify_variants(store: Store, sid: int, variants: dict[str, list[str]]) -> None:
    """After the scan is created (Codex P4: this used to hold the request for 3-12 s): check each name-paired variant's
    capture time and camera with exiftool; one that does not match its original is another shot and becomes a photo
    of its own. Without exiftool the names alone stand."""
    if not variants or not decode.ExifTool.available():
        return
    et = decode.ExifTool()
    try:
        flat = [Path(v) for vs in variants.values() for v in vs] + [Path(m) for m in variants]
        _, ok = decode.pair_variants(flat, et.read)
    except Exception:  # noqa: BLE001 - unreadable: keep the name pairing
        return
    finally:
        et.close()
    wrong = [(m, v) for m, vs in variants.items() for v in vs if v not in ok.get(m, [])]
    if wrong:
        store.unpair(sid, wrong)


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
    names = places.use(store)

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        if start_scheduler:
            names.start()                                   # place names: one paced background lookup thread
            sched.start()                                   # loads the models in the background: the page is up at once
            api.state.library.refresh()                     # a restart with a dirty index rebuilds it (background)
            for (sid,) in store._db().execute("SELECT id FROM single WHERE result IS NULL AND error IS NULL"):
                r = store.single(sid)                       # queued when the last run ended: queued again
                run_single(sid, r["region"], r["boxes"], wait=False)
        yield
        names.stop()
        sched.close()
        previews.close()
        exif.close()

    api = FastAPI(title="BirdCM", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    from starlette.middleware.gzip import GZipMiddleware
    api.add_middleware(GZipMiddleware, minimum_size=4096)    # the list snapshot is JSON: ~1/10 on the wire (event streams excluded)
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
        """ready = the files are here; engine = loading | ready | error (loaded in the background at start-up)."""
        st = models.status()
        if st["ready"] and sched.state == "error" and (sched.load_error or "").startswith("FileNotFoundError"):
            sched.retry()                              # the missing files were downloaded meanwhile: load, no click needed
        return {**st, "exiftool": decode.ExifTool.available(), "engine_error": sched.engine_error,
                "engine": sched.state, "load_error": sched.load_error}

    @api.post("/api/models/retry")
    def models_retry():
        sched.retry()
        return {"engine": sched.state}

    @api.get("/api/regions")
    def regions():
        return geo.catalogue()

    @api.get("/api/places")
    def place_search(q: str):
        q = q.strip()[:200]
        if not q:
            return []
        try:
            return places_search(q)
        except Exception as e:  # offline, timeout, HTTP error: the map's local matches still work
            raise HTTPException(502, f"在线地名搜索用不了：{e}")

    @api.get("/api/places/name")
    def place_name(lat: float | None = None, lon: float | None = None, code: str | None = None, label: str | None = None):
        """{label, online, pending}: a point's place name now (cached online name, else the offline region; pending = an
        online lookup is queued, ask again in a moment), or a chosen region's English name (code, or our region label)."""
        if lat is None and lon is None:
            from birdcm import rarity
            return {"label": places.region_text(code or rarity.label_iso(label)) or label, "online": False, "pending": False}
        if not geo.valid(lat, lon):
            raise HTTPException(422, "经纬度不对")
        return names.name(lat, lon)

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
            shots, variants = decode.pair_variants(decode.list_photos(folder, body.recursive))    # names only: instant
            files = [(str(p), (st := p.stat()).st_size, st.st_mtime_ns) for p in shots]
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        sid = store.create_scan(str(folder), body.recursive, body.region, body.ratio, fingerprint(body.region), files, variants)
        threading.Thread(target=verify_variants, args=(store, sid, variants), daemon=True).start()
        sched.wake.set()
        return {"id": sid, "photos": len(files)}

    @api.get("/api/scans")
    def list_scans(all: bool = False):
        return store.scans(every=all)

    @api.get("/api/scans/{sid}")
    def snapshot(sid: int):
        snap = store.snapshot(sid, slim_results=True)
        if not snap:
            raise HTTPException(404, "没有这个扫描")
        # plain JSON already: json.dumps directly (FastAPI's encoder walk was 2/3 of a 5,000-photo snapshot)
        return Response(json.dumps({**snap, **store.related(sid), "stale": is_stale(snap["scan"])}, ensure_ascii=False,
                                   separators=(",", ":")),
                        media_type="application/json")

    @api.get("/api/scans/{sid}/related")
    def related(sid: int):
        """Light poll for an open results page: is there a newer scan of this folder, how far is it."""
        s = get_scan(sid)
        return {**store.related(sid), "stale": is_stale(s)}

    def is_stale(scan: dict) -> bool:
        """Results computed under another fingerprint than the one this engine would use now (models, rules, data)."""
        try:
            want = sched.engine.fingerprint(scan["region"]) if sched.engine else fingerprint(scan["region"])
        except Exception:  # noqa: BLE001 - no models: nothing to compare with
            return False
        if scan.get("fp") and scan["fp"] != want:
            with contextlib.suppress(Exception):
                digest = getattr(sched.engine, "model_digest", None)
                if scan["fp"] in [fingerprint(scan["region"], digest, data=d, old_key=k)
                                  for d in (None, *EQUIVALENT_DATA) for k in (False, EQUIVALENT_OLD_KEY)]:
                    store.move_fp(scan["id"], scan["fp"], want)      # same results, only a display-only input changed
                    scan["fp"] = want
        return scan.get("fp") not in (None, want) and scan.get("state") == "completed"

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
        """Changes the given star settings and keeps the others (a ratio change must not drop custom weights,
        Codex I3); {"replace": true, ...} replaces the whole set."""
        scan = get_scan(sid)
        body = dict(body)
        if not body.pop("replace", False):
            body = {**(scan.get("ratio") or {}), **body}
            if "keep" in body and "p3" in body and body.get("strategy") != "quota":   # an old {p3, p2} set: the new ratio wins
                body.pop("p3", None)
                body.pop("p2", None)
        try:
            stars.validate(body)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        try:
            sched.set_ratio(sid, body)                     # computed first, stored with its stars only on success
        except Exception as e:  # noqa: BLE001
            raise HTTPException(400, f"这个设置算不出星级：{type(e).__name__}: {e}") from None
        return {"ok": True}

    def photo_file(pid: int, which: int, request: Request | None = None):
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
        # the ETag names this database, this photo row and this cached image: another database or a re-made preview
        # never matches (Codex P5); a matching If-None-Match gets 304 instead of the image again
        st = path.stat()
        import hashlib
        tag = '"' + hashlib.sha1(f"{store.path}|{pid}|{path}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()[:20] + '"'
        headers = {"Cache-Control": "private, no-cache", "ETag": tag}
        if request is not None and tag in [t.strip() for t in request.headers.get("if-none-match", "").split(",")]:
            from fastapi.responses import Response
            return Response(status_code=304, headers=headers)
        return FileResponse(path, media_type="image/jpeg", headers=headers)

    @api.get("/api/photos/{pid}/thumb")
    def thumb(pid: int, request: Request):
        return photo_file(pid, 0, request)

    @api.get("/api/photos/{pid}/preview")
    def preview(pid: int, request: Request):
        return photo_file(pid, 1, request)

    @api.get("/api/species")
    def species_search(q: str = ""):
        """Species by Chinese, English or Latin name (for correcting a photo's species)."""
        from birdcm import names
        return names.search(q[:100])

    @api.post("/api/scans/{sid}/corrections")
    def correct(sid: int, body: Correction):
        """The person says what the bird is: for this photo, its burst, or every photo of the scan named like it.
        Stored per file signature (survives re-scans); stars re-rated at once."""
        from birdcm import names
        get_scan(sid)
        if body.scope not in ("one", "burst", "same"):
            raise HTTPException(400, "范围只能是 one / burst / same")
        if not body.undo and body.sci is not None and body.sci not in names.catalogue():
            raise HTTPException(400, f"名录里没有这个学名：{body.sci}")
        photos = store.snapshot(sid, slim_results=True)["photos"]        # ids, bursts and the shown species only
        me = next((p for p in photos if p["id"] == body.photo_id), None)
        if not me:
            raise HTTPException(404, "这次扫描里没有这张照片")

        def named(p):
            sp = p.get("species_fix") or (p.get("result") or {}).get("species") or {}
            return (sp.get("label") or {}).get("sci") if sp.get("level") in ("species", "genus") else None
        if body.scope == "one":
            ids = [me["id"]]
        elif body.scope == "burst":
            ids = [p["id"] for p in photos if me["burst_group"] is not None and p["burst_group"] == me["burst_group"]] or [me["id"]]
        else:
            target = named(me)
            ids = [p["id"] for p in photos if target is not None and named(p) == target] or [me["id"]]
        if body.undo:
            store.clear_corrections(ids)
        else:
            store.set_corrections(ids, body.sci, body.scope)
        sched.rerate_now(sid)
        return {"ok": True, "photos": len(ids)}

    @api.post("/api/scans/{sid}/stars")
    def set_stars(sid: int, body: StarFix):
        """The person's stars for these photos (None: back to the computed ones). Stored per file signature like the
        corrections (survive re-scans and settings changes); laid over the rating, so no other photo changes."""
        get_scan(sid)
        if body.stars is not None and body.stars not in (-1, 0, 1, 2, 3):
            raise HTTPException(400, "星级只能是 -1（淘汰）、0、1、2、3")
        ids = set(body.photo_ids)
        if not ids:
            raise HTTPException(400, "没有选照片")
        have = {r[0] for r in store._db().execute(
            f"SELECT id FROM photo WHERE scan_id = ? AND id IN ({','.join('?' * len(ids))})", (sid, *ids))}
        if have != ids:
            raise HTTPException(404, "这次扫描里没有这张照片")
        store.set_star_fixes(sorted(ids), body.stars)
        sched.rerate_now(sid)
        return {"ok": True, "photos": len(ids)}

    @api.post("/api/singles/{sid}/correct")
    def correct_single(sid: int, body: SingleCorrection):
        from birdcm import names
        rec = store.single(sid)
        if not rec:
            raise HTTPException(404, "没有这条记录")
        if not body.undo and body.sci is not None and body.sci not in names.catalogue():
            raise HTTPException(400, f"名录里没有这个学名：{body.sci}")
        store.update_single(sid, correction=None if body.undo else {"sci": body.sci, **(names.catalogue().get(body.sci or "", {}))})
        rec = store.single(sid)
        return {**rec, "stale": single_stale(rec)}

    @api.get("/api/scans/{sid}/ebird/plan")
    def ebird_plan(sid: int):
        """The species and checklists an eBird export of this scan would hold (the dialog's choices)."""
        from birdcm import ebird
        scan = get_scan(sid)
        pl = ebird.plan(store.snapshot(sid)["photos"], scan["region"])
        pl["checklists"] = [{k: v for k, v in c.items() if k != "photos"} | {"photos": len(c["photos"])} for c in pl["checklists"]]
        return pl

    @api.post("/api/scans/{sid}/ebird")
    def ebird_csv(sid: int, body: EbirdBody):
        """The eBird Record Format file (text/csv, UTF-8, no header row, no BOM)."""
        from fastapi.responses import Response
        from birdcm import ebird
        scan = get_scan(sid)
        photos = store.snapshot(sid)["photos"]
        if body.ids is not None:
            keep = set(body.ids)
            photos = [p for p in photos if p["id"] in keep]
        for v in body.counts.values():
            if not (v.upper() == "X" or (v.isdigit() and 0 < int(v) < 999999)):
                raise HTTPException(400, "数量只能是正整数或 X")
        try:
            text = ebird.record_csv(photos, scan["region"], body.species, body.counts, body.comments, body.protocol, body.with_files)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        return Response(text, media_type="text/csv; charset=utf-8")

    @api.get("/api/photos/{pid}")
    def photo_full(pid: int):
        """One photo's full row (every box's own species, the likeness thumbnail): what the list snapshot leaves out."""
        p = store.photo(pid)
        if not p:
            raise HTTPException(404, "没有这张照片")
        return p

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

    def run_single(sid: int, region: str | None, boxes: list | None, wait: bool = True) -> dict:
        """Queued on the model thread; the answer is stored with the entry. wait=False returns at once (an entry with
        neither result nor error is queued: the page polls it), e.g. while the models are still loading."""
        path = str(stored_path(store.single(sid)))

        def job(e):
            res, fp = e.identify(path, region, boxes), e.fingerprint(region)
            store.update_single(sid, result=res, subject=res["subject"], boxes=boxes, region=region, error=None, fp=fp)

        def failed(f):
            # the stored result, region and boxes stay one consistent set (the last success); only the error is new (Codex I6)
            if (e := f.exception()) is not None:
                store.update_single(sid, error=f"{type(e).__name__}: {e}"[:500])
        try:
            f = sched.submit(job)
            f.add_done_callback(failed)
            if wait:
                f.result(timeout=600)
        except Exception:  # noqa: BLE001 - kept with the entry (failed()); the person can retry
            pass
        rec = store.single(sid)
        return {**rec, "stale": single_stale(rec)}

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
        return await run_in_threadpool(run_single, sid, region, None, sched.state == "ready")

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
            rec = store.single(sid)
            return {**rec, "stale": single_stale(rec)}
        try:
            check_location(body.region)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        box = body.box
        if box is not None and not (len(box) == 4 and 0 <= box[0] < box[2] <= 1 and 0 <= box[1] < box[3] <= 1):
            raise HTTPException(400, "框的坐标不对")
        return run_single(sid, body.region if body.region is not None else rec["region"], [box] if box else rec["boxes"])

    def single_stale(rec: dict) -> bool:
        """A history entry made under another fingerprint (models, rules, data) than this engine's now."""
        if not rec.get("result"):
            return False
        try:
            want = sched.engine.fingerprint(rec["region"]) if sched.engine else fingerprint(rec["region"])
        except Exception:  # noqa: BLE001 - no models: nothing to compare with
            return False
        return rec.get("fp") != want

    @api.get("/api/singles")
    def list_singles():
        return [{k: r[k] for k in ("id", "name", "created_at", "region", "subject", "error")} |
                {"result": slim_result(r["result"], r["subject"]), "stale": single_stale(r)} for r in store.singles()]

    @api.get("/api/singles/{sid}")
    def get_single(sid: int):
        rec = store.single(sid)
        if not rec:
            raise HTTPException(404, "没有这条记录")
        return {**rec, "stale": single_stale(rec)}

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

    # ---- the life list (library.py, archive.py; docs/design-lifelist.md §7.1) ----------------------------------------

    lib = library.of(store, singles_dir=singles_dir, imports_dir=config.data_dir() / "imports")
    api.state.library = lib

    def day_arg(v: str | None, name: str) -> str | None:
        if v in (None, ""):
            return None
        p = library.parse_wall(v)
        if not p or p[3] != "day":
            raise HTTPException(422, f"{name} 要是 YYYY-MM-DD")
        return p[2]

    def view(frm: str | None, to: str | None):
        """The status and the index of one generation (a dirty index is rebuilt in the background meanwhile)."""
        if not store.library_ok:
            raise HTTPException(503, "数据库是更新版本的观羽写的：这个版本不改动它的记录本")
        st = lib.refresh()
        return st, lib.index(), day_arg(frm, "from"), day_arg(to, "to")

    def page(offset: int, limit: int) -> tuple[int, int]:
        if offset < 0 or not 1 <= limit <= 100:
            raise HTTPException(422, "offset ≥ 0，limit 1–100")
        return offset, limit

    @api.get("/api/library/summary")
    def library_summary(request: Request):
        q = request.query_params
        st, ix, frm, to = view(q.get("from"), q.get("to"))
        return {**st, "generation": ix.generation, "range": {"from": frm, "to": to}, **ix.summary(frm, to)}

    @api.get("/api/library/species")
    def library_species(request: Request, q: str = "", seen: str = "yes", rarity: str = "all", iucn: str = "all", family: str = "",
                        sort: str = "recent", offset: int = 0, limit: int = 50):
        if seen not in ("all", "yes", "no") or rarity not in ("all", "0", "1", "2", "3", "4") or iucn not in ("all", "threatened") \
                or sort not in ("recent", "first", "name"):
            raise HTTPException(422, "seen / rarity / iucn / sort 的取值不对")
        st, ix, frm, to = view(request.query_params.get("from"), request.query_params.get("to"))
        offset, limit = page(offset, limit)
        return {**st, "generation": ix.generation, **library.species_list(ix, frm, to, q[:100], seen, rarity, iucn, family[:100], sort, offset, limit)}

    @api.get("/api/library/species/detail")
    def library_species_detail(request: Request, sci: str):
        st, ix, frm, to = view(request.query_params.get("from"), request.query_params.get("to"))
        return {**st, "generation": ix.generation, **library.species_detail(ix, sci[:200], frm, to)}

    @api.get("/api/library/photos")
    def library_photos(request: Request, sci: str | None = None, day: str | None = None, status: str = "all", offset: int = 0, limit: int = 50):
        if status not in ("all", "pending", "no-bird"):
            raise HTTPException(422, "status 只能是 all / pending / no-bird")
        st, ix, frm, to = view(request.query_params.get("from"), request.query_params.get("to"))
        offset, limit = page(offset, limit)
        return {**st, "generation": ix.generation, **library.photo_list(ix, sci, day_arg(day, "day"), status, frm, to, offset, limit)}

    @api.get("/api/library/observations")
    def library_observations(request: Request, sci: str | None = None, day: str | None = None, rare: bool | None = None,
                             offset: int = 0, limit: int = 50):
        st, ix, frm, to = view(request.query_params.get("from"), request.query_params.get("to"))
        offset, limit = page(offset, limit)
        gs = ix.observation_groups(frm, to, sci, day_arg(day, "day"), rare)
        return {**st, "generation": ix.generation, "total": len(gs), "items": [ix.observation(g) for g in gs[offset:offset + limit]]}

    @api.get("/api/library/calendar")
    def library_calendar(year: int):
        if not 1 <= year <= 9999:
            raise HTTPException(422, "year 不对")
        st, ix, _, _ = view(None, None)
        return {**st, "generation": ix.generation, **ix.calendar(year)}

    @api.get("/api/library/map")
    def library_map(request: Request, bounds: str, sci: str | None = None):
        try:
            s, w, n, e = (float(x) for x in bounds.split(","))
            assert -90 <= s < n <= 90 and -180 <= w <= 180 and -180 <= e <= 180
        except (ValueError, AssertionError):
            raise HTTPException(422, "bounds 要是 south,west,north,east") from None
        st, ix, frm, to = view(request.query_params.get("from"), request.query_params.get("to"))
        return {**st, "generation": ix.generation, **ix.map(s, w, n, e, frm, to, sci)}


    @api.post("/api/library/observation-count")
    def library_count(body: CountBody):
        st, ix, _, _ = view(None, None)
        if body.expected_generation != ix.generation:
            raise HTTPException(409, "统计已经更新，请重新载入后再改")
        if body.group_key not in ix.groups:
            raise HTTPException(404, "没有这条观察记录")
        if body.count is not None and not 1 <= body.count <= library.MAX_COUNT:
            raise HTTPException(422, "数量只能是 1–999998")
        gen = store._write(lambda db: library.write_group_edit(db, body.group_key, body.count))
        return {**lib.status(), "generation": gen}


    @api.post("/api/library/subject-edit")
    def library_subject_edit(body: SubjectEditBody):
        from birdcm import names
        st, ix, _, _ = view(None, None)
        if body.expected_generation != ix.generation or st["updating"]:
            raise HTTPException(409, "统计正在更新或已经更新，请重新载入后再改")
        r = body.source_ref
        row = next((x for x in ix.by_hash.get(str(r.get("asset_hash")), []) if x["source_kind"] == r.get("kind")
                    and x["source_id"] == str(r.get("id")) and x["subject_id"] == r.get("subject_id")), None)
        if row is None:
            raise HTTPException(404, "没有这张照片或这个主体")
        try:
            edit = library.check_edit(body.edit, names.catalogue())
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        photo_wide = edit["op"] in ("date", "place")
        if not photo_wide and row["subject_id"] == "photo":
            raise HTTPException(422, "鸟种、数量、排除只能改某一只鸟，不能改整张照片")
        res = None
        if row["source_kind"] == "photo":
            res = (store.photo(int(row["source_id"])) or {}).get("result")
        elif row["source_kind"] == "single":
            rec = store.single(int(row["source_id"])) or {}
            res = rec.get("result")
        if edit["op"] == "place" and (edit["value"] or {}).get("source") == "photo" and not ((res or {}).get("exif") or {}).get("gps"):
            raise HTTPException(422, "这张照片没有 GPS，不能恢复成照片位置")
        box = json.loads(row["box_json"]) if row["box_json"] else None
        store._write(lambda db: library.write_subject_edit(db, row["asset_hash"], "photo" if photo_wide else row["subject_id"], edit, box))
        # the subject bird of a scan / single photo: the scan view's correction says the same (one source of truth)
        if edit["op"] == "species" and res and res.get("boxes"):
            k = res.get("subject") if row["source_kind"] == "photo" else (store.single(int(row["source_id"])) or {}).get("subject")
            k = res.get("subject") if k is None else k
            if k is not None and k < len(res["boxes"]) and library.subject_uuid(row["asset_hash"], res["boxes"][k]["box"]) == row["subject_id"]:
                if row["source_kind"] == "photo":
                    pid = int(row["source_id"])
                    if edit["state"] == "none":
                        store.clear_corrections([pid])
                    else:
                        store.set_corrections([pid], edit["key"], "one")
                    sched.rerate_now(store.photo(pid)["scan_id"])
                else:
                    sid = int(row["source_id"])
                    store.update_single(sid, correction=None if edit["state"] == "none" else
                                        {"sci": edit["key"], **(names.catalogue().get(edit["key"] or "", {}))})
        return lib.refresh()

    staging = archive.Staging(config.data_dir() / "import-staging")

    @api.get("/api/library/export")
    def library_export(request: Request):
        """The portable .birdcm file (originals included, not encrypted); from/to = a selection, not a full backup."""
        q = request.query_params
        frm, to = day_arg(q.get("from"), "from"), day_arg(q.get("to"), "to")
        out = staging.new_path()
        try:
            archive.export(lib, out, frm, to)
        except Exception as e:  # noqa: BLE001 - disk full, unreadable file: nothing half-written is sent
            out.unlink(missing_ok=True)
            raise HTTPException(500, f"导出失败：{type(e).__name__}: {e}") from None
        from starlette.background import BackgroundTask
        name = f"BirdCM-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}{'-selection' if frm or to else ''}.birdcm"
        return FileResponse(out, media_type=archive.MIME, filename=name, background=BackgroundTask(out.unlink, missing_ok=True))

    @api.post("/api/library/import/preview")
    async def library_import_preview(request: Request):
        try:
            declared = int(request.headers.get("content-length", ""))
        except ValueError:
            raise HTTPException(411, "需要 Content-Length") from None
        if declared > archive.MAX_ARCHIVE or declared * 2 > archive.free_bytes(staging.folder):
            raise HTTPException(413, "文件太大，或磁盘空间不够暂存和导入它")
        form = await request.form(max_files=1, max_fields=2)
        f = form.get("file")
        if f is None or not hasattr(f, "read"):
            raise HTTPException(422, "没有收到文件")
        path = staging.new_path()
        with open(path, "wb") as out:                     # bounded chunks onto disk, never the whole file in memory
            while chunk := await f.read(1 << 20):
                out.write(chunk)
        try:
            summary, conflicts, _ = await run_in_threadpool(archive.plan, lib, path)
        except ValueError as e:
            path.unlink(missing_ok=True)
            raise HTTPException(422, str(e)) from None
        return staging.add(path, summary, conflicts)


    @api.post("/api/library/import/apply")
    def library_import_apply(body: ApplyBody):
        item = staging.get(body.token)
        if item is None:
            raise HTTPException(404, "导入已过期（30 分钟），请重新选择文件")
        if item["result"] is not None:
            return item["result"]                            # a retry of a committed import: the same answer, nothing again
        if body.mode not in ("merge", "restore") or any(v not in ("local", "file") for v in body.choices.values()):
            raise HTTPException(422, "mode 只能是 merge / restore，选择只能是 local / file")
        if body.mode == "restore" and (item["summary"]["scope"] != "full" or not body.confirm_restore):
            raise HTTPException(422, "只有完整备份能恢复，并且要先确认会替换记录本")
        if body.expected_generation != lib.status()["generation"]:
            raise HTTPException(409, "统计已经更新，请重新预览")
        safety = None
        if body.mode == "restore":                           # a local safety copy first
            safety = config.data_dir() / "backups" / f"BirdCM-before-restore-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.birdcm"
            safety.parent.mkdir(parents=True, exist_ok=True)
            archive.export(lib, safety)
        try:
            res = archive.apply(lib, Path(item["path"]), body.choices, restore=body.mode == "restore")
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        if safety:
            res["safety_backup"] = safety.name
        item["result"] = res
        Path(item["path"]).unlink(missing_ok=True)
        return res

    def import_record(rid: str) -> dict:
        r = store._db().execute("SELECT r.*, a.relative_path, a.missing, a.mime FROM ll_record r JOIN ll_asset a ON a.hash = r.asset_hash "
                                "WHERE r.id = ?", (rid,)).fetchone()
        if not r:
            raise HTTPException(404, "没有这条导入记录")
        return dict(r)

    @api.get("/api/library/import-records/{rid}")
    def library_import_record(rid: str):
        r = import_record(rid)
        subs = [dict(s) for s in store._db().execute("SELECT id, ordinal, x0, y0, x1, y1, model_level, model_key, correction_state, "
                                                       "corrected_key, count_edit, excluded, needs_match FROM ll_subject WHERE record_id = ? "
                                                       "AND retired = 0 ORDER BY ordinal", (rid,))]
        keep = ("id", "asset_hash", "origin", "local_day", "capture_wall", "capture_offset_min", "date_source", "lat", "lon",
                "place_label", "place_source", "region_code", "missing", "mime", "first_identified_utc")
        return {**{k: r[k] for k in keep}, "shooting": json.loads(store._db().execute(
            "SELECT shooting_json FROM ll_asset WHERE hash = ?", (r["asset_hash"],)).fetchone()[0]), "subjects": subs}

    @api.get("/api/library/import-records/{rid}/image")
    def library_import_image(rid: str, size: str = "preview"):
        r = import_record(rid)
        if r["missing"] or not r["relative_path"]:
            raise HTTPException(404, "这张照片的原图不在这台电脑上")
        path = lib.imports_dir / Path(r["relative_path"]).name        # only our own stored name, never a client path
        if not path.is_file():
            raise HTTPException(404, "原图不见了")
        if size == "original":
            return FileResponse(path, media_type=r["mime"], headers={"Cache-Control": "private, no-cache"})
        st = path.stat()
        thumb, prev = image_paths(str(path), st.st_size, st.st_mtime_ns)
        out = thumb if size == "thumb" else prev
        if not out.exists():
            try:
                previews.make({"path": str(path), "size": st.st_size, "mtime_ns": st.st_mtime_ns, "thumb": str(thumb), "preview": str(prev)})
            except Exception as e:  # noqa: BLE001
                raise HTTPException(404, f"无法生成预览：{e}") from None
        return FileResponse(out, media_type="image/jpeg", headers={"Cache-Control": "private, no-cache"})

    @api.get("/api/library/ebird/plan")
    def library_ebird_plan(request: Request):
        from birdcm import ebird
        st, ix, frm, to = view(request.query_params.get("from"), request.query_params.get("to"))
        cls = ebird.lifelist_checklists(ix, frm, to)
        names = ebird.clements()
        sp = sorted({g["sci"] for c in cls for g in c["groups"]})
        pending = sum(1 for r in ix.rows_in(frm, to) if r["level"] in library.PENDING)
        return {**st, "generation": ix.generation, "checklists": len(cls), "fallback_checklists": sum(1 for c in cls if c["fallback"]),
                "pending_subjects_excluded": pending,
                "species": [{"sci": s, **library.names_of(s), "ebird_en": names.get(s, ("", ""))[0],
                             "name_check": "" if names.get(s, ("", ""))[0] else "not_in_ebird"} for s in sp]}


    @api.get("/api/library/crop")
    def library_crop(kind: str, id: str, subject_id: str, asset_hash: str):
        """One bird's square crop (calendar covers): cut from the photo's cached preview, cached itself. 404 when
        the original is not reachable (unmounted volume): the page falls back to the count."""
        import hashlib
        ix = lib.index()
        row = next((x for x in ix.by_hash.get(asset_hash, []) if x["source_kind"] == kind and x["source_id"] == id
                    and x["subject_id"] == subject_id and x["box_json"]), None)
        if row is None:
            raise HTTPException(404, "没有这只鸟")
        try:
            if kind == "photo":
                p = store.photo(int(id))
                src, size, mtime = p["path"], p["size"], p["mtime_ns"]
            elif kind == "single":
                path = stored_path(store.single(int(id)))
                st = path.stat()
                src, size, mtime = str(path), st.st_size, st.st_mtime_ns
            else:
                rel = import_record(id)["relative_path"]
                path = lib.imports_dir / Path(rel or "").name
                st = path.stat()
                src, size, mtime = str(path), st.st_size, st.st_mtime_ns
        except (OSError, TypeError, ValueError):
            raise HTTPException(404, "原图不可用") from None
        thumb, prev = image_paths(src, size, mtime)
        out = prev.with_name(prev.stem + "-c" + hashlib.sha1(row["box_json"].encode()).hexdigest()[:10] + ".jpg")
        if not out.exists():
            try:
                if not prev.exists():
                    previews.make({"path": src, "size": size, "mtime_ns": mtime, "thumb": str(thumb), "preview": str(prev)})
                library.crop_file(prev, json.loads(row["box_json"]), out)
            except Exception:  # noqa: BLE001 - not mounted, unreadable: no picture, the count stands
                raise HTTPException(404, "原图不可用") from None
        return FileResponse(out, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})

    @api.post("/api/library/ebird")
    def library_ebird(body: LifeEbird):
        from fastapi.responses import Response
        from birdcm import ebird
        if body.fallback not in ("refuse", "include", "exclude"):
            raise HTTPException(422, "fallback 只能是 refuse / include / exclude")
        st, ix, frm, to = view(body.start, body.end)
        if st["hashing"]:                            # the stand-in generation may count a file seen twice: not for a file to keep
            raise HTTPException(409, "正在给照片做指纹，做完再导出")
        try:
            text = ebird.lifelist_csv(ix, frm, to, body.species, body.counts, body.use_estimates, body.fallback)
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        return Response(text, media_type="text/csv; charset=utf-8")

    # ---- online species reference (online.py; docs/design-species-search.md): GET reads the cache, POST asks the source
    from birdcm import online

    def reference(sci: str, refresh: bool, kinds: tuple = ("summary", "image"), force: bool = False) -> dict:
        net = refresh and online.settings()["enabled"]
        out = {k: online.card(k, sci[:200], net, force) for k in kinds}
        if refresh and not net:
            out = {k: {**v, "state": "off"} if v["state"] in ("missing", "unavailable") else v for k, v in out.items()}
        return {**out, "links": online.links(online.mapping(sci[:200]), sci)}

    @api.get("/api/online/settings")
    def online_settings():
        return online.settings()

    @api.post("/api/online/settings")
    def online_set(body: dict):
        if any(not isinstance(body.get(k, False), bool) for k in ("enabled", "disclosed", "places")):
            raise HTTPException(422, "enabled / disclosed / places 要是 true / false")
        return online.set_settings(body.get("enabled"), body.get("disclosed"), body.get("places"))

    @api.delete("/api/online/cache")
    def online_clear():
        places.clear(store)                            # the cached place names go too
        return {"deleted_bytes": online.clear()}

    @api.get("/api/species/reference")
    def species_reference(sci: str):
        return reference(sci, refresh=False)

    @api.post("/api/species/reference")
    def species_reference_refresh(body: dict):
        kinds = tuple(k for k in ("summary", "image") if k in (body.get("kinds") or ("summary", "image")))
        return reference(str(body.get("sci", "")), refresh=True, kinds=kinds, force=bool(body.get("force")))

    @api.get("/api/species/reference/image")
    def species_reference_image(sci: str):
        f = online.cached_file(sci[:200])
        if f is None:
            raise HTTPException(404, "没有缓存的授权参考图")
        return FileResponse(f[0], media_type=f[1], headers={"Cache-Control": "private, no-cache"})

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


def prepare(port: int):
    """Every start-up step both `birdcm serve` and the Mac app's `birdcm admin serve` take (one place, Codex note):
    preflight, own dirs, the app, and the warnings about what is missing. Returns the guarded app."""
    preflight()
    for d in (config.data_dir(), config.cache_dir()):
        d.mkdir(parents=True, exist_ok=True)
    guarded, _api = create_app(port)
    if not decode.ExifTool.available():
        print("警告：找不到 exiftool，拍摄信息和对焦点会是空的。`brew install exiftool` 安装。", file=sys.stderr)
    st = models.status()
    if not st["ready"]:
        print(f"缺模型文件：{', '.join(st['missing'])}。{st['fetch_hint']}", file=sys.stderr)
    for o in st["optional_missing"]:
        print(f"{'还没有发布' if not o['released'] else '没有'} {o['name']}：{o['effect']}", file=sys.stderr)
    if not WEB.is_dir():
        print(f"没有找到界面文件 {WEB}；先在 web/ 里运行 `npm install && npm run build`。", file=sys.stderr)
    return guarded


def run(guarded, port: int) -> None:
    """uvicorn with a short graceful window: an open event stream (a browser tab) must not hold a stop hostage; the
    lifespan then closes the decode pools and exiftool."""
    import uvicorn
    uvicorn.run(guarded, host="127.0.0.1", port=port, log_level="warning", timeout_graceful_shutdown=3)


def serve(port: int = 8765, open_browser: bool = True) -> int:
    guarded = prepare(port)
    url = f"http://127.0.0.1:{port}/"
    if open_browser:
        threading.Timer(1.5, webbrowser.open, (url,)).start()
    print(f"观羽 BirdCM: {url}", flush=True)
    run(guarded, port)
    return 0
