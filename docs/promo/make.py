"""Rebuild docs/promo/promo.mp4 and promo.gif from real app screens (CC0 fixture photos only, never a real library).

  iOS shots: the AppearanceSnapshots + Step4Snapshots unit tests with TEST_RUNNER_SCREENSHOT_DIR=<ios>, simulator
             'BirdCM 18 Pro' (see ios/README.md); uses result / identify / species-page / stats (-light).
  Desktop:   `birdcm serve --no-open --port 8799` with BIRDCM_CONFIG / BIRDCM_DATA_DIR / BIRDCM_CACHE_DIR in a scratch
             dir, one scan of ios/Tests/Fixtures/photo-0..3.jpg (with a made-up date and Bolsa Chica GPS), then
             `python make.py capture <desk>`.
  Render:    `python make.py render <ios> <desk>`  (needs ffmpeg; Playwright: `uv run --with playwright python make.py`).
Set CHROME to a Chromium binary if Playwright's own is not installed.
"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FPS = 24


def browser(p):
    return p.chromium.launch(**({"executable_path": os.environ["CHROME"]} if os.environ.get("CHROME") else {}))


def capture(out: str):
    with sync_playwright() as p:
        b = browser(p)
        pg = b.new_page(viewport={"width": 1280, "height": 800}, device_scale_factor=2, locale="zh-CN")
        pg.route("**/hero.jpg", lambda r: r.abort())          # the owner's own photo: never captured
        pg.route("**/tile.openstreetmap.org/**", lambda r: r.abort())
        for name, q in [("home", "?view=batch"), ("scan", "?scan=1"), ("stats", "?view=stats")]:
            pg.goto(f"http://127.0.0.1:8799/{q}"); pg.wait_for_timeout(2500)
            pg.screenshot(path=f"{out}/{name}.png")
        b.close()


def render(ios: str, desk: str):
    work = Path(tempfile.mkdtemp())
    (work / "shots").mkdir()
    shutil.copy(HERE / "promo.html", work)
    shutil.copy(ROOT / "ios/design/icon/B.svg", work / "shots/icon.svg")
    for n in ["identify", "result", "species-page"]:
        shutil.copy(f"{ios}/-[Flows testDarkLargestAndLoading]-{n}-light.png", work / f"shots/{n}-light.png")
    shutil.copy(f"{ios}/-[Flows testStep4Screens]-stats-light.png", work / "shots/stats-light.png")
    for n in ["home", "scan", "stats"]:
        shutil.copy(f"{desk}/{n}.png", work / f"shots/{n}.png")
    frames = work / "frames"; frames.mkdir()
    with sync_playwright() as p:
        b = browser(p)
        pg = b.new_page(viewport={"width": 960, "height": 540}, device_scale_factor=2)
        pg.goto((work / "promo.html").as_uri()); pg.wait_for_load_state("networkidle")
        n = round(pg.evaluate("DURATION") * FPS)
        for i in range(n):
            pg.evaluate(f"seek({i / FPS})")
            pg.screenshot(path=frames / f"{i:04d}.png")
        b.close()
    src = ["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(FPS), "-i", str(frames / "%04d.png")]
    subprocess.run([*src, "-an", "-c:v", "libx264", "-crf", "20", "-preset", "slow", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(HERE / "promo.mp4")], check=True)
    pal = work / "palette.png"
    scale = "fps=12,scale=960:540:flags=lanczos"
    subprocess.run([*src, "-vf", f"{scale},palettegen=max_colors=256:stats_mode=diff", str(pal)], check=True)
    subprocess.run([*src, "-i", str(pal), "-lavfi", f"{scale}[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                    "-loop", "0", str(HERE / "promo.gif")], check=True)
    print(work)


if __name__ == "__main__":
    {"capture": capture, "render": render}[sys.argv[1]](*sys.argv[2:])
