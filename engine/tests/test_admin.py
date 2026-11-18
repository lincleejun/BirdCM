"""birdcm admin: config persistence, usage, clear-cache, moves (photo-folder refusal, survives a restart), model status
with a fake manifest (incl. not released), fetch progress, lock-proven stop."""
import hashlib
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
from pathlib import Path

import pytest

from birdcm import admin, config, models
from birdcm.store import Store


@pytest.fixture
def home(tmp_path, monkeypatch):
    """Only BIRDCM_CONFIG set (as the app runs); data and cache come from the config file."""
    for env in ("BIRDCM_DATA_DIR", "BIRDCM_CACHE_DIR", "BIRDCM_MODEL_DIR"):
        monkeypatch.delenv(env, raising=False)
    monkeypatch.setenv("BIRDCM_CONFIG", str(tmp_path / "home" / "config.toml"))
    monkeypatch.setattr(admin, "OVERRIDDEN", set())
    admin.write_config(data_dir=str(tmp_path / "data"), cache_dir=str(tmp_path / "cache"))
    admin.apply_config()
    return tmp_path


def restart(monkeypatch):
    """A new process: nothing in the environment but BIRDCM_CONFIG, then the config is read again."""
    for env in ("BIRDCM_DATA_DIR", "BIRDCM_CACHE_DIR", "BIRDCM_MODEL_DIR"):
        monkeypatch.delenv(env, raising=False)
    admin.OVERRIDDEN.clear()
    admin.apply_config()


def put(p: Path, n: int) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"x" * n)
    return p


def test_config_roundtrip_and_env_wins(home, monkeypatch):
    admin.write_config(port=8790, model_dirs=["/a b/c", "/d"], data_dir='/x/"quoted" 观羽')
    cfg = admin.read_config()
    assert cfg["port"] == 8790 and cfg["model_dirs"] == ["/a b/c", "/d"] and cfg["data_dir"] == '/x/"quoted" 观羽'
    assert admin.port() == 8790
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(home / "envcache"))
    restart_keep = {"BIRDCM_CACHE_DIR"}
    for env in ("BIRDCM_DATA_DIR", "BIRDCM_MODEL_DIR"):
        monkeypatch.delenv(env, raising=False)
    admin.OVERRIDDEN.clear()
    admin.apply_config()
    assert config.cache_dir() == (home / "envcache").resolve()                 # env beats the file
    assert admin.OVERRIDDEN == restart_keep
    assert os.environ["BIRDCM_MODEL_DIR"] == os.pathsep.join(["/a b/c", "/d"])
    with pytest.raises(admin.AdminError, match="环境变量"):
        admin.move("cache", str(home / "elsewhere"))


def test_usage_and_clear_cache_keeps_db(home):
    put(home / "cache" / "img" / "ab" / "x-t.jpg", 1000)
    put(home / "cache" / "models" / "m.safetensors", 500)
    Store(home / "data" / "birdcm.db").create_scan("/photos", False, None, {"preset": "std"}, "fp", [])
    u = admin.usage()
    assert u["img"] == 1000 and u["models"] == 500 and u["db"] > 0
    out = admin.clear_cache()
    assert out == {"freed": 1000, "database": False}
    assert not (home / "cache" / "img").exists()
    assert (home / "data" / "birdcm.db").exists() and (home / "cache" / "models" / "m.safetensors").exists()
    out = admin.clear_cache(database=True)
    assert out["database"] and not (home / "data" / "birdcm.db").exists()


def test_move_refuses_photo_folder_and_survives_restart(home, monkeypatch):
    photos = home / "photos"
    photos.mkdir()
    Store(home / "data" / "birdcm.db").create_scan(str(photos), False, None, {"preset": "std"}, "fp", [])
    put(home / "cache" / "img" / "ab" / "x-t.jpg", 1234)
    with pytest.raises(admin.AdminError, match="照片文件夹"):
        admin.move("cache", str(photos / "cache"))
    with pytest.raises(admin.AdminError, match="照片文件夹"):
        admin.move("data", str(photos))
    with pytest.raises(admin.AdminError, match="自己里面"):
        admin.move("cache", str(home / "cache" / "img" / "inner"))
    assert (home / "cache" / "img" / "ab" / "x-t.jpg").exists()               # refused moves change nothing

    out = admin.move("cache", str(home / "newcache"))
    assert out["moved"] and out["bytes"] == 1234
    assert (home / "newcache" / "img" / "ab" / "x-t.jpg").stat().st_size == 1234
    assert not (home / "cache").exists()
    restart(monkeypatch)
    assert config.cache_dir() == (home / "newcache").resolve()

    other = home / "busy"                                                       # not empty: goes into busy/BirdCM
    put(other / "something.txt", 1)
    admin.move("data", str(other))
    restart(monkeypatch)
    assert config.data_dir() == (other / "BirdCM").resolve()
    assert (other / "BirdCM" / "birdcm.db").exists() and (other / "something.txt").exists()


def test_move_keeps_app_files_when_they_share_the_data_dir(tmp_path, monkeypatch):
    for env in ("BIRDCM_DATA_DIR", "BIRDCM_CACHE_DIR", "BIRDCM_MODEL_DIR"):
        monkeypatch.delenv(env, raising=False)
    monkeypatch.setattr(admin, "OVERRIDDEN", set())
    monkeypatch.setenv("BIRDCM_CONFIG", str(tmp_path / "BirdCM" / "config.toml"))
    admin.write_config(data_dir=str(tmp_path / "BirdCM"), cache_dir=str(tmp_path / "c"))   # the default layout
    admin.apply_config()
    put(tmp_path / "BirdCM" / "engine.log", 10)
    Store(tmp_path / "BirdCM" / "birdcm.db").create_scan("/photos", False, None, {"preset": "std"}, "fp", [])
    admin.move("data", str(tmp_path / "d2"))
    assert (tmp_path / "BirdCM" / "config.toml").exists() and (tmp_path / "BirdCM" / "engine.log").exists()
    assert (tmp_path / "d2" / "birdcm.db").exists() and not (tmp_path / "d2" / "config.toml").exists()
    assert admin.read_config()["data_dir"] == str((tmp_path / "d2").resolve())


def fake_manifest(tmp_path, monkeypatch, blobs: dict[str, bytes]):
    """'a' present on disk, 'b' downloadable, 'c' not released (its URL answers 404), 'd' marked released = false and
    optional in the manifest (never asked for, even though its URL would answer)."""
    rows = []
    for name, data in blobs.items():
        rows.append(f'[[file]]\nname = "{name}"\nrole = "{name}"\nurl = "https://example.invalid/{name}"\n'
                    f'sha256 = "{hashlib.sha256(data).hexdigest()}"\nbytes = {len(data)}\n' +
                    ('optional = true\nreleased = false\n' if name == "d.bin" else ""))
    m = tmp_path / "models.toml"
    m.write_text("\n".join(rows))
    monkeypatch.setattr(models, "MANIFEST", m)


class FakeOpener:
    def __init__(self, blobs, released):
        self.blobs, self.released = blobs, released

    def __call__(self, req, timeout=None):
        url = req if isinstance(req, str) else req.full_url
        name = url.rsplit("/", 1)[1]
        if name not in self.released:
            raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
        return io.BytesIO(self.blobs[name])


def test_models_status_and_fetch(home, monkeypatch):
    blobs = {"a.bin": b"a" * 10, "b.bin": b"b" * (3 << 20), "c.bin": b"c" * 7, "d.bin": b"d"}
    fake_manifest(home, monkeypatch, blobs)
    put(home / "cache" / "models" / "a.bin", 0).write_bytes(blobs["a.bin"])
    opener = FakeOpener(blobs, released={"a.bin", "b.bin", "d.bin"})

    st = admin.models_status(opener=opener)
    states = {f["name"]: f["state"] for f in st["files"]}
    assert states == {"a.bin": "present", "b.bin": "missing", "c.bin": "not_released", "d.bin": "not_released"}
    assert st["download_bytes"] == 3 << 20 and st["present_bytes"] == 10 and not st["ready"]
    assert st["not_released"] == ["c.bin", "d.bin"]

    lines = []
    assert admin.models_fetch(lines.append, opener=opener) == 0                 # not released is not a failure
    by = {}
    for o in lines:
        by.setdefault(o.get("file"), []).append(o)
    assert by["b.bin"][-1]["state"] == "present" and by["c.bin"][-1]["state"] == "not_released"
    assert by["d.bin"] == [{"file": "d.bin", "state": "not_released"}]                # no request made
    assert lines[-1] == {"finished": True, "failed": 0}
    assert not list((home / "cache" / "models").glob("*.part"))
    assert admin.models_status(opener=opener)["missing"] == []

    blobs_bad = {**blobs, "b.bin": b"corrupt"}                                  # sha256 mismatch: failure, no file
    (home / "cache" / "models" / "b.bin").unlink()
    lines = []
    assert admin.models_fetch(lines.append, opener=FakeOpener(blobs_bad, {"b.bin"})) == 1
    assert not (home / "cache" / "models" / "b.bin").exists()

    assert admin.models_remove(["a.bin"])["removed"] == ["a.bin"]
    assert {f["name"]: f["state"] for f in admin.models_status(opener=opener)["files"]}["a.bin"] == "missing"


def test_lock_health_and_stop_only_signal_the_lock_holder(home, tmp_path):
    """A child that takes the lock the way serve does; stop() SIGTERMs it; a process without the lock is never seen."""
    holder = subprocess.Popen([sys.executable, "-c", f"""
import fcntl, json, os, signal, sys, time
os.setpgid(0, 0)
fd = os.open({str(admin.lock_path())!r}, os.O_RDWR | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
os.write(fd, json.dumps({{"pid": os.getpid(), "port": 1}}).encode())
print("locked", flush=True)
time.sleep(60)
"""], stdout=subprocess.PIPE, text=True)
    assert holder.stdout.readline().strip() == "locked"
    h = admin.health()
    assert h["running"] and h["engine"]["pid"] == holder.pid and not h["ready"]
    with pytest.raises(admin.AdminError, match="停止"):
        admin.move("cache", str(tmp_path / "x"))
    out = admin.stop(timeout=5)
    assert out["stopped"] and out["pid"] == holder.pid
    assert holder.wait(5) == -15
    assert admin.health()["running"] is False
    assert admin.stop() == {"stopped": False, "was_running": False}


def test_port_busy_is_reported(home):
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen()
    busy = s.getsockname()[1]
    try:
        r = subprocess.run([sys.executable, "-m", "birdcm.cli", "admin", "serve", "--port", str(busy), "--no-log"],
                           capture_output=True, text=True, env={**os.environ}, timeout=60)
        assert r.returncode == 4, r.stderr
        why = json.loads(r.stdout.splitlines()[-1])
        assert why["error"] == "port_busy" and why["holder"]["pid"] == os.getpid() and why["suggest"] > busy
    finally:
        s.close()
