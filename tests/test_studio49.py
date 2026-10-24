import datetime as dt
import importlib.util
import math
import tempfile
import time
from pathlib import Path
import struct
import unittest
from unittest.mock import patch,Mock
from test_studio import StudioCase,wav,studio,ROOT

spec=importlib.util.spec_from_file_location('audio_bus',ROOT/'audio_bus.py')
audio=importlib.util.module_from_spec(spec);spec.loader.exec_module(audio)

def pcm(value,frames=441): return struct.pack('<hh',value,value)*frames

def average(data):
    samples=audio.pcm_samples(data)
    return sum(samples)/len(samples)

class DuckingTests(unittest.TestCase):
    def test_microphone_unchanged_without_music(self):
        d=audio.Ducker()
        for _ in range(100): mixed=d.mix(pcm(0),pcm(6000))
        self.assertAlmostEqual(average(mixed),6000,delta=1)
        self.assertTrue(d.active)

    def test_music_ducked_and_recovers_smoothly(self):
        d=audio.Ducker()
        for _ in range(100): mixed=d.mix(pcm(8000),pcm(4000))
        self.assertAlmostEqual(average(mixed)-4000,8000*10**(-18/20),delta=10)
        gain=d.gain
        for _ in range(20): d.mix(pcm(8000),pcm(0))
        self.assertAlmostEqual(d.gain,gain,delta=.01)  # hold bridges short pauses in speech
        for _ in range(600): mixed=d.mix(pcm(8000),pcm(0))
        self.assertGreater(d.gain,.99);self.assertFalse(d.active)

    def test_noise_below_threshold_does_not_duck(self):
        d=audio.Ducker()
        for _ in range(100): d.mix(pcm(8000),pcm(50))
        self.assertEqual(d.gain,1);self.assertFalse(d.active)

    def test_disabled_ducking_still_mixes_microphone(self):
        d=audio.Ducker();d.enabled=False
        self.assertAlmostEqual(average(d.mix(pcm(3000),pcm(4000))),7000,delta=1)

    def test_limiter_avoids_wraparound(self):
        d=audio.Ducker();data=d.mix(pcm(32000),pcm(32000))
        samples=audio.pcm_samples(data)
        self.assertTrue(all(0<x<=32767 for x in samples))

class BusBoundaryTests(unittest.TestCase):
    def test_pause_and_deadline_gate_only_music(self):
        bus=audio.AudioBus({},capture_enabled=False)
        with tempfile.TemporaryFile() as song:
            song.write(pcm(5000)*4);song.seek(0);bus.attach(song,deadline=time.time()+60)
            self.assertGreater(average(bus._music_block()),4000)
            position=bus.position;bus.pause(True)
            self.assertEqual(bus._music_block(),bytes(bus.block_bytes));self.assertEqual(bus.position,position)
            self.assertEqual(average(bus.ducker.mix(bus._music_block(),pcm(2000))),2000)
            bus.pause(False);bus.set_deadline(time.time()-1)
            self.assertEqual(bus._music_block(),bytes(bus.block_bytes));self.assertTrue(bus.deadline_hit)

class RecoveryTests(StudioCase):
    def test_bus_owner_marker_and_audio_unit_coordination(self):
        with patch.object(studio,'run') as command:
            self.engine._ensure_audio()
            self.assertTrue(self.engine.bus_marker.exists())
            self.assertEqual([c.args[0][1] for c in command.call_args_list],['stop','start'])
            self.engine._live()
            self.assertTrue(self.engine.bus_marker.exists())  # mic bus remains owner
        self.engine.bus.closed=True
        with patch.object(studio,'run'): self.engine._live()
        self.assertFalse(self.engine.bus_marker.exists())

    def test_bus_start_failure_restores_original_microphone(self):
        self.engine.audio_factory=Mock(side_effect=OSError('audio unavailable'))
        with patch.object(studio,'run') as command:
            with self.assertRaises(OSError): self.engine._ensure_audio()
            self.assertEqual(command.call_args.args[0],['systemctl','start','roc-museum.service'])
        self.assertFalse(self.engine.bus_marker.exists());self.assertIsNone(self.engine.bus)

class WindowsTests(StudioCase):
    def setUp(self):
        super().setUp();wav(self.engine.media/'second.wav')

    def slot(self,**kwargs):
        return self.event(**{'tracks':['test.wav','second.wav'],'end_time':'12:00','repetitions':0,**kwargs})

    def test_single_and_group_repetitions_in_order(self):
        event=self.slot(repetitions=2);now=self.now()
        with patch.object(self.engine,'_play') as play:
            self.engine._fire(event,'2026-10-24T10:00',now)
            self.engine._next_track(now);self.engine._next_track(now);self.engine._next_track(now);self.engine._next_track(now)
            self.assertEqual([c.args[0] for c in play.call_args_list],['test.wav','second.wav','test.wav','second.wav'])
        self.assertIsNone(self.engine.plan)
        self.assertEqual(self.engine.snapshot()['history'][0]['state'],'completed')

    def test_stop_at_end_midtrack(self):
        event=self.slot();self.enable()
        with patch.object(self.engine,'_play'):
            self.engine._fire(event,'2026-10-24T10:00',self.now())
        self.engine.status='playing'
        self.engine.tick(self.now('2026-10-24T10:00:00+00:00'))
        self.assertIsNone(self.engine.plan);self.assertEqual(self.engine.status,'live')

    def test_interval_only_after_full_group(self):
        event=self.slot(interval_seconds=30)
        now=self.now()
        with patch.object(self.engine,'_play') as play:
            self.engine._fire(event,'2026-10-24T10:00',now)
            self.engine._next_track(now);self.assertIsNone(self.engine.plan['next_at'])
            self.engine._next_track(now)
            self.assertEqual(self.engine.plan['next_at'],now.timestamp()+30)
            self.assertEqual(play.call_count,2)
            self.engine.tick(now+dt.timedelta(seconds=29));self.assertEqual(play.call_count,2)
            self.engine.tick(now+dt.timedelta(seconds=30));self.assertEqual(play.call_count,3)

    def test_overnight_weekly_uses_start_day(self):
        event=self.event(start='2026-10-24T23:00',end_time='02:00',recurrence='weekly',weekdays=[5],repetitions=0)
        when=self.now('2026-10-24T23:30:00+00:00')  # Sunday 01:30, start was Saturday
        window=self.engine.window(event,when)
        self.assertIsNotNone(window)
        self.assertEqual(self.engine.occurrence(event,when),'2026-10-24T23:00')
        self.assertIsNone(self.engine.window(event,self.now('2026-10-25T02:00:00+00:00')))

    def test_dst_window_end_is_rome_time(self):
        event=self.event(start='2026-10-25T01:00',end_time='04:00',repetitions=0)
        window=self.engine.window(event,self.now('2026-10-25T01:30:00+00:00'))
        self.assertEqual(window[1].hour,4)
        self.assertEqual(window[1].timestamp()-window[0].timestamp(),4*3600)

    def test_active_window_restored_after_restart(self):
        self.slot();self.enable()
        with patch.object(self.engine,'_play') as play:
            self.engine.tick(self.now('2026-10-24T09:20:00+00:00'))
            play.assert_called_once()
        other=studio.Studio({},self.engine.media,self.engine.state,self.engine.usb_root,bus_marker=self.base/'other-marker')
        try:
            with patch.object(other,'_play') as play:
                other.tick(self.now('2026-10-24T09:30:00+00:00'));play.assert_called_once()
        finally: other.close()

    def test_manual_hold_then_resume_current_window(self):
        self.slot();self.enable();self.engine.manual_hold=True
        with patch.object(self.engine,'_play') as play:
            self.engine.tick(self.now('2026-10-24T09:00:00+00:00'));play.assert_not_called()
            self.engine.command({'command':'automation','enabled':True})
            self.engine.tick(self.now('2026-10-24T09:01:00+00:00'));play.assert_called_once()

    def test_invalid_repetitions_and_end(self):
        for kwargs in ({'end_time':'bad'},{'end_time':None},{'repetitions':True},{'repetitions':-1},{'repetitions':0,'end_time':''},{'interval_seconds':-1},{'tracks':[]}):
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError): self.event(**kwargs)

    def test_legacy_event_is_still_single_track(self):
        event=self.event()
        self.assertEqual(event['tracks'],['test.wav']);self.assertEqual(event['repetitions'],1)

class LibraryTests(StudioCase):
    def test_delete_unused_file_and_clear_metadata(self):
        self.engine.metadata[('test.wav',1,0)]={'name':'test.wav'}
        self.assertTrue(self.engine.delete_media('test.wav')['ok'])
        self.assertFalse((self.engine.media/'test.wav').exists());self.assertEqual(self.engine.metadata,{})

    def test_cannot_delete_active_paused_or_scheduled_track(self):
        self.engine.track='test.wav';self.engine.status='paused'
        with self.assertRaises(ValueError): self.engine.delete_media('test.wav')
        self.engine.track=None;self.engine.status='live';self.event()
        with self.assertRaises(ValueError): self.engine.delete_media('test.wav')
        self.assertTrue((self.engine.media/'test.wav').exists())

    def test_group_reference_protects_all_members(self):
        wav(self.engine.media/'second.wav');self.event(tracks=['test.wav','second.wav'])
        with self.assertRaises(ValueError): self.engine.delete_media('second.wav')

    def test_cannot_delete_during_copy_or_via_traversal(self):
        self.engine.copy_lock.acquire()
        try:
            with self.assertRaises(ValueError): self.engine.delete_media('test.wav')
        finally: self.engine.copy_lock.release()
        with self.assertRaises(ValueError): self.engine.delete_media('../test.wav')

    def test_duck_settings_persist_and_validate(self):
        self.engine.command({'command':'ducking','enabled':True,'threshold_db':-30,'reduction_db':-20})
        self.assertEqual(self.engine.snapshot()['ducking']['threshold_db'],-30)
        for kwargs in ({'threshold_db':float('nan')},{'reduction_db':10},{'enabled':'yes'}):
            with self.assertRaises(ValueError): self.engine.command({'command':'ducking',**kwargs})

if __name__=='__main__': unittest.main()
