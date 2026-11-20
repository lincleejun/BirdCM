"""Update check (R7): off by default (online.json "updates", the same file as the other network switches). When on, at
most one GET a day to GitHub's public API for the latest release tag of this repository; the request carries nothing
about the person or this install (no cookie, no id, no current version; the fixed User-Agent of online.py). GitHub's
/releases/latest skips drafts and prereleases, so beta / rc are never offered. Any failure is silent: no notice. The
page links to the Releases page; nothing is downloaded or installed.
"""
from __future__ import annotations

import json
import re
import time
import urllib.request
from importlib import metadata

from birdcm import config, online

LATEST = "https://api.github.com/repos/lincleejun/BirdCM/releases/latest"
RELEASES = "https://github.com/lincleejun/BirdCM/releases"
TAG = re.compile(r"^release/v(\d+)\.(\d+)\.(\d+)$")
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(.*)$")       # 0.0.2, 0.0.2b0 (pyproject's -beta as uv/Python records it)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a):
        return None                                     # a 3xx becomes an HTTPError: no answer


fetch = urllib.request.build_opener(_NoRedirect()).open  # tests replace this


def current() -> str | None:
    try:
        return metadata.version("birdcm")
    except metadata.PackageNotFoundError:
        return None


def newer(latest: str | None, cur: str | None) -> bool:
    """latest is a release x.y.z; cur may be a prerelease, which is older than the same x.y.z."""
    a, b = latest and VERSION.match(latest), cur and VERSION.match(cur)
    if not a or not b or a[4]:
        return False
    return (*map(int, a.groups()[:3]), 1) > (*map(int, b.groups()[:3]), 0 if b[4] else 1)


def _ask() -> str | None:
    req = urllib.request.Request(LATEST, headers={"User-Agent": online.UA, "Accept": "application/vnd.github+json"})
    try:
        with fetch(req, timeout=online.TIMEOUT) as r:
            m = TAG.match(str(json.loads(r.read(online.MAX_JSON))["tag_name"]))
    except Exception:                                   # offline, rate limit, 404, a body we cannot read: silent
        return None
    return ".".join(m.groups()) if m else None


def check() -> dict:
    """{current, latest, newer, url}. Off: nothing asked. On: the cached answer (a failure counts) when under a day old."""
    cur = current()
    out = {"current": cur, "latest": None, "newer": False, "url": RELEASES}
    if not online.settings()["updates"]:
        return out
    p = config.cache_dir() / "update.json"
    try:
        e = json.loads(p.read_text())
        if not 0 <= time.time() - float(e["checked"]) < online.DAY:
            raise ValueError("stale")
    except (OSError, ValueError, KeyError, TypeError):
        e = {"checked": time.time(), "latest": _ask()}
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(e))
        except OSError:
            pass
    return {**out, "latest": e.get("latest"), "newer": newer(e.get("latest"), cur)}
