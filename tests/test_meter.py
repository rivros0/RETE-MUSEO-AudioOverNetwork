"""Test the actual Python monitor embedded in the installer, without installing it."""
import math
import struct
import types
import unittest
from pathlib import Path

source=(Path(__file__).resolve().parents[1]/'setup_roc_museum.sh').read_text().split("<<'PY_MONITOR'\n",1)[1].split('\nPY_MONITOR',1)[0]
monitor=types.ModuleType('monitor')
exec(compile(source,'monitor','exec'),monitor.__dict__)

def rtp(samples, pt=10, flags=0x80):
    return struct.pack('!BBHII',flags,pt,1,0,42)+struct.pack('!%dh'%len(samples),*samples)

class MeterTests(unittest.TestCase):
    def test_stereo_peak_rms_and_clipping(self):
        m=monitor.AudioMeter()
        m.feed(rtp([16384,32767,-16384,-32768]))
        s=m.snapshot()
        self.assertTrue(s['available'])
        self.assertAlmostEqual(s['channels'][0]['peak_dbfs'],-6.0)
        self.assertAlmostEqual(s['channels'][0]['rms_dbfs'],-6.0)
        self.assertEqual(s['channels'][1]['full_scale_samples'],2)
        self.assertIsNotNone(s['clip_age_seconds'])

    def test_silence_is_distinct_from_no_signal(self):
        m=monitor.AudioMeter()
        self.assertFalse(m.snapshot()['available'])
        m.feed(rtp([0,0],11))
        self.assertEqual(m.snapshot()['channels'][0]['rms_dbfs'],-96)
        self.assertTrue(m.snapshot()['available'])

    def test_expired_data(self):
        m=monitor.AudioMeter()
        m.feed(rtp([100,100]),monitor.time.monotonic()-6)
        self.assertFalse(m.snapshot()['available'])

    def test_extension_padding_and_csrc(self):
        m=monitor.AudioMeter()
        header=struct.pack('!BBHII',0xb1,11,1,0,42)
        packet=header+bytes(4)+struct.pack('!HH',1,1)+bytes(4)+struct.pack('!h',16384)+bytes([0,2])
        m.feed(packet)
        self.assertEqual(m.snapshot()['channels'][0]['peak_dbfs'],-6)

    def test_malformed_and_unknown_payloads(self):
        for packet in (b'',bytes(12),rtp([1],10),rtp([1],96),rtp([1],11,0x90),rtp([1],11,0xa0)):
            m=monitor.AudioMeter();m.feed(packet)
            self.assertFalse(m.snapshot()['available'])

class PostFaderTests(unittest.TestCase):
    def test_attenuation_and_mute(self):
        m=monitor.AudioMeter();m.feed(rtp([16384,32767]))
        result=monitor.post_fader_meter(m.snapshot(),"Front Left: Playback 50 [50%] [-6.00dB] [on]\nFront Right: Playback 50 [50%] [-6.00dB] [off]")
        self.assertEqual(result['channels'][0]['peak_dbfs'],-12)
        self.assertEqual(result['channels'][1]['peak_dbfs'],-96)
        self.assertIsNotNone(result['input_clip_age_seconds'])
        self.assertNotIn('clip_age_seconds',result)

    def test_unknown_gain_is_not_assumed(self):
        m=monitor.AudioMeter();m.feed(rtp([100,100]))
        self.assertFalse(monitor.post_fader_meter(m.snapshot(),'Mono: Playback 50 [50%]')['available'])

    def test_shared_mono_gain(self):
        m=monitor.AudioMeter();m.feed(rtp([16384,16384]))
        result=monitor.post_fader_meter(m.snapshot(),'Mono: Playback 50 [50%] [-12.00dB]')
        self.assertEqual([c['peak_dbfs'] for c in result['channels']],[-18,-18])

if __name__=='__main__': unittest.main()
