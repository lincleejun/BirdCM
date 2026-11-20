#!/bin/bash
set -euo pipefail
BUNDLE_MODELS="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Models"
# Restore the original on every incremental build so a previous opt-out cannot persist into an opt-in.
cp "$SRCROOT/Models/rarity-global.sqlite" "$BUNDLE_MODELS/rarity-global.sqlite"
cp "$SRCROOT/Models/integrity.json" "$BUNDLE_MODELS/integrity.json"
# The shipped species.iucn column is the repository's engine/birdcm/data/iucn.csv (CC BY 4.0, iucn-LICENSE.md), the same
# table the desktop engine reads; BIRDCM_BUNDLE_IUCN=0 ships it empty. The table's own column is never shipped.
/usr/bin/python3 - "$BUNDLE_MODELS" "${BIRDCM_BUNDLE_IUCN:-1}" "$SRCROOT/../engine/birdcm/data/iucn.csv" <<'PY'
import csv,hashlib,json,sqlite3,sys
from pathlib import Path
p=Path(sys.argv[1]);f=p/'rarity-global.sqlite'
db=sqlite3.connect(f);db.execute('UPDATE species SET iucn=NULL')
if sys.argv[2].lower() not in ('0','no','false'):
 with open(sys.argv[3],newline='',encoding='utf-8') as c:
  db.executemany('UPDATE species SET iucn=? WHERE scientific=?',[(r['category'],r['scientific']) for r in csv.DictReader(c)])
db.commit();db.execute('VACUUM');db.close()
manifest=json.loads((p/'integrity.json').read_text())
for row in manifest:
 if row['path']==f.name:row['sha256']=hashlib.sha256(f.read_bytes()).hexdigest();row['bytes']=f.stat().st_size
(p/'integrity.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
printf '%s\n' "${BIRDCM_BUNDLE_IUCN:-1}" > "$BUNDLE_MODELS/iucn-build-flag"
