"""Regenerate CC0-only inputs and converted-model references using read-only desktop geometry.py.
Usage: ios/build/python/bin/python ios/tools/regenerate_crop_references.py ../BirdCM
"""
import hashlib,importlib.util,json,sys
from pathlib import Path
import numpy as np
from PIL import Image,ImageOps
import coremltools as ct
root=Path(__file__).resolve().parents[1];desktop=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('geometry',desktop/'engine/birdcm/geometry.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
fix=root/'Tests/Fixtures';cases=json.loads((fix/'expected.json').read_text())
manifest=json.loads((fix/'photos.json').read_text());assert all(c['license']=='CC0' for c in manifest)
assert {c['path'] for c in cases} <= {r['file'] for r in manifest}, 'Every input must have an explicit CC0 fixture manifest row'
assert all(Path(c['path']).name==c['path'] for c in cases), 'Fixture paths must stay inside the CC0 folder'
models=root/'Models';tower=ct.models.CompiledMLModel(str(models/'BioCLIP.mlmodelc'),compute_units=ct.ComputeUnit.CPU_ONLY)
heads=ct.models.CompiledMLModel(str(models/'Heads.mlmodelc'),compute_units=ct.ComputeUnit.CPU_ONLY)
names=np.fromfile(models/'names.f16',dtype=np.float16).astype(np.float32).reshape(-1,1024)
rows=[r.split('\t') for r in (models/'names.tsv').read_text().splitlines()]
report=[]
for i,c in enumerate(cases):
 im=ImageOps.exif_transpose(Image.open(fix/c['path'])).convert('RGB')
 k=min(1,2048/max(im.size));frame=im.resize((round(im.width*k),round(im.height*k)),Image.Resampling.LANCZOS)
 assert list(frame.size)==c['size']
 box=c['box'];normal=(box[0]/frame.width,box[1]/frame.height,box[2]/frame.width,box[3]/frame.height)
 small=max(box[2]-box[0],box[3]-box[1])<128
 src=im if small else frame
 rect=g.crop_rect(normal,*src.size)
 inp=g.pad_crop(src,rect).resize((224,224),Image.Resampling.BICUBIC)
 inp.save(fix/f'{i}.png')
 out=tower.predict({'image':inp});e=out['embedding'].reshape(-1).astype(np.float32)
 logits=names@e;probs=np.exp(98.8644790649414*(logits-logits.max()));probs/=probs.sum()
 ids=np.argsort(-probs)[:5]
 c['embedding']=e.tolist();c['top5']=[dict(scientific=rows[j][0],p=float(probs[j])) for j in ids]
 h=heads.predict({'tokens15':out['tokens15'].astype(np.float16)});c['flying']=float(h['flying'].reshape(-1)[0])
 heat=h['heat'].reshape(256,3);offset=h['offset'].reshape(256,3,2);cell=heat.argmax(0)
 xy=(np.stack([cell%16,cell//16],axis=-1)+offset[cell,np.arange(3)])*14
 c['points224']=xy.tolist();c['visible']=(1/(1+np.exp(-h['visible'].reshape(3)))).tolist()
 c['points_normalized']=[g.from_input(tuple(p),rect,*src.size) for p in xy]
 report.append(dict(file=c['path'],license='CC0',source_fixture=c['path'],source_size=src.size,small=small,rect=rect,input_sha256=hashlib.sha256((fix/f'{i}.png').read_bytes()).hexdigest()))
 print(i,rect,c['top5'][0],flush=True)
(fix/'expected.json').write_text(json.dumps(cases,indent=2)+'\n')
(fix/'crop-reference.json').write_text(json.dumps(dict(desktop_geometry_sha256=hashlib.sha256((desktop/'engine/birdcm/geometry.py').read_bytes()).hexdigest(),cases=report),indent=2)+'\n')

# Same CC0 derivative, but a tiny box explicitly exercising a decode-resolution source.
im=ImageOps.exif_transpose(Image.open(fix/'photo-4.png')).convert('RGB')
rect=g.crop_rect((0.4,0.4,0.41,0.41),*im.size)
g.pad_crop(im,rect).resize((224,224),Image.Resampling.BICUBIC).save(fix/'small-highres.png')

metadata=json.loads((fix/'crop-reference.json').read_text())
metadata['small_highres']=dict(file='small-highres.png',source_fixture='photo-4.png',license='CC0',rect=rect,source_size=im.size,input_sha256=hashlib.sha256((fix/'small-highres.png').read_bytes()).hexdigest())
(fix/'crop-reference.json').write_text(json.dumps(metadata,indent=2)+'\n')
