"""SQLite: scans, photos, and the event log the browser replays from (stdlib sqlite3, WAL).

One write lock for the whole process and short transactions; every photo result is written together with its
event in one transaction, and overwriting a photo's result is idempotent (by photo id). Readers use their own
connection per call; a snapshot and its event cursor come from one explicit read transaction.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS scan (
  id INTEGER PRIMARY KEY, folder TEXT NOT NULL, recursive INTEGER NOT NULL, region TEXT, ratio TEXT NOT NULL,
  fp TEXT NOT NULL, state TEXT NOT NULL, error TEXT, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS photo (
  id INTEGER PRIMARY KEY, scan_id INTEGER NOT NULL REFERENCES scan(id), seq INTEGER NOT NULL, path TEXT NOT NULL,
  size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, state TEXT NOT NULL, fp TEXT, result TEXT, error TEXT, reused INTEGER DEFAULT 0,
  stars INTEGER, star_reason TEXT, burst_group INTEGER, burst_rank INTEGER, burst_size INTEGER,
  UNIQUE (scan_id, path));
CREATE INDEX IF NOT EXISTS photo_reuse ON photo(path, size, mtime_ns, fp) WHERE state = 'done';
CREATE INDEX IF NOT EXISTS photo_scan_state ON photo(scan_id, state);
CREATE TABLE IF NOT EXISTS event (
  n INTEGER PRIMARY KEY AUTOINCREMENT, scan_id INTEGER NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS event_scan ON event(scan_id, n);
"""
# scan.state: queued -> running -> stopping -> paused -> finalizing -> completed; failed = fatal engine error
TERMINAL = ("done", "failed")
PHOTO_COLS = "id, seq, path, size, mtime_ns, state, result, error, reused, stars, star_reason, burst_group, burst_rank, burst_size"


def photo_row(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["result"] = json.loads(d["result"]) if d["result"] else None
    d["file"] = Path(d["path"]).name
    return d


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self._local = threading.local()
        with self.lock:
            self._db().executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        """One connection per thread, autocommit (transactions are explicit)."""
        db = getattr(self._local, "db", None)
        if db is None:
            db = sqlite3.connect(self.path, isolation_level=None, check_same_thread=True, timeout=30)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA busy_timeout=30000")
            self._local.db = db
        return db

    def _write(self, fn):
        with self.lock:
            db = self._db()
            db.execute("BEGIN IMMEDIATE")
            try:
                out = fn(db)
                db.execute("COMMIT")
                return out
            except BaseException:
                db.execute("ROLLBACK")
                raise

    @staticmethod
    def _event(db: sqlite3.Connection, scan_id: int, kind: str, data: dict) -> int:
        return db.execute("INSERT INTO event (scan_id, kind, data) VALUES (?, ?, ?)",
                          (scan_id, kind, json.dumps(data, ensure_ascii=False))).lastrowid

    @staticmethod
    def _counts(db: sqlite3.Connection, scan_id: int) -> dict:
        c = {s: 0 for s in ("queued", "working", "done", "failed")}
        for s, n in db.execute("SELECT state, count(*) FROM photo WHERE scan_id = ? GROUP BY state", (scan_id,)):
            c[s] = n
        c["total"] = sum(c.values())
        return c

    def _scan_event(self, db, scan_id: int) -> None:
        r = db.execute("SELECT state, error FROM scan WHERE id = ?", (scan_id,)).fetchone()
        self._event(db, scan_id, "scan", {"state": r["state"], "error": r["error"], "counts": self._counts(db, scan_id)})

    def _photo_event(self, db, photo_id: int) -> None:
        r = db.execute(f"SELECT scan_id, {PHOTO_COLS} FROM photo WHERE id = ?", (photo_id,)).fetchone()
        row = photo_row(r)
        self._event(db, row.pop("scan_id"), "photo", row)

    # ---- scans --------------------------------------------------------------------------------------------------

    def create_scan(self, folder: str, recursive: bool, region: str | None, ratio: dict, fp: str,
                    files: list[tuple[str, int, int]]) -> int:
        """files: (path, size, mtime_ns). Photos whose (path, size, mtime, fingerprint) match a finished result of an
        earlier scan are done at once with that result copied; the rest are queued."""
        def go(db):
            sid = db.execute("INSERT INTO scan (folder, recursive, region, ratio, fp, state, created_at) VALUES (?,?,?,?,?,?,?)",
                             (folder, int(recursive), region, json.dumps(ratio), fp, "queued", time.time())).lastrowid
            for seq, (path, size, mtime) in enumerate(files):
                old = db.execute("SELECT result FROM photo WHERE path=? AND size=? AND mtime_ns=? AND fp=? AND state='done' "
                                 "ORDER BY id DESC LIMIT 1", (path, size, mtime, fp)).fetchone()
                db.execute("INSERT INTO photo (scan_id, seq, path, size, mtime_ns, state, fp, result, reused) VALUES (?,?,?,?,?,?,?,?,?)",
                           (sid, seq, path, size, mtime, "done" if old else "queued", fp, old["result"] if old else None, int(bool(old))))
            self._scan_event(db, sid)
            return sid
        return self._write(go)

    def scans(self) -> list[dict]:
        db = self._db()
        out = []
        for r in db.execute("SELECT id, folder, recursive, region, ratio, state, error, created_at FROM scan ORDER BY id DESC"):
            d = dict(r)
            d["ratio"] = json.loads(d["ratio"])
            d["counts"] = self._counts(db, r["id"])
            out.append(d)
        return out

    def scan(self, scan_id: int) -> dict | None:
        r = self._db().execute("SELECT * FROM scan WHERE id = ?", (scan_id,)).fetchone()
        if not r:
            return None
        d = dict(r)
        d["ratio"] = json.loads(d["ratio"])
        return d

    def state(self, scan_id: int) -> str | None:
        r = self._db().execute("SELECT state FROM scan WHERE id = ?", (scan_id,)).fetchone()
        return r["state"] if r else None

    def snapshot(self, scan_id: int) -> dict | None:
        """Scan, counts, every photo row, and the last event number, all from one read transaction."""
        db = self._db()
        db.execute("BEGIN")
        try:
            s = db.execute("SELECT * FROM scan WHERE id = ?", (scan_id,)).fetchone()
            if not s:
                return None
            rows = [photo_row(r) for r in db.execute(f"SELECT {PHOTO_COLS} FROM photo WHERE scan_id = ? ORDER BY seq", (scan_id,))]
            cursor = db.execute("SELECT coalesce(max(n), 0) FROM event WHERE scan_id = ?", (scan_id,)).fetchone()[0]
            scan = dict(s)
            scan["ratio"] = json.loads(scan["ratio"])
            scan["counts"] = self._counts(db, scan_id)
            return {"scan": scan, "photos": rows, "cursor": cursor}
        finally:
            db.execute("COMMIT")

    def set_state(self, scan_id: int, new: str, *, when: tuple[str, ...] | None = None, error: str | None = None) -> bool:
        """Compare-and-set: change the state only from one of `when` (any when None). True if it changed."""
        def go(db):
            q, args = "UPDATE scan SET state = ?, error = ? WHERE id = ?", [new, error, scan_id]
            if when:
                q += f" AND state IN ({','.join('?' * len(when))})"
                args += list(when)
            if db.execute(q, args).rowcount:
                self._scan_event(db, scan_id)
                return True
            return False
        return self._write(go)

    def stop(self, scan_id: int) -> str | None:
        """Idempotent: queued -> paused, running -> stopping; anything else unchanged."""
        if not self.set_state(scan_id, "paused", when=("queued",)):
            self.set_state(scan_id, "stopping", when=("running",))
        return self.state(scan_id)

    def resume(self, scan_id: int) -> str | None:
        """Idempotent: stopping -> running (the scheduler simply keeps going), paused / failed -> queued."""
        if not self.set_state(scan_id, "running", when=("stopping",)):
            self.set_state(scan_id, "queued", when=("paused", "failed"))
        return self.state(scan_id)

    def set_ratio(self, scan_id: int, ratio: dict) -> None:
        self._write(lambda db: db.execute("UPDATE scan SET ratio = ? WHERE id = ?", (json.dumps(ratio), scan_id)))

    def next_scan(self) -> dict | None:
        """What the scheduler does next: a scan being finalized, else the running one, else the oldest queued."""
        r = self._db().execute("SELECT id FROM scan WHERE state IN ('finalizing', 'running', 'queued') ORDER BY "
                               "CASE state WHEN 'finalizing' THEN 0 WHEN 'running' THEN 1 ELSE 2 END, id LIMIT 1").fetchone()
        return self.scan(r["id"]) if r else None

    # ---- photos -------------------------------------------------------------------------------------------------

    def queued(self, scan_id: int) -> list[dict]:
        return [dict(r) for r in self._db().execute(
            "SELECT id, path, size, mtime_ns FROM photo WHERE scan_id = ? AND state = 'queued' ORDER BY seq", (scan_id,))]

    def photo(self, photo_id: int) -> dict | None:
        r = self._db().execute(f"SELECT scan_id, {PHOTO_COLS} FROM photo WHERE id = ?", (photo_id,)).fetchone()
        return photo_row(r) if r else None

    def mark_working(self, photo_id: int) -> None:
        def go(db):
            if db.execute("UPDATE photo SET state = 'working' WHERE id = ? AND state = 'queued'", (photo_id,)).rowcount:
                self._photo_event(db, photo_id)
        self._write(go)

    def commit(self, photo_id: int, result: dict | None, error: str | None) -> None:
        """A photo's outcome and its event, one transaction; writing it again just overwrites."""
        def go(db):
            db.execute("UPDATE photo SET state = ?, result = ?, error = ? WHERE id = ?",
                       ("failed" if error else "done", json.dumps(result, ensure_ascii=False) if result else None, error, photo_id))
            self._photo_event(db, photo_id)
        self._write(go)

    def requeue_working(self, scan_id: int | None = None) -> int:
        def go(db):
            q = "SELECT id FROM photo WHERE state = 'working'" + (" AND scan_id = ?" if scan_id else "")
            ids = [r[0] for r in db.execute(q, (scan_id,) if scan_id else ())]
            for i in ids:
                db.execute("UPDATE photo SET state = 'queued' WHERE id = ?", (i,))
                self._photo_event(db, i)
            return len(ids)
        return self._write(go)

    def unfinished(self, scan_id: int) -> int:
        return self._db().execute("SELECT count(*) FROM photo WHERE scan_id = ? AND state NOT IN ('done', 'failed')",
                                  (scan_id,)).fetchone()[0]

    def rows_for_rating(self, scan_id: int) -> list[dict]:
        return [photo_row(r) for r in self._db().execute(f"SELECT {PHOTO_COLS} FROM photo WHERE scan_id = ? ORDER BY seq", (scan_id,))]

    def write_rating(self, scan_id: int, fields: dict[int, dict], complete: bool) -> None:
        """Per-scan fields (stars, reason, burst) for every photo, then one `stars` event (+ completed), atomically."""
        def go(db):
            for pid, f in fields.items():
                db.execute("UPDATE photo SET stars=?, star_reason=?, burst_group=?, burst_rank=?, burst_size=? WHERE id=? AND scan_id=?",
                           (f.get("stars"), f.get("star_reason"), f.get("burst_group"), f.get("burst_rank"), f.get("burst_size"), pid, scan_id))
            self._event(db, scan_id, "stars", {})
            if complete and db.execute("UPDATE scan SET state='completed', error=NULL WHERE id=? AND state='finalizing'", (scan_id,)).rowcount:
                self._scan_event(db, scan_id)
        self._write(go)

    # ---- events and recovery ------------------------------------------------------------------------------------

    def events_after(self, scan_id: int, n: int, limit: int = 500) -> list[dict]:
        return [{"n": r["n"], "kind": r["kind"], "data": json.loads(r["data"])} for r in self._db().execute(
            "SELECT n, kind, data FROM event WHERE scan_id = ? AND n > ? ORDER BY n LIMIT ?", (scan_id, n, limit))]

    def recover(self) -> None:
        """Engine start: photos left `working` go back to the queue; a scan that was running continues, one that was
        stopping is paused; `finalizing` stays and is redone by the scheduler."""
        self.requeue_working()
        for r in self._db().execute("SELECT id, state FROM scan WHERE state IN ('running', 'stopping')").fetchall():
            self.set_state(r["id"], "queued" if r["state"] == "running" else "paused", when=(r["state"],))
