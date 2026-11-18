"""Queue with a fake pipeline: stop / resume, crash recovery at each state, reuse by fingerprint, edge cases."""
import pytest

from birdcm.queue import Scheduler
from birdcm.store import Store


class FakeEngine:
    """Engine.run's contract: batches of `batch`, should_stop checked between batches, on_submit per photo."""

    def __init__(self, batch=2, fail=(), on_batch=None, explode_after=None, fp="fp1"):
        self.batch, self.fail, self.on_batch, self.explode_after, self.fp = batch, set(fail), on_batch, explode_after, fp
        self.seen = []

    def fingerprint(self, region):
        return self.fp

    def run(self, items, region=None, should_stop=lambda: False, on_submit=None, between=None):
        for i in range(0, len(items), self.batch):
            if should_stop():
                return
            between and between()
            chunk = items[i:i + self.batch]
            for it in chunk:
                on_submit and on_submit(it)
            if self.explode_after is not None and len(self.seen) >= self.explode_after:
                raise RuntimeError("GPU gone")
            if self.on_batch:
                self.on_batch(len(self.seen))
            for it in chunk:
                self.seen.append(it["path"])
                if it["path"] in self.fail:
                    yield it, None, "解码失败"
                else:
                    yield it, {"file": it["path"], "rejected": it["path"].endswith("0"), "reject_reason": "没有找到鸟",
                               "exif": {"camera": "A", "taken_at": None}}, None


def files(n, prefix="/p/x"):
    return [(f"{prefix}{i}", 100 + i, 1000 + i) for i in range(n)]


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "t.db")


def mk(store, n=5, fp="fp1", region=None):
    return store.create_scan("/p", False, region, {"p3": 30, "p2": 30}, fp, files(n))


def kinds(store, sid):
    return [e["kind"] for e in store.events_after(sid, 0)]


def test_runs_to_completed(store):
    sid = mk(store)
    eng = FakeEngine()
    s = Scheduler(store, lambda: eng)
    s.run_until_idle()
    snap = store.snapshot(sid)
    assert snap["scan"]["state"] == "completed"
    assert [p["state"] for p in snap["photos"]] == ["done"] * 5
    assert snap["photos"][0]["stars"] == -1 and snap["photos"][1]["stars"] == 0        # 淘汰 / gated (no subject score)
    assert {p["burst_size"] for p in snap["photos"]} == {1}                          # no times: own groups
    k = kinds(store, sid)
    assert k[-2:] == ["stars", "scan"] and k.count("photo") == 10                    # working + done per photo
    assert snap["cursor"] == store.events_after(sid, 0)[-1]["n"]


def test_empty_folder_completes(store):
    sid = store.create_scan("/p", False, None, {}, "fp", [])
    Scheduler(store, FakeEngine).run_until_idle()
    assert store.state(sid) == "completed" and kinds(store, sid)[-1] == "scan"


def test_all_failed_completes(store):
    sid = mk(store, 3)
    Scheduler(store, lambda: FakeEngine(fail={"/p/x0", "/p/x1", "/p/x2"})).run_until_idle()
    snap = store.snapshot(sid)
    assert snap["scan"]["state"] == "completed"
    assert all(p["state"] == "failed" and p["error"] for p in snap["photos"])


def test_stop_mid_scan_then_resume(store):
    sid = mk(store, 6)
    eng = FakeEngine(on_batch=lambda done: done == 2 and store.stop(sid))
    s = Scheduler(store, lambda: eng)
    s.run_until_idle()
    snap = store.snapshot(sid)
    assert snap["scan"]["state"] == "paused"
    assert [p["state"] for p in snap["photos"]] == ["done"] * 4 + ["queued"] * 2   # in-flight batch finished
    assert store.stop(sid) == "paused"                                               # idempotent
    eng.on_batch = None
    assert store.resume(sid) == "queued" and store.resume(sid) == "queued"          # idempotent
    s.run_until_idle()
    assert store.state(sid) == "completed"
    assert eng.seen == [f"/p/x{i}" for i in range(6)]                                # nothing processed twice


def test_stop_during_last_batch(store):
    sid = mk(store, 4)
    s = Scheduler(store, lambda: FakeEngine(on_batch=lambda done: done == 2 and store.stop(sid)))
    s.run_until_idle()
    # the last batch completed: nothing is left, so the stop leaves it paused with all photos done;
    assert store.state(sid) == "paused" and store.unfinished(sid) == 0
    store.resume(sid)                                                                # resume with nothing queued
    s.run_until_idle()
    assert store.state(sid) == "completed"


def test_resume_while_stopping_keeps_running(store):
    sid = mk(store, 6)

    def hook(done):
        if done == 2:
            store.stop(sid)
            assert store.resume(sid) == "running"                                    # before the scheduler noticed
    eng = FakeEngine(on_batch=hook)
    Scheduler(store, lambda: eng).run_until_idle()
    assert store.state(sid) == "completed" and len(eng.seen) == 6


def test_stop_queued_scan(store):
    sid = mk(store)
    assert store.stop(sid) == "paused"
    Scheduler(store, FakeEngine).run_until_idle()
    assert store.state(sid) == "paused"


def test_one_scan_at_a_time_in_order(store):
    a, b = mk(store, 2), store.create_scan("/q", False, None, {}, "fp1", files(2, "/q/y"))
    order = []
    eng = FakeEngine()
    run = eng.run
    eng.run = lambda items, **kw: (order.append(items[0]["path"]), run(items, **kw))[1]
    Scheduler(store, lambda: eng).run_until_idle()
    assert order == ["/p/x0", "/q/y0"] and store.state(a) == store.state(b) == "completed"


@pytest.mark.parametrize("crash_state", ["running", "stopping", "finalizing"])
def test_crash_recovery(tmp_path, crash_state):
    path = tmp_path / "c.db"
    st = Store(path)
    sid = mk(st, 4)
    st.set_state(sid, "running")
    st.mark_working(st.queued(sid)[0]["id"])
    st.commit(st.queued(sid)[1]["id"], {"file": "x", "rejected": False, "exif": {}}, None)
    if crash_state == "finalizing":                                                  # all photos done, stars not written
        for p in st.queued(sid) + [r for r in st.rows_for_rating(sid) if r["state"] == "working"]:
            st.commit(p["id"], {"file": "x", "rejected": False, "exif": {}}, None)
    st.set_state(sid, crash_state)
    # "restart": a new store and scheduler on the same file
    st2 = Store(path)
    st2.recover()
    assert not [r for r in st2.rows_for_rating(sid) if r["state"] == "working"]
    expect = {"running": "queued", "stopping": "paused", "finalizing": "finalizing"}[crash_state]
    assert st2.state(sid) == expect
    if expect == "paused":
        st2.resume(sid)
    eng = FakeEngine()
    Scheduler(st2, lambda: eng).run_until_idle()
    assert st2.state(sid) == "completed"
    assert all(r["state"] == "done" for r in st2.rows_for_rating(sid))
    assert kinds(st2, sid)[-1] == "scan"


def test_reuse_needs_same_fingerprint_and_signature(store):
    a = mk(store, 3)
    Scheduler(store, FakeEngine).run_until_idle()
    b = mk(store, 3)                                                                  # same files, same fingerprint
    snap = store.snapshot(b)
    assert all(p["state"] == "done" and p["reused"] for p in snap["photos"])
    assert snap["photos"][1]["stars"] is None                                         # per-scan fields not copied (not rated yet)
    c = mk(store, 3, fp="fp2")                                                        # region / models changed
    assert all(p["state"] == "queued" for p in store.snapshot(c)["photos"])
    changed = [(p, s + 1, m) for p, s, m in files(3)]                                 # file size changed
    d = store.create_scan("/p", False, None, {}, "fp1", changed)
    assert all(p["state"] == "queued" for p in store.snapshot(d)["photos"])
    eng = FakeEngine()
    Scheduler(store, lambda: eng).run_until_idle()
    assert store.state(b) == "completed" and len(eng.seen) == 6                       # b ran nothing
    assert store.state(a) == "completed"


def test_fatal_engine_error_fails_scan_not_photos(store):
    sid = mk(store, 6)
    s = Scheduler(store, lambda: FakeEngine(explode_after=2))
    assert s.run_once() is False
    snap = store.snapshot(sid)
    assert snap["scan"]["state"] == "failed" and "GPU gone" in snap["scan"]["error"]
    assert [p["state"] for p in snap["photos"]] == ["done"] * 2 + ["queued"] * 4
    store.resume(sid)
    s.engine = FakeEngine()
    s.run_until_idle()
    assert store.state(sid) == "completed"


def test_ratio_change_rerates_only(store):
    sid = mk(store, 3)
    s = Scheduler(store, FakeEngine)
    s.run_until_idle()
    n = store.snapshot(sid)["cursor"]
    store.set_ratio(sid, {"p3": 10, "p2": 20})
    s.rerate(sid)
    assert [e["kind"] for e in store.events_after(sid, n)] == ["stars"]
    assert store.state(sid) == "completed"


def test_stop_between_last_batch_and_finalizing(store):
    """Deterministic interleaving: the scheduler has read `running` and all photos are done; a stop lands before it
    moves to finalizing. The scan must end paused (not stuck in stopping), and resume must complete it."""
    sid = mk(store, 2)
    s = Scheduler(store, FakeEngine)
    real = store.unfinished

    def stop_first(scan_id):
        store.stop(scan_id)
        return real(scan_id)
    store.unfinished = stop_first
    s.run_until_idle()
    store.unfinished = real
    assert store.state(sid) == "paused"
    store.resume(sid)
    s.run_until_idle()
    assert store.state(sid) == "completed"


def test_engine_fingerprint_mismatch_recomputes_everything(store):
    sid = mk(store, 3, fp="old")
    pid = store.queued(sid)[0]["id"]
    store.commit(pid, {"file": "stale", "rejected": False, "exif": {}}, None)     # done under the old engine
    eng = FakeEngine(fp="new")
    Scheduler(store, lambda: eng).run_until_idle()
    assert store.state(sid) == "completed" and len(eng.seen) == 3                 # the stale one was redone too
    assert store.scan(sid)["fp"] == "new"
    rows = store._db().execute("SELECT fp, result FROM photo WHERE scan_id = ?", (sid,)).fetchall()
    assert {r["fp"] for r in rows} == {"new"} and all("stale" not in r["result"] for r in rows)
    again = mk(store, 3, fp="new")                                                # reuse only under the engine's fp
    assert all(p["reused"] for p in store.snapshot(again)["photos"])


def test_bad_stored_star_settings_fail_that_scan_only(store):
    bad = store.create_scan("/p", False, None, {"p3": "x"}, "fp1", files(2))          # bypassing the API's check
    good = mk(store, 2)
    s = Scheduler(store, FakeEngine)
    s.run_until_idle()
    assert store.state(bad) == "failed" and "标星出错" in store.scan(bad)["error"]
    assert store.state(good) == "completed"


def test_stop_between_next_scan_and_running(store):
    sid = mk(store, 4)
    s = Scheduler(store, FakeEngine)
    s.run_once()                                                                       # starts: some photos done
    store.set_state(sid, "running")
    real = store.next_scan

    def stop_after_read():
        scan = real()
        store.stop(scan["id"])                                                         # running -> stopping, after the read
        return scan
    store.next_scan = stop_after_read
    s.run_once()
    store.next_scan = real
    assert store.state(sid) == "paused"                                                # not stuck in stopping


def test_singles_go_first_at_batch_boundaries(store):
    sid = mk(store, 6)
    order = []
    eng = FakeEngine(on_batch=lambda done: order.append(f"batch@{done}"))
    s = Scheduler(store, lambda: eng)
    f = s.submit(lambda e: order.append("single") or "ok")
    s.run_once()
    assert f.result(timeout=1) == "ok" and order[0] == "single" and store.state(sid) == "completed"
    g = s.submit(lambda e: 1 / 0)
    s.drain()
    assert isinstance(g.exception(timeout=1), ZeroDivisionError)
