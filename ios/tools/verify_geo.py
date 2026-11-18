"""Compare the production Swift fp32 executor with ONNX Runtime and committed desktop geo.py.
Requires compiled ios/build/geo-check. No owner photographs or model weights are copied into Git.
"""
import argparse,json,os,sys,subprocess
from pathlib import Path
import numpy as np
import onnxruntime as ort
ROOT=Path(__file__).resolve().parents[2]; IOS=ROOT/'ios'; BUILD=IOS/'build'; FIX=IOS/'Tests/Fixtures'
os.chdir(BUILD)
sys.path.insert(0,str(ROOT/'engine')); from birdcm import geo
p=argparse.ArgumentParser();p.add_argument('--onnx',type=Path,required=True);p.add_argument('--names',type=Path,required=True);a=p.parse_args()
points=[[37.7,-122.4,42],[39.9,116.4,18],[-33.9,151.2,1],[0,0,48],[49.3,-123.1,6]]
scientific=[r.split('\t')[0] for r in a.names.read_text().splitlines()]
desktop=geo.Geo(str(a.onnx),scientific)
places=[(36.6,-121.9,'2026-11-14','photo',None),(37.2,-119.5,'2026-11-14','region','美国 · 加利福尼亚州')]
cover=[]
for place_index,(la,lo,date,source,label) in enumerate(places):
 pts=geo.cover(la,lo,source,label);weeks=geo.weeks_around(geo.week_of(date))
 cover.extend([[x,y,w] for x,y in pts for w in weeks])
allpts=points+cover
(BUILD/'geo-input.json').write_text(json.dumps(allpts))
subprocess.run([str(BUILD/'geo-check'),str(a.onnx),str(IOS/'BirdCM/Resources/geo-graph.json'),str(BUILD/'geo-input.json'),str(BUILD/'geo-output.f32')],check=True)
native=np.fromfile(BUILD/'geo-output.f32',np.float32).reshape(-1,14082)
sess=ort.InferenceSession(str(a.onnx));ref=sess.run(None,{sess.get_inputs()[0].name:np.array(allpts,np.float32)})[0]
error=np.abs(native-ref);assert error.max()<2e-5,error.max()
(FIX/'geo-points.json').write_text(json.dumps(points)); ref[:len(points)].tofile(FIX/'geo-reference.f32')
report={'raw_points':len(allpts),'raw_max_abs_error':float(error.max()),'raw_mean_abs_error':float(error.mean()),'spread':[]}
# Exercise the actual phone cover/mapping/aggregation implementation, not just the network.
subprocess.run([str(BUILD/'spread-check'),str(a.onnx),str(a.names),str(BUILD/'spread-output.json'),'-resourceDir',str(IOS/'BirdCM/Resources')],check=True)
swift_spread=json.loads((BUILD/'spread-output.json').read_text())
offset=len(points)
for place_index,(la,lo,date,source,label) in enumerate(places):
 pts=geo.cover(la,lo,source,label);weeks=geo.weeks_around(geo.week_of(date));n=len(pts)*len(weeks)
 q=native[offset:offset+n].reshape(len(pts),len(weeks),-1).max(1);offset+=n
 ix=desktop.index; mapped=np.where(ix[None]>=0,q[:,np.maximum(ix,0)],0).max(2)
 wide,typical=desktop.spread(la,lo,date,source,label)
 actual_wide=np.array(swift_spread[place_index]['wide']);actual_typical=np.array(swift_spread[place_index]['typical'])
 assert np.abs(actual_wide-wide).max()<2e-5 and np.abs(actual_typical-typical).max()<2e-5
 report['spread'].append({'native_swift_wide_error':float(np.abs(actual_wide-wide).max()),'native_swift_median_error':float(np.abs(actual_typical-typical).max()),'source':source,'points':len(pts),'weeks':len(weeks),'wide_error':float(np.abs(mapped.max(0)-wide).max()),'median_error':float(np.abs(np.median(mapped,0)-typical).max())})
 if source=='region':
  regression={s:{'max':float(wide[scientific.index(s)]),'median':float(typical[scientific.index(s)])} for s in ['Xenopsaris albinucha','Tyrannus melancholicus','Tyrannus couchii']}
  (FIX/'california-november.json').write_text(json.dumps(regression,indent=2));report['california']=regression
  assert regression['Xenopsaris albinucha']['max']<.01
  assert regression['Tyrannus melancholicus']['max']>=.01 and regression['Tyrannus melancholicus']['median']<.05
(IOS/'geo-verification.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
