import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('stack_health',ROOT/'tools'/'stack_health.py')
health=importlib.util.module_from_spec(spec);spec.loader.exec_module(health)


class Response(io.BytesIO):
    def __enter__(self):return self
    def __exit__(self,*args):self.close()


class Opener:
    def __init__(self,failed=None):self.failed=failed or {};self.paths=[]
    def open(self,request,timeout):
        path=request.full_url;self.paths.append(path)
        if path.endswith('/auth/login'):value={'token':'dummy'}
        elif path.endswith('/plugins/failed'):value=self.failed
        else:value={'activated':True}
        return Response(json.dumps({'status':'ok','data':value}).encode())


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=ROOT);self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);(self.root/'private').mkdir()
        (self.root/'private'/'backend.txt').write_text('url: http://127.0.0.1:6185\nusername: dummy\npassword: dummy\n',encoding='utf-8')

    def test_plugin_loads_and_no_provider_model_test(self):
        opener=Opener();result=health.check(self.root,opener)
        self.assertTrue(result['ok']);self.assertTrue(result['features']['voice'])
        self.assertTrue(all('/providers/test' not in p and '/chat/' not in p for p in opener.paths))

    def test_failed_plugin_prevents_ready(self):
        result=health.check(self.root,Opener({'broken':{'error':'not printed'}}))
        self.assertFalse(result['ok']);self.assertEqual(result['failed_plugins'],1)
        self.assertNotIn('not printed',str(result))

    def test_remote_dashboard_never_receives_credentials(self):
        (self.root/'private'/'backend.txt').write_text('url: http://example.invalid\nusername: dummy\npassword: dummy\n',encoding='utf-8')
        opener=Opener();self.assertFalse(health.check(self.root,opener)['ok']);self.assertEqual(opener.paths,[])


if __name__=='__main__':unittest.main()
