"""Export the fixed v3.0.4 graph, referencing raw weights in the SHA-checked public ONNX.
No model weights are committed. Run with numpy, onnx, onnxruntime, safetensors installed.
python export_geo.py --onnx PATH --clear PATH
The native executor supports exactly these graph operations; not a general ONNX runtime.
"""
import argparse, hashlib, json
from pathlib import Path
import numpy as np
import onnx
from onnx import numpy_helper, helper
from safetensors.numpy import load_file

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(); p.add_argument('--onnx',type=Path,required=True); p.add_argument('--clear',type=Path,required=True); a=p.parse_args()
raw=a.onnx.read_bytes(); assert hashlib.sha256(raw).hexdigest()=='0de81d222c23dcb6fa428e958b4dac978783191357e01b7268a103fc6f08e61a'
m=onnx.load(a.onnx)
initial={}
for t in m.graph.initializer:
 v=numpy_helper.to_array(t)
 if v.dtype==np.float32 and v.size>16:
  offset=raw.find(t.raw_data); assert offset>=0 and len(t.raw_data)==v.size*4
  initial[t.name]={'offset':offset,'count':v.size,'shape':list(v.shape)}
 else: initial[t.name]={'values':v.flatten().astype(float).tolist(),'shape':list(v.shape)}
nodes=[]
allowed={'Gather','Mul','Sub','Div','Unsqueeze','Sin','Cos','Concat','Gemm','Erf','Add','Split','Tanh','LayerNormalization','Sigmoid'}
for n in m.graph.node:
 assert n.op_type in allowed
 attrs={k.name:helper.get_attribute_value(k) for k in n.attribute}
 if n.op_type=='Gemm': assert attrs==dict(alpha=1.,beta=1.,transA=0,transB=1)
 if n.op_type=='LayerNormalization': assert attrs['axis']==-1
 nodes.append({'op':n.op_type,'inputs':list(n.input),'outputs':list(n.output),'epsilon':attrs.get('epsilon',0)})
(ROOT/'BirdCM/Resources/geo-graph.json').write_text(json.dumps({'initial':initial,'nodes':nodes},separators=(',',':')))
h=load_file(a.clear)
(ROOT/'BirdCM/Resources/clear.json').write_text(json.dumps({k:v.flatten().astype(float).tolist() for k,v in h.items()},separators=(',',':')))
print('exported',len(nodes),'nodes; ONNX weights remain external')
