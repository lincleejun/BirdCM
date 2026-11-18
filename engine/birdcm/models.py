"""Model manifest (models.toml): find each file, check its sha256, download what is missing."""
from __future__ import annotations

import hashlib
import json
import os
import tomllib
import urllib.request
from pathlib import Path

from birdcm import config

# ponytail: manifest found next to the source checkout; ship it as package data when there is a wheel release.
MANIFEST = Path(os.environ.get("BIRDCM_MANIFEST") or Path(__file__).resolve().parents[2] / "models.toml")


def manifest() -> dict:
    return tomllib.loads(MANIFEST.read_text())


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


def _verified(path: Path, entry: dict) -> bool:
    """sha256 once per (path, size, mtime); the result is remembered in the cache dir so a start-up check of
    0.8 GB of models does not re-hash every time."""
    st = path.stat()
    if st.st_size != entry["bytes"]:
        return False
    memo = config.cache_dir() / "verified.json"
    try:
        seen = json.loads(memo.read_text())
    except (OSError, ValueError):
        seen = {}
    key = f"{path}|{st.st_size}|{st.st_mtime_ns}"
    if seen.get(key) == entry["sha256"]:
        return True
    ok = _sha256(path) == entry["sha256"]
    if ok:
        seen[key] = entry["sha256"]
        memo.parent.mkdir(parents=True, exist_ok=True)
        memo.write_text(json.dumps(seen))
    return ok


def locate(entry: dict) -> Path | None:
    for d in config.model_dirs():
        p = d / entry["name"]
        if p.is_file() and _verified(p, entry):
            return p
    return None


def status() -> dict:
    """{"ready": bool, "files": [{name, role, path|None}], "missing": [names], "fetch": command}"""
    files = [{"name": e["name"], "role": e["role"], "path": str(p) if (p := locate(e)) else None}
             for e in manifest()["file"]]
    missing = [f["name"] for f in files if not f["path"]]
    return {"ready": not missing, "files": files, "missing": missing, "fetch": "uv run birdcm models fetch",
            "pending": ["aesthetic", "clear-bird", "sharpness", "geo", "rarity", "stars"]}


def paths() -> dict[str, Path]:
    """role -> verified path; raises with the fetch command when anything is missing."""
    out, missing = {}, []
    for e in manifest()["file"]:
        p = locate(e)
        if p is None:
            missing.append(e["name"])
        else:
            out[e["role"]] = p
    if missing:
        raise FileNotFoundError(f"缺模型文件：{', '.join(missing)}。运行 `uv run birdcm models fetch` 下载。")
    return out


def digest() -> str:
    """The models' part of the result fingerprint: every manifest sha256."""
    return hashlib.sha256("|".join(sorted(e["sha256"] for e in manifest()["file"])).encode()).hexdigest()[:16]


def fetch(log=print) -> int:
    """Download every missing file to <cache>/models: stream to a .part file, check sha256, then rename."""
    dest = config.cache_dir() / "models"
    dest.mkdir(parents=True, exist_ok=True)
    failed = 0
    for e in manifest()["file"]:
        if locate(e):
            log(f"ok       {e['name']}")
            continue
        part = dest / (e["name"] + ".part")
        log(f"download {e['name']} ({e['bytes'] / 1e6:.0f} MB) <- {e['url']}")
        try:
            h = hashlib.sha256()
            with urllib.request.urlopen(e["url"], timeout=60) as r, open(part, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
                    h.update(chunk)
            if h.hexdigest() != e["sha256"]:
                raise ValueError(f"sha256 mismatch: {h.hexdigest()}")
            part.rename(dest / e["name"])
            log(f"ok       {e['name']}")
        except Exception as err:  # noqa: BLE001 - report and go on with the next file
            part.unlink(missing_ok=True)
            log(f"FAILED   {e['name']}: {err}")
            failed += 1
    return failed
