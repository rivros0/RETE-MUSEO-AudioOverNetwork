import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rx_diagnostics as d

@unittest.skipIf(d.np is None, 'NumPy required for DSP tests')
class WaveformTests(unittest.TestCase):
    def setUp(self):
        self.np=d.np
        rng=d.np.random.default_rng(123)
        # Broadband, nonperiodic audio with energy safely above the noise floor.
        self.ref=d.np.repeat(rng.normal(0, .12, (44100, 2)), 4, axis=0)
        # reference is 4 seconds at 44.1k; select second 2, emulate a separate ADC.
        self.segment=self.ref[88200:132300]
        self.heard=d.resample(self.segment,44100,16000)*.4

    def test_gain_and_sample_rate_alignment(self):
        result=d.compare(self.ref,self.heard)
        self.assertEqual(result['status'],'matched',result)
        for c in result['channels']:
            self.assertAlmostEqual(c['offset']/4000,2,delta=.001)
            self.assertGreater(c['correlation'],.95)
            self.assertAlmostEqual(c['gain_db'],-7.96,delta=.6)

    def test_dropouts(self):
        self.heard[6400:8000]=0
        result=d.compare(self.ref,self.heard)
        self.assertEqual(result['status'],'dropout',result)
        self.assertTrue(any(x['duration_ms']>=80 for x in result['channels'][0]['dropouts']))

    def test_wrong_signal(self):
        heard=d.np.random.default_rng(9).normal(0,.1,self.heard.shape)
        self.assertEqual(d.compare(self.ref,heard)['status'],'mismatch')

    def test_silence_not_verified(self):
        result=d.compare(self.ref,d.np.zeros_like(self.heard))
        self.assertEqual(result['status'],'insufficient_signal')

    def test_periodic_audio_latency_ambiguous(self):
        t=d.np.arange(44100*4)/44100
        ref=d.np.column_stack([.2*d.np.sin(2*d.np.pi*440*t)]*2)
        heard=d.resample(ref[88200:132300],44100,16000)
        self.assertEqual(d.compare(ref,heard)['status'],'ambiguous')

    def test_swapped_channels(self):
        result=d.compare(self.ref,self.heard[:, ::-1])
        self.assertEqual(result['status'],'possible_channel_swap',result)

    def test_single_missing_channel(self):
        self.heard[:, 1]=0
        result=d.compare(self.ref,self.heard)
        self.assertEqual(result['status'],'missing_channel',result)

    def test_clipping(self):
        self.heard[100:200]=1
        self.assertEqual(d.compare(self.ref,self.heard)['status'],'return_clipping')

    def test_polarity(self):
        result=d.compare(self.ref,-self.heard)
        self.assertEqual(result['status'],'matched')
        self.assertLess(result['channels'][0]['correlation'],-.95)

@unittest.skipIf(d.np is None, 'NumPy required for DSP tests')
class StreamTests(unittest.TestCase):
    def packet(self,seq,stamp,ssrc=42):
        return struct.pack('!BBHII',0x80,10,seq,stamp,ssrc)+struct.pack('!200h',*range(200))

    def test_wrap_reorder_duplicates_and_holes(self):
        diag=d.Diagnostics()
        for seq, stamp in [(65534,4294967096),(0,0),(65535,4294967196),(0,0)]:
            diag.feed_rtp(self.packet(seq,stamp),now=10)
        stats=diag.snapshot()['rtp']
        self.assertEqual(stats['packets'],3)
        self.assertEqual(stats['sequence_gaps'],1)
        self.assertEqual(stats['out_of_order'],1)
        self.assertEqual(stats['duplicates'],1)
        diag.feed_capture(bytes(32000),now=10)
        buffers=diag.buffers(10)
        self.assertTrue(buffers[2].all()) # reordered packet fills the provisional hole
        self.assertEqual(len(buffers[0]),300)

    def test_ssrc_change_resets_history(self):
        diag=d.Diagnostics()
        diag.feed_rtp(self.packet(1,0),10)
        diag.feed_capture(bytes(32000),10)
        diag.feed_rtp(self.packet(1,0,43),10.1)
        self.assertEqual(len(diag.reference),1)
        self.assertEqual(len(diag.capture),0)

    def test_stale_data(self):
        diag=d.Diagnostics()
        diag.feed_rtp(self.packet(1,0),10)
        diag.feed_capture(bytes(32000),10)
        self.assertIsNone(diag.buffers(14))

    def synthetic_stream(self, directory):
        diag=d.Diagnostics(directory)
        rng=d.np.random.default_rng(10)
        reference=d.np.repeat(rng.normal(0,.1,(44100,2)),4,axis=0)
        for start in range(0,len(reference),441):
            raw=(reference[start:start+441]*32768).astype('>i2').tobytes()
            packet=struct.pack('!BBHII',0x80,10,start//441,start,42)+raw
            diag.feed_rtp(packet,6+(start+441)/44100)
        heard=d.resample(reference[88200:132300],44100,16000)*.4
        raw=(heard*32768).astype('<i2').tobytes()
        diag.feed_capture(raw,10.25)
        with patch.object(d.time,'monotonic',return_value=10.25):
            diag.update_context(False,{'available':True,'channels':[{'rms_dbfs':-20}]})
        return diag

    def test_delay_estimate_and_mute_suppression(self):
        with tempfile.TemporaryDirectory() as directory:
            diag=self.synthetic_stream(directory)
            diag.analyze(10.25)
            self.assertEqual(diag.snapshot()['status'],'matched',diag.snapshot())
            self.assertAlmostEqual(diag.snapshot()['estimated_delay_ms'],1250,delta=1)
            diag.context['muted']=True
            diag.analyze(10.5)
            self.assertEqual(diag.snapshot()['status'],'suspended')
            self.assertFalse(diag.snapshot()['confirmed'])

    def test_natural_pause_is_not_missing_return_despite_old_meter(self):
        with tempfile.TemporaryDirectory() as directory:
            diag=self.synthetic_stream(directory)
            diag.previous_delay=1250
            diag.previous_delay_time=10.25
            for _, stamp, data in diag.reference:
                if 88200 <= stamp < 132300:
                    data[:]=0
            diag.capture[-1][1][:]=0
            diag.analyze(10.25)
            self.assertEqual(diag.snapshot()['status'],'insufficient_signal',diag.snapshot())
            self.assertFalse(diag.snapshot()['confirmed'])

    def test_sustained_missing_return_requires_active_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            diag=self.synthetic_stream(directory)
            diag.capture[-1][1][:]=0
            diag.analyze(10.25)
            self.assertEqual(diag.snapshot()['status'],'missing_return',diag.snapshot())
            self.assertFalse(diag.snapshot()['confirmed'])
            diag.analyze(10.5)
            self.assertTrue(diag.snapshot()['confirmed'])

    def test_post_window_saved_even_after_disconnection(self):
        with tempfile.TemporaryDirectory() as directory:
            diag=self.synthetic_stream(directory)
            diag.capture[-1][1][6400:8000]=0
            diag.analyze(10.25)
            self.assertEqual(diag.snapshot()['status'],'dropout',diag.snapshot())
            self.assertTrue(diag.snapshot()['confirmed'])
            with patch.object(d.subprocess,'run',return_value=type('Result',(),{'stdout':'underrun','stderr':'','returncode':0})()):
                diag.analyze(13)
            self.assertEqual(len(diag.snapshot()['events']),1)
            event=json.loads(next(Path(directory).glob('event-*/event.json')).read_text())
            self.assertTrue(event['post_capture_unavailable'])
            self.assertEqual(event['roc_journal'],'underrun')

    def test_evidence_and_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            diag=d.Diagnostics(directory)
            for index in range(22):
                diag.pending={'due':0,'triggered_at':index,'analysis':{'status':'dropout'}}
                samples=d.np.zeros((100,2),dtype=d.np.float32)
                diag.save_event((samples,samples,d.np.ones(100,dtype=bool),0,0,{}, {},0))
            folders=list(Path(directory).glob('event-*'))
            self.assertEqual(len(folders),20)
            self.assertTrue((folders[0]/'reference.wav').exists())
            self.assertEqual(json.loads((folders[0]/'event.json').read_text())['analysis']['status'],'dropout')

    def test_embedded_module_matches_source(self):
        root=Path(__file__).resolve().parents[1]
        embedded=(root/'setup_roc_museum.sh').read_text().split("<<'PY_RX_DIAGNOSTICS'\n",1)[1].split('\nPY_RX_DIAGNOSTICS',1)[0]
        self.assertEqual(embedded,(root/'rx_diagnostics.py').read_text().rstrip())

class ParserTests(unittest.TestCase):
    def test_invalid_packets(self):
        for packet in (b'',bytes(12),struct.pack('!BBHII',0x90,10,0,0,0),
                       struct.pack('!BBHII',0x80,10,0,0,0)+bytes(3)):
            self.assertIsNone(d.decode_rtp(packet))
