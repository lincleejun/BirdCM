"""Where BirdCM keeps its own files, and the one rule about them: never inside a photo folder.

BIRDCM_DATA_DIR  (default ~/Library/Application Support/BirdCM): the SQLite database.
BIRDCM_CACHE_DIR (default ~/Library/Caches/BirdCM): thumbnails, previews, downloaded models (models/).
BIRDCM_MODEL_DIR: extra directories (os.pathsep separated) searched for model files before the cache.
"""
from __future__ import annotations

import os
from pathlib import Path

HOME = Path.home()


def _dir(env: str, default: Path) -> Path:
    return Path(os.environ.get(env) or default).expanduser().resolve()


def data_dir() -> Path:
    return _dir("BIRDCM_DATA_DIR", HOME / "Library" / "Application Support" / "BirdCM")


def cache_dir() -> Path:
    return _dir("BIRDCM_CACHE_DIR", HOME / "Library" / "Caches" / "BirdCM")


def model_dirs() -> list[Path]:
    extra = [Path(p).expanduser().resolve() for p in os.environ.get("BIRDCM_MODEL_DIR", "").split(os.pathsep) if p]
    return [*extra, cache_dir() / "models"]


def inside(child: Path, parent: Path) -> bool:
    return child == parent or parent in child.parents


def check_own_dirs(folder: str | Path) -> None:
    """Refuse a photo folder that contains our data or cache directory (we would write into it)."""
    f = Path(folder).expanduser().resolve()
    for d in (data_dir(), cache_dir()):
        if inside(d, f):
            raise ValueError(f"数据或缓存目录 {d} 在照片文件夹 {f} 里面；请用 BIRDCM_DATA_DIR / BIRDCM_CACHE_DIR 换到别处")
