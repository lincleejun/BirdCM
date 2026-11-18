"""Small test-only subset of the reviewed global table, retaining the original Natural Earth polygons."""
import importlib.util,json,sqlite3,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]);module=Path(sys.argv[2])
spec=importlib.util.spec_from_file_location('global_rarity',module)
# Load only dependency-free region_at and inside directly from the read-only source AST.
import ast,array,collections
parsed=ast.parse(module.read_text());functions=[n for n in parsed.body if isinstance(n,ast.FunctionDef) and n.name in ('inside','region_at')]
ns=dict(sqlite3=sqlite3,array=array.array,defaultdict=collections.defaultdict,NEAR=0.25)
exec(compile(ast.Module(body=functions,type_ignores=[]),str(module),'exec'),ns)
src=sqlite3.connect(source);out=root/'Tests/Fixtures/rarity-global-test.sqlite'
if out.exists():out.unlink()
dst=sqlite3.connect(out)
for name,sql in src.execute("SELECT name,sql FROM sqlite_master WHERE type='table'"):
 if name in ('regions','shapes','species','months','counts'):dst.execute(sql)
points=[(33.7,-118.06),(49.28,-123.12),(32.53,-117.02),(42.89,-78.88),(35.7,139.7),(20,-150),(-20.9,55.5),(39.9,116.4)]
ids=set();expected=[]
for lat,lon in points:
 div,country=ns['region_at'](src,lat,lon);expected.append(dict(lat=lat,lon=lon,division=div,country=country))
 ids.update(r[0] for r in src.execute('SELECT region_id FROM shapes WHERE minx<=? AND maxx>=? AND miny<=? AND maxy>=?',(lon+.25,lon-.25,lat+.25,lat-.25)))
for rid in ids:
 for table,col in [('regions','id'),('shapes','region_id')]:
  for row in src.execute(f'SELECT * FROM {table} WHERE {col}=?',(rid,)):
   dst.execute(f'INSERT INTO {table} VALUES('+','.join('?' for _ in row)+')',row)
# A deterministic coverage regression: a present species + NULL source is insufficient, never no-record/rare.
sp=src.execute("SELECT * FROM species WHERE scientific='Anas platyrhynchos'").fetchone()
dst.execute('INSERT INTO species VALUES(?,?,?)',sp)
ca=dst.execute("SELECT id FROM regions WHERE code='US-CA'").fetchone()[0]
columns=[r[1] for r in dst.execute('PRAGMA table_info(months)')]
values=dict(region_id=ca,month=11,records=0,n_species=0,source_id=None,coverage='数据不足')
dst.execute('INSERT INTO months VALUES('+','.join('?' for _ in columns)+')',[values[c] for c in columns])
dst.commit();dst.close()
(root/'Tests/Fixtures/global-region-reference.json').write_text(json.dumps(expected,indent=2)+'\n')
print('Global fixture bytes',out.stat().st_size)
