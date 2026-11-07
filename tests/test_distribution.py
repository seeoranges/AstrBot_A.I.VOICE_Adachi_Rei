"""Plugin-market entry points and direct-install resource paths."""
import ast
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from test_voice import voice

ROOT = Path(__file__).resolve().parents[1]

class DistributionTests(unittest.TestCase):
    def test_market_files_are_at_repository_root(self):
        for name in ['main.py','metadata.yaml','_conf_schema.json','requirements.txt']:
            self.assertTrue((ROOT/name).is_file(),name)
        module=ast.parse((ROOT/'main.py').read_text(encoding='utf-8-sig'))
        self.assertTrue(any(isinstance(n,ast.ClassDef) and n.name=='AdachiAIVoice' for n in module.body))
        metadata=(ROOT/'metadata.yaml').read_text(encoding='utf-8')
        for field in ['name: astrbot_plugin_adachi_aivoice','version: 0.4.1','repo:','author:','support_platforms:']:
            self.assertIn(field,metadata)
        self.assertIn('home_dir',json.loads((ROOT/'_conf_schema.json').read_text(encoding='utf-8')))

    def test_direct_install_uses_bundled_bridge_with_configured_private_home(self):
        home=str(ROOT/'example-runtime')
        paths=voice._runtime_paths({'home_dir':home,'ffmpeg_path':'custom-ffmpeg.exe'})
        self.assertEqual(paths[0],home)
        self.assertEqual(Path(paths[1]),ROOT/'tools/aivoice-daemon.ps1')
        self.assertEqual(paths[2],'custom-ffmpeg.exe')
        self.assertEqual(Path(paths[3]),Path(home)/'private/deepseek-key.txt')
        self.assertEqual(Path(paths[4]),Path(home)/'private/owner-qq.txt')

    def test_home_environment_and_legacy_bridge_fallback(self):
        home=str(ROOT/'environment-runtime')
        with patch.dict(os.environ,ADACHI_REI_HOME=home),patch.object(voice.os.path,'isfile',return_value=False),patch.object(voice.shutil,'which',return_value=None):
            paths=voice._runtime_paths()
        self.assertEqual(paths[0],home)
        self.assertEqual(Path(paths[1]),Path(home)/'tools/aivoice-daemon.ps1')
