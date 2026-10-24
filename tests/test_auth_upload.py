"""Exercise HTTP auth and upload handlers without hardware or network sockets."""
import io
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from test_meter import monitor

class AccessTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.media=Path(self.temp.name)/'media'
        self.auth=Path(self.temp.name)/'auth.json'
        self.patches=[patch.object(monitor,'MEDIA_DIR',self.media),patch.object(monitor,'AUTH_FILE',self.auth)]
        for p in self.patches: p.start();self.addCleanup(p.stop)
        monitor.SESSIONS.clear();monitor.LOGIN_ATTEMPTS.clear()
        monitor.SESSIONS['test']={'expires':time.monotonic()+100,'csrf':'secret'}
    def request(self,path,body=b'',headers=None,method='POST'):
        h=object.__new__(monitor.Handler)
        h.path=path;h.headers=headers or {};h.client_address=('127.0.0.1',10)
        h.rfile=io.BytesIO(body);h.wfile=io.BytesIO()
        h.connection=type('Connection',(),{'settimeout':lambda *args:None})()
        h.config={};h.send_response=lambda code:setattr(h,'code',code)
        h.send_header=lambda *args:None;h.end_headers=lambda:None
        getattr(h,'do_'+method)()
        return h.code,h.wfile.getvalue()
    def headers(self,**extra):
        return {'Cookie':'regia=test','X-CSRF-Token':'secret',**extra}
    def test_public_status_private_controls(self):
        with patch.object(monitor,'system_status',return_value={'nodes':[]}):
            self.assertEqual(self.request('/api/status',method='GET')[0],200)
        for path in ('/api/control','/api/upload','/api/media/delete','/api/player','/api/calendar/save','/api/calendar/delete','/api/usb/browse','/api/usb/import','/api/usb/eject'):
            self.assertEqual(self.request(path)[0],401)
        for path in ('/api/media','/api/studio','/api/usb'):
            self.assertEqual(self.request(path,method='GET')[0],401)
        self.assertEqual(self.request('/api/control',headers={'Cookie':'regia=test'})[0],403)
    def test_upload_atomic_and_duplicate(self):
        headers=self.headers(**{'Content-Length':'4','X-Filename':'brano.wav'})
        self.assertEqual(self.request('/api/upload',b'audio'[:4],headers)[0],201)
        self.assertEqual((self.media/'brano.wav').read_bytes(),b'audi')
        self.assertEqual(self.request('/api/upload',b'abcd',headers)[0],409)
        self.assertEqual(list(self.media.glob('.upload-*')),[])
    def test_incomplete_and_traversal(self):
        for name in ('../test.wav','%2Ftmp%2Ftest.wav','test.exe'):
            self.assertEqual(self.request('/api/upload',b'ab',self.headers(**{'Content-Length':'2','X-Filename':name}))[0],400)
        self.assertEqual(self.request('/api/upload',b'a',self.headers(**{'Content-Length':'20','X-Filename':'x.wav'}))[0],400)
        self.assertEqual(list(self.media.iterdir()),[])
    def test_logout_revokes_session(self):
        self.assertEqual(self.request('/api/logout',headers=self.headers())[0],200)
        self.assertEqual(self.request('/api/media',headers=self.headers(),method='GET')[0],401)
    def test_password_login_and_rate_limit(self):
        salt='test'
        digest=monitor.hashlib.pbkdf2_hmac('sha256',b'long-password',salt.encode(),600000).hex()
        self.auth.write_text(json.dumps({'salt':salt,'hash':digest}))
        data=json.dumps({'username':'admin','password':'long-password'}).encode()
        headers={'Content-Length':str(len(data)),'X-Regia-Request':'1'}
        self.assertEqual(self.request('/api/login',data,headers)[0],200)
        monitor.LOGIN_ATTEMPTS['127.0.0.1']=[time.monotonic(),10]
        self.assertEqual(self.request('/api/login',data,headers)[0],429)
    def test_expired_session(self):
        monitor.SESSIONS['test']['expires']=0
        self.assertEqual(self.request('/api/media',headers=self.headers(),method='GET')[0],401)

    def test_delete_route_protected_and_delegates(self):
        from unittest.mock import Mock
        engine=Mock();engine.delete_media.return_value={'ok':True,'message':'Traccia eliminata'}
        body=json.dumps({'name':'test.wav'}).encode()
        with patch.object(monitor.Handler,'studio',engine):
            self.assertEqual(self.request('/api/media/delete',body,{'Cookie':'regia=test','Content-Length':str(len(body))})[0],403)
            self.assertEqual(self.request('/api/media/delete',body,self.headers(**{'Content-Length':str(len(body))}))[0],200)
            engine.delete_media.assert_called_once_with('test.wav')

if __name__=='__main__': unittest.main()
