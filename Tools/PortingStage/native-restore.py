#!/usr/bin/env python3
"""Temporary immutable-blob qualification. Never creates or changes a Git ref."""
import base64,hashlib,json,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[2]
config=json.loads((Path(__file__).with_suffix('.json')).read_text())
def blob(data):return hashlib.sha1(f'blob {len(data)}\0'.encode()+data).hexdigest()
def gh(args,payload=None):
    return json.loads(subprocess.check_output(['gh','api',*args],input=payload))
if sys.argv[1]=='apply':
    paths={config['protocol']:'8b06289ea90ca54fdc69e6b6ceb3f4fe2587656c',
           config['handler']:'a3032b36c9d85b91f109008bbf9b978281e31933'}
    for name,sha in paths.items():
        assert blob((root/name).read_bytes())==sha,(name,'unexpected preimage')
    p=root/config['protocol'];s=p.read_text()
    a=s.index('public struct ReaderContentEbookInitialRestore: Sendable {')
    b=s.index('@globalActor\npublic actor ReaderContentSyncStatusLoader',a)
    p.write_text(s[:a]+s[b:])
    p=root/config['handler'];s=p.read_text()
    a=s.index('private struct ReaderEBookInitialRestoreBridgeRequest {')
    b=s.index('public typealias ReaderShowOriginalWillBeginHandler',a)
    s=s[:a]+s[b:]
    a=s.index('            ("ebookViewerInitialized"');b=s.index('            ("updateReadingProgress"',a)
    p.write_text(s[:a]+config['main_handler']+s[b:])
    # Read an immutable public source blob. Do not export private Core content.
    value=gh(['repos/lake-of-fire/LakeOfFire/git/blobs/'+config['integration_blob']])
    data=base64.b64decode(value['content']);assert blob(data)==config['integration_blob']
    s=data.decode();a=s.index('private struct ReaderEBookInitialRestoreBridgeRequest {')
    b=s.index('public typealias ReaderShowOriginalWillBeginHandler',a);s=s[:a]+s[b:]
    for old,new in [(config['integration_replacement_before'],config['integration_replacement_after']),
                    (config['integration_remove'],'')]:
        assert s.count(old)==1;s=s.replace(old,new)
    p=root/'.port-native-stage/integration-handler.swift';p.parent.mkdir(exist_ok=True);p.write_text(s)
for name,sha in config['outputs'].items():
    assert blob((root/name).read_bytes())==sha,(name,'output mismatch')
if sys.argv[1]=='publish':
    results={}
    for name,sha in config['outputs'].items():
        payload=json.dumps({'content':base64.b64encode((root/name).read_bytes()).decode(),'encoding':'base64'}).encode()
        result=gh(['--method','POST','repos/lake-of-fire/LakeOfFire/git/blobs','--input','-'],payload)
        assert result['sha']==sha;results[name]=sha
    (root/'evidence/published-blobs.json').write_text(json.dumps(results,indent=2)+'\n')
else:
    assert sys.argv[1]=='apply'
    for name in config['outputs']:
        subprocess.run(['swiftc','-frontend','-parse',str(root/name)],check=True)
