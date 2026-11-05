import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from diagnostic_history import History
from test_meter import monitor

class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path=Path(self.directory.name)/'history.sqlite3'
        self.history=History(self.path)

    def node(self, code='NETWORK_SEQUENCE_GAPS'):
        return {'name':'RX-51','online':True,'transport_diagnosis':{
            'severity':'warning' if code else 'ok','code':code or 'RX_RTP_CLEAN',
            'summary':'Pacchetti mancanti' if code else 'Regolare'},
            'audio_meter':{'integrity':{'missing_packets':3}}}

    def test_continuous_error_grouped_then_recovery_retained(self):
        self.history.observe([self.node()],100)
        self.history.observe([self.node()],105)
        self.history.observe([self.node(None)],110)
        rows=self.history.query()['events']
        self.assertEqual(len(rows),1)
        self.assertFalse(rows[0]['active'])
        self.assertEqual(rows[0]['observations'],2)
        self.assertEqual(rows[0]['observed_duration_seconds'],10)
        self.assertEqual(rows[0]['resolution'],'recovered')

    def test_restart_preserves_events_without_claiming_recovery(self):
        self.history.observe([self.node()],100)
        self.history.observe([self.node()],105)
        history=History(self.path)
        event=history.query()['events'][0]
        self.assertEqual(event['resolution'],'monitor_restart')
        self.assertEqual(event['ended_at'],105)

    def test_evidence_after_recovery_is_logged_once(self):
        node=self.node(None)
        node['waveform_diagnostics']={'status':'matched','events':[{
            'path':'/var/lib/roc-museum/diagnostics/event-123','status':'dropout','triggered_at':90}]}
        self.history.observe([node],100)
        self.history.observe([node],105)
        rows=self.history.query()['events']
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['source'],'evidence')
        self.assertEqual(rows[0]['details']['rx_triggered_at'],90)

    def test_transient_waveform_observation_is_retained_as_unconfirmed(self):
        node=self.node(None)
        node['waveform_diagnostics']={'status':'mismatch','confirmed':False,'message':'Segnale diverso'}
        self.history.observe([node],100)
        self.history.observe([self.node(None)],105)
        event=self.history.query()['events'][0]
        self.assertEqual(event['severity'],'info')
        self.assertFalse(event['active'])
        self.assertIn('da confermare',event['summary'])

    def test_confirmation_updates_same_incident_without_downgrading_later(self):
        node=self.node(None)
        wave={'status':'mismatch','confirmed':False,'message':'Segnale diverso'}
        node['waveform_diagnostics']=wave
        self.history.observe([node],100)
        wave['confirmed']=True
        self.history.observe([node],105)
        wave['confirmed']=False
        self.history.observe([node],110)
        rows=self.history.query()['events']
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['severity'],'warning')
        self.assertEqual(rows[0]['summary'],'Segnale diverso')

    def test_probe_timing_and_cost_are_information_only(self):
        node=self.node(None)
        node['waveform_diagnostics']={'status':'matched','confirmed':False,
            'timing_observation':'capture_delay_change','timing_message':'Stima temporale variata',
            'workload':{'over_budget':True,'analysis_cpu_ms':250}}
        self.history.observe([node],100)
        rows=self.history.query()['events']
        self.assertEqual({r['source'] for r in rows},{'probe_timing','probe_runtime'})
        self.assertTrue(all(r['severity']=='info' for r in rows))

    def test_offline_does_not_close_error_as_recovered(self):
        node=self.node()
        self.history.observe([node],100)
        node['online']=False
        self.history.observe([node],105)
        rows=self.history.query()['events']
        prior=next(e for e in rows if e['source']=='transport')
        self.assertEqual(prior['resolution'],'node_offline')
        self.assertTrue(next(e for e in rows if e['source']=='node')['active'])

    def test_retention_and_node_filter(self):
        history=History(self.path,limit=3)
        for i in range(6):
            history.observe([self.node(str(i))],100+i*10)
            history.observe([self.node(None)],105+i*10)
        self.assertEqual(len(history.query()['events']),3)
        self.assertEqual(history.query("RX-51' OR 1=1 --")['events'],[])
        self.assertEqual(len(history.query('RX-51')['events']),3)
        history.observe([],31*86400)
        self.assertEqual(history.query()['events'],[])

    def test_no_events_for_healthy_rx_without_card(self):
        self.history.observe([self.node(None)],100)
        self.assertEqual(self.history.query()['events'],[])

    def test_info_observation_not_upgraded_to_confirmed_fault(self):
        node=self.node('TX_MONITOR_STALL_UNCONFIRMED')
        node['transport_diagnosis']['severity']='info'
        self.history.observe([node],100)
        self.assertEqual(self.history.query()['events'][0]['severity'],'info')

    def test_payload_details_are_bounded(self):
        node=self.node();node['network']={'extra':'x'*10000}
        self.history.observe([node],100)
        detail=self.history.query()['events'][0]['details']
        self.assertTrue(detail['truncated'])
        self.assertLess(len(json.dumps(detail)),6200)

    def test_embedded_source_matches(self):
        root=Path(__file__).resolve().parents[1]
        embedded=(root/'setup_roc_museum.sh').read_text().split("<<'PY_DIAGNOSTIC_HISTORY'\n",1)[1].split('\nPY_DIAGNOSTIC_HISTORY',1)[0]
        self.assertEqual(embedded,(root/'diagnostic_history.py').read_text().rstrip())

class MonitorHistoryTests(unittest.TestCase):
    def test_collection_does_not_depend_on_browser(self):
        history=Mock()
        with patch.object(monitor,'HISTORY',history),patch.object(monitor,'system_status',return_value={'nodes':[{'name':'RX'}]}):
            monitor.record_diagnostic_history({'ROLE':'tx'})
        history.observe.assert_called_once_with([{'name':'RX'}])

    def test_storage_failure_does_not_stop_monitor(self):
        history=Mock();history.observe.side_effect=OSError('disk full')
        with patch.object(monitor,'HISTORY',history),patch.object(monitor,'HISTORY_ERROR',''), \
             patch.object(monitor,'system_status',return_value={'nodes':[]}),patch('builtins.print'):
            monitor.record_diagnostic_history({'ROLE':'tx'})
            self.assertEqual(monitor.HISTORY_ERROR,'disk full')

    def test_probe_report_is_read_only_and_keeps_node_filter(self):
        handler=object.__new__(monitor.Handler);handler.json_reply=Mock()
        handler.path='/api/diagnostics/report?node=RX-93'
        history=Mock();history.query.return_value={'events':[]}
        status={'generated_at':100,'software_version':'4.32','nodes':[{'name':'RX-91'},{'name':'RX-93'}]}
        with patch.object(monitor,'HISTORY',history),patch.object(monitor,'HISTORY_ERROR',''),patch.object(monitor,'system_status',return_value=status):
            handler.do_GET()
        code,payload=handler.json_reply.call_args.args
        self.assertEqual(code,200)
        self.assertEqual(payload['nodes'],[{'name':'RX-93'}])
        self.assertEqual(payload['schema_version'],2)
        history.query.assert_called_once_with('RX-93',20)
        history.observe.assert_not_called()

    def test_endpoint_filter_and_invalid_limit(self):
        handler=object.__new__(monitor.Handler)
        handler.json_reply=Mock()
        history=Mock();history.query.return_value={'events':[]}
        with patch.object(monitor,'HISTORY',history),patch.object(monitor,'HISTORY_ERROR',''):
            handler.path='/api/diagnostics/history?node=RX-51&limit=25'
            handler.do_GET()
            history.query.assert_called_once_with('RX-51',25)
            handler.json_reply.assert_called_with(200,{'events':[],'error':''})
            handler.path='/api/diagnostics/history?limit=10001'
            handler.do_GET()
            self.assertEqual(handler.json_reply.call_args.args[0],400)
