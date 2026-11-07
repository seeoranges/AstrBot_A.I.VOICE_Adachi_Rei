"""Exercise distribution installation only against isolated fake runtime folders."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform == 'win32', 'Windows installer')
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        # Installer rejects runtimes nested in the source repo. A sibling fixture
        # supplies isolation without ever using the real installed environment.
        self.runtime_temp = tempfile.TemporaryDirectory(prefix='adachi-install-',dir=ROOT.parent)
        self.addCleanup(self.runtime_temp.cleanup)
        self.runtime = Path(self.runtime_temp.name)
        (self.runtime/'astrbot/data').mkdir(parents=True)

    def install(self, component='voice', target=None):
        return subprocess.run(['powershell.exe','-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
            '-File',str(ROOT/'scripts/install.ps1'),'-Dir',str(target or self.runtime),'-Component',component],
            capture_output=True,timeout=30)

    def test_voice_install_backs_up_previous_code_without_reading_private_settings(self):
        target = self.runtime/'astrbot/data/plugins/astrbot_plugin_adachi_aivoice/main.py'
        target.parent.mkdir(parents=True)
        target.write_text('# previous code',encoding='utf-8')
        private = self.runtime/'private'
        private.mkdir()
        marker = private/'owner-qq.txt'
        marker.write_text('local-placeholder',encoding='utf-8')
        result=self.install()
        self.assertEqual(result.returncode,0,result.stdout.decode(errors='replace')+result.stderr.decode(errors='replace'))
        snapshots=list((private/'snapshots').glob('github-install-*'))
        self.assertEqual(len(snapshots),1)
        self.assertEqual((snapshots[0]/target.relative_to(self.runtime)).read_text(encoding='utf-8'),'# previous code')
        self.assertEqual(marker.read_text(encoding='utf-8'),'local-placeholder')
        self.assertEqual(target.read_bytes(),(ROOT/'main.py').read_bytes())
        self.assertTrue((self.runtime/'tools/aivoice-daemon.ps1').exists())

    def test_unknown_proactive_source_is_rejected_before_backups_or_writes(self):
        target=self.runtime/'astrbot/data/plugins/astrbot_plugin_proactive_chat/core/services/sender_service.py'
        target.parent.mkdir(parents=True)
        target.write_text('# unknown version',encoding='utf-8')
        self.assertNotEqual(self.install('proactive').returncode,0)
        self.assertEqual(target.read_text(encoding='utf-8'),'# unknown version')
        self.assertFalse((self.runtime/'private').exists())

    def test_current_proactive_source_accepts_windows_line_endings(self):
        source=ROOT/'integrations/astrbot_plugin_proactive_chat/core/services/sender_service.py'
        target=self.runtime/'astrbot/data/plugins/astrbot_plugin_proactive_chat/core/services/sender_service.py'
        target.parent.mkdir(parents=True)
        target.write_text(source.read_text(encoding='utf-8-sig'),encoding='utf-8-sig',newline='\r\n')
        result=self.install('proactive')
        self.assertEqual(result.returncode,0,result.stdout.decode(errors='replace')+result.stderr.decode(errors='replace'))
        self.assertEqual(target.read_bytes(),source.read_bytes())

    def test_missing_runtime_and_source_nested_target_are_rejected(self):
        self.assertNotEqual(self.install(target=self.base).returncode,0)
        (self.base/'astrbot/data').mkdir(parents=True)
        self.assertNotEqual(self.install(target=self.base).returncode,0)
        self.assertFalse((self.base/'private').exists())
