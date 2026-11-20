"""Update check (birdcm/update.py): no live network, every request goes to a stub."""
import io
import json
import urllib.error

import pytest
from fastapi.testclient import TestClient

from birdcm import online, update


class Stub:
    def __init__(self):
        self.answer, self.reqs = {"tag_name": "release/v9.0.0"}, []

    def __call__(self, req, timeout=None):
        self.reqs.append(req)
        if isinstance(self.answer, BaseException):
            raise self.answer
        return io.BytesIO(self.answer if isinstance(self.answer, bytes) else json.dumps(self.answer).encode())


@pytest.fixture
def gh(tmp_path, monkeypatch):
    monkeypatch.setenv("BIRDCM_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("BIRDCM_CACHE_DIR", str(tmp_path / "cache"))
    stub = Stub()
    monkeypatch.setattr(update, "fetch", stub)
    return stub


@pytest.mark.parametrize("latest,cur,yes", [
    ("0.0.3", "0.0.2", True), ("0.1.0", "0.0.9", True), ("0.0.10", "0.0.9", True), ("0.0.2", "0.0.2", False),
    ("0.0.2", "0.0.3", False), ("0.0.2", "0.0.2b0", True), ("0.0.2", "0.0.2rc1", True), ("0.0.1", "0.0.2b0", False),
    ("0.0.3b0", "0.0.2", False), (None, "0.0.2", False), ("0.0.3", None, False), ("x", "0.0.2", False)])
def test_newer(latest, cur, yes):
    assert update.newer(latest, cur) is yes


def test_off_by_default_asks_nothing(gh):
    assert online.settings()["updates"] is False
    assert update.check() == {"current": update.current(), "latest": None, "newer": False, "url": update.RELEASES}
    assert gh.reqs == []


def test_on_asks_once_a_day_and_sends_nothing_about_us(gh, monkeypatch):
    online.set_settings(updates=True)
    r = update.check()
    assert r["latest"] == "9.0.0" and r["newer"] is True and len(gh.reqs) == 1
    req = gh.reqs[0]
    assert req.full_url == update.LATEST and req.get_method() == "GET" and req.data is None
    assert dict(req.header_items()) == {"User-agent": online.UA, "Accept": "application/vnd.github+json"}
    assert update.current() not in online.UA
    assert update.check()["newer"] is True and len(gh.reqs) == 1                 # cached
    real = update.time.time
    monkeypatch.setattr(update.time, "time", lambda: real() + online.DAY + 1)
    update.check()
    assert len(gh.reqs) == 2
    online.set_settings(updates=False)
    assert update.check()["newer"] is False and len(gh.reqs) == 2


@pytest.mark.parametrize("answer", [
    urllib.error.URLError("offline"), urllib.error.HTTPError(update.LATEST, 403, "rate limited", {}, None),
    urllib.error.HTTPError(update.LATEST, 404, "none", {}, None), TimeoutError(), b"<html>", {"message": "x"},
    {"tag_name": "release/v9.0.0-beta"}, {"tag_name": "v9.0.0"}, {"tag_name": None}])
def test_failure_is_silent_and_not_retried_at_once(gh, answer):
    online.set_settings(updates=True)
    gh.answer = answer
    assert update.check()["newer"] is False and update.check()["latest"] is None and len(gh.reqs) == 1


def test_api(gh, tmp_path):
    from birdcm.app import create_app
    from birdcm.store import Store
    from test_queue import FakeEngine
    guarded, _ = create_app(8799, token="tok", store=Store(tmp_path / "t.db"), engine_factory=FakeEngine, start_scheduler=False)
    c = TestClient(guarded, base_url="http://127.0.0.1:8799")
    w = {"host": "127.0.0.1:8799", "x-birdcm-token": "tok"}
    assert c.post("/api/update", headers={"host": "127.0.0.1:8799"}).status_code == 403
    assert c.post("/api/update", headers=w).json()["newer"] is False and gh.reqs == []
    assert c.post("/api/online/settings", json={"updates": "yes"}, headers=w).status_code == 422
    assert c.post("/api/online/settings", json={"updates": True}, headers=w).json()["updates"] is True
    assert c.post("/api/update", headers=w).json()["latest"] == "9.0.0" and len(gh.reqs) == 1
