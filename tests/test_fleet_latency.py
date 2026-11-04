import io
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import fleet_latency as latency
from test_meter import monitor


class FleetLatencyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'fleet.json'
        self.nodes=[{'name':'RX-92','role':'rx','received_at':time.time(),'latency_control_supported':True,'target_latency':'100ms'},
                    {'name':'RX-93','role':'rx','received_at':0,'latency_control_supported':True,'target_latency':'100ms'}]
        self.send=Mock(return_value=(True,'id'))
        self.fleet=latency.Fleet(lambda:self.nodes,self.send,self.path)

    def test_validation_rejects_noninteger_and_out_of_range(self):
        for value in [None,True,'200',200.5,0,19,2001]:
            with self.assertRaises(ValueError):self.fleet.request(value)
        self.assertFalse(self.path.exists())

    def test_persist_reconcile_confirmation_and_offline_return(self):
        self.fleet.request(250);self.fleet.tick()
        self.assertEqual(self.send.call_count,1)
        target=self.fleet.desired
        self.assertEqual(self.send.call_args.args,('RX-92','set_latency',target))
        self.nodes[0].update(target_latency='250ms',latency_revision=target['revision'])
        self.assertEqual(self.fleet.snapshot()['nodes'][0]['state'],'confermato')
        self.nodes[1]['received_at']=time.time();self.fleet.tick()
        self.assertEqual(self.send.call_count,2)
        self.assertEqual(latency.Fleet(lambda:self.nodes,self.send,self.path).desired,target)

    def test_old_receiver_not_sent_and_failed_send_retried_with_backoff(self):
        self.nodes[0]['latency_control_supported']=False
        self.fleet.request(300);self.fleet.tick();self.send.assert_not_called()
        self.assertEqual(self.fleet.snapshot()['nodes'][0]['state'],'aggiornamento_richiesto')
        self.nodes[0]['latency_control_supported']=True
        self.send.return_value=(False,'Invio fallito');self.fleet.tick();self.fleet.tick()
        self.assertEqual(self.send.call_count,1)
        self.assertEqual(self.fleet.snapshot()['nodes'][0]['state'],'errore')

    def test_apply_receiver_restart_and_duplicate_idempotent(self):
        path=Path(self.temp.name)/'config';path.write_text('ROLE="rx"\nTARGET_LATENCY="100ms"\n')
        config={'TARGET_LATENCY':'100ms'};value={'target_ms':250,'revision':'a'*32}
        with patch.object(latency.subprocess,'run') as run:
            latency.apply_receiver(config,value,path)
            self.assertEqual(run.call_count,2)
            self.assertIn('TARGET_LATENCY="250ms"',path.read_text())
            latency.apply_receiver(config,value,path)
            self.assertEqual(run.call_count,2)
        self.assertEqual(config['FLEET_LATENCY_REVISION'],'a'*32)

    def test_same_target_new_revision_does_not_restart_audio(self):
        path=Path(self.temp.name)/'config';path.write_text('TARGET_LATENCY="250ms"\n')
        with patch.object(latency.subprocess,'run') as run:
            latency.apply_receiver({'TARGET_LATENCY':'250ms'},{'target_ms':250,'revision':'b'*32},path)
            run.assert_not_called()

    def test_failed_restart_rolls_back_disk_and_memory(self):
        path=Path(self.temp.name)/'config';original='TARGET_LATENCY="100ms"\n';path.write_text(original)
        config={'TARGET_LATENCY':'100ms'}
        with patch.object(latency.subprocess,'run',side_effect=latency.subprocess.CalledProcessError(1,'systemctl')):
            with self.assertRaises(RuntimeError):latency.apply_receiver(config,{'target_ms':250,'revision':'c'*32},path)
        self.assertEqual(path.read_text(),original);self.assertEqual(config,{'TARGET_LATENCY':'100ms'})

    def request(self,method,headers=None,payload=None):
        h=object.__new__(monitor.Handler);h.path='/api/latency';h.headers=headers or {};h.wfile=io.BytesIO()
        data=json.dumps(payload).encode() if payload is not None else b''
        h.rfile=io.BytesIO(data);h.headers={**h.headers,'Content-Length':str(len(data))}
        h.connection=Mock();h.send_response=lambda c:setattr(h,'code',c);h.send_header=lambda *args:None;h.end_headers=lambda:None
        with patch.object(monitor,'LATENCY_FLEET',self.fleet):getattr(h,'do_'+method)()
        return h.code,h.wfile.getvalue()

    def test_http_admin_and_csrf_protection(self):
        self.assertEqual(self.request('GET')[0],401)
        self.assertEqual(self.request('POST',payload={'target_ms':250})[0],401)
        monitor.SESSIONS['latency-test']={'expires':time.monotonic()+60,'csrf':'test'}
        self.addCleanup(lambda:monitor.SESSIONS.pop('latency-test',None))
        headers={'Cookie':'regia=latency-test'}
        self.assertEqual(self.request('GET',headers)[0],200)
        self.assertEqual(self.request('POST',headers,{'target_ms':250})[0],403)
        self.assertEqual(self.request('POST',{**headers,'X-CSRF-Token':'test'},{'target_ms':250})[0],202)
        self.assertEqual(self.fleet.desired['target_ms'],250)
