"""Online species reference (birdcm/online.py) over recorded answers: no live network here, every request goes to a stub
that fails the test on a URL it does not know. Fixtures (tests/fixtures/online/*.json: request URL, date, status,
headers, body) were recorded on 2026-11-18 from zh/en.wikipedia.org (text CC BY-SA 4.0, Wikipedia contributors) and
commons.wikimedia.org (file metadata); image bytes are made here, no third-party photo is committed."""
import io
import json
import urllib.error
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from birdcm import online
from birdcm.i18n import t

FX = Path(__file__).parent / "fixtures" / "online"
SPARROW = {"sci": "Passer domesticus", "wd_state": "exact-reviewed", "wd_qid": "Q14683", "inat_state": "exact-reviewed", "inat_id": 13858,
           "gbif_state": "exact-reviewed", "gbif_legacy_key": 5231190, "ebird_code": "houspa",
           "commons_file": "House Sparrow, England - May 09.jpg",
           "articles": {"zh": {"title": "家麻雀", "url": "https://zh.wikipedia.org/wiki/%E5%AE%B6%E9%BA%BB%E9%9B%80"},
                        "en": {"title": "House sparrow", "url": "https://en.wikipedia.org/wiki/House_sparrow"}}}


def fixture(name):
    return json.loads((FX / name).read_text())


def jpeg() -> bytes:
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (64, 48), (120, 90, 60)).save(b, "JPEG")
    return b.getvalue()


class Resp(io.BytesIO):
    def __init__(self, body: bytes, ctype: str):
        super().__init__(body)
        self.headers = {"Content-Type": ctype}


class Stub:
    """url -> fixture | bytes | exception; anything else fails the test."""

    def __init__(self):
        self.routes, self.calls = {}, []

    def __call__(self, req, timeout=None):
        url = req.full_url
        self.calls.append(url)
        for prefix, v in self.routes.items():
            if url.startswith(prefix):
                if isinstance(v, BaseException):
                    raise v
                if isinstance(v, bytes):
                    return Resp(v, "image/jpeg")
                if v["status"] != 200:
                    raise urllib.error.HTTPError(url, v["status"], "x", v.get("headers") or {}, None)
                return Resp(json.dumps(v["body"]).encode(), "application/json")
        pytest.fail(f"unexpected request {url}")


@pytest.fixture
def net(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    stub = Stub()
    monkeypatch.setattr(online.NET, "open", stub)
    monkeypatch.setattr(online.NET, "GAP", 0.0)
    monkeypatch.setattr(online.NET, "until", 0.0)
    monkeypatch.setattr(online, "mapping", lambda sci: {**SPARROW, "articles": dict(SPARROW["articles"])} if sci == SPARROW["sci"] else None)
    return stub


ZH = "https://zh.wikipedia.org/api/rest_v1/page/summary/"
EN = "https://en.wikipedia.org/api/rest_v1/page/summary/"


# ---- the mapping package --------------------------------------------------------------------------------------------
@pytest.mark.skipif(not online.MAP.is_file(), reason="data/species-map.sqlite not built")
def test_mapping_package():
    import sqlite3
    db = sqlite3.connect(online.MAP)
    n, keys = db.execute("SELECT COUNT(*), COUNT(DISTINCT sci) FROM species_map").fetchone()
    import csv
    avilist = {r["scientific"] for r in csv.DictReader(open(Path(online.__file__).with_name("data") / "ebird-names.csv", encoding="utf-8"))}
    assert n == keys == len(avilist) == 11172 and {r[0] for r in db.execute("SELECT sci FROM species_map")} == avilist
    m = online.mapping("Passer domesticus")
    assert m["wd_qid"] == "Q14683" and m["wd_state"] == "exact-reviewed" and m["articles"]["zh"]["title"] == "家麻雀"
    assert m["inat_id"] == 13858 and m["gbif_legacy_key"] == 5231190 and m["ebird_code"] == "houspa"
    assert online.mapping("Porphyrio porphyrio")["wd_state"] == "narrower"                 # a reviewed lump: no content
    assert online.mapping("Nothing here") is None
    # no accepted QID shared by two species, every accepted row has its QID, ids are empty outside accepted states
    assert not db.execute("SELECT wd_qid FROM species_map WHERE wd_state IN ('exact-reviewed','synonym-reviewed') "
                          "GROUP BY wd_qid HAVING COUNT(*) > 1").fetchall()
    assert not db.execute("SELECT 1 FROM species_map WHERE wd_state IN ('exact-reviewed','synonym-reviewed') AND wd_qid IS NULL").fetchall()
    assert not db.execute("SELECT 1 FROM species_map WHERE wd_state IN ('ambiguous','unmapped') AND wd_qid IS NOT NULL").fetchall()
    links = {x["name"]: x["url"] for x in online.links(m, "Passer domesticus")}
    assert links["eBird"] == "https://ebird.org/species/houspa" and links["Wikidata"].endswith("/Q14683")


def test_links_only_for_accepted_states():
    assert online.links(None, "x") == []
    m = {**SPARROW, "wd_state": "narrower", "inat_state": "ambiguous", "gbif_state": "unmapped"}
    assert [x["name"] for x in online.links(m, "x")] == ["Wikidata（来源分类与 AviList 不同）", "eBird"]   # eBird: the AviList code
    assert [x["name"] for x in online.links({**m, "wd_state": "ambiguous", "wd_qid": None}, "x")] == ["eBird"]


# ---- Wikipedia summary ----------------------------------------------------------------------------------------------
def test_summary_zh(net):
    net.routes[ZH] = fixture("zh-summary-passer-domesticus.json")
    c = online.card("summary", "Passer domesticus", network=True)
    assert c["state"] == "ok" and c["lang"] == "zh" and c["title"] == "家麻雀" and "麻雀属" in c["text"]
    assert c["licence"] == "CC BY-SA 4.0" and c["licence_url"].startswith("https://creativecommons.org/licenses/by-sa/4.0")
    assert c["revision"] == "87011385" and c["history_url"].endswith("action=history") and c["source_url"].startswith("https://zh.wikipedia.org/")
    assert "原文摘录" in c["changes"] and c["credit"] == "维基百科贡献者"
    assert net.calls == [ZH + "%E5%AE%B6%E9%BA%BB%E9%9B%80"]
    # cached: no second request, and offline reading gives the same card
    assert online.card("summary", "Passer domesticus", network=True)["state"] == "ok" and len(net.calls) == 1
    assert online.card("summary", "Passer domesticus", network=False)["text"] == c["text"]


def test_summary_missing_zh_falls_back_to_en_once(net, monkeypatch):
    monkeypatch.setattr(online, "mapping", lambda sci: {**SPARROW, "articles": {"en": SPARROW["articles"]["en"]}})
    net.routes[EN] = fixture("en-summary-passer-domesticus.json")
    c = online.card("summary", "Passer domesticus", network=True)
    assert c["state"] == "ok" and c["lang"] == "en" and c["text"].startswith("The house sparrow")
    assert all(u.startswith(EN) for u in net.calls) and len(net.calls) == 1


def test_summary_zh_404_then_en(net):
    net.routes[ZH] = fixture("zh-summary-404.json")
    net.routes[EN] = fixture("en-summary-passer-domesticus.json")
    c = online.card("summary", "Passer domesticus", network=True)
    assert c["state"] == "ok" and c["lang"] == "en" and len(net.calls) == 2


def test_summary_404_everywhere_is_negative_cached(net):
    net.routes[ZH] = fixture("zh-summary-404.json")
    net.routes[EN] = fixture("zh-summary-404.json")
    assert online.card("summary", "Passer domesticus", network=True)["state"] == "none"
    assert online.card("summary", "Passer domesticus", network=True)["state"] == "none" and len(net.calls) == 2   # a day
    online.card("summary", "Passer domesticus", network=True, force=True)                                         # a retry asks
    assert len(net.calls) == 4


def test_summary_wrong_item_or_disambiguation_is_not_this_species(net):
    net.routes[ZH] = fixture("zh-summary-404.json")
    net.routes[EN] = fixture("en-summary-swamphen-genus-redirect.json")        # the genus Porphyrio: another QID
    c = online.card("summary", "Passer domesticus", network=True)
    assert c["state"] == "none" and "不对应" in c["why"]
    d = fixture("en-summary-passer-domesticus.json")
    d["body"]["type"] = "disambiguation"
    net.routes[EN] = d
    assert online.card("summary", "Passer domesticus", network=True, force=True)["state"] == "none"


def test_summary_timeout_and_offline_cache_hit(net, monkeypatch):
    net.routes[ZH] = TimeoutError("timed out")
    c = online.card("summary", "Passer domesticus", network=True)
    assert c["state"] == "unavailable"
    assert online._read("summary", "Passer domesticus") is None              # a timeout is not cached as "absent"
    net.routes[ZH] = fixture("zh-summary-passer-domesticus.json")
    assert online.card("summary", "Passer domesticus", network=True)["state"] == "ok"
    # a month later, offline: the cached copy, marked stale with its date
    import time
    real = time.time
    monkeypatch.setattr(online.time, "time", lambda: real() + 31 * 86400)
    net.routes[ZH] = urllib.error.URLError("offline")
    c = online.card("summary", "Passer domesticus", network=True)
    assert c["state"] == "stale" and c["problem"] == "unavailable" and c["text"] and c["cached_at"]
    # half a year later the text is no longer shown, only the link
    monkeypatch.setattr(online.time, "time", lambda: real() + 181 * 86400)
    c = online.card("summary", "Passer domesticus", network=False)
    assert c["state"] == "stale" and "text" not in c and c["source_url"]


def test_summary_429_cools_down(net):
    net.routes[ZH] = urllib.error.HTTPError(ZH, 429, "busy", {"Retry-After": "120"}, None)
    assert online.card("summary", "Passer domesticus", network=True)["state"] == "busy"
    n = len(net.calls)
    assert online.card("summary", "Passer domesticus", network=True)["state"] == "busy" and len(net.calls) == n   # not asked again


def test_unmapped_species_never_asks(net):
    assert online.card("summary", "Nothing here", network=True)["state"] == "unmapped"
    assert online.card("image", "Nothing here", network=True)["state"] == "unmapped"
    assert net.calls == []


def test_hosts_are_fixed(net):
    with pytest.raises(ValueError):
        online.NET.get("https://evil.example/x", 100)
    with pytest.raises(ValueError):
        online.NET.get("http://zh.wikipedia.org/x", 100)


# ---- licence gate and the Commons image -------------------------------------------------------------------------------
BASE = {"Artist": '<a href="//commons.wikimedia.org/wiki/User:X">X</a>', "Restrictions": "", "LicenseUrl": ""}


@pytest.mark.parametrize("code,ok,name,nc", [
    ("cc0", True, "CC0 1.0", False),
    ("cc-by-4.0", True, "CC BY 4.0", False),
    ("cc-by-sa-3.0", True, "CC BY-SA 3.0", False),
    ("cc-by-sa-3.0-de", True, "CC BY-SA 3.0", False),
    ("cc-by-nc-4.0", True, "CC BY-NC 4.0", True),
    ("cc-by-nc-sa-2.0", True, "CC BY-NC-SA 2.0", True),
    ("cc-by-nd-4.0", False, None, None),
    ("cc-by-nc-nd-4.0", False, None, None),
    ("cc-by-sa", False, None, None),                 # no version
    ("pd", False, None, None),
    ("gfdl", False, None, None),
    ("", False, None, None),
])
def test_licence_gate(code, ok, name, nc):
    got, info = online.licence({**BASE, "License": code})
    assert got is ok
    if ok:
        assert info["licence"] == name and info["nc"] is nc and info["author"] == "X" and info["licence_url"].startswith("https://creativecommons.org/")


def test_licence_gate_refuses_restricted_nonfree_deleted_or_anonymous():
    assert not online.licence({**BASE, "License": "cc-by-4.0", "Restrictions": "personality"})[0]
    assert not online.licence({**BASE, "License": "cc-by-4.0", "NonFree": "true"})[0]
    assert not online.licence({**BASE, "License": "cc-by-4.0", "DeletionReason": "copyvio"})[0]
    assert not online.licence({**BASE, "License": "cc-by-4.0", "Artist": "<span> </span>"})[0]
    assert online.licence({**BASE, "License": "cc-by-4.0", "Artist": "<script>x</script>A &amp; B"})[1]["author"] == "xA & B"


COMMONS = "https://commons.wikimedia.org/w/api.php"
THUMB = "https://thumb.wikimedia.org/"


@pytest.mark.parametrize("artist,author", [
    ("Salvadori, 1876", None), ("(Linnaeus, 1758)", None), ("Gould & Sharpe, 1880", None), ("<span> </span>", None),
    ("Diliff", "Diliff"), ('<a href="//commons.wikimedia.org/wiki/User:X">JJ Harrison</a> (https://www.jjharrison.com.au/)',
                           "JJ Harrison (https://www.jjharrison.com.au/)"), ("Ernst Haeckel 1904", "Ernst Haeckel 1904"),
])
def test_author_is_not_a_taxon_authority(artist, author):
    assert online._author({"Artist": artist}) == author
    assert online._author({"Artist": artist, "Attribution": "<b>Photo by Y</b>"}) == "Photo by Y"    # the required credit line wins


def authority_fixture(licence_code=None):
    f = fixture("commons-imageinfo-authority-as-artist.json")      # Naturalis specimen photo: Artist "Salvadori, 1876", CC0
    if licence_code:
        f["body"]["query"]["pages"][0]["imageinfo"][0]["extmetadata"]["License"]["value"] = licence_code
    return f


def test_cc0_with_authority_as_artist_points_to_the_file_page(net):
    net.routes[COMMONS] = authority_fixture()
    net.routes[THUMB] = jpeg()
    c = online.card("image", "Passer domesticus", network=True)
    assert c["state"] == "ok" and c["licence"] == "CC0 1.0" and c["author"] is None
    assert c["credit"] == "Naturalis Biodiversity Center" and c["source_url"].startswith("https://commons.wikimedia.org/wiki/File:")


def test_attribution_licence_with_authority_as_artist_is_refused(net):
    net.routes[COMMONS] = authority_fixture("cc-by-4.0")
    c = online.card("image", "Passer domesticus", network=True)
    assert c["state"] == "none" and "作者" in c["why"] and online.cached_file("Passer domesticus") is None
    f = authority_fixture("cc-by-sa-3.0")
    f["body"]["query"]["pages"][0]["imageinfo"][0]["extmetadata"]["Artist"]["value"] = ""
    net.routes[COMMONS] = f
    assert online.card("image", "Passer domesticus", network=True, force=True)["state"] == "none"


def test_disclosure_names_only_what_is_built():
    assert "地区包" not in t(online.DISCLOSURE) and "不会发送你的照片" in t(online.DISCLOSURE)


def test_image_rendition_404_is_absent(net):
    net.routes[COMMONS] = fixture("commons-imageinfo-cc-by-sa.json")
    net.routes[THUMB] = urllib.error.HTTPError(THUMB, 404, "not found", {}, None)
    c = online.card("image", "Passer domesticus", network=True)
    assert c["state"] == "none" and online._read("image", "Passer domesticus")["state"] == "none"


def test_image_entry_without_its_file_is_fetched_again(net):
    net.routes[COMMONS] = fixture("commons-imageinfo-cc-by-sa.json")
    net.routes[THUMB] = jpeg()
    online.card("image", "Passer domesticus", network=True)
    online.cached_file("Passer domesticus")[0].unlink()
    assert online.card("image", "Passer domesticus", network=False)["state"] == "missing"
    assert online.card("image", "Passer domesticus", network=True)["state"] == "ok" and online.cached_file("Passer domesticus")


def test_image_ok_cached_and_served(net):
    net.routes[COMMONS] = fixture("commons-imageinfo-cc-by-sa.json")
    net.routes[THUMB] = jpeg()
    c = online.card("image", "Passer domesticus", network=True)
    assert c["state"] == "ok" and c["licence"] == "CC BY-SA 3.0" and c["author"] == "Diliff" and not c["nc"]
    assert c["source_url"] == "https://commons.wikimedia.org/wiki/File:House_Sparrow,_England_-_May_09.jpg" and "blob" not in c
    p, mime = online.cached_file("Passer domesticus")
    assert p.read_bytes()[:2] == b"\xff\xd8" and mime == "image/jpeg"


def test_image_refused_licence_writes_no_file(net):
    f = fixture("commons-imageinfo-cc-by-sa.json")
    f["body"]["query"]["pages"][0]["imageinfo"][0]["extmetadata"]["License"]["value"] = "cc-by-nd-4.0"
    net.routes[COMMONS] = f
    c = online.card("image", "Passer domesticus", network=True)
    assert c["state"] == "none" and "暂无可用的授权参考图" in c["why"]
    assert not any(u.startswith(THUMB) for u in net.calls) and online.cached_file("Passer domesticus") is None


def test_cache_cap_drops_images_first(net):
    net.routes[COMMONS] = fixture("commons-imageinfo-cc-by-sa.json")
    net.routes[THUMB] = jpeg()
    net.routes[ZH] = fixture("zh-summary-passer-domesticus.json")
    online.card("image", "Passer domesticus", network=True)
    online.card("summary", "Passer domesticus", network=True)
    d = online._dir()
    online.prune(cap=sum(p.stat().st_size for p in d.iterdir() if p.suffix != ".img"))   # room for everything but the image
    assert online.cached_file("Passer domesticus") is None and online._read("summary", "Passer domesticus")


# ---- the API ----------------------------------------------------------------------------------------------------------
def test_api_settings_and_reference(net, tmp_path):
    from birdcm.app import create_app
    from birdcm.store import Store
    from test_queue import FakeEngine
    guarded, _ = create_app(8799, token="tok", store=Store(tmp_path / "t.db"), engine_factory=FakeEngine, start_scheduler=False)
    c = TestClient(guarded, base_url="http://127.0.0.1:8799")
    h, w = {"host": "127.0.0.1:8799"}, {"host": "127.0.0.1:8799", "x-birdcm-token": "tok"}
    s = c.get("/api/online/settings", headers=h).json()
    assert s["enabled"] is True and s["disclosed"] is False and "不会发送你的照片" in s["disclosure"]
    net.routes[ZH] = fixture("zh-summary-passer-domesticus.json")
    net.routes[COMMONS] = fixture("commons-imageinfo-cc-by-sa.json")
    net.routes[THUMB] = jpeg()
    r = c.get("/api/species/reference?sci=Passer%20domesticus", headers=h).json()
    assert r["summary"]["state"] == "missing" and r["image"]["state"] == "missing" and net.calls == []   # GET never asks
    assert c.post("/api/species/reference", json={"sci": "Passer domesticus"}, headers=h).status_code == 403
    r = c.post("/api/species/reference", json={"sci": "Passer domesticus"}, headers=w).json()
    assert r["summary"]["state"] == "ok" and r["image"]["state"] == "ok" and any(x["name"] == "eBird" for x in r["links"])
    assert c.get("/api/species/reference/image?sci=Passer%20domesticus", headers=h).content[:2] == b"\xff\xd8"
    # off: no request, the cache is still read
    assert c.post("/api/online/settings", json={"enabled": False, "disclosed": True}, headers=w).json()["enabled"] is False
    n = len(net.calls)
    r = c.post("/api/species/reference", json={"sci": "Passer domesticus", "force": True}, headers=w).json()
    assert r["summary"]["state"] == "ok" and len(net.calls) == n
    assert c.delete("/api/online/cache", headers=w).json()["deleted_bytes"] > 0
    r = c.post("/api/species/reference", json={"sci": "Passer domesticus"}, headers=w).json()
    assert r["summary"]["state"] == "off" and len(net.calls) == n
    assert c.get("/api/species/reference/image?sci=Passer%20domesticus", headers=h).status_code == 404
