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

class OptionalRuntimeTests(unittest.TestCase):
    def setUp(self):
        from unittest.mock import patch
        self.patch=patch
        self.state=patch.multiple(monitor,ANALOG_RETURN=None,ANALOG_PRESENT=False,
                                  DIAGNOSTICS=None,ANALOG_LAST_ATTEMPT=-1e9)
        self.state.start()
        self.addCleanup(self.state.stop)

    def test_absent_interface_starts_nothing_and_adds_no_payload(self):
        with self.patch.object(monitor,'read_text',return_value='0 [Headphones]: bcm2835 Headphones'), \
             self.patch.object(monitor.subprocess,'run') as run, \
             self.patch.object(monitor.threading,'Thread') as thread:
            monitor.refresh_analog_return({'ROLE':'rx'})
            self.assertEqual(monitor.analog_snapshot_fields({'available':True},False),{})
        run.assert_not_called();thread.assert_not_called()
        self.assertIsNone(monitor.DIAGNOSTICS)
        self.assertIsNone(monitor.ANALOG_RETURN)

    def test_tx_does_not_probe_optional_interface(self):
        with self.patch.object(monitor,'read_text') as read:
            monitor.refresh_analog_return({'ROLE':'tx'})
        read.assert_not_called()

    def test_present_interface_starts_capture_only(self):
        from unittest.mock import Mock
        listing=Mock(stdout='card 2: USB [Scarlett 2i4 USB], device 0: USB Audio')
        with self.patch.object(monitor,'read_text',return_value='2 [USB]: USB-Audio - Scarlett 2i4 USB'), \
             self.patch.object(monitor.subprocess,'run',return_value=listing), \
             self.patch.object(monitor.threading,'Thread') as thread:
            monitor.refresh_analog_return({'ROLE':'rx'})
        self.assertEqual(thread.call_count,1)
        self.assertEqual(monitor.ANALOG_RETURN.device,'plughw:CARD=USB,DEV=0')
        self.assertIsNone(monitor.DIAGNOSTICS)
        self.assertIsNone(monitor.ANALOG_RETURN.diagnostics)

    def test_disconnection_stops_capture_and_removes_payload(self):
        from unittest.mock import Mock
        capture=Mock();capture.thread.is_alive.return_value=False
        monitor.ANALOG_RETURN=capture
        with self.patch.object(monitor,'read_text',return_value=''), \
             self.patch.object(monitor.subprocess,'run') as run:
            monitor.refresh_analog_return({'ROLE':'rx'})
        capture.stop.assert_called_once()
        run.assert_not_called()
        self.assertEqual(monitor.analog_snapshot_fields({},False),{})
        self.assertIsNone(monitor.ANALOG_RETURN)

    def test_busy_interface_does_not_start_analysis(self):
        capture=monitor.AnalogReturn('plughw:CARD=USB,DEV=0')
        with self.patch.object(monitor.subprocess,'Popen',side_effect=OSError('Device busy')), \
             self.patch.object(capture,'enable_analysis') as enable:
            capture.loop()
        enable.assert_not_called()
        self.assertTrue(capture.stop_event.is_set())
        self.assertIsNone(monitor.DIAGNOSTICS)

    def test_pcm_enables_analysis_and_capture_exit_stops_it(self):
        import sys
        import types
        from unittest.mock import Mock
        diagnostics=Mock()
        module=types.SimpleNamespace(Diagnostics=Mock(return_value=diagnostics),np=object())
        process=Mock();process.poll.return_value=None
        capture=monitor.AnalogReturn('plughw:CARD=USB,DEV=0')
        with self.patch.dict(sys.modules,{'rx_diagnostics':module}), \
             self.patch.object(monitor.subprocess,'Popen',return_value=process), \
             self.patch('select.select',return_value=([process.stdout],[],[])), \
             self.patch.object(monitor.os,'read',side_effect=[bytes(32000),b'']), \
             self.patch.object(monitor.threading,'Thread') as thread:
            capture.loop()
        module.Diagnostics.assert_called_once()
        diagnostics.feed_capture.assert_called_once()
        self.assertEqual(diagnostics.feed_capture.call_args.args[0],bytes(32000))
        self.assertTrue(capture.analysis_stop.is_set())
        thread.return_value.join.assert_called_once_with(timeout=5)
        self.assertIsNone(monitor.DIAGNOSTICS)
        self.assertIsNone(capture.diagnostics)
        self.assertIsNone(capture.process)

    def test_capture_stderr_counts_split_xrun_lines(self):
        capture=monitor.AnalogReturn('plughw:CARD=USB,DEV=0')
        with self.patch('builtins.print'):
            capture.note_stderr(b'over')
            self.assertEqual(capture.capture_health['xrun_events'],0)
            capture.note_stderr(b'run!!! (at least 10 ms)\n')
        self.assertEqual(capture.capture_health['xrun_events'],1)
        self.assertIn('overrun',capture.capture_health['last_message'])

    def test_capture_failure_retries_are_throttled(self):
        with self.patch.object(monitor,'read_text',return_value='USB Scarlett'), \
             self.patch.object(monitor.subprocess,'run',side_effect=OSError('busy')) as run, \
             self.patch.object(monitor.time,'monotonic',side_effect=[10,15,41]):
            for _ in range(3): monitor.refresh_analog_return({'ROLE':'rx'})
        self.assertEqual(run.call_count,2)

    def test_monitor_import_does_not_load_dsp_modules(self):
        import subprocess
        import sys
        from pathlib import Path
        installer=Path(__file__).resolve().parents[1]/'setup_roc_museum.sh'
        script="""import sys
from pathlib import Path
source=Path(sys.argv[1]).read_text().split(\"<<'PY_MONITOR'\\n\",1)[1].split('\\nPY_MONITOR',1)[0]
exec(compile(source,'monitor','exec'),{'__name__':'monitor'})
assert 'numpy' not in sys.modules
assert 'rx_diagnostics' not in sys.modules
"""
        subprocess.run([sys.executable,'-c',script,str(installer)],check=True,capture_output=True)
