"""Copy only the old mobile CC0 reference cases; reject every photo without an explicit CC0 manifest row.
Usage: python import_fixtures.py /path/to/bioclip-bird
"""
import csv,hashlib,json,shutil,sys
from pathlib import Path
src=Path(sys.argv[1]).resolve(); dst=Path(__file__).resolve().parents[1]/'Tests/Fixtures'
manifest={Path(r['path']).name:r for r in csv.DictReader((src/'eval/groundtruth.csv').open())}
cases=json.loads((src/'mobile/expected/expected.json').read_text()); licences=[]
for i,c in enumerate(cases):
 photo=(src/c['path']).resolve()
 if photo.name=='big-synthetic.png':
  # Bind the existing 8x derivative pixel-for-pixel to a CC0 manifest row.
  from PIL import Image
  match=None
  big=Image.open(photo).convert('RGB')
  for name,row in manifest.items():
   if row['scientific']!='Zonotrichia leucophrys' or row['license']!='cc0':continue
   q=src.parent/'bioscan/data/inat/Zonotrichia_leucophrys'/name
   if not q.exists():continue
   im=Image.open(q).convert('RGB')
   if (im.width*8,im.height*8)==big.size and any(im.resize(big.size,f).tobytes()==big.tobytes() for f in [Image.Resampling.NEAREST,Image.Resampling.BILINEAR,Image.Resampling.BICUBIC,Image.Resampling.LANCZOS]):match=row;break
  assert match is not None,'cannot prove synthetic image is a CC0 derivative'
  row=match
 else:
  row=manifest[photo.name];assert row['license']=='cc0'
  assert hashlib.sha256(photo.read_bytes()).hexdigest()==row['sha256']
 out=f'photo-{i}{photo.suffix}';shutil.copy(photo,dst/out);c['path']=out
 shutil.copy(src/f'mobile/expected/{i}.png',dst/f'{i}.png')
 licences.append({'file':out,'source':row['source'],'license':'CC0','attribution':row['attribution'],'original_sha256':row['sha256'],'derivative':photo.name=='big-synthetic.png'})
(dst/'expected.json').write_text(json.dumps(cases,indent=2));(dst/'photos.json').write_text(json.dumps(licences,indent=2))
print('copied',len(cases),'CC0-only fixtures')
