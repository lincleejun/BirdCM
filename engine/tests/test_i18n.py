"""R8: the engine's text in English has no Chinese (bird names aside), and the two languages stay one table."""
import re
import string
from pathlib import Path

from fastapi.testclient import TestClient

from birdcm import i18n, names, stars
from birdcm.app import create_app
from birdcm.i18n import MSG, R, text
from birdcm.store import Store
from test_corrections import CAT, PORT
from test_queue import FakeEngine
from test_select import photo

CJK = re.compile(r"[　-〿一-鿿＀-￯]")
SRC = Path(__file__).resolve().parents[1] / "birdcm"
EN = {"accept-language": "en-US,en;q=0.9"}


def fields(s: str) -> set[str]:
    return {f for _, f, _, _ in string.Formatter().parse(s) if f}


def test_one_table_both_languages_same_parameters():
    for k, (zh, en) in MSG.items():
        assert zh and en and fields(zh) == fields(en), k
        assert not CJK.search(en), k


def test_every_key_used_exists_and_every_key_is_used():
    src = "\n".join(p.read_text() for p in SRC.glob("*.py") if p.name != "i18n.py")
    areas = {k.split(".")[0] for k in MSG}
    used = set(re.findall(r"""["']((?:%s)\.[a-z0-9_]+)["']""" % "|".join(areas), src)) | {"stars.unnamed"}   # that one: i18n._param
    used -= {"models.toml", "online.json"}                     # file names, not keys
    assert used - set(MSG) == set()
    assert set(MSG) - used == set()


def test_language_pick():
    assert i18n.pick("en-US,en;q=0.9") == "en" and i18n.pick("zh-CN,zh;q=0.9") == "zh" and i18n.pick("zh-Hant") == "zh"
    assert i18n.pick("") is None and i18n.pick("C.UTF-8") is None and i18n.pick("fr_FR.UTF-8") == "en"


def english(v):
    tok = i18n.use("en")
    try:
        return text(v)
    finally:
        i18n.reset(tok)


def reasons(strategy: str, keep: int = 40) -> list:
    """A batch that reaches every kind of reason: rejected, gates, quota ranks and caps, select's three / two / one
    and 0-star whys, flight, rarity, genus, uncertain, exposure, the person's stars; Chinese bird names throughout."""
    lab = lambda sci, zh: {"sci": sci, "en": sci.replace(" ", "-"), "zh": zh, "p": 0.97}      # noqa: E731
    sp = lambda sci, zh: {"level": "species", "label": lab(sci, zh), "top5": [lab(sci, zh)]}   # noqa: E731
    ps = []
    for i in range(40):
        p = photo(10.0 * i + (0.3 if i % 4 else 0), sharp=1 + (i % 7) / 2, aes=0.3 + (i % 5) / 10, eye=(0.2, 0.6, 0.95)[i % 3],
                  area=(0.001, 0.01, 0.05)[i % 3], fly=0.9 if i % 6 == 1 else 0.1, species=sp(f"S{i % 4} x", "白头鹎"))
        ps.append(p)
    ps[0].update(rejected=True, reject_reason=MSG["stars.no_clear_bird"][0])
    ps[1].update(rejected=True, reject_reason=None)
    ps[2]["boxes"][0]["score"] = 0.01
    ps[3].update(eye_p=0.1, beak_p=0.1)
    ps[14].update(aesthetic=0.01)
    ps[4].update(clip_hi=0.9)
    ps[5].update(clip_lo=0.9)
    ps[6].update(eye_p=0.95, sharpness=4.0, species={"level": "genus", "label": {"sci": "Pycnonotus sp.", "en": None, "zh": "鹎属", "p": 0.5}, "top5": []})
    ps[7].update(eye_p=0.95, sharpness=4.0, species={"level": "uncertain", "label": None, "top5": []})
    ps[8].update(species=sp("Rare bird", "稀有鸟"), rarity={"tier": 1, "label": "罕见"})
    ps[9].update(species=sp("No zh", None))
    ps[10].update(focus=[0.05, 0.05])
    ps[11].update(file=None)
    cfg = {"strategy": strategy, "keep": keep, "min_aes": 0.05, "min_sharp": 1.2}
    out = stars.rate([{"id": i, "result": p} for i, p in enumerate(ps)], cfg, fixed={12: 3, 13: -1})
    return [out[i]["star_reason"] for i in range(len(ps))] + [out[12]["star_auto"]["reason"]]


def keys_of(v, acc: set) -> set:
    if isinstance(v, list):
        acc.add(v[0])
        for x in v[1].values():
            keys_of(x, acc)
    return acc


def test_star_reasons_render_in_english_without_chinese():
    seen = {}
    for strategy in ("select", "quota"):
        got = reasons(strategy) + reasons(strategy, keep=70)
        en = [english(r) for r in got]
        assert all(s and not CJK.search(s) for s in en), [s for s in en if not s or CJK.search(s)]
        assert all(CJK.search(text(r)) for r in got)                       # Chinese by default (conftest)
        seen[strategy] = set().union(*(keys_of(r, set()) for r in got))
    # the batch reaches the reasons a person sees most: each strategy's main kinds, the exposure malus, flight, by hand
    assert {"stars.three", "stars.two", "stars.joined", "stars.manual", "stars.expo", "stars.flying"} <= seen["select"], seen
    assert {"stars.low_det", "stars.no_eye_beak", "stars.rank", "stars.ranked_low", "stars.expo_malus", "stars.manual"} <= seen["quota"], seen


def test_older_chinese_sentences():
    assert english("没有清楚的鸟") == "No clear bird" and english("主人手动设定") == "Set by you"
    assert english("比例已满，排在后面") == "The ratio is full; ranked below"
    assert english("飞版，白头鹎第 1 / 3 名") == "飞版，白头鹎第 1 / 3 名"          # with parameters: re-rated instead
    tok = i18n.use("en")
    try:
        assert i18n.legacy("飞版，白头鹎第 1 / 3 名") and not i18n.legacy("没有清楚的鸟") and not i18n.legacy(R("stars.manual"))
    finally:
        i18n.reset(tok)


def client(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setattr(names, "catalogue", lambda: CAT)
    store = Store(tmp_path / "t.db")
    guarded, api = create_app(PORT, token="tok", store=store, engine_factory=FakeEngine, start_scheduler=False)
    return TestClient(guarded, base_url=f"http://127.0.0.1:{PORT}"), store, api


def test_api_errors_follow_accept_language(tmp_path, monkeypatch):
    c, store, _ = client(tmp_path, monkeypatch)
    h = {"host": f"127.0.0.1:{PORT}", "x-birdcm-token": "tok"}
    sid = store.create_scan(str(tmp_path), False, None, {"keep": 50}, "fp", [("/p/0.ARW", 1, 1)])
    calls = [("get", "/api/scans/999", None), ("post", "/api/scans", {"folder": str(tmp_path / "nope")}),
             ("put", f"/api/scans/{sid}/ratio", {"strategy": "bogus"}), ("put", f"/api/scans/{sid}/ratio", {"bogus": 1}),
             ("post", f"/api/scans/{sid}/stars", {"photo_ids": [1], "stars": 7}),
             ("post", f"/api/scans/{sid}/stars", {"photo_ids": []}),
             ("post", f"/api/scans/{sid}/corrections", {"photo_id": 1, "sci": "Nope nope"}),
             ("post", f"/api/scans/{sid}/corrections", {"photo_id": 1, "scope": "x"}),
             ("get", "/api/places/name?lat=99&lon=0", None), ("get", "/api/photos/999", None),
             ("get", "/api/library/species?seen=bogus", None), ("post", "/api/singles/999/correct", {"sci": None})]
    for method, url, body in calls:
        zh = getattr(c, method)(url, headers=h, **({"json": body} if body is not None else {}))
        en = getattr(c, method)(url, headers={**h, **EN}, **({"json": body} if body is not None else {}))
        assert en.status_code == zh.status_code >= 400, (url, zh.status_code, en.status_code)
        dz, de = zh.json()["detail"], en.json()["detail"]
        assert isinstance(de, str) and CJK.search(dz) and not CJK.search(de), (url, dz, de)
    assert CJK.search(c.get("/api/scans/999", headers={**h, "accept-language": "zh-CN"}).json()["detail"])


def test_snapshot_reasons_in_the_requests_language_and_older_rows_rerated(tmp_path, monkeypatch):
    c, store, api = client(tmp_path, monkeypatch)
    h = {"host": f"127.0.0.1:{PORT}"}
    sid = store.create_scan(str(tmp_path), False, None, {"keep": 50}, "fp", [(f"/p/{i}.ARW", 1, 1) for i in range(4)])
    for k, p in enumerate(store.queued(sid)):
        store.commit(p["id"], photo(30.0 * k, sp="Thalasseus maximus", species={"level": "species", "top5": [],
                     "label": {"sci": "Thalasseus maximus", "en": "Royal Tern", "zh": "橙嘴凤头燕鸥", "p": 0.97}}), None)
    store.set_state(sid, "completed")
    api.state.scheduler.rerate_now(sid)
    zh = c.get(f"/api/scans/{sid}", headers=h).json()["photos"]
    en = c.get(f"/api/scans/{sid}", headers={**h, **EN}).json()["photos"]
    assert all(CJK.search(p["star_reason"]) for p in zh) and not any(CJK.search(p["star_reason"]) for p in en)
    # a database from before R8: Chinese sentences with parameters; an English request re-rates the scan once
    store._db().execute("UPDATE photo SET star_reason = '飞版，橙嘴凤头燕鸥第 1 / 4 名' WHERE scan_id = ?", (sid,))
    assert all(CJK.search(p["star_reason"]) for p in c.get(f"/api/scans/{sid}", headers=h).json()["photos"])
    en = c.get(f"/api/scans/{sid}", headers={**h, **EN}).json()["photos"]
    assert not any(CJK.search(p["star_reason"]) for p in en)
    assert all(isinstance(p["star_reason"], list) for p in store.snapshot(sid)["photos"])
