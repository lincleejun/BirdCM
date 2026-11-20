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

from birdcm.names import relabel

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS scan (
  id INTEGER PRIMARY KEY, folder TEXT NOT NULL, recursive INTEGER NOT NULL, region TEXT, ratio TEXT NOT NULL,
  fp TEXT NOT NULL, state TEXT NOT NULL, error TEXT, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS photo (
  id INTEGER PRIMARY KEY, scan_id INTEGER NOT NULL REFERENCES scan(id), seq INTEGER NOT NULL, path TEXT NOT NULL,
  size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, state TEXT NOT NULL, fp TEXT, result TEXT, error TEXT, reused INTEGER DEFAULT 0,
  stars INTEGER, star_reason TEXT, burst_group INTEGER, burst_rank INTEGER, burst_size INTEGER, species_fix TEXT, quality TEXT,
  variants TEXT, star_auto TEXT, UNIQUE (scan_id, path));
CREATE INDEX IF NOT EXISTS photo_reuse ON photo(path, size, mtime_ns, fp) WHERE state = 'done';
CREATE INDEX IF NOT EXISTS photo_scan_state ON photo(scan_id, state);
CREATE TABLE IF NOT EXISTS event (
  n INTEGER PRIMARY KEY AUTOINCREMENT, scan_id INTEGER NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS event_scan ON event(scan_id, n);
CREATE TABLE IF NOT EXISTS correction (
  path TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, species TEXT, scope TEXT NOT NULL,
  app TEXT, created_at REAL NOT NULL, PRIMARY KEY (path, size, mtime_ns));
CREATE TABLE IF NOT EXISTS star_fix (
  path TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, stars INTEGER NOT NULL, created_at REAL NOT NULL,
  PRIMARY KEY (path, size, mtime_ns));
CREATE TABLE IF NOT EXISTS single (
  id INTEGER PRIMARY KEY, stored TEXT NOT NULL, name TEXT NOT NULL, created_at REAL NOT NULL, region TEXT,
  boxes TEXT, subject INTEGER, result TEXT, error TEXT, fp TEXT, correction TEXT);
CREATE TABLE IF NOT EXISTS xmp_batch (id INTEGER PRIMARY KEY, scan_id INTEGER NOT NULL, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS xmp_file (
  batch_id INTEGER NOT NULL REFERENCES xmp_batch(id), path TEXT NOT NULL, before BLOB, after_sha TEXT NOT NULL, ours TEXT NOT NULL,
  PRIMARY KEY (batch_id, path));
CREATE TABLE IF NOT EXISTS place_name (key TEXT PRIMARY KEY, label TEXT, fetched REAL NOT NULL);
"""
# scan.state: queued -> running -> stopping -> paused -> finalizing -> completed; failed = fatal engine error
TERMINAL = ("done", "failed")
PHOTO_COLS = "id, seq, path, size, mtime_ns, state, result, error, reused, stars, star_reason, burst_group, burst_rank, burst_size, species_fix, quality, variants, star_auto"


def location(v):
    """A scan's stored location: a JSON object {lat, lon, label, source} or, for older scans, a plain label."""
    if isinstance(v, str) and v.startswith("{"):
        try:
            return json.loads(v)
        except ValueError:
            return v
    return v


def present(v):
    """A stored result as shown today: Chinese names from the current table, and no IUCN category anywhere when it is
    switched off (BIRDCM_IUCN=0) — old batch, single and export results included (Codex I7)."""
    from birdcm import rarity
    v = relabel(v)
    if not rarity.SHOW_IUCN:
        def strip(x):
            if isinstance(x, dict):
                if "iucn" in x:
                    x["iucn"] = None
                for y in x.values():
                    strip(y)
            elif isinstance(x, list):
                for y in x:
                    strip(y)
        strip(v)
    return v


def slim(r: dict) -> dict:
    """A result as the list needs it (snapshot, photo events): each box without its own species block (the subject's
    is the photo's species) and without the likeness thumbnail. The full row: GET /api/photos/{id}. Codex P2."""
    r = {k: v for k, v in r.items() if k != "look"}
    r["boxes"] = [{k: v for k, v in b.items() if k != "species"} for b in r.get("boxes") or []]
    return r


def photo_row(r: sqlite3.Row, slim_result: bool = False) -> dict:
    """slim_result: the list's shape, cut before the names are joined (half the cost of a 5,000-photo snapshot)."""
    d = dict(r)
    d["result"] = present((slim if slim_result else lambda x: x)(json.loads(d["result"]))) if d["result"] else None
    d["species_fix"] = present(json.loads(d["species_fix"])) if d.get("species_fix") else None
    d["quality"] = json.loads(d["quality"]) if d.get("quality") else None
    d["variants"] = json.loads(d["variants"]) if d.get("variants") else []
    d["star_auto"] = json.loads(d["star_auto"]) if d.get("star_auto") else None
    if (d.get("star_reason") or "").startswith("["):                   # a code (i18n.R); older rows: a Chinese sentence
        d["star_reason"] = json.loads(d["star_reason"])
    d["file"] = Path(d["path"]).name
    return d


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self._local = threading.local()
        with self.lock:
            db = self._db()
            db.executescript(SCHEMA)
            have = {r[1] for r in db.execute("PRAGMA table_info(photo)")}
            for col in ("species_fix", "quality", "variants", "star_auto"):                 # databases from before these columns
                if col not in have:
                    db.execute(f"ALTER TABLE photo ADD COLUMN {col} TEXT")
            have_s = {r[1] for r in db.execute("PRAGMA table_info(single)")}
            for col in ("fp", "correction"):
                if col not in have_s:
                    db.execute(f"ALTER TABLE single ADD COLUMN {col} TEXT")
            from birdcm import library
            self.library_ok = library.init(db)              # the life list's derived index (additive, user_version 1)

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

    def _touch(self, db: sqlite3.Connection) -> None:
        """A life-list source changed in this transaction: the derived index must be rebuilt (library.py)."""
        if self.library_ok:
            from birdcm import library
            library.touch(db)

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
        row = photo_row(r, slim_result=True)
        self._event(db, row.pop("scan_id"), "photo", row)

    # ---- scans --------------------------------------------------------------------------------------------------

    def create_scan(self, folder: str, recursive: bool, region, ratio: dict, fp: str,
                    files: list[tuple[str, int, int]], variants: dict[str, list[str]] | None = None) -> int:
        """files: (path, size, mtime_ns), one per shot; variants: original path -> derived files of the same shot (listed,
        never analysed or rated). Photos whose (path, size, mtime, fingerprint) match a finished result of an
        earlier scan are done at once with that result copied; the rest are queued."""
        def go(db):
            sid = db.execute("INSERT INTO scan (folder, recursive, region, ratio, fp, state, created_at) VALUES (?,?,?,?,?,?,?)",
                             (folder, int(recursive), json.dumps(region, ensure_ascii=False) if isinstance(region, dict) else region,
                              json.dumps(ratio), fp, "queued", time.time())).lastrowid
            for seq, (path, size, mtime) in enumerate(files):
                old = db.execute("SELECT result FROM photo WHERE path=? AND size=? AND mtime_ns=? AND fp=? AND state='done' "
                                 "ORDER BY id DESC LIMIT 1", (path, size, mtime, fp)).fetchone()
                v = (variants or {}).get(path)
                db.execute("INSERT INTO photo (scan_id, seq, path, size, mtime_ns, state, fp, result, reused, variants) VALUES (?,?,?,?,?,?,?,?,?,?)",
                           (sid, seq, path, size, mtime, "done" if old else "queued", fp, old["result"] if old else None, int(bool(old)),
                            json.dumps(v) if v else None))
            self._scan_event(db, sid)
            return sid
        return self._write(go)

    def scans(self, every: bool = False) -> list[dict]:
        """Newest first. One folder, one current result: a scan of the same folder (and recursive flag) supersedes the
        older ones, which are listed under it as `previous` (ids, newest first) and left out unless every=True."""
        db = self._db()
        out, seen = [], {}
        for r in db.execute("SELECT id, folder, recursive, region, ratio, fp, state, error, created_at FROM scan ORDER BY id DESC"):
            d = dict(r)
            d["ratio"] = json.loads(d["ratio"])
            d["region"] = location(d["region"])
            key = (d["folder"], d["recursive"])
            if key in seen:
                seen[key]["previous"].append(d["id"])
                if d["state"] == "completed" and seen[key]["state"] != "completed" and not seen[key].get("last_completed"):
                    seen[key]["last_completed"] = d["id"]          # the newest scan failed / paused: the last good one
                if not every:
                    continue
            else:
                d["previous"] = []
                seen[key] = d
            d["counts"] = self._counts(db, r["id"])
            out.append(d)
        return out

    def related(self, scan_id: int) -> dict:
        """The newest scan of the same folder when it is newer than this one (else None), and the scan just before it."""
        db = self._db()
        s = db.execute("SELECT folder, recursive FROM scan WHERE id = ?", (scan_id,)).fetchone()
        if not s:
            return {"newer": None, "previous": None}
        ids = [r[0] for r in db.execute("SELECT id FROM scan WHERE folder = ? AND recursive = ? ORDER BY id DESC", (s[0], s[1]))]
        newer = ids[0] if ids and ids[0] != scan_id else None
        prev = next((i for i in ids if i < scan_id), None)
        info = None
        if newer:
            st = db.execute("SELECT state FROM scan WHERE id = ?", (newer,)).fetchone()[0]
            info = {"id": newer, "state": st, "counts": self._counts(db, newer)}
        cursor = db.execute("SELECT coalesce(max(n), 0) FROM event WHERE scan_id = ?", (scan_id,)).fetchone()[0]
        return {"newer": info, "previous": prev, "cursor": cursor}      # cursor: another tab re-rated it (Codex I1)

    def scan(self, scan_id: int) -> dict | None:
        r = self._db().execute("SELECT * FROM scan WHERE id = ?", (scan_id,)).fetchone()
        if not r:
            return None
        d = dict(r)
        d["ratio"] = json.loads(d["ratio"])
        d["region"] = location(d["region"])
        return d

    def state(self, scan_id: int) -> str | None:
        r = self._db().execute("SELECT state FROM scan WHERE id = ?", (scan_id,)).fetchone()
        return r["state"] if r else None

    def snapshot(self, scan_id: int, slim_results: bool = False) -> dict | None:
        """Scan, counts, every photo row, and the last event number, all from one read transaction."""
        db = self._db()
        db.execute("BEGIN")
        try:
            s = db.execute("SELECT * FROM scan WHERE id = ?", (scan_id,)).fetchone()
            if not s:
                return None
            rows = [photo_row(r, slim_results) for r in db.execute(f"SELECT {PHOTO_COLS} FROM photo WHERE scan_id = ? ORDER BY seq", (scan_id,))]
            cursor = db.execute("SELECT coalesce(max(n), 0) FROM event WHERE scan_id = ?", (scan_id,)).fetchone()[0]
            scan = dict(s)
            scan["ratio"] = json.loads(scan["ratio"])
            scan["region"] = location(scan["region"])
            scan["counts"] = self._counts(db, scan_id)
            return {"scan": scan, "photos": rows, "cursor": cursor}
        finally:
            db.execute("COMMIT")

    def set_state(self, scan_id: int, new: str, *, when: tuple[str, ...] | None = None, error: str | None = None) -> bool:
        """Compare-and-set: change the state only from one of `when` (any when None). True if it changed."""
        def go(db):
            old = db.execute("SELECT state FROM scan WHERE id = ?", (scan_id,)).fetchone()
            q, args = "UPDATE scan SET state = ?, error = ? WHERE id = ?", [new, error, scan_id]
            if when:
                q += f" AND state IN ({','.join('?' * len(when))})"
                args += list(when)
            if db.execute(q, args).rowcount:
                self._scan_event(db, scan_id)
                if new == "completed" or (old and old[0] == "completed"):    # which scan counts for its folder changed
                    self._touch(db)
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

    def commit(self, photo_id: int, result: dict | None, error: str | None, fp: str | None = None) -> None:
        """A photo's outcome and its event, one transaction; writing it again just overwrites. fp: the fingerprint of
        the engine that computed it (what reuse matches on)."""
        def go(db):
            db.execute("UPDATE photo SET state = ?, result = ?, error = ?, fp = coalesce(?, fp) WHERE id = ?",
                       ("failed" if error else "done", json.dumps(result, ensure_ascii=False) if result else None, error, fp, photo_id))
            self._photo_event(db, photo_id)
        self._write(go)

    def unpair(self, scan_id: int, wrong: list[tuple[str, str]]) -> None:
        """Variants that turned out to be other shots: off their original's list, in as photos of their own (queued;
        a finished scan goes back to the queue for them)."""
        def go(db):
            seq = db.execute("SELECT coalesce(max(seq), -1) FROM photo WHERE scan_id = ?", (scan_id,)).fetchone()[0]
            for main, v in wrong:
                r = db.execute("SELECT id, variants FROM photo WHERE scan_id = ? AND path = ?", (scan_id, main)).fetchone()
                if r:
                    left = [x for x in json.loads(r[1] or "[]") if x != v]
                    db.execute("UPDATE photo SET variants = ? WHERE id = ?", (json.dumps(left) if left else None, r[0]))
                try:
                    st = Path(v).stat()
                except OSError:
                    continue
                seq += 1
                db.execute("INSERT OR IGNORE INTO photo (scan_id, seq, path, size, mtime_ns, state) VALUES (?,?,?,?,?,?)",
                           (scan_id, seq, v, st.st_size, st.st_mtime_ns, "queued"))
            db.execute("UPDATE scan SET state = 'queued' WHERE id = ? AND state = 'completed'", (scan_id,))
            self._scan_event(db, scan_id)
            self._touch(db)
        self._write(go)

    # ---- the person's species corrections: keyed by the file's signature, so they outlive re-scans and fingerprints --

    def set_corrections(self, photo_ids: list[int], sci: str | None, scope: str) -> None:
        """sci None = marked 不确定. app = what the app said (its own or burst-corrected name) when corrected."""
        def go(db):
            for pid in photo_ids:
                r = db.execute("SELECT path, size, mtime_ns, result, species_fix FROM photo WHERE id = ?", (pid,)).fetchone()
                if not r:
                    continue
                fix = json.loads(r["species_fix"]) if r["species_fix"] else None
                own = (json.loads(r["result"]) or {}).get("species") if r["result"] else None
                app = (fix if fix and not fix.get("manual") else own) or {}
                app_name = (app.get("label") or {}).get("sci") if app.get("level") in ("species", "genus") else None
                db.execute("INSERT OR REPLACE INTO correction (path, size, mtime_ns, species, scope, app, created_at) VALUES (?,?,?,?,?,?,?)",
                           (r["path"], r["size"], r["mtime_ns"], sci, scope, app_name, time.time()))
            self._touch(db)
        self._write(go)

    def clear_corrections(self, photo_ids: list[int]) -> None:
        def go(db):
            for pid in photo_ids:
                db.execute("DELETE FROM correction WHERE (path, size, mtime_ns) = (SELECT path, size, mtime_ns FROM photo WHERE id = ?)", (pid,))
            self._touch(db)
        self._write(go)

    def corrections_for(self, scan_id: int) -> dict[int, dict]:
        """photo id -> {sci (None = 不确定), scope, app} for the photos of a scan that the person corrected."""
        return {r[0]: {"sci": r[1], "scope": r[2], "app": r[3]} for r in self._db().execute(
            "SELECT p.id, c.species, c.scope, c.app FROM photo p JOIN correction c ON c.path = p.path AND c.size = p.size "
            "AND c.mtime_ns = p.mtime_ns WHERE p.scan_id = ?", (scan_id,))}

    # ---- the person's stars: keyed like the corrections; stars.rate puts them over the computed ones -----------------

    def set_star_fixes(self, photo_ids: list[int], stars: int | None) -> None:
        """stars None = back to the computed stars."""
        def go(db):
            for pid in photo_ids:
                if stars is None:
                    db.execute("DELETE FROM star_fix WHERE (path, size, mtime_ns) = (SELECT path, size, mtime_ns FROM photo WHERE id = ?)", (pid,))
                else:
                    db.execute("INSERT OR REPLACE INTO star_fix (path, size, mtime_ns, stars, created_at) "
                               "SELECT path, size, mtime_ns, ?, ? FROM photo WHERE id = ?", (stars, time.time(), pid))
        self._write(go)

    def star_fixes_for(self, scan_id: int) -> dict[int, int]:
        """photo id -> the person's stars, for the photos of a scan that have them."""
        return {r[0]: r[1] for r in self._db().execute(
            "SELECT p.id, f.stars FROM photo p JOIN star_fix f ON f.path = p.path AND f.size = p.size "
            "AND f.mtime_ns = p.mtime_ns WHERE p.scan_id = ?", (scan_id,))}

    # ---- XMP sidecars we wrote (xmp.py): before = the sidecar's bytes before our write (NULL: there was none) ---------

    def xmp_record(self, scan_id: int, files: list[dict]) -> int:
        def go(db):
            bid = db.execute("INSERT INTO xmp_batch (scan_id, created_at) VALUES (?, ?)", (scan_id, time.time())).lastrowid
            db.executemany("INSERT INTO xmp_file (batch_id, path, before, after_sha, ours) VALUES (?,?,?,?,?)",
                           [(bid, f["path"], f["before"], f["after_sha"], json.dumps(f["ours"], ensure_ascii=False)) for f in files])
            return bid
        return self._write(go)

    def xmp_forget(self, batch_id: int, path: str) -> None:
        self._write(lambda db: db.execute("DELETE FROM xmp_file WHERE batch_id = ? AND path = ?", (batch_id, path)))

    def xmp_drop(self, batch_id: int) -> None:
        def go(db):
            db.execute("DELETE FROM xmp_file WHERE batch_id = ?", (batch_id,))
            db.execute("DELETE FROM xmp_batch WHERE id = ?", (batch_id,))
        self._write(go)

    def xmp_last(self, path: str) -> dict | None:
        """What our latest write to this sidecar added ({keywords, pick}), whichever scan wrote it."""
        r = self._db().execute("SELECT ours FROM xmp_file WHERE path = ? ORDER BY batch_id DESC LIMIT 1", (path,)).fetchone()
        return json.loads(r[0]) if r else None

    def xmp_batch(self, scan_id: int) -> dict | None:
        """This scan's latest batch: {id, created_at, files: [{path, before, after_sha}]}."""
        b = self._db().execute("SELECT id, created_at FROM xmp_batch WHERE scan_id = ? ORDER BY id DESC LIMIT 1", (scan_id,)).fetchone()
        if not b:
            return None
        files = [dict(r) for r in self._db().execute("SELECT path, before, after_sha FROM xmp_file WHERE batch_id = ?", (b[0],))]
        return {"id": b[0], "created_at": b[1], "files": files}

    def all_corrections(self) -> list[dict]:
        return [dict(r) for r in self._db().execute("SELECT path, species, scope, app, created_at FROM correction ORDER BY created_at")]

    def move_fp(self, scan_id: int, old: str, new: str) -> None:
        """Relabel a scan (and its photos, so they stay reusable) from an equivalent old fingerprint to the current one."""
        def go(db):
            db.execute("UPDATE scan SET fp = ? WHERE id = ? AND fp = ?", (new, scan_id, old))
            db.execute("UPDATE photo SET fp = ? WHERE scan_id = ? AND fp = ?", (new, scan_id, old))
        self._write(go)

    def reset_scan(self, scan_id: int, fp: str) -> None:
        """The engine's fingerprint differs from the scan's: drop every result and queue the whole scan again."""
        def go(db):
            db.execute("UPDATE scan SET fp = ? WHERE id = ?", (fp, scan_id))
            db.execute("UPDATE photo SET state='queued', result=NULL, error=NULL, reused=0, fp=?, stars=NULL, star_reason=NULL, "
                       "burst_group=NULL, burst_rank=NULL, burst_size=NULL, species_fix=NULL, quality=NULL, star_auto=NULL WHERE scan_id = ?", (fp, scan_id))
            self._event(db, scan_id, "stars", {})                 # clients refetch the snapshot
            self._scan_event(db, scan_id)
            self._touch(db)
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

    def write_rating(self, scan_id: int, fields: dict[int, dict], complete: bool, ratio: dict | None = None,
                     set_ratio: bool = False) -> bool:
        """Per-scan fields (stars, reason, burst) for every photo, then one `stars` event (+ completed), atomically.
        ratio: the settings these stars were computed with. set_ratio=True stores it with them (a settings change);
        otherwise the write is refused (False) when the scan's settings are no longer these (changed meanwhile):
        settings and stars are always one consistent pair."""
        def go(db):
            if ratio is not None:
                if set_ratio:
                    db.execute("UPDATE scan SET ratio = ? WHERE id = ?", (json.dumps(ratio), scan_id))
                else:
                    cur = db.execute("SELECT ratio FROM scan WHERE id = ?", (scan_id,)).fetchone()
                    if cur is None or json.loads(cur[0]) != ratio:
                        return False
            for pid, f in fields.items():
                fix = f.get("species_fix")
                qual = {"q": f["q"], "parts": f.get("q_parts")} if f.get("q") is not None else None
                auto = f.get("star_auto")
                db.execute("UPDATE photo SET stars=?, star_reason=?, burst_group=?, burst_rank=?, burst_size=?, species_fix=?, quality=?, "
                           "star_auto=? WHERE id=? AND scan_id=?",
                           (f.get("stars"), json.dumps(f["star_reason"], ensure_ascii=False) if isinstance(f.get("star_reason"), list) else f.get("star_reason"), f.get("burst_group"), f.get("burst_rank"), f.get("burst_size"),
                            json.dumps(fix, ensure_ascii=False) if fix else None, json.dumps(qual) if qual else None,
                            json.dumps(auto, ensure_ascii=False) if auto else None, pid, scan_id))
            self._event(db, scan_id, "stars", {})
            self._touch(db)                                        # burst species / corrections changed
            if complete and db.execute("UPDATE scan SET state='completed', error=NULL WHERE id=? AND state='finalizing'", (scan_id,)).rowcount:
                self._scan_event(db, scan_id)
            return True
        return self._write(go)

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

    # ---- single photos (history) ----------------------------------------------------------------------------------

    @staticmethod
    def _single(r: sqlite3.Row) -> dict:
        d = dict(r)
        d["result"] = present(json.loads(d["result"])) if d["result"] else None
        d["boxes"] = json.loads(d["boxes"]) if d["boxes"] else None
        d["region"] = location(d["region"])
        d["correction"] = json.loads(d["correction"]) if d.get("correction") else None
        return d

    def add_single(self, stored: str, name: str, region) -> int:
        reg = json.dumps(region, ensure_ascii=False) if isinstance(region, dict) else region
        return self._write(lambda db: db.execute("INSERT INTO single (stored, name, created_at, region) VALUES (?,?,?,?)",
                                                 (stored, name, time.time(), reg)).lastrowid)

    def update_single(self, sid: int, **f) -> None:
        reg = f.get("region")
        cols = {"region": json.dumps(reg, ensure_ascii=False) if isinstance(reg, dict) else reg, "boxes": json.dumps(f["boxes"]) if f.get("boxes") is not None else None,
                "subject": f.get("subject"), "result": json.dumps(f["result"], ensure_ascii=False) if f.get("result") else None,
                "error": f.get("error"), "fp": f.get("fp"),
                "correction": json.dumps(f["correction"], ensure_ascii=False) if f.get("correction") is not None else None}
        keys = [k for k in cols if k in f]
        if keys:
            def go(db):
                db.execute(f"UPDATE single SET {', '.join(k + ' = ?' for k in keys)} WHERE id = ?", [cols[k] for k in keys] + [sid])
                self._touch(db)
            self._write(go)

    def single(self, sid: int) -> dict | None:
        r = self._db().execute("SELECT * FROM single WHERE id = ?", (sid,)).fetchone()
        return self._single(r) if r else None

    def singles(self) -> list[dict]:
        return [self._single(r) for r in self._db().execute("SELECT * FROM single ORDER BY id DESC")]

    def delete_singles(self, sid: int | None = None) -> list[str]:
        """Delete one (or every) history entry; returns the stored file names so the caller removes the originals."""
        def go(db):
            q, a = ("SELECT stored FROM single WHERE id = ?", (sid,)) if sid is not None else ("SELECT stored FROM single", ())
            names = [r[0] for r in db.execute(q, a)]
            db.execute("DELETE FROM single" + (" WHERE id = ?" if sid is not None else ""), (sid,) if sid is not None else ())
            self._touch(db)
            return names
        return self._write(go)

