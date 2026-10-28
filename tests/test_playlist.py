from test_studio import StudioCase, studio, wav
from unittest.mock import patch

class PlaylistTests(StudioCase):
    def setUp(self):
        super().setUp()
        wav(self.engine.media/'a.wav');wav(self.engine.media/'z.wav')

    def choose(self,*names):
        self.engine.command({'command':'playlist_select','tracks':list(names)})

    def finish(self):
        self.engine.encoder.terminate();self.engine.encoder.wait(timeout=5);self.engine.encoder.returncode=0
        self.engine.bus.eof=True
        self.engine.tick()

    def test_skip_and_stop(self):
        self.choose('a.wav','z.wav')
        self.engine.command({'command':'playlist_start'})
        self.assertEqual(self.engine.track,'a.wav')
        self.finish();self.assertEqual(self.engine.track,'z.wav')
        self.finish();self.assertEqual(self.engine.status,'live')
        self.assertFalse(self.engine.playlist_active)

    def test_loop_and_single_override(self):
        self.choose('a.wav','z.wav')
        self.engine.command({'command':'playlist_loop','enabled':True})
        self.engine.command({'command':'playlist_start'})
        self.finish();self.finish();self.assertEqual(self.engine.track,'a.wav')
        self.engine.command({'command':'play','name':'test.wav'})
        self.assertFalse(self.engine.playlist_active)
        self.finish();self.assertEqual(self.engine.status,'live')
        self.assertEqual(self.engine.playlist(),['a.wav','z.wav'])

    def test_persist_and_exclusive_loops(self):
        self.choose('z.wav')
        self.engine.command({'command':'loop','enabled':True})
        self.engine.command({'command':'playlist_loop','enabled':True})
        self.assertFalse(self.engine.snapshot()['track_loop'])
        self.engine.command({'command':'loop','enabled':True})
        self.assertFalse(self.engine.snapshot()['playlist_loop'])
        other=studio.Studio({},self.engine.media,self.engine.state,self.engine.usb_root,bus_marker=self.base/'other')
        try:
            self.assertEqual(other.playlist(),['z.wav'])
            self.assertTrue(other.snapshot()['track_loop'])
        finally: other.close()

    def test_empty_invalid_selection_and_live_changes(self):
        self.choose()
        with self.assertRaises(ValueError): self.engine.command({'command':'playlist_start'})
        for tracks in (None,['missing.wav'],['a.wav','a.wav'],[{}]):
            with self.assertRaises(ValueError): self.engine.command({'command':'playlist_select','tracks':tracks})
        self.choose('a.wav','test.wav','z.wav')
        self.engine.command({'command':'playlist_start'})
        self.choose('a.wav','z.wav')
        self.engine.command({'command':'pause'})
        self.assertTrue(self.engine.playlist_active)
        self.engine.command({'command':'resume'})
        self.engine.command({'command':'seek','position':.2})
        self.assertTrue(self.engine.playlist_active)
        self.finish();self.assertEqual(self.engine.track,'z.wav')

    def test_resume_restores_playlist(self):
        self.choose('a.wav','z.wav')
        self.engine.command({'command':'playlist_start'})
        self.engine.command({'command':'pause'})
        state=self.engine._setting('resume_playback')
        self.assertTrue(state['playlist_active'])
        self.engine._terminate();self.engine.playlist_active=False
        self.assertTrue(self.engine._restore_playback_resume())
        self.assertTrue(self.engine.playlist_active)
        self.assertEqual(self.engine.status,'paused')
