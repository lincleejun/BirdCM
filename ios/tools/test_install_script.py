"""Installer contract without provisioning or touching a phone."""
import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
class InstallerTests(unittest.TestCase):
 def test_fetch_build_install_order_and_team(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);(root/'tools').mkdir();(root/'bin').mkdir()
   shutil.copy(Path(__file__).with_name('install_on_device.sh'),root/'tools/install_on_device.sh')
   mock='''#!/usr/bin/env python3
import json,os,sys,pathlib
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps([pathlib.Path(sys.argv[0]).name]+sys.argv[1:])+'\\n')
'''
   for p in [root/'tools/fetch_models.sh',root/'bin/xcodebuild',root/'bin/xcrun']:
    p.write_text(mock);p.chmod(0o755)
   env=dict(os.environ,PATH=str(root/'bin')+':'+os.environ['PATH'],CALL_LOG=str(root/'calls'))
   subprocess.run(['bash',str(root/'tools/install_on_device.sh'),'phone-udid','3U353L39GB'],env=env,check=True,capture_output=True)
   calls=[json.loads(s) for s in (root/'calls').read_text().splitlines()]
   self.assertEqual([c[0] for c in calls],['fetch_models.sh','xcodebuild','xcrun'])
   self.assertIn('id=phone-udid',calls[1]);self.assertIn('DEVELOPMENT_TEAM=3U353L39GB',calls[1])
   self.assertIn('-allowProvisioningUpdates',calls[1]);self.assertEqual(calls[2][1:6],['devicectl','device','install','app','--device'])
if __name__=='__main__':unittest.main()
