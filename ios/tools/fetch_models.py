"""Build-only fetch/compile; no networking, compilation or model copying in the app."""
import hashlib,json,os,shutil,sqlite3,subprocess,tempfile,urllib.request
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=Path(os.environ['MODEL_SOURCE']) if os.environ.get('MODEL_SOURCE') else None
rarity=Path(os.environ['RARITY_SOURCE']) if os.environ.get('RARITY_SOURCE') else None
if not rarity or not rarity.is_file():
    raise SystemExit('Unreleased global rarity table is required: set RARITY_SOURCE or pass argument 2 (rarity-global.sqlite).')
def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
if digest(rarity)!='f2eff2f41e0bfa5faad0cf70151f66eec64246a7193f81dadba827bb89f54e66':
    raise SystemExit('rarity-global.sqlite SHA256 does not match the reviewed global table.')
staging=root/'build/model-source'; staging.mkdir(parents=True,exist_ok=True)
out=root/'Models'; out.mkdir(exist_ok=True)
manifest=json.loads((root/'tools/model-assets.json').read_text())
for asset in manifest:
    dest=staging/asset['path'];dest.parent.mkdir(parents=True,exist_ok=True)
    if dest.is_file() and digest(dest)==asset['sha256']:continue
    local=source/asset['path'] if source else None
    geo=os.environ.get('GEO_SOURCE')
    if geo and asset['path'].endswith('.onnx'):local=Path(geo)
    tmp=dest.with_name(dest.name+'.partial')
    if local and local.is_file():shutil.copyfile(local,tmp)
    else:
        print('Downloading',asset['url'],flush=True)
        urllib.request.urlretrieve(asset['url'],tmp)
    if digest(tmp)!=asset['sha256']:tmp.unlink();raise SystemExit('SHA256 mismatch: '+asset['path'])
    tmp.replace(dest)
for name in ['BioCLIP','Detector','Heads']:
    compiled=out/(name+'.mlmodelc')
    stamp=out/(name+'.source-sha')
    identity=''.join(a['sha256'] for a in manifest if a['path'].startswith(name+'.'))
    if not compiled.exists() or not stamp.exists() or stamp.read_text()!=identity:
        with tempfile.TemporaryDirectory() as td:
            subprocess.run(['xcrun','coremlcompiler','compile',str(staging/(name+'.mlpackage')),td],check=True)
            if compiled.exists():shutil.rmtree(compiled)
            shutil.copytree(Path(td)/(name+'.mlmodelc'),compiled)
        stamp.write_text(identity)
for a in manifest:
    if '.mlpackage/' not in a['path']:shutil.copyfile(staging/a['path'],out/a['path'])
shutil.copyfile(rarity,out/'rarity-global.sqlite')
if os.environ.get('BIRDCM_BUNDLE_IUCN','1').lower() in ('0','no','false'):
    with sqlite3.connect(out/'rarity-global.sqlite') as db:
        db.execute("UPDATE species SET iucn=NULL")
        db.commit();db.execute('VACUUM')
# Empty values retain the compatible SQLite schema while actually removing IUCN data from the shipped file.
records=[dict(path=str(p.relative_to(out)),url='',sha256=digest(p),bytes=p.stat().st_size)
         for p in sorted(out.rglob('*')) if p.is_file() and p.name!='integrity.json']
(out/'integrity.json').write_text(json.dumps(records,indent=2)+'\n')
print('Bundled models ready:',sum(a['bytes'] for a in records),'bytes',flush=True)
