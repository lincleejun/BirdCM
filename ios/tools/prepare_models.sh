#!/bin/bash
# Compatibility wrapper: all developer paths now contain build-time compiled models.
set -euo pipefail
export MODEL_SOURCE="${1:?Usage: prepare_models.sh MOBILE_BUILD GEO_ONNX GLOBAL_RARITY_SQLITE}"
export GEO_SOURCE="${2:?Missing geo ONNX}"
export RARITY_SOURCE="${3:?Missing global rarity table}"
exec "$(dirname "$0")/fetch_models.sh"
