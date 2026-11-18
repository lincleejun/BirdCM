"""Build flag must strip the shipped data, restore on incremental opt-in, and preserve source files."""
import hashlib,json,os,sqlite3,subprocess,tempfile,unittest
from pathlib import Path
class BundleTests(unittest.TestCase):
 def test_iucn_flag_and_integrity(self):
  script=Path(__file__).with_name('prepare_bundle.sh').resolve()
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);source=root/'src/Models';target=root/'out/Models';source.mkdir(parents=True);target.mkdir(parents=True)
   db=source/'rarity-global.sqlite'
   with sqlite3.connect(db) as conn:conn.execute('CREATE TABLE species(iucn TEXT)');conn.execute("INSERT INTO species VALUES('EN')")
   h=hashlib.sha256(db.read_bytes()).hexdigest()
   (source/'integrity.json').write_text(json.dumps([dict(path=db.name,sha256=h,bytes=db.stat().st_size,url='')]))
   for flag in ('0','1'):
    env=dict(os.environ,SRCROOT=str(root/'src'),TARGET_BUILD_DIR=str(root/'out'),UNLOCALIZED_RESOURCES_FOLDER_PATH='',BIRDCM_BUNDLE_IUCN=flag)
    subprocess.run(['bash',str(script)],env=env,check=True)
    with sqlite3.connect(target/db.name) as conn:self.assertEqual(conn.execute('SELECT iucn FROM species').fetchone()[0],None if flag=='0' else 'EN')
    row=json.loads((target/'integrity.json').read_text())[0]
    self.assertEqual(hashlib.sha256((target/db.name).read_bytes()).hexdigest(),row['sha256'])
    self.assertEqual(hashlib.sha256(db.read_bytes()).hexdigest(),h)
if __name__=='__main__':unittest.main()
