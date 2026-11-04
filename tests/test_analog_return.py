import struct
import unittest
from test_meter import monitor

class AnalogReturnTests(unittest.TestCase):
    def setUp(self):
        self.capture=monitor.AnalogReturn()
        self.reference={'available':True,'channels':[{'rms_dbfs':-20}]}

    def feed(self, value):
        self.capture.feed(struct.pack('<320h', *([value,-value]*160)))

    def test_missing_return_and_presence(self):
        self.feed(0)
        self.assertEqual(self.capture.snapshot(self.reference)['status'],'missing_return')
        self.feed(4000)
        self.assertEqual(self.capture.snapshot(self.reference)['status'],'signal_present')
        self.assertEqual(self.capture.snapshot(self.reference)['comparison'],'levels_only')

    def test_mute_and_clipping(self):
        self.feed(4000)
        self.assertEqual(self.capture.snapshot(self.reference,True)['status'],'audio_while_muted')
        self.feed(32767)
        self.assertEqual(self.capture.snapshot(self.reference)['status'],'capture_clipping')

    def test_stale_and_reference_unavailable(self):
        self.feed(4000)
        self.assertEqual(self.capture.snapshot({'available':False})['status'],'reference_unavailable')
        self.capture.updated-=4
        self.assertFalse(self.capture.snapshot(self.reference)['available'])

    def test_expected_silence(self):
        self.feed(0)
        self.assertEqual(self.capture.snapshot(self.reference,True)['status'],'expected_silence')
        self.assertEqual(self.capture.snapshot({'available':True,'channels':[{'rms_dbfs':-96}]})['status'],'expected_silence')

class IntegratedDiagnosisTests(unittest.TestCase):
    def node(self, waveform=None, integrity=None):
        return {'role':'rx','online':True,'audio_meter':{'available':True,'integrity':integrity or {}},
                'waveform_diagnostics':waveform or {}}

    def test_optional_interface_absent_keeps_transport_diagnosis(self):
        node=self.node()
        monitor.apply_audio_diagnosis([node])
        self.assertEqual(node['audio_diagnosis']['code'],'RX_RTP_CLEAN')
        self.assertEqual(node['transport_diagnosis']['code'],'RX_RTP_CLEAN')

    def test_confirmed_output_fault_is_visible_with_clean_rtp(self):
        node=self.node({'confirmed':True,'status':'dropout','message':'Interruzione analogica'})
        monitor.apply_audio_diagnosis([node])
        self.assertEqual(node['audio_diagnosis']['code'],'RX_OUTPUT_DROPOUT')
        self.assertEqual(node['transport_diagnosis']['code'],'RX_RTP_CLEAN')

    def test_digital_warning_preserved_with_output_evidence(self):
        node=self.node({'confirmed':True,'status':'dropout','message':'Interruzione analogica'},
                       {'missing_packets':4})
        monitor.apply_audio_diagnosis([node])
        self.assertEqual(node['audio_diagnosis']['code'],'NETWORK_SEQUENCE_GAPS')
        self.assertIn('Interruzione analogica',node['audio_diagnosis']['detail'])

    def test_level_meter_does_not_override_waveform_silence_check(self):
        node=self.node({'status':'insufficient_signal','confirmed':False})
        node['analog_return']={'status':'missing_return','message':'Meter precedente ancora attivo'}
        monitor.apply_audio_diagnosis([node])
        self.assertEqual(node['audio_diagnosis']['code'],'RX_RTP_CLEAN')
        self.assertFalse(monitor.analog_return_problem(node))

    def test_offline_node_does_not_report_stale_output_fault(self):
        node=self.node({'confirmed':True,'status':'dropout','message':'Interruzione analogica'})
        node['online']=False
        monitor.apply_audio_diagnosis([node])
        self.assertEqual(node['audio_diagnosis']['code'],'NODE_OFFLINE')
