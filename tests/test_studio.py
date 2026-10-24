import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock,patch
import wave

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('studio',ROOT/'studio.py')
studio=importlib.util.module_from_spec(spec);spec.loader.exec_module(studio)


def wav(path,seconds=1):
    with wave.open(str(path),'wb') as out:
        out.setnchannels(2);out.setsampwidth(2);out.setframerate(44100)
        out.writeframes(struct.pack('<hh',8000,-8000)*int(44100*seconds))


class StudioCase(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.engine=studio.Studio({},media=self.base/'media',state=self.base/'state',usb_root=self.base/'usb')
        self.addCleanup(self.engine.close)
        wav(self.engine.media/'test.wav')

    def event(self,**kwargs):
        data={'name':'Annuncio','track':'test.wav','start':'2026-10-24T10:00','recurrence':'daily','policy':'skip',**kwargs}
        with patch.object(self.engine,'info',return_value={'duration':1}): return self.engine.save_event(data)

    def enable(self): self.engine.command({'command':'automation','enabled':True})

    def now(self,value='2026-10-24T08:00:05+00:00'): return dt.datetime.fromisoformat(value)


class CalendarTests(StudioCase):
    def test_disabled_by_default(self):
        self.event()
        with patch.object(self.engine,'_play') as play: self.engine.tick(self.now())
        play.assert_not_called()

    def test_once_per_occurrence_and_survives_reopen(self):
        self.event();self.enable()
        with patch.object(self.engine,'_play') as play:
            self.engine.tick(self.now());self.engine.tick(self.now());self.assertEqual(play.call_count,1)
        other=studio.Studio({},self.engine.media,self.engine.state,self.engine.usb_root)
        try:
            with patch.object(other,'_play') as play: other.tick(self.now());play.assert_not_called()
            self.assertTrue(other.snapshot()['automation_enabled'])
        finally: other.close()

    def test_manual_hold_skips_events(self):
        self.event();self.enable();self.engine.manual_hold=True
        with patch.object(self.engine,'_play') as play: self.engine.tick(self.now());play.assert_not_called()
        self.assertEqual(self.engine.snapshot()['history'][0]['state'],'skipped')

    def test_busy_skip_wait_interrupt(self):
        for policy in ('skip','wait','interrupt'):
            with self.subTest(policy=policy):
                event=self.event(name=policy,policy=policy);self.enable();self.engine.status='playing'
                with patch.object(self.engine,'_play') as play:
                    self.engine.tick(self.now());self.assertEqual(play.call_count,1 if policy=='interrupt' else 0)
                state=self.engine.db.execute('SELECT state FROM runs WHERE event=?',(event['id'],)).fetchone()[0]
                self.assertEqual(state,{'skip':'skipped','wait':'waiting','interrupt':'started'}[policy])
                self.engine.delete_event(event['id']);self.engine.status='live'

    def test_wait_runs_after_track_and_expires(self):
        self.event(policy='wait');self.enable();self.engine.status='playing'
        self.engine.tick(self.now());self.assertEqual(len(self.engine.queue),1)
        self.engine.status='live'
        with patch.object(self.engine,'_play') as play:
            self.engine.tick(self.now('2026-10-24T08:01:00+00:00'));play.assert_called_once()
        # A second day queues a new occurrence, which is dropped after 15 minutes.
        self.engine.status='playing';self.engine.tick(self.now('2026-10-25T09:00:00+00:00'))
        self.engine.tick(self.now('2026-10-25T09:16:00+00:00'));self.assertEqual(self.engine.queue,[])

    def test_no_replay_missed_event(self):
        self.event(recurrence='once');self.enable()
        with patch.object(self.engine,'_play') as play:
            self.engine.tick(self.now('2026-10-24T08:01:00+00:00'));play.assert_not_called()

    def test_dst_fall_occurrence_identity(self):
        event=self.event(start='2026-10-25T02:30',recurrence='once')
        a=studio.Studio.occurrence(event,self.now('2026-10-25T00:30:00+00:00'))
        b=studio.Studio.occurrence(event,self.now('2026-10-25T01:30:00+00:00'))
        self.assertEqual(a,b);self.assertIsNotNone(a)
        self.enable()
        with patch.object(self.engine,'_play') as play:
            self.engine.tick(self.now('2026-10-25T00:30:00+00:00'));self.engine.tick(self.now('2026-10-25T01:30:00+00:00'));self.assertEqual(play.call_count,1)

    def test_dst_spring_missing_hour_and_weekdays(self):
        event=self.event(start='2027-03-28T02:30',recurrence='once')
        self.assertIsNone(studio.Studio.occurrence(event,self.now('2027-03-28T01:30:00+00:00')))
        self.assertEqual(self.engine.next_events(self.now('2027-03-28T00:00:00+00:00')),[])
        weekly=self.event(start='2026-10-24T10:00',recurrence='weekly',weekdays=[0])
        self.assertIsNone(studio.Studio.occurrence(weekly,self.now()))
        self.assertIsNotNone(studio.Studio.occurrence(weekly,self.now('2026-10-26T09:00:00+00:00')))

    def test_bad_events_rejected(self):
        for kwargs in ({'name':''},{'track':'../etc.wav'},{'start':'bad'},{'start':'2026-10-24T10:00+02:00'},{'policy':'bad'},{'weekdays':[True]},{'enabled':'yes'},{'id':'f'*32}):
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError): self.event(**kwargs)

    def test_delete_cancels_waiting_event(self):
        event=self.event(policy='wait');self.enable();self.engine.status='playing';self.engine.tick(self.now())
        self.engine.delete_event(event['id']);self.assertEqual(self.engine.queue,[]);self.assertEqual(self.engine.events(),[])


class USBTests(StudioCase):
    def setUp(self):
        super().setUp();self.usb=self.base/'stick';self.usb.mkdir();(self.usb/'music').mkdir()
        wav(self.usb/'music'/'usb.wav');(self.usb/'note.txt').write_text('not audio')
        (self.usb/'escape').symlink_to(self.base,target_is_directory=True)

    def test_browse_and_import_durable_copy(self):
        with patch.object(self.engine,'mount',return_value=str(self.usb)):
            listing=self.engine.browse('sda1')
            self.assertEqual([e['name'] for e in listing['entries']],['music'])
            result=self.engine.import_usb('sda1','music/usb.wav')
            self.assertEqual(result['name'],'usb.wav')
            self.assertEqual((self.engine.media/'usb.wav').read_bytes(),(self.usb/'music'/'usb.wav').read_bytes())
            with self.assertRaises(ValueError): self.engine.import_usb('sda1','music/usb.wav')
        self.assertEqual(list(self.engine.media.glob('.upload-*')),[])

    def test_traversal_and_symlink_denied(self):
        for relative in ('../media/test.wav','/etc/passwd','escape/media/test.wav','music/../music/usb.wav'):
            with self.subTest(relative=relative),patch.object(self.engine,'mount',return_value=str(self.usb)),self.assertRaises((ValueError,OSError)):
                self.engine.import_usb('sda1',relative)
        self.assertFalse((self.engine.media/'usb.wav').exists())

    def test_system_disk_and_nonusb_excluded(self):
        tree={'blockdevices':[
            {'name':'/dev/sda','path':'/dev/sda','tran':'usb','type':'disk','mountpoints':[], 'children':[{'name':'/dev/sda1','type':'part','fstype':'ext4','mountpoints':['/']},{'name':'/dev/sda2','type':'part','fstype':'vfat','mountpoints':[]}]},
            {'name':'/dev/mmcblk0','type':'disk','tran':None,'mountpoints':[],'fstype':'vfat'},
            {'name':'/dev/sdb','type':'disk','tran':'usb','mountpoints':[],'children':[{'name':'/dev/sdb1','type':'part','fstype':'exfat','label':'Music','mountpoints':[]}]}]}
        with patch.object(studio,'run',return_value=Mock(stdout=json.dumps(tree))):
            devices=self.engine.devices()
        self.assertEqual([d['id'] for d in devices],['sdb1'])

    def test_mount_readonly_and_eject_busy(self):
        device={'id':'sdb1','device':'/dev/sdb1','mount':None}
        with patch.object(self.engine,'_device',return_value=device),patch.object(studio,'run') as command:
            self.engine.mount('sdb1')
        self.assertIn('ro,nosuid,nodev,noexec',command.call_args.args[0])
        self.engine.copy_lock.acquire()
        try:
            with self.assertRaises(ValueError): self.engine.eject('sdb1')
        finally: self.engine.copy_lock.release()

    def test_low_space_leaves_no_partial(self):
        with patch.object(self.engine,'mount',return_value=str(self.usb)),patch.object(studio.shutil,'disk_usage',return_value=Mock(free=10)):
            with self.assertRaises(ValueError): self.engine.import_usb('sda1','music/usb.wav')
        self.assertEqual(list(self.engine.media.iterdir()),[self.engine.media/'test.wav'])


class PlayerTests(StudioCase):
    def process(self,returncode=None):
        p=Mock();p.poll.return_value=returncode;p.returncode=returncode;p.wait.return_value=0
        return p

    def test_exclusive_sender_pause_resume_stop(self):
        encoder=self.process();sender=self.process()
        with patch.object(self.engine,'info',return_value={'duration':20}),patch.object(studio,'run') as run,patch.object(studio.subprocess,'Popen',side_effect=[encoder,sender]) as popen:
            self.engine.command({'command':'play','name':'test.wav'})
            self.assertEqual(run.call_args.args[0],['systemctl','stop','roc-museum.service'])
            self.assertEqual(popen.call_args_list[1].args[0][0],'roc-send')
            self.assertIs(popen.call_args_list[1].kwargs['stdin'],encoder.stdout)
            self.engine.command({'command':'pause'});encoder.terminate.assert_called();sender.terminate.assert_called()
            self.assertEqual(self.engine.status,'paused');self.assertTrue(self.engine.manual_hold)
        with patch.object(self.engine,'_play') as play:
            self.engine.command({'command':'resume'});play.assert_called_once()
        with patch.object(studio,'run') as run:
            self.engine.command({'command':'stop'})
            self.assertEqual(run.call_args.args[0],['systemctl','start','roc-museum.service'])
            self.assertEqual(self.engine.status,'live')

    def test_failed_spawn_restores_mixer(self):
        with patch.object(self.engine,'info',return_value={'duration':20}),patch.object(studio,'run') as run,patch.object(studio.subprocess,'Popen',side_effect=OSError('missing executable')):
            with self.assertRaises(OSError): self.engine.command({'command':'play','name':'test.wav'})
            self.assertEqual(run.call_args.args[0],['systemctl','start','roc-museum.service'])
            self.assertEqual(self.engine.status,'live')

    def test_invalid_seek_keeps_playing(self):
        self.engine.status='playing';self.engine.track='test.wav'
        for value in (-1,True,float('nan'),float('inf'),100,None):
            with patch.object(self.engine,'info',return_value={'duration':20}),self.assertRaises(ValueError): self.engine.command({'command':'seek','position':value})
        self.assertEqual(self.engine.status,'playing')

    def test_finish_restores_mixer_and_loop_restarts(self):
        self.engine.status='playing';self.engine.track='test.wav';self.engine.sender=self.process(0);self.engine.encoder=self.process(0)
        with patch.object(studio,'run'): self.engine.tick()
        self.assertEqual(self.engine.status,'live')
        self.engine.status='playing';self.engine.track='test.wav';self.engine.loop=True;self.engine.sender=self.process(0);self.engine.encoder=self.process(0)
        with patch.object(self.engine,'_play') as play: self.engine.tick();play.assert_called_once_with('test.wav',origin='mixer',loop=True)

    def test_resume_program_releases_manual_source(self):
        self.engine.manual_hold=True;self.engine.status='paused'
        with patch.object(studio,'run'): self.engine.command({'command':'automation','enabled':True})
        self.assertEqual(self.engine.status,'live');self.assertFalse(self.engine.manual_hold)

    @unittest.skipUnless(shutil.which('ffprobe'),'ffprobe not installed')
    def test_real_probe_and_corrupt_audio(self):
        self.assertEqual(self.engine.info('test.wav')['duration'],1)
        (self.engine.media/'bad.mp3').write_text('this is not audio')
        with self.assertRaises((ValueError,subprocess.SubprocessError)): self.engine.info('bad.mp3')


class PackagingTests(unittest.TestCase):
    def test_embedded_sources_match(self):
        setup=(ROOT/'setup_roc_museum.sh').read_text()
        for marker,name in (('PY_STUDIO','studio.py'),('HTML_STUDIO','studio.html')):
            embedded=setup.split("<<'"+marker+"'\n",1)[1].split('\n'+marker,1)[0]
            self.assertEqual(embedded.rstrip(),(ROOT/name).read_text().rstrip())


@unittest.skipUnless(os.environ.get('ROC_SEND_BINARY') and shutil.which('ffmpeg'),'set ROC_SEND_BINARY for real Roc integration')
class RocIntegration(StudioCase):
    def test_real_ffmpeg_to_roc_produces_l16_packets(self):
        receiver=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.addCleanup(receiver.close)
        receiver.bind(('127.0.0.1',0));receiver.settimeout(5)
        self.engine.config={'MULTICAST_ADDR':'127.0.0.1','RTP_PORT':str(receiver.getsockname()[1])}
        real_popen=studio.subprocess.Popen;real_run=studio.run
        def popen(args,**kwargs):
            if args[0]=='roc-send': args=[os.environ['ROC_SEND_BINARY'],*args[1:]]
            return real_popen(args,**kwargs)
        def run(args,**kwargs):
            if args[0]=='systemctl': return Mock()
            return real_run(args,**kwargs)
        with patch.object(studio,'run',side_effect=run),patch.object(studio.subprocess,'Popen',side_effect=popen):
            self.engine.command({'command':'play','name':'test.wav'})
            try: packet,_=receiver.recvfrom(65535)
            except TimeoutError:
                self.engine.error_log.seek(0)
                self.fail(self.engine.error_log.read().decode(errors='replace'))
            self.assertEqual(packet[0]>>6,2);self.assertEqual(packet[1]&127,10)
            self.assertGreater(len(packet),12)
            self.assertTrue(any(packet[12:]))
            self.engine.sender.wait(timeout=10)
            self.engine.tick();self.assertEqual(self.engine.status,'live')

if __name__=='__main__': unittest.main()
