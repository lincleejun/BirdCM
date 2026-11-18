# 观羽.app — the macOS installer

A menu-bar app (no Dock icon) that runs the BirdCM engine in the background and opens the web UI in the default
browser. Apple Silicon only (arm64), macOS 13 or later. Nothing needs to be installed on the user's Mac: Python, the
engine's dependencies, the built web UI and ExifTool are inside the app; the model files are downloaded on first use.

## Build

```sh
macos/build.sh                      # -> macos/dist/观羽-<version>-arm64.dmg (ad-hoc signed)
SIGN_ID="Developer ID Application: NAME (TEAMID)" macos/build.sh      # signed for distribution
```

Needs on the build Mac: `uv`, `npm`, `swift` (the Command Line Tools are enough; no Xcode), network on the first build.
About 3 minutes. Steps: `npm ci && npm run build` (web) → copy uv's python-build-standalone CPython 3.12.11 →
`uv export --frozen` + `uv pip install` the locked dependencies and the engine into that copy (no venv) → trim
(torch headers, pip, Tk, console scripts) and pre-compile `.pyc` → ExifTool 13.64 (pinned sha256) → `swift build` the
menu-bar shell → draw the icon (`tools/icon.swift`) → sign every Mach-O inside, then the app → `hdiutil` (ULMO).

`web/public/hero.jpg` (the home page's example photo) is gitignored; a build from a fresh clone ships without it and the
home page shows its text mark instead.

## What is inside

| Path in `观羽.app/Contents` | What | Size |
|---|---|---|
| `MacOS/BirdCM` | the menu-bar shell (SwiftUI, `Sources/main.swift`) | 0.4 MB |
| `Resources/engine/python` | CPython 3.12.11 + the locked dependencies (torch 2.15 ≈ 520 MB of it) | 1.1 GB |
| `Resources/engine/exiftool` | ExifTool 13.64 (Perl, runs on macOS's `/usr/bin/perl`) | 20 MB |
| `Resources/engine/web` | the built web UI | 0.4 MB |
| `Resources/engine/birdcm` | launcher: bundled Python, `PATH=<exiftool>:/usr/bin:/bin:/usr/sbin:/sbin`, `python -I -B` | |
| `Resources/engine/models.toml` | the model manifest | |
| `Resources/licenses` | MIT licence, NOTICE.md, Python / ExifTool licences, THIRD-PARTY.md | |

dmg ≈ 215 MB, installed ≈ 1.2 GB, models downloaded on first use ≈ 0.83 GB (three files not released yet).

Why a bundled Python and not "uv + lockfile, environment built on first launch": that option makes a ~50 MB app but
then downloads ~265 MB of wheels plus a Python at first launch (1.0 GB installed either way), needs the network for
that, and fails in more ways (proxy, PyPI outage, half-built environment). The bundled one works offline once installed,
and it has no venv, so nothing embeds an absolute path: the app can be moved or renamed (tested).

## How it works

Everything the menu does is a `birdcm admin …` command (`engine/birdcm/admin.py`, tests in `engine/tests/test_admin.py`)
printing JSON; the Swift shell only shows state and runs them.

- `admin serve [--port N]`: one engine per user (an `flock` on `engine.lock` holding pid / port / exe), its own process
  group, the port checked first (busy → exit 4 with the holder and a free alternative; the menu offers "改用端口 N 启动"),
  then output goes to `engine.log` (rotated past 4 MB, one old copy).
- `admin stop`: SIGTERM to the pid in the held lock (never to anything else), the engine finishes the batch on the GPU,
  puts the rest back in the queue and closes its decode workers and exiftool; SIGKILL to the process group after 20 s.
- `admin health | paths | usage | models-status | models-fetch | models-verify | models-remove | clear-cache [--database] |
  move-cache DIR | move-data DIR`.
- Settings live in one file, `~/Library/Application Support/BirdCM/config.toml` (`data_dir`, `cache_dir`, `model_dirs`,
  `port`), read at every start; `BIRDCM_DATA_DIR` / `BIRDCM_CACHE_DIR` / `BIRDCM_MODEL_DIR` still override it, and
  `BIRDCM_CONFIG=/some/config.toml` moves everything for testing.
- Moving the cache or data: engine stopped, refused inside any photo folder that was scanned, copied, verified, config
  written, then the old copy deleted. A non-empty target gets a `BirdCM` subfolder.

The menu: status (已停止 / 启动中 / 运行中 · 端口 / 出错：原因), 打开观羽, 启动 / 停止 / 重新启动, the model line
(就绪 / 缺 n 个 / 下载中 x% / n 个尚未发布), 下载缺少的模型 / 取消下载, 设置…, 查看日志, 登录时启动 (SMAppService), 退出观羽
(stops the engine first). 设置 has the model list (已就绪 / 缺少 / 尚未发布, sizes, 下载 / 重新校验 / 删除 / 打开模型文件夹)
and cache & data (sizes; 清空缓存 removes thumbnails and previews only; 删除数据库… asks twice; 在访达中显示; 更改…).
Opening the app again (Finder, Spotlight, `open`) opens the web page, starting the engine if needed. First launch shows a
welcome window with the download size and the folders; 开始使用 starts the download, the engine and the browser.

Test switches (environment, e.g. `open -n --env BIRDCM_CONFIG=… 观羽.app`): `BIRDCM_CONFIG`, `BIRDCM_NO_BROWSER=1`,
`BIRDCM_SKIP_WELCOME=1`, `BIRDCM_SNAPSHOT=dir` (writes the menu's status lines and window renderings there).

## Permissions the user sees

- Scanning a folder on an external disk: macOS asks once "“观羽”想要访问可移除宗卷上的文件" (text from
  `NSRemovableVolumesUsageDescription`). Desktop / Documents / Downloads and network volumes have their own one-time
  prompts. The engine is a child of the app, so the prompts and the grants are the app's, not Terminal's.
- The web page's 选择文件夹 button runs `osascript` (`choose folder`) from the engine: a normal folder dialog, no
  Automation prompt (it sends no Apple Events to another app).
- 登录时启动 adds 观羽 under System Settings → General → Login Items.

## Signing and distribution

This Mac has no "Developer ID Application" identity (only "Apple Development" and a self-signed one), so `build.sh`
signs ad-hoc with the hardened runtime. Ad-hoc signatures carry no Team ID, so library validation is turned off
(`com.apple.security.cs.disable-library-validation`, added only for ad-hoc builds); Python and torch need no other
exception (no JIT, no unsigned executable memory). With a Developer ID every library gets the same Team ID and
`entitlements.plist` stays empty — untested here, since there is no such identity.

**An ad-hoc dmg is blocked by Gatekeeper on other Macs** ("cannot be opened because Apple cannot check it…"). On your
own Mac, after copying the app to /Applications:

```sh
xattr -dr com.apple.quarantine /Applications/观羽.app
```

or open it once, then System Settings → Privacy & Security → "Open Anyway" (since macOS 15, Control-click → Open no
longer bypasses this).

To distribute: get a "Developer ID Application" certificate (Apple Developer Program, Xcode → Settings → Accounts or
developer.apple.com), then

```sh
SIGN_ID="Developer ID Application: NAME (TEAMID)" macos/build.sh
xcrun notarytool store-credentials birdcm-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID   # app-specific password
xcrun notarytool submit "macos/dist/观羽-0.1.0-arm64.dmg" --keychain-profile birdcm-notary --wait
xcrun stapler staple "macos/dist/观羽-0.1.0-arm64.dmg"
spctl -a -t open --context context:primary-signature -vv "macos/dist/观羽-0.1.0-arm64.dmg"
```

(`notarytool` and `stapler` come with Xcode; if notarization reports problems, `xcrun notarytool log <id>
--keychain-profile birdcm-notary` lists them file by file.)

## Uninstall

Quit 观羽 from its menu (this stops the engine), then delete:

| What | Where |
|---|---|
| the app | `/Applications/观羽.app` |
| settings, engine.lock, engine.log, the database (default data dir) | `~/Library/Application Support/BirdCM` |
| models, thumbnails, previews (default cache dir) | `~/Library/Caches/BirdCM` |
| moved data / cache | wherever 设置 put them (see `config.toml`) |
| the app's preferences (welcome shown) | `defaults delete io.github.lincleejun.birdcm` |

Turn off 登录时启动 first, or remove it under Login Items. Photos are never written to.
