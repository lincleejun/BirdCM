"""Online species reference: the Wikipedia summary and one Commons reference image of a species, fetched on demand by
the engine and cached on disk (docs/design-species-search.md §4–§9 and the owner decisions of 2026-11-18: online on by
default and only when needed, the first use shows the disclosure, no translation, NC images allowed but labelled).

Only ids and titles from the bundled mapping (data/species-map.sqlite, tools/build_species_map.py) leave the machine:
a species with no accepted mapping gets nothing, nothing is guessed. Never photos, paths, places or typed text (place
names are places.py: rounded coordinates to OpenStreetMap Nominatim, its own setting in the same file; the update check
is update.py: one bare GET to api.github.com, off by default, its own setting in the same file). The browser only
talks to the engine; this module only talks to a fixed set of Wikimedia hosts.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from functools import cache
from pathlib import Path

from birdcm import config
from birdcm.i18n import R, t, text
from birdcm.i18n import lang as ui_lang

# BIRDCM_SPECIES_MAP, else the source checkout's data/, else the Mac app's Resources/engine/data/ (macos/build.sh copies
# it there; the bundled interpreter is Resources/engine/python, so sys.prefix's parent is Resources/engine)
MAP = Path(os.environ.get("BIRDCM_SPECIES_MAP") or next(
    (p for p in (Path(__file__).resolve().parents[2] / "data" / "species-map.sqlite",
                 Path(sys.prefix).resolve().parent / "data" / "species-map.sqlite") if p.is_file()),
    Path(__file__).resolve().parents[2] / "data" / "species-map.sqlite"))
UA = "BirdCM/0.1 (https://github.com/lincleejun/BirdCM; open-source local bird photo app)"
HOSTS = {"zh.wikipedia.org", "en.wikipedia.org", "commons.wikimedia.org", "upload.wikimedia.org", "thumb.wikimedia.org"}
ACCEPT = {"exact-reviewed", "synonym-reviewed"}
DAY = 86400
FRESH, TEXT_MAX, NEGATIVE = 30 * DAY, 180 * DAY, DAY        # design §6.2
CACHE_CAP = 500 << 20                                         # desktop engine: all online content, images first to go
MAX_JSON, MAX_IMAGE = 1 << 20, 2 << 20
TIMEOUT, DEADLINE = 3.0, 8.0                                  # per socket operation / per item
BY_SA = "https://creativecommons.org/licenses/by-sa/4.0/"

DISCLOSURE = "online.disclosure"                                # i18n key


# ---- the mapping ------------------------------------------------------------------------------------------------------
@cache
def _db() -> sqlite3.Connection | None:
    if not MAP.is_file():
        return None
    con = sqlite3.connect(f"{MAP.as_uri()}?mode=ro&immutable=1", uri=True, check_same_thread=False)
    con.row_factory = sqlite3.Row
    return con


def mapping(sci: str) -> dict | None:
    """The species' row with its articles {lang: {title, url}}; None when the package or the species is missing."""
    db = _db()
    if db is None:
        return None
    r = db.execute("SELECT * FROM species_map WHERE sci = ?", (sci,)).fetchone()
    if r is None:
        return None
    arts = {a["lang"]: {"title": a["title"], "url": f"https://{a['lang']}.wikipedia.org/wiki/" + urllib.parse.quote(a["title"].replace(" ", "_"))}
            for a in db.execute("SELECT * FROM article WHERE sci = ?", (sci,))}
    return {**dict(r), "articles": arts}


def links(m: dict | None, sci: str) -> list[dict]:
    """Verified deep links only (an accepted state, or the AviList Cornell code for eBird); the page adds the generic
    entrances itself."""
    if not m:
        return []
    out = []
    if m["wd_state"] in ACCEPT:
        for lang, name in (("zh", t("online.wiki_zh")), ("en", "Wikipedia (English)")):
            if lang in m["articles"]:
                out.append({"name": name, "url": m["articles"][lang]["url"]})
        out.append({"name": "Wikidata", "url": f"https://www.wikidata.org/wiki/{m['wd_qid']}"})
    elif m["wd_qid"]:                                  # broader / narrower / split-lump: only the source, said to differ
        out.append({"name": t("online.wikidata_differs"), "url": f"https://www.wikidata.org/wiki/{m['wd_qid']}"})
    if m["inat_state"] in ACCEPT and m["inat_id"]:
        out.append({"name": "iNaturalist", "url": f"https://www.inaturalist.org/taxa/{m['inat_id']}"})
    if m["gbif_state"] in ACCEPT and m["gbif_legacy_key"]:
        out.append({"name": "GBIF", "url": f"https://www.gbif.org/species/{m['gbif_legacy_key']}"})
    if m["ebird_code"]:
        out.append({"name": "eBird", "url": f"https://ebird.org/species/{m['ebird_code']}"})
    return out


# ---- settings (this machine only) -------------------------------------------------------------------------------------
def _settings_path() -> Path:
    return config.data_dir() / "online.json"


def settings() -> dict:
    """enabled: online species reference; places: 用网络显示地名 (places.py); updates: 检查更新 (update.py), off by default."""
    try:
        s = json.loads(_settings_path().read_text())
    except (OSError, ValueError):
        s = {}
    return {"enabled": bool(s.get("enabled", True)), "disclosed": bool(s.get("disclosed", False)),
            "places": bool(s.get("places", True)), "updates": bool(s.get("updates", False)), "disclosure": t(DISCLOSURE)}


def set_settings(enabled: bool | None = None, disclosed: bool | None = None, places: bool | None = None,
                 updates: bool | None = None) -> dict:
    s = {k: v for k, v in settings().items() if k != "disclosure"}
    for k, v in (("enabled", enabled), ("disclosed", disclosed), ("places", places), ("updates", updates)):
        if v is not None:
            s[k] = v
    p = _settings_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(s))
    return settings()


# ---- the network: fixed hosts, shared pace, Retry-After, size caps ----------------------------------------------------
class Offline(Exception):
    """No answer: offline, DNS, TLS, timeout, a 5xx. Not cached as "absent"."""


class Busy(Exception):
    """429 / 503 with Retry-After: the source asks us to slow down."""


class NotFound(Exception):
    """404: cached as absent for a day."""


class _Guard(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        u = urllib.parse.urlsplit(newurl)
        if u.scheme != "https" or u.hostname not in HOSTS:
            raise Offline(f"refused redirect to {u.hostname}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Net:
    """All Wikimedia requests: at most 2 at a time and one start every 2 s (30 a minute, design §2.1), a cool-down
    after 429 / 503 (Retry-After, else 5 s, 15 s, 60 s)."""

    GAP, BACKOFF = 2.0, (5, 15, 60)

    def __init__(self) -> None:
        self.slots, self.lock = threading.Semaphore(2), threading.Lock()
        self.last, self.until, self.strikes = 0.0, 0.0, 0
        self.open = urllib.request.build_opener(_Guard()).open      # tests replace this

    def get(self, url: str, limit: int, accept: str = "application/json", headers: dict | None = None) -> tuple[bytes, dict]:
        u = urllib.parse.urlsplit(url)
        if u.scheme != "https" or u.hostname not in HOSTS:
            raise ValueError(f"host not allowed: {u.hostname}")
        with self.lock:
            if time.monotonic() < self.until:
                raise Busy(self.until - time.monotonic())
            wait = self.GAP - (time.monotonic() - self.last)
            self.last = time.monotonic() + max(0.0, wait)
        if wait > 0:
            time.sleep(wait)
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept, **(headers or {})})
        start = time.monotonic()
        with self.slots:
            try:
                with self.open(req, timeout=TIMEOUT) as r:
                    body = bytearray()
                    while chunk := r.read(65536):
                        body += chunk
                        if len(body) > limit:
                            raise Offline("response too large")
                        if time.monotonic() - start > DEADLINE:
                            raise Offline("timeout")
                    self.strikes = 0
                    return bytes(body), {k.lower(): v for k, v in r.headers.items()}
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    raise NotFound() from None
                if e.code in (429, 503):
                    try:
                        delay = float(e.headers.get("Retry-After"))
                    except (TypeError, ValueError):
                        delay = self.BACKOFF[min(self.strikes, 2)]
                    with self.lock:
                        self.strikes += 1
                        self.until = time.monotonic() + delay
                    raise Busy(delay) from None
                raise Offline(f"HTTP {e.code}") from None
            except (urllib.error.URLError, OSError, TimeoutError) as e:
                raise Offline(str(getattr(e, "reason", e))) from None


NET = Net()


# ---- the cache: one JSON entry per (kind, species), image bytes beside it ---------------------------------------------
def _dir() -> Path:
    return config.cache_dir() / "online"


def _key(kind: str, sci: str) -> Path:
    return _dir() / f"{kind}-{hashlib.sha1(sci.encode()).hexdigest()[:20]}"


def _read(kind: str, sci: str) -> dict | None:
    try:
        e = json.loads(_key(kind, sci).with_suffix(".json").read_text())
    except (OSError, ValueError):
        return None                                   # missing or damaged: fetched again
    return e if e.get("sci") == sci else None


def _write(kind: str, sci: str, entry: dict, blob: bytes | None = None) -> None:
    """Atomic: the image first, then the entry that points at it; a full disk leaves the old entry."""
    d = _dir()
    d.mkdir(parents=True, exist_ok=True)
    base = _key(kind, sci)
    try:
        if blob is not None:
            tmp = base.with_suffix(".tmp")
            tmp.write_bytes(blob)
            os.replace(tmp, base.with_suffix(".img"))
        tmp = base.with_suffix(".jtmp")
        tmp.write_text(json.dumps({**entry, "sci": sci}, ensure_ascii=False))
        os.replace(tmp, base.with_suffix(".json"))
    except OSError:
        return
    prune()


def prune(cap: int = CACHE_CAP) -> None:
    """Keep the online cache under cap: oldest images go first, then the oldest entries (with their image)."""
    d = _dir()
    if not d.is_dir():
        return
    files = [(p, p.stat()) for p in d.iterdir() if p.is_file()]
    total = sum(s.st_size for _, s in files)
    if total <= cap:
        return
    for p, s in sorted(files, key=lambda x: (x[0].suffix != ".img", x[1].st_mtime)):
        if total <= cap:
            break
        p.unlink(missing_ok=True)
        total -= s.st_size
        if p.suffix == ".json":
            p.with_suffix(".img").unlink(missing_ok=True)


def clear() -> int:
    d, n = _dir(), 0
    if d.is_dir():
        for p in d.iterdir():
            n += p.stat().st_size
            p.unlink(missing_ok=True)
    return n


def cached_file(sci: str) -> tuple[Path, str] | None:
    """The cached reference image and its type, only while its entry still passes the licence gate."""
    e = _read("image", sci)
    p = _key("image", sci).with_suffix(".img")
    if not e or e.get("state") != "ok" or not licence(e.get("meta") or {})[0] or not p.is_file():
        return None
    return p, e.get("mime") or "image/jpeg"


# ---- cards ------------------------------------------------------------------------------------------------------------
_inflight: dict[tuple, threading.Lock] = {}
_inflight_lock = threading.Lock()


def card(kind: str, sci: str, network: bool, force: bool = False) -> dict:
    """The card's state from the cache, refreshed from the source when network is allowed and the entry is missing or
    stale (or force: a person's retry, which also skips the one-day negative cache). States: ok / stale (cached copy,
    the source could not be asked) / none (no article or no allowed image, with why) / unmapped / off / unavailable /
    busy; missing = not cached and not asked (due: the page may ask for a refresh). A card never fails the request:
    errors become states."""
    m = mapping(sci)
    if kind == "summary" and ui_lang() == "en":                 # the English page: the English article first, cached apart
        kind = "summary-en"
    if m is None or m["wd_state"] not in ACCEPT:
        why = (t("online.unmapped") if m is None else
               t("online.taxonomy_differs", note=m["wd_note"] or m["wd_state"]) if m["wd_state"] in ("broader", "narrower", "split-lump")
               else t("online.unverified"))
        return {"state": "unmapped", "why": why}
    with _inflight_lock:
        lock = _inflight.setdefault((kind, sci), threading.Lock())
    with lock:                                         # one fetch per species and kind, however many requests ask
        e = _read(kind, sci)
        if e and kind == "image" and e["state"] == "ok" and not _key(kind, sci).with_suffix(".img").is_file():
            e = None                                   # the image went (cache cap, clean-up): fetch it again
        age = time.time() - e["fetched"] if e else None
        due = e is None or (age > (NEGATIVE if e["state"] == "none" else FRESH)) or force
        if network and due:
            try:
                e = _image(sci, m) if kind == "image" else _summary(sci, m, en_first=kind == "summary-en")
                _write(kind, sci, e, e.pop("blob", None))
                age = 0
            except NotFound:                           # e.g. the file's rendition is gone: absent for a day
                e, age = {"state": "none", "fetched": time.time(), "why": R("online.file_gone")}, 0
                _write(kind, sci, e)
            except Busy:
                return _shown(e, age, "busy")
            except Offline:
                return _shown(e, age, "unavailable")
        if e is None:
            return {"state": "missing" if not network else "unavailable", "due": True}
        return {**_shown(e, age, None), "due": due and not network}


def _shown(e: dict | None, age: float | None, problem: str | None) -> dict:
    if e is None:
        return {"state": problem or "unavailable"}
    out = {k: text(v) if k in ("why", "credit", "changes") else v for k, v in e.items() if k not in ("sci", "meta")}
    out["cached_at"] = time.strftime("%Y-%m-%d", time.localtime(e["fetched"]))
    if e["state"] == "ok" and age is not None and age > FRESH:
        out["state"] = "stale"
    if e["state"] == "ok" and "text" in e and age is not None and age > TEXT_MAX:
        return {"state": "stale", "why": t("online.text_old"), "source_url": e.get("source_url"), "cached_at": out["cached_at"]}
    if problem:
        out["problem"] = problem
        if e["state"] == "ok":
            out["state"] = "stale"
    return out


# ---- Wikipedia summary --------------------------------------------------------------------------------------------------
def _summary(sci: str, m: dict, en_first: bool = False) -> dict:
    """zh article first (its zh-Hans variant), then en (en_first: the English page), no translation. A disambiguation page or one whose Wikidata
    item is not the mapped QID is not this species' summary."""
    why = R("online.no_article")
    for lang in ("en", "zh") if en_first else ("zh", "en"):
        a = m["articles"].get(lang)
        if not a:
            continue
        url = f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{urllib.parse.quote(a['title'].replace(' ', '_'), safe='')}"
        try:
            body, _ = NET.get(url, MAX_JSON, headers={"Accept-Language": "zh-cn"} if lang == "zh" else None)
        except NotFound:
            why = R("online.article_gone", lang=lang)
            continue
        try:
            s = json.loads(body)
            text = s["extract"].strip()
        except (ValueError, KeyError, TypeError, AttributeError):
            raise Offline("malformed summary") from None
        if s.get("type") == "disambiguation" or s.get("wikibase_item") != m["wd_qid"] or not text:
            why = R("online.article_wrong", lang=lang)
            continue
        page = (s.get("content_urls") or {}).get("desktop") or {}
        return {"state": "ok", "fetched": time.time(), "lang": lang, "title": _plain(s.get("displaytitle") or "") or s.get("title") or a["title"], "text": text,
                "source_url": page.get("page") or a["url"], "history_url": page.get("revisions"),
                "revision": s.get("revision"), "licence": "CC BY-SA 4.0", "licence_url": BY_SA,
                "credit": R("online.credit_wiki"), "changes": R("online.changes_extract_zh" if lang == "zh" else "online.changes_extract")}
    return {"state": "none", "fetched": time.time(), "why": why}


# ---- Commons reference image ------------------------------------------------------------------------------------------
_CC = re.compile(r"^cc-by(?P<nc>-nc)?(?P<sa>-sa)?-(?P<v>\d\.\d)(-[a-z]{2,3})?$")


def _plain(v: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", v or "")).strip()


_AUTHORITY = re.compile(r"^\(?\s*[^\d()]+,\s*\d{4}\s*\)?$")      # "Salvadori, 1876", "(Linnaeus, 1758)": a taxon authority


def _author(meta: dict) -> str | None:
    """Who to credit, from the Commons fields as plain text: Attribution (the author's own required credit line) first,
    then Artist. An empty Artist, or one that is a taxonomic authority citation (Commons often fills Artist from the
    species name of a specimen photo), is not an author: None."""
    att = _plain(meta.get("Attribution") or "")
    if att:
        return att
    a = _plain(meta.get("Artist") or "")
    return None if not a or _AUTHORITY.match(a) else a


def licence(meta: dict) -> tuple[bool, dict | str]:
    """The per-file licence gate (design §7, owner decision on NC): CC0, CC BY, CC BY-SA with a version pass; CC BY-NC
    (-SA) pass labelled nc; ND, public domain without a verified basis, GFDL-only, unknown, version-less, non-free,
    restricted, being deleted, or (unless CC0) without a reliable author do not. meta = Commons extmetadata (values, not {value: ...})."""
    code = (meta.get("License") or "").strip().lower()
    if str(meta.get("NonFree", "")).lower() in ("true", "1"):
        return False, R("online.non_free")
    if (meta.get("DeletionReason") or "").strip():
        return False, R("online.deletion")
    if _plain(meta.get("Restrictions") or ""):
        return False, R("online.restricted")
    author = _author(meta)
    url = (meta.get("LicenseUrl") or "").strip()
    if code == "cc0":                 # no attribution required: without a reliable author the page points to the file page
        return True, {"licence": "CC0 1.0", "licence_url": url or "https://creativecommons.org/publicdomain/zero/1.0/", "nc": False, "author": author}
    if not author:
        return False, R("online.no_author")
    m = _CC.match(code)
    if not m or "-nd" in code:
        return False, R("online.licence", name=meta.get("LicenseShortName") or code or R("online.unknown"))
    name = "CC BY" + ("-NC" if m["nc"] else "") + ("-SA" if m["sa"] else "") + f" {m['v']}"
    path = "by" + ("-nc" if m["nc"] else "") + ("-sa" if m["sa"] else "")
    return True, {"licence": name, "licence_url": url or f"https://creativecommons.org/licenses/{path}/{m['v']}/", "nc": bool(m["nc"]),
                  "author": author}


def _image(sci: str, m: dict) -> dict:
    """The Commons file the build chose (Wikidata P18), its metadata, the licence gate, then the 640 px rendition."""
    f = m.get("commons_file")
    if not f:
        return {"state": "none", "fetched": time.time(), "why": R("online.no_wikidata_image")}
    q = urllib.parse.urlencode({"action": "query", "prop": "imageinfo", "titles": f"File:{f}", "format": "json", "formatversion": 2,
                                "iiprop": "url|extmetadata|sha1|mime|size", "iiurlwidth": 640,
                                "iiextmetadatafilter": "Artist|Credit|Attribution|LicenseShortName|License|LicenseUrl|UsageTerms|"
                                                       "Restrictions|NonFree|DeletionReason|ObjectName"})
    body, _ = NET.get(f"https://commons.wikimedia.org/w/api.php?{q}", MAX_JSON)
    try:
        page = json.loads(body)["query"]["pages"][0]
        info = page["imageinfo"][0]
    except (ValueError, KeyError, IndexError, TypeError):
        return {"state": "none", "fetched": time.time(), "why": R("online.no_commons_file")}
    meta = {k: (v or {}).get("value", "") for k, v in (info.get("extmetadata") or {}).items()}
    ok, lic = licence(meta)
    if not ok:
        return {"state": "none", "fetched": time.time(), "why": R("online.no_licensed_image", why=lic), "source_url": info.get("descriptionurl")}
    thumb = info.get("thumburl") or ""
    if not info.get("mime", "").startswith("image/") or urllib.parse.urlsplit(thumb).hostname not in HOSTS:
        return {"state": "none", "fetched": time.time(), "why": R("online.no_licensed_image", why=R("online.not_image"))}
    blob, h = NET.get(thumb, MAX_IMAGE, accept="image/*")
    if not h.get("content-type", "").startswith("image/"):
        raise Offline("not an image")
    return {"state": "ok", "fetched": time.time(), "file": f, "source_url": info.get("descriptionurl"), **lic,
            "credit": _plain(meta.get("Credit") or ""), "attribution": _plain(meta.get("Attribution") or ""),
            "width": info.get("thumbwidth"), "height": info.get("thumbheight"), "mime": h.get("content-type"),
            "changes": R("online.changes_scaled"), "meta": meta, "blob": blob}
