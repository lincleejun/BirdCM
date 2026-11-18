#!/bin/bash
set -euo pipefail
BUNDLE_MODELS="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Models"
# Restore the original on every incremental build so a previous opt-out cannot persist into an opt-in.
cp "$SRCROOT/Models/rarity-global.sqlite" "$BUNDLE_MODELS/rarity-global.sqlite"
cp "$SRCROOT/Models/integrity.json" "$BUNDLE_MODELS/integrity.json"
case "${BIRDCM_BUNDLE_IUCN:-1}" in
  0|NO|no|false)
    /usr/bin/sqlite3 "$BUNDLE_MODELS/rarity-global.sqlite" 'UPDATE species SET iucn=NULL; VACUUM;'
    /usr/bin/python3 - "$BUNDLE_MODELS" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]);manifest=json.loads((p/'integrity.json').read_text())
for row in manifest:
 if row['path']=='rarity-global.sqlite':
  f=p/row['path'];row['sha256']=hashlib.sha256(f.read_bytes()).hexdigest();row['bytes']=f.stat().st_size
(p/'integrity.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
    ;;
esac
printf '%s\n' "${BIRDCM_BUNDLE_IUCN:-1}" > "$BUNDLE_MODELS/iucn-build-flag"
