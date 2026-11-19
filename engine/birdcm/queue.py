"""The one scheduler: a single thread that owns the model engine and runs one scan at a time.

run_once() does one unit of work and is what the tests drive synchronously; start() loops it on a thread.
States (store.py): queued -> running -> stopping -> paused -> finalizing -> completed, or failed.
"""
from __future__ import annotations

import queue
import threading
import traceback
from collections.abc import Callable
from concurrent.futures import Future

from birdcm import stars
from birdcm.store import Store


class Scheduler:
    def __init__(self, store: Store, engine_factory: Callable[[], object]) -> None:
        self.store, self.engine_factory, self.engine = store, engine_factory, None
        self.wake = threading.Event()
        self._quit = threading.Event()
        self.thread: threading.Thread | None = None
        self.engine_error: str | None = None
        self.state = "loading"                  # the engine: loading | ready | error (load_error says why; retry())
        self.load_error: str | None = None
        self.singles: queue.SimpleQueue = queue.SimpleQueue()

    def load(self) -> object:
        """Make the engine and warm it up, on the model thread; it is published only when ready. A failure is kept (state
        "error": queued scans wait, singles fail at once) until retry(), never retried on every wake."""
        if self.engine is not None:
            return self.engine
        if self.state == "error":
            raise RuntimeError(self.load_error)
        try:
            eng = self.engine_factory()
        except Exception as e:
            self.load_error, self.state = f"{type(e).__name__}: {e}"[:500], "error"
            raise
        if hasattr(eng, "warm"):
            try:
                eng.warm()
            except Exception:  # noqa: BLE001 - a failed warm-up only costs the first photo its speed
                traceback.print_exc()
        self.engine, self.state = eng, "ready"
        return eng

    def retry(self) -> None:
        """Load again after an error (models downloaded meanwhile, say)."""
        if self.state == "error":
            from birdcm import names
            names.catalogue.cache_clear()       # it remembered "no name list"
            self.load_error, self.state = None, "loading"
            self.wake.set()

    def submit(self, fn: Callable[[object], object]) -> Future:
        """Run fn(engine) on the model thread: at once when idle, else at the next batch boundary of the running scan."""
        f: Future = Future()
        self.singles.put((fn, f))
        self.wake.set()
        return f

    def drain(self) -> None:
        while True:
            try:
                fn, f = self.singles.get_nowait()
            except queue.Empty:
                return
            if not f.set_running_or_notify_cancel():
                continue
            try:
                f.set_result(fn(self.load()))
            except Exception as e:  # noqa: BLE001 - the caller gets it
                f.set_exception(e)

    def start(self) -> None:
        self.store.recover()
        self.thread = threading.Thread(target=self._loop, name="birdcm-scheduler", daemon=True)
        self.thread.start()

    def close(self) -> None:
        self._quit.set()
        self.wake.set()
        if self.thread:
            self.thread.join(10)
        if self.engine and hasattr(self.engine, "close"):
            self.engine.close()

    def _loop(self) -> None:
        while not self._quit.is_set():
            try:
                if self.engine is None and self.state == "loading":
                    self.load()                                   # at start-up, not at the first photo
                self.drain()
                busy = self.run_once()
            except Exception:  # noqa: BLE001 - the one model thread must not die (singles would hang)
                traceback.print_exc()
                busy = False
            if not busy:
                self.wake.wait(1.0)
                self.wake.clear()

    def run_until_idle(self) -> None:
        while self.run_once():
            pass

    def run_once(self) -> bool:
        scan = self.store.next_scan()
        if not scan:
            return False
        sid = scan["id"]
        if scan["state"] == "finalizing" or not self.store.queued(sid):
            self.finalize(sid)
            return True
        try:
            self.load()
        except Exception:  # noqa: BLE001 - no engine: the scan stays queued until retry() (state / load_error say why)
            return False
        if not self.store.set_state(sid, "running", when=("queued", "running")):
            self.store.set_state(sid, "paused", when=("stopping",))    # a stop landed after next_scan read it
            return True
        try:
            fp = self.engine.fingerprint(scan["region"])
            if fp != scan["fp"]:                                  # models, data or settings changed since the scan began:
                self.store.reset_scan(sid, fp)                    # every result of it is recomputed, none kept under a stale fp
            items = self.store.queued(sid)
            for it, res, err in self.engine.run(items, region=scan["region"],
                                                should_stop=lambda: self._quit.is_set() or self.store.state(sid) != "running",
                                                on_submit=lambda it: self.store.mark_working(it["id"]), between=self.drain):
                self.store.commit(it["id"], res, err, fp)
        except Exception as e:  # noqa: BLE001 - a fatal engine error pauses this scan as failed, never marks photos bad
            traceback.print_exc()
            self.engine_error = f"{type(e).__name__}: {e}"
            self.store.requeue_working(sid)
            self.store.set_state(sid, "failed", error=self.engine_error[:500])
            return False                                          # don't spin on a broken engine
        self.store.requeue_working(sid)                            # decodes dropped by a stop go back to the queue
        if self._quit.is_set():
            return False
        state = self.store.state(sid)
        if state == "stopping":
            self.store.set_state(sid, "paused", when=("stopping",))
        elif state == "running" and not self.store.unfinished(sid):
            self.finalize(sid)
        return True

    def finalize(self, sid: int) -> None:
        """Group bursts and rate, deterministically from the stored rows; safe to redo after a crash. A stop that got in
        first wins: the scan is paused instead (resume finalizes it). A rating error fails this scan, not the scheduler."""
        if not self.store.set_state(sid, "finalizing", when=("queued", "running", "finalizing")):
            self.store.set_state(sid, "paused", when=("stopping",))
            return
        for _ in range(5):                                         # the settings may change while we compute: redo
            scan = self.store.scan(sid)
            try:
                rating = self._rate(sid, scan["ratio"])
            except Exception as e:  # noqa: BLE001
                traceback.print_exc()
                self.store.set_state(sid, "failed", error=f"标星出错：{type(e).__name__}: {e}"[:500])
                return
            if self.store.write_rating(sid, rating, complete=True, ratio=scan["ratio"]):
                return

    def _rarity(self):
        """The rarity table for burst-corrected frames (they take the majority species' rarity); None when absent."""
        if not hasattr(self, "_rarity_table"):
            from birdcm import rarity
            self._rarity_table = rarity.table()
        return self._rarity_table

    def _rate(self, sid: int, ratio: dict) -> dict[int, dict]:
        rows = self.store.rows_for_rating(sid)                    # read once (it was twice: half of a re-rate)
        return stars.rate(rows, ratio, rarity=self._rarity(), manual=self.manual(sid, rows))

    def manual(self, sid: int, rows: list[dict]) -> dict[int, dict]:
        """The person's corrections of this scan as species blocks for stars.rate (rows: rows_for_rating, not rated yet)."""
        from birdcm import names
        cor = self.store.corrections_for(sid)
        if not cor:
            return {}
        own = {r["id"]: (r.get("result") or {}).get("species") for r in rows if r["id"] in cor}
        cat = names.catalogue()
        return {i: {**stars.manual_species(own.get(i), c["sci"], cat), "scope": c["scope"]} for i, c in cor.items()}

    def rerate_now(self, sid: int) -> None:
        """Stars again with the current settings (after a correction), stored only if the settings did not change."""
        for _ in range(5):
            scan = self.store.scan(sid)
            if not scan or scan["state"] != "completed":
                return
            rating = self._rate(sid, scan["ratio"])
            if self.store.write_rating(sid, rating, complete=False, ratio=scan["ratio"]):
                return

    def set_ratio(self, sid: int, ratio: dict) -> None:
        """New star settings. A completed scan is re-rated first and the settings are stored together with their stars
        (ValueError / any rating error: nothing changes); otherwise only stored, finalize uses them."""
        scan = self.store.scan(sid)
        if scan and scan["state"] == "completed":
            rating = self._rate(sid, ratio)
            self.store.write_rating(sid, rating, complete=False, ratio=ratio, set_ratio=True)
        else:
            self.store.set_ratio(sid, ratio)
