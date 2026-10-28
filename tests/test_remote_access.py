"""Run remote setup with fake commands and a temporary filesystem."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class RemoteTests(unittest.TestCase):
    def run_enable(self,password=True,hostname='tx.example.ts.net.'):
        with tempfile.TemporaryDirectory() as directory:
            work=Path(directory);bin=work/'bin';bin.mkdir();log=work/'calls'
            (work/'node.conf').write_text('ROLE="tx"\n')
            if password: (work/'auth.json').write_text(json.dumps({'salt':'salt','hash':'hash'}))
            watchdog=work/'watchdog/scripts';watchdog.mkdir(parents=True)
            (watchdog/'install.sh').write_text('cat "$1" > "$TEST_CONFIG"\n')
            for name,body in {
                'id':'echo 0',
                'tailscale': 'echo "$*" >> "$TEST_LOG"\nif [ "$1" = status ]; then echo \'{"Self":{"DNSName":"'+hostname+'"}}\'; fi',
            }.items():
                path=bin/name;path.write_text('#!/bin/bash\n'+body+'\n');path.chmod(0o755)
            script=(ROOT/'remote_access.sh').read_text().replace('/etc/roc-museum.conf',str(work/'node.conf')).replace('/var/lib/roc-museum/auth.json',str(work/'auth.json')).replace('/usr/local/lib/roc-museum/funnel-watchdog',str(work/'watchdog'))
            path=work/'remote.sh';path.write_text(script)
            result=subprocess.run(['bash',str(path),'enable'],env={**os.environ,'PATH':str(bin)+':'+os.environ['PATH'],'TEST_LOG':str(log),'TEST_CONFIG':str(work/'config')},capture_output=True,text=True)
            return result.returncode,log.read_text() if log.exists() else '',(work/'config').read_text() if (work/'config').exists() else ''
    def test_enable_configures_existing_watchdog(self):
        code,calls,config=self.run_enable()
        self.assertEqual(code,0)
        self.assertIn('funnel --bg --https=443 http://127.0.0.1:8080',calls)
        self.assertIn('PUBLIC_URL=https://tx.example.ts.net/healthz',config)
        self.assertIn('LOCAL_URL=http://127.0.0.1:8080/healthz',config)
    def test_missing_password_never_publishes(self):
        code,calls,_=self.run_enable(password=False)
        self.assertNotEqual(code,0);self.assertNotIn('funnel',calls)
    def test_invalid_hostname_never_publishes(self):
        code,calls,_=self.run_enable(hostname='invalid/path')
        self.assertNotEqual(code,0);self.assertNotIn('funnel',calls)
