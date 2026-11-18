"""The one scheduler: a single thread that owns the model engine and runs one scan at a time.

run_once() does one unit of work and is what the tests drive synchronously; start() loops it on a thread.
States (store.py): queued -> running -> stopping -> paused -> finalizing -> completed, or failed.
"""
from __future__ import annotations

import threading
import traceback
from collections.abc import Callable

from birdcm import stars
from birdcm.store import Store


class Scheduler:
    def __init__(self, store: Store, engine_factory: Callable[[], object]) -> None:
        self.store, self.engine_factory, self.engine = store, engine_factory, None
        self.wake = threading.Event()
        self._quit = threading.Event()
        self.thread: threading.Thread | None = None
        self.engine_error: str | None = None

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
            if not self.run_once():
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
        if not self.store.set_state(sid, "running", when=("queued", "running")):
            return True                                           # stopped meanwhile: look again
        try:
            if self.engine is None:
                self.engine = self.engine_factory()
            items = self.store.queued(sid)
            for it, res, err in self.engine.run(items, region=scan["region"],
                                                should_stop=lambda: self._quit.is_set() or self.store.state(sid) != "running",
                                                on_submit=lambda it: self.store.mark_working(it["id"])):
                self.store.commit(it["id"], res, err)
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
        """Group bursts and rate, deterministically from the stored rows; safe to redo after a crash."""
        self.store.set_state(sid, "finalizing", when=("queued", "running", "finalizing"))
        scan = self.store.scan(sid)
        self.store.write_rating(sid, stars.rate(self.store.rows_for_rating(sid), scan["ratio"]), complete=True)

    def rerate(self, sid: int) -> None:
        """Ratio changed on a completed scan: stars only, no rescan."""
        scan = self.store.scan(sid)
        if scan and scan["state"] == "completed":
            self.store.write_rating(sid, stars.rate(self.store.rows_for_rating(sid), scan["ratio"]), complete=False)
