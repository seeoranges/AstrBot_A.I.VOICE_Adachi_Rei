"""Read-only dashboard/plugin readiness; never tests a paid provider or sends QQ."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


def check(directory, opener=None):
    fields={}
    for line in (Path(directory)/'private'/'backend.txt').read_text(encoding='utf-8-sig').splitlines():
        key,sep,value=line.replace('：',':',1).partition(':')
        if sep:fields[key.strip().lower()]=value.strip()
    base=(fields.get('url') or 'http://127.0.0.1:6185').split()[0].rstrip('/')
    parsed=urllib.parse.urlsplit(base)
    if parsed.scheme!='http' or parsed.hostname not in {'127.0.0.1','localhost','::1'}:
        return dict(ok=False,reason='dashboard_not_local')
    opener=opener or urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(method,path,body=None,token=None):
        req=urllib.request.Request(base+'/api/v1'+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json'})
        if token:req.add_header('Authorization','Bearer '+token)
        with opener.open(req,timeout=4) as response:result=json.load(response)
        if result.get('status')=='error':raise RuntimeError('dashboard_operation_failed')
        return result.get('data',{})
    token=None
    for password in (fields['password'],hashlib.md5(fields['password'].encode()).hexdigest()):
        try:token=request('POST','/auth/login',{'username':fields['username'],'password':password}).get('token')
        except (urllib.error.HTTPError,RuntimeError):continue
        if token:break
    if not token:return dict(ok=False,reason='dashboard_auth_failed')
    failed=request('GET','/plugins/failed',token=token)
    if not isinstance(failed,dict):return dict(ok=False,reason='invalid_plugin_status')
    features={}
    for name,label in (('astrbot_plugin_adachi_aivoice','voice'),('astrbot_plugin_livingmemory','memory'),('meme_manager','memes')):
        try:features[label]=request('GET','/plugins/by-id?plugin_id='+name,token=token).get('activated') is True
        except urllib.error.HTTPError:features[label]=False
    return dict(ok=not failed,failed_plugins=len(failed),features=features,
                reason='plugins_failed' if failed else 'dashboard_and_plugin_registry_ready')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--dir',required=True);args=parser.parse_args()
    try:result=check(args.dir)
    except Exception:result=dict(ok=False,reason='dashboard_not_ready')
    print(json.dumps(result));return 0


if __name__=='__main__':raise SystemExit(main())
