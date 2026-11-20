"""birdcm serve | scan FOLDER [--json] | models [fetch]"""
from __future__ import annotations

import argparse
import json
import sys
import time
from birdcm.i18n import t


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="birdcm", description="观羽 BirdCM: local bird photo culling")
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("models", help="show model status; `models fetch` downloads what is missing")
    m.add_argument("action", nargs="?", choices=["status", "fetch"], default="status")
    co = sub.add_parser("corrections", help="the species corrections made in the app (a test set, never for tuning)")
    co.add_argument("action", choices=["export"])
    co.add_argument("--out", help="CSV file (default: stdout)")
    s = sub.add_parser("scan", help="run the pipeline on a folder and print results (no database)")
    s.add_argument("folder")
    s.add_argument("--json", action="store_true", help="one JSON object per photo (JSON lines)")
    s.add_argument("-r", "--recursive", action="store_true")
    s.add_argument("--limit", type=int)
    s.add_argument("--region")
    s.add_argument("--workers", type=int, default=4)
    ev = sub.add_parser("eval", help="run the pipeline over an evaluation list and report (fixed denominators)")
    ev.add_argument("--groundtruth", default="../../bioclip-bird/eval/groundtruth.csv")
    ev.add_argument("--photos", required=True, help="folder the groundtruth paths are relative to (minus 'photos/')")
    ev.add_argument("--kinds", default="bird", help="comma list: bird,mammal")
    ev.add_argument("--limit", type=int)
    ev.add_argument("--out", help="write the report and per-photo rows as JSON")
    ev.add_argument("--no-prior", action="store_true", help="image only: ignore the list's coordinates and dates")
    ev.add_argument("--place", choices=("point", "region"), default="point",
                    help="region: use the division / country around each photo instead of its coordinates")
    v = sub.add_parser("serve", help="start the local web app")
    v.add_argument("--port", type=int, default=8765)
    v.add_argument("--no-open", action="store_true", help="do not open the browser")
    sub.add_parser("admin", help="JSON commands for the macOS app (birdcm admin -h)").add_argument("args", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    from birdcm import admin
    admin.apply_config()
    if a.cmd == "admin":
        return admin.main(a.args)

    if a.cmd == "models":
        from birdcm import models
        if a.action == "fetch":
            return 1 if models.fetch() else 0
        st = models.status()
        for f in st["files"]:
            tag = "ok     " if f["path"] else t("cli.unreleased") if not f["released"] else t("cli.optional_missing") if f["optional"] else "MISSING"
            print(f"{tag} {f['role']:22s} {f['path'] or f['name']}")
        unrel = [o for o in st["optional_missing"] if not o["released"]]
        if unrel:
            print(t("cli.unreleased_list", n=len(unrel), names=t("cli.list_sep").join(o["name"] for o in unrel)))
            for o in unrel:
                print(f"  - {o['effect']}")
        print("ready" if st["ready"] else f"missing {len(st['missing'])}: {st['fetch_hint']}")
        return 0 if st["ready"] else 1

    if a.cmd == "corrections":
        import csv
        from birdcm import config
        from birdcm.store import Store
        rows = Store(config.data_dir() / "birdcm.db").all_corrections()
        f = open(a.out, "w", newline="", encoding="utf-8") if a.out else sys.stdout
        w = csv.writer(f)
        w.writerow(["file", "app_species", "corrected_species", "scope"])
        for r in rows:
            w.writerow([r["path"], r["app"] or "", r["species"] or "不确定", r["scope"]])
        if a.out:
            f.close()
        return 0

    if a.cmd == "scan":
        return scan(a)

    if a.cmd == "eval":
        from birdcm import evaluate
        print(json.dumps(evaluate.run(a.groundtruth, a.photos, tuple(a.kinds.split(",")), a.limit, a.out, prior=not a.no_prior, place=a.place), ensure_ascii=False, indent=1))
        return 0

    from birdcm import app
    return app.serve(a.port, open_browser=not a.no_open)


def scan(a) -> int:
    import os

    from birdcm import config, decode
    from birdcm.pipeline import Engine
    config.check_own_dirs(a.folder)
    paths = decode.list_photos(a.folder, a.recursive)[:a.limit]
    t0 = time.perf_counter()
    engine = Engine(workers=a.workers)
    t_load = time.perf_counter() - t0
    items = []
    for i, p in enumerate(paths):
        st = os.stat(p)
        items.append({"id": i, "path": str(p), "size": st.st_size, "mtime_ns": st.st_mtime_ns})
    t1, n_ok, n_bird, first = time.perf_counter(), 0, 0, None
    try:
        for it, res, err in engine.run(items, region=a.region):
            first = first or time.perf_counter() - t1
            if a.json:
                print(json.dumps({"path": it["path"], "result": res, "error": err}, ensure_ascii=False), flush=True)
            elif err:
                print(f"{os.path.basename(it['path'])}  FAILED {err}")
            else:
                sp = res["species"]
                name = (sp["label"]["zh"] or sp["label"]["en"] or sp["label"]["sci"]) if sp and sp["label"] else (t("cli.uncertain") if sp else "—")
                print(f"{res['file']}  {len(res['boxes'])} box  {name}  {t('cli.flying') if res['flying'] else ''}")
            n_ok += err is None
            n_bird += bool(res and not res["rejected"])
    finally:
        engine.close()
    dt = time.perf_counter() - t1
    print(json.dumps({"photos": len(items), "ok": n_ok, "with_bird": n_bird, "model_load_s": round(t_load, 1),
                      "run_s": round(dt, 1), "photos_per_s": round(len(items) / dt, 2) if dt else None,
                      "first_result_s": round(first or 0, 2), "stage_s": {k: round(v, 1) for k, v in engine.stats.items()}},
                     ensure_ascii=False), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
