import io
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import diagnostics_access as access
from test_meter import monitor


class DiagnosticAccessTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.event=self.root/'event-123'
        self.event.mkdir()
        (self.event/'event.json').write_text(json.dumps({'analysis':{'status':'dropout'},'saved_at':123}))
        (self.event/'return.wav').write_bytes(b'RIFFtest')

    def test_list_and_original_audio(self):
        kind,data=access.collect({'action':'events'},self.root)
        self.assertEqual(json.loads(data)['events'][0]['id'],'event-123')
        self.assertEqual(access.collect({'action':'file','event':'event-123','file':'return.wav'},self.root),('audio/wav',b'RIFFtest'))

    def test_paths_symlinks_and_nonregular_files_rejected(self):
        for event,file in [('../event-123','event.json'),('event-123','../../etc/passwd'),('event-123','unknown')]:
            with self.assertRaises(ValueError): access.read_artifact(event,file,self.root)
        (self.event/'reference.wav').symlink_to(self.event/'return.wav')
        with self.assertRaises(OSError): access.read_artifact('event-123','reference.wav',self.root)
        (self.root/'event-456').symlink_to(self.event,target_is_directory=True)
        with self.assertRaises(OSError): access.read_artifact('event-456','event.json',self.root)

    def test_journal_allowlist_and_truncation(self):
        with patch.object(access.subprocess,'run') as run:
            for request in [{'window':'; reboot'},{'unit':'ssh'}]:
                with self.assertRaises(ValueError): access.collect({'action':'journal',**request})
            run.assert_not_called()
            run.return_value=type('Result',(),{'returncode':0,'stdout':b'x\n'*5001,'stderr':b''})()
            _,data=access.collect({'action':'journal'})
            self.assertTrue(json.loads(data)['truncated'])
            self.assertEqual(len(json.loads(data)['text'].splitlines()),5000)
            self.assertIn('roc-museum.service',run.call_args.args[0])

    def test_transport_roundtrip_and_peer_restriction(self):
        with access.DiagnosticServer(('127.0.0.1',0),access.DiagnosticHandler) as server:
            server.tx_ip='127.0.0.1'
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                with patch.object(access,'collect',return_value=('audio/wav',b'RIFForiginal')):
                    self.assertEqual(access.fetch('127.0.0.1',server.server_address[1],{'action':'file'}),('audio/wav',b'RIFForiginal'))
                server.tx_ip='192.0.2.1'
                self.assertFalse(server.verify_request(None,('127.0.0.1',123)))
            finally: server.shutdown();thread.join()

    def request(self,query,cookie=True):
        handler=object.__new__(monitor.Handler)
        handler.path='/api/diagnostics/debug?'+query
        handler.config={'ROLE':'tx','NODE_NAME':'TX'}
        handler.headers={'Cookie':'regia=debug-test'} if cookie else {}
        handler.wfile=io.BytesIO()
        handler.send_response=lambda code:setattr(handler,'code',code)
        handler.send_header=lambda *args:None;handler.end_headers=lambda:None
        monitor.SESSIONS['debug-test']={'expires':time.monotonic()+60,'csrf':'test'}
        try: handler.do_GET();return handler.code,handler.wfile.getvalue()
        finally: monitor.SESSIONS.pop('debug-test',None)

    def test_http_auth_offline_and_no_arbitrary_host(self):
        with patch.object(access,'fetch') as fetch,patch.dict(monitor.REGISTRY,{'RX-93':{'role':'rx','source_ip':'192.168.1.93','received_at':0}},clear=True):
            self.assertEqual(self.request('node=RX-93',False)[0],401)
            self.assertEqual(self.request('node=RX-93')[0],503)
            self.assertEqual(self.request('node=127.0.0.1')[0],404)
            fetch.assert_not_called()

    def test_http_proxy_uses_registered_peer_and_returns_wav(self):
        with patch.object(access,'fetch',return_value=('audio/wav',b'RIFForiginal')) as fetch,patch.dict(monitor.REGISTRY,{'RX-93':{'role':'rx','source_ip':'192.168.1.93','received_at':time.time()}},clear=True):
            code,data=self.request('node=RX-93&action=file&event=event-123&file=return.wav&host=evil')
            self.assertEqual((code,data),(200,b'RIFForiginal'))
            self.assertEqual(fetch.call_args.args[:2],('192.168.1.93',19091))
