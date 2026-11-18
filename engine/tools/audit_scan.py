"""Read-only audit of one scan in the app's database: counts the oddities worth a look, with a few example files each.

  uv run python tools/audit_scan.py SCAN_ID [DB_PATH]        (default DB: the app's data dir)

Opens the database read-only (sqlite mode=ro); never touches photos or caches.
"""
import json
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from birdcm import config  # noqa: E402
from birdcm.decode import VARIANT_SUFFIXES  # noqa: E402
from birdcm.names import relabel  # noqa: E402


def load(db: sqlite3.Connection, sid: int) -> list[dict]:
    rows = []
    for r in db.execute("SELECT path, stars, burst_group, result, species_fix FROM photo WHERE scan_id = ? ORDER BY seq", (sid,)):
        rows.append({"file": Path(r[0]).name, "stars": r[1], "burst": r[2],
                     "result": relabel(json.loads(r[3])) if r[3] else None, "fix": json.loads(r[4]) if r[4] else None})
    return rows


def audit(rows: list[dict]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = defaultdict(list)
    eff = {}
    for p in rows:
        r = p["result"]
        eff[p["file"]] = None if not r or r["rejected"] else (p["fix"] or r["species"])
    by_burst = defaultdict(list)
    for p in rows:
        by_burst[p["burst"]].append(p)
    for b, ps in by_burst.items():
        names = {(eff[p["file"]] or {}).get("label", {}).get("sci") for p in ps
                 if (eff[p["file"]] or {}).get("level") == "species"}
        if len(names) > 1:
            out["burst with more than one confirmed species after correction"].append(f"group {b}: {', '.join(sorted(names))}")
    for p in rows:
        r, f = p["result"], p["file"]
        if not r:
            continue
        own = r.get("species")
        if r["rejected"]:
            best = max((x["species"]["top5"][0]["p"] for x in r.get("boxes", []) if x.get("species") and x["species"].get("top5")), default=0)
            if best >= 0.9:
                out["rejected although a box names a bird at >= 90 %"].append(f"{f} ({best:.2f})")
            continue
        if own and own["level"] != "species" and own["top5"] and own["top5"][0]["p"] >= 0.95:
            why = "range rule" if own.get("override") else "no rule recorded"
            out["genus / 不确定 although its own first name is >= 95 %"].append(f"{f} ({own['top5'][0]['sci']} {own['top5'][0]['p']:.2f}, {why})")
        fix = p["fix"]
        if fix and own and fix["label"]["sci"] not in {c["sci"] for c in own["top5"]}:
            out["corrected to a species absent from its own top five"].append(f"{f} -> {fix['label']['sci']}")
        if (p["stars"] or 0) > 0 and r.get("eye_visible") is False and not r.get("flying"):
            out["starred, perched, eye not visible"].append(f"{f} ({p['stars']}★)")
        e = eff[f]
        rar = (fix or {}).get("rarity") if fix else r.get("rarity")
        if rar and rar.get("tier") is not None and (not e or e.get("level") != "species"):
            out["rarity tier on a photo without a confirmed species"].append(f)
    for p in rows:
        stem = Path(p["file"]).stem.lower()
        if Path(p["file"]).suffix.lower() == ".dng" and any(stem.endswith(x) for x in VARIANT_SUFFIXES):
            out["Lightroom variant left as its own photo (not paired)"].append(p["file"])
    return out


def main() -> None:
    sid = int(sys.argv[1])
    path = sys.argv[2] if len(sys.argv) > 2 else str(config.data_dir() / "birdcm.db")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    rows = load(db, sid)
    found = audit(rows)
    print(f"scan {sid}: {len(rows)} photos, {len({p['burst'] for p in rows})} bursts")
    checks = ["burst with more than one confirmed species after correction", "genus / 不确定 although its own first name is >= 95 %",
              "corrected to a species absent from its own top five", "rejected although a box names a bird at >= 90 %",
              "starred, perched, eye not visible", "Lightroom variant left as its own photo (not paired)",
              "rarity tier on a photo without a confirmed species"]
    for k in checks:
        v = found.get(k, [])
        print(f"{len(v):5d}  {k}" + (f"   e.g. {'; '.join(v[:4])}" if v else ""))


if __name__ == "__main__":
    main()
