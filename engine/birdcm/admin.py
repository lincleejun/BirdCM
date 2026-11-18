"""`birdcm admin <command>`: everything the macOS menu-bar app does, as commands that print one JSON object
(models-fetch: one JSON object per line as it goes). The app stays a thin shell over these.

One config file, read at every start (cli.main calls apply_config):
  BIRDCM_CONFIG (default ~/Library/Application Support/BirdCM/config.toml) with keys
  data_dir, cache_dir, model_dirs (list), port.
Environment variables (BIRDCM_DATA_DIR / BIRDCM_CACHE_DIR / BIRDCM_MODEL_DIR) still win, for development.
Next to the config: engine.lock (the running engine: pid, port, exe; flock-held while it runs) and engine.log (+ .1).
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

from birdcm import config

ENV = {"data_dir": "BIRDCM_DATA_DIR", "cache_dir": "BIRDCM_CACHE_DIR"}
DEFAULT_PORT = 8765
LOG_MAX = 4 << 20                  # bytes; engine.log is renamed to engine.log.1 past this (one old copy kept)
OVERRIDDEN: set[str] = set()       # env vars that were set before the config was applied (the config does not apply)


class AdminError(Exception):
    pass


# ---- config ------------------------------------------------------------------------------------------------------

def config_path() -> Path:
    return Path(os.environ.get("BIRDCM_CONFIG") or config.HOME / "Library/Application Support/BirdCM/config.toml").expanduser()


def home() -> Path:
    return config_path().parent


def read_config() -> dict:
    try:
        return tomllib.loads(config_path().read_text())
    except FileNotFoundError:
        return {}


def write_config(**changes) -> dict:
    cfg = {k: v for k, v in {**read_config(), **changes}.items() if v is not None}
    p = config_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    # JSON strings, numbers and string lists are valid TOML values
    tmp.write_text("# 观羽 BirdCM settings (written by the app; environment variables override)\n" +
                   "".join(f"{k} = {json.dumps(v)}\n" for k, v in cfg.items()))
    os.replace(tmp, p)
    return cfg


def apply_config() -> None:
    """Config values become the environment the rest of the engine (and its worker processes) already read."""
    cfg = read_config()
    for key, env in [*ENV.items(), ("model_dirs", "BIRDCM_MODEL_DIR")]:
        if os.environ.get(env):
            OVERRIDDEN.add(env)
        elif cfg.get(key):
            os.environ[env] = os.pathsep.join(cfg[key]) if isinstance(cfg[key], list) else str(cfg[key])


def port() -> int:
    return int(read_config().get("port") or DEFAULT_PORT)


# ---- what is where, how big ----------------------------------------------------------------------------------------

def du(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    n = 0
    for root, _dirs, files in os.walk(p):
        for f in files:
            with contextlib.suppress(OSError):
                n += os.lstat(os.path.join(root, f)).st_size
    return n


def db_files() -> list[Path]:
    db = config.data_dir() / "birdcm.db"
    return [db, db.with_name("birdcm.db-wal"), db.with_name("birdcm.db-shm")]


def paths() -> dict:
    return {"config": str(config_path()), "data": str(config.data_dir()), "cache": str(config.cache_dir()),
            "models": str(config.cache_dir() / "models"), "model_dirs": [str(d) for d in config.model_dirs()],
            "img": str(config.cache_dir() / "img"), "db": str(db_files()[0]), "log": str(home() / "engine.log"),
            "port": port(), "overridden": sorted(OVERRIDDEN)}


def usage() -> dict:
    c, d = config.cache_dir(), config.data_dir()
    out = {"img": du(c / "img"), "models": du(c / "models"), "db": sum(du(p) for p in db_files() if p.exists()),
           "singles": du(d / "singles"), "log": sum(du(p) for p in home().glob("engine.log*"))}
    return {**out, "cache_total": du(c), "data_total": du(d)}


# ---- the running engine ---------------------------------------------------------------------------------------------

def lock_path() -> Path:
    return home() / "engine.lock"


def running() -> dict | None:
    """The engine holding the lock ({pid, port, exe, ...}); None when none runs. Only a pid read from a held lock is
    ever signalled, so a server started some other way (a dev `birdcm serve`) is never touched."""
    p = lock_path()
    try:
        fd = os.open(p, os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return None                              # nobody holds it
    except BlockingIOError:
        try:
            return json.loads(p.read_text()) or {}
        except ValueError:
            return {}                            # holder is still writing it
    finally:
        os.close(fd)


def http_ok(port_: int, timeout: float = 1.0) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port_}/api/session", timeout=timeout) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def health() -> dict:
    r = running()
    return {"running": r is not None, "ready": bool(r and r.get("port") and http_ok(r["port"])), "engine": r,
            "port": port(), "url": f"http://127.0.0.1:{(r or {}).get('port') or port()}/"}


def stop(timeout: float = 20.0) -> dict:
    """SIGTERM (the server finishes the batch on the GPU, puts the rest back in the queue, closes its workers), wait,
    then SIGKILL the engine's whole process group."""
    r = running()
    if not r or not r.get("pid"):
        return {"stopped": False, "was_running": r is not None}
    pid, killed = r["pid"], False
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGTERM)
    end = time.monotonic() + timeout
    while running() is not None and time.monotonic() < end:
        time.sleep(0.2)
    if running() is not None:
        killed = True
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pid, signal.SIGKILL) if os.getpgid(pid) == pid else os.kill(pid, signal.SIGKILL)
    for _ in range(50):                          # the group's leftovers (decode workers, exiftool) follow the leader
        try:
            os.killpg(pid, 0)
        except (ProcessLookupError, PermissionError):
            break
        time.sleep(0.1)
    else:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pid, signal.SIGKILL)
    return {"stopped": True, "killed": killed, "pid": pid}


def port_holder(port_: int) -> dict | None:
    r = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{port_}", "-sTCP:LISTEN", "-Fpc"], capture_output=True, text=True)
    f = {line[0]: line[1:] for line in r.stdout.splitlines() if line[:1] in ("p", "c")}
    return {"pid": int(f["p"]), "command": f.get("c")} if "p" in f else None


def port_free(port_: int) -> bool:
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)    # as uvicorn binds
        try:
            s.bind(("127.0.0.1", port_))
            return True
        except OSError:
            return False


def _log_to(path: Path) -> None:
    """stdout + stderr -> engine.log; past LOG_MAX it becomes engine.log.1 (checked at start and every minute)."""
    path.parent.mkdir(parents=True, exist_ok=True)

    def reopen():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.close(fd)

    def rotate():
        with contextlib.suppress(OSError):
            if path.stat().st_size > LOG_MAX:
                os.replace(path, path.with_name(path.name + ".1"))
                reopen()

    rotate()
    reopen()
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)

    def loop():
        while True:
            time.sleep(60)
            rotate()
    threading.Thread(target=loop, daemon=True, name="birdcm-log").start()


def serve(port_: int | None, log: bool = True) -> int:
    """The engine as the app runs it: one per user (lock), its own process group, the port checked first, then logs to
    engine.log. Errors before that are one JSON line on stdout and an exit code: 3 already running, 4 port busy,
    5 refused to start."""
    def fail(code: int, **why) -> int:
        print(json.dumps(why, ensure_ascii=False), flush=True)
        return code

    port_ = port_ or port()
    home().mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path(), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return fail(3, error="already_running", message="观羽引擎已经在运行", engine=running())
    with contextlib.suppress(OSError):
        os.setpgid(0, 0)                         # stop() can then end the decode workers and exiftool with us
    if not port_free(port_):
        h = port_holder(port_)
        alt = next((p for p in range(port_ + 1, port_ + 50) if port_free(p)), None)
        who = f"{h['command']}（pid {h['pid']}）" if h else "另一个程序"
        return fail(4, error="port_busy", port=port_, holder=h, suggest=alt, message=f"端口 {port_} 被 {who}占用")
    from birdcm import app
    try:
        app.preflight()
    except ValueError as e:
        return fail(5, error="refused", message=str(e))
    for d in (config.data_dir(), config.cache_dir()):
        d.mkdir(parents=True, exist_ok=True)
    if port_ != port():
        write_config(port=port_)
    info = {"pid": os.getpid(), "port": port_, "exe": sys.executable, "exiftool": shutil.which("exiftool"),
            "started": time.time()}
    os.ftruncate(fd, 0)
    os.write(fd, json.dumps(info).encode())
    print(json.dumps({"event": "starting", **info, "log": str(home() / "engine.log")}), flush=True)
    if log:
        _log_to(home() / "engine.log")
    print(f"{time.strftime('%F %T')} 观羽引擎启动 {json.dumps(info, ensure_ascii=False)}", flush=True)
    import uvicorn
    guarded, _api = app.create_app(port_)
    # a short graceful window: an open event stream (a browser tab) must not hold a stop hostage
    uvicorn.run(guarded, host="127.0.0.1", port=port_, log_level="warning", timeout_graceful_shutdown=3)
    return 0                                     # (after a SIGTERM uvicorn re-raises it once shut down: no return)


# ---- cache and data ---------------------------------------------------------------------------------------------------

def clear_cache(database: bool = False) -> dict:
    """Thumbnails and previews (always made again on demand). With database=True also the database and the uploaded
    single photos: only with the engine stopped (the app asks twice before passing it)."""
    img = config.cache_dir() / "img"
    freed = du(img)
    shutil.rmtree(img, ignore_errors=True)
    out = {"freed": freed, "database": False}
    if database:
        if running() is not None:
            raise AdminError("先停止服务，再删除数据库")
        singles = config.data_dir() / "singles"
        out["freed"] += du(singles) + sum(du(p) for p in db_files() if p.exists())
        shutil.rmtree(singles, ignore_errors=True)
        for p in db_files():
            p.unlink(missing_ok=True)
        out["database"] = True
    return out


def scanned_folders() -> list[Path]:
    db = db_files()[0]
    if not db.is_file():
        return []
    con = sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True)
    try:
        return [Path(r[0]).expanduser().resolve() for r in con.execute("SELECT folder FROM scan")]
    finally:
        con.close()


def move(kind: str, dest: str) -> dict:
    """Move the data or cache directory to dest (or dest/BirdCM when dest already has other things in it): engine
    stopped, never into a photo folder that was scanned, copy -> verify -> config -> delete the old copy."""
    env = ENV[f"{kind}_dir"]
    if env in OVERRIDDEN:
        raise AdminError(f"{env} 由环境变量指定，这里不能更改")
    if running() is not None:
        raise AdminError("先停止服务再移动")
    src = config.data_dir() if kind == "data" else config.cache_dir()
    target = Path(dest).expanduser().resolve()
    if target.exists() and not target.is_dir():
        raise AdminError(f"不是文件夹：{target}")
    if target.is_dir() and any(target.iterdir()) and target != src:
        target = target / "BirdCM"
        if target.exists() and any(target.iterdir()) and target != src:
            raise AdminError(f"{target} 里已经有内容，请选一个空文件夹")
    if target == src:
        return {"moved": False, kind: str(src)}
    if config.inside(target, src):
        raise AdminError("不能移到它自己里面")
    for f in scanned_folders():
        if config.inside(target, f):
            raise AdminError(f"{target} 在扫描过的照片文件夹 {f} 里面；观羽不往照片文件夹里写东西，请选别处")
    # the app's own files (config, lock, log) stay where they are, also when they share the data directory
    keep = {p.resolve() for p in (config_path(), lock_path(), *home().glob("engine.log*"))}
    items = [p for p in src.iterdir() if p.resolve() not in keep] if src.is_dir() else []
    target.mkdir(parents=True, exist_ok=True)
    for p in items:
        if p.is_dir() and not p.is_symlink():
            shutil.copytree(p, target / p.name, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(p, target / p.name, follow_symlinks=False)
    moved = sum(du(p) for p in items)
    copied = sum(du(target / p.name) for p in items)
    if copied != moved:
        raise AdminError(f"复制不完整（{copied} / {moved} 字节），原位置未改动")
    write_config(**{f"{kind}_dir": str(target)})
    os.environ[env] = str(target)
    for p in items:
        shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()
    with contextlib.suppress(OSError):
        src.rmdir()
    return {"moved": True, kind: str(target), "bytes": moved}


# ---- models -----------------------------------------------------------------------------------------------------------

def remote_state(url: str, opener=None) -> str:
    """'released' / 'not_released' (the release URL answers 404) / 'unknown' (offline, other errors)."""
    try:
        (opener or urllib.request.urlopen)(urllib.request.Request(url, method="HEAD"), timeout=8).close()
        return "released"
    except urllib.error.HTTPError as e:
        return "not_released" if e.code == 404 else "unknown"
    except Exception:  # noqa: BLE001
        return "unknown"


def models_status(remote: bool = True, opener=None) -> dict:
    """Each manifest file: present (sha256-checked) / missing (downloadable) / not_released; totals in bytes."""
    from birdcm import models
    own = config.cache_dir() / "models"
    files = []
    for e in models.manifest()["file"]:
        p = models.locate(e)
        if p:
            state = "present"
        elif not e.get("released", True):                     # the manifest says so: no network needed
            state = "not_released"
        else:                                                 # the manifest may be older than the release page
            state = remote_state(e["url"], opener) if remote else "unknown"
            state = {"released": "missing", "unknown": "missing"}.get(state, state)
        files.append({"name": e["name"], "role": e["role"], "bytes": e["bytes"], "state": state,
                      "optional": bool(e.get("optional")), "effect": models.OPTIONAL_EFFECT.get(e["role"], ""),
                      "path": str(p) if p else None, "downloaded": bool(p and p.parent == own), "license": e.get("license")})
    by = lambda s: [f for f in files if f["state"] == s]  # noqa: E731
    return {"files": files, "ready": not any(f["state"] != "present" and not f["optional"] for f in files),
            "present_bytes": sum(f["bytes"] for f in by("present")),
            "download_bytes": sum(f["bytes"] for f in by("missing")),
            "missing": [f["name"] for f in by("missing")], "not_released": [f["name"] for f in by("not_released")],
            "dir": str(own)}


def models_fetch(emit=lambda o: print(json.dumps(o, ensure_ascii=False), flush=True), opener=None) -> int:
    """Download every missing file into <cache>/models: .part, sha256, rename. A 404 is 'not_released', not a failure.
    Progress: {"file", "done", "total"} at most 4 a second. Returns the number of failures."""
    from birdcm import models
    opener = opener or urllib.request.urlopen
    dest = config.cache_dir() / "models"
    dest.mkdir(parents=True, exist_ok=True)
    failed = 0
    for e in models.manifest()["file"]:
        name = e["name"]
        if models.locate(e):
            emit({"file": name, "state": "present"})
            continue
        if not e.get("released", True):
            emit({"file": name, "state": "not_released"})
            continue
        part = dest / (name + ".part")
        try:
            h, done, last = hashlib.sha256(), 0, 0.0
            emit({"file": name, "done": 0, "total": e["bytes"]})
            with opener(e["url"], timeout=60) as r, open(part, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
                    h.update(chunk)
                    done += len(chunk)
                    if time.monotonic() - last > 0.25:
                        last = time.monotonic()
                        emit({"file": name, "done": done, "total": e["bytes"]})
            if h.hexdigest() != e["sha256"]:
                raise ValueError("sha256 不符")
            part.rename(dest / name)
            emit({"file": name, "state": "present", "done": done, "total": e["bytes"]})
        except urllib.error.HTTPError as err:
            if err.code == 404:
                emit({"file": name, "state": "not_released"})
            else:
                failed += 1
                emit({"file": name, "state": "failed", "error": f"HTTP {err.code}"})
        except Exception as err:  # noqa: BLE001 - report and go on with the next file
            failed += 1
            emit({"file": name, "state": "failed", "error": str(err)})
        finally:
            part.unlink(missing_ok=True)
    emit({"finished": True, "failed": failed})
    return failed


def models_remove(names: list[str] | None = None) -> dict:
    """Delete downloaded model files (only those in <cache>/models; a development BIRDCM_MODEL_DIR is never touched)."""
    from birdcm import models
    if running() is not None:
        raise AdminError("先停止服务再删除模型")
    d = config.cache_dir() / "models"
    known = {e["name"] for e in models.manifest()["file"]}
    removed = []
    for p in d.glob("*") if d.is_dir() else []:
        base = p.name.removesuffix(".part")
        if base in known and (not names or base in names):
            p.unlink()
            removed.append(p.name)
    return {"removed": removed}


def models_verify() -> dict:
    """Forget the remembered checksums, so the next status re-hashes every file."""
    (config.cache_dir() / "verified.json").unlink(missing_ok=True)
    return models_status()


# ---- command line -----------------------------------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="birdcm admin")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("paths", "usage", "health", "stop", "models-status", "models-verify", "models-fetch"):
        sub.add_parser(c)
    sub.add_parser("clear-cache").add_argument("--database", action="store_true", help="also the database (engine stopped)")
    for c in ("move-cache", "move-data"):
        sub.add_parser(c).add_argument("dest")
    sub.add_parser("models-remove").add_argument("names", nargs="*")
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int)
    s.add_argument("--no-log", action="store_true", help="keep output on the terminal")
    a = ap.parse_args(argv)

    if a.cmd == "serve":
        return serve(a.port, log=not a.no_log)
    if a.cmd == "models-fetch":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))     # cancel: the .part file is removed on the way out
        return 1 if models_fetch() else 0
    try:
        out = {"paths": paths, "usage": usage, "health": health, "stop": stop, "models-status": models_status,
               "models-verify": models_verify,
               "clear-cache": lambda: clear_cache(a.database), "move-cache": lambda: move("cache", a.dest),
               "move-data": lambda: move("data", a.dest), "models-remove": lambda: models_remove(a.names)}[a.cmd]()
    except AdminError as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False))
        return 2
    print(json.dumps(out, ensure_ascii=False))
    return 0
