#!/bin/bash
# Released files are pinned in downloads.json. Local inputs are never fetched from an invented URL.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
IOS="$(cd "$(dirname "$0")/.." && pwd)"
export MODEL_SOURCE="${MODEL_SOURCE:-${1:-}}"
export RARITY_SOURCE="${RARITY_SOURCE:-${2:-}}"
export BIRDCM_BUNDLE_IUCN="${BIRDCM_BUNDLE_IUCN:-1}"
python3 "$IOS/tools/fetch_models.py"
