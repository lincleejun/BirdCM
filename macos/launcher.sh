#!/bin/sh
# 观羽.app/Contents/Resources/engine/birdcm: the engine with the bundled Python, web UI and exiftool, and nothing
# from the user's PATH. Also usable from Terminal, e.g.  ".../engine/birdcm" admin health
E="$(cd "$(dirname "$0")" && pwd -P)"
export PATH="$E/exiftool:/usr/bin:/bin:/usr/sbin:/sbin"
export BIRDCM_MANIFEST="$E/models.toml" BIRDCM_WEB_DIR="$E/web"
# -I: ignore PYTHON* variables and user site-packages; -B: never write .pyc into the signed bundle
exec "$E/python/bin/python3" -I -B -X utf8 -m birdcm.cli "$@"
