import unittest
from unittest.mock import patch
from test_meter import monitor

class Controls(unittest.TestCase):
    def setUp(self):
        monitor.MUTED=False
        monitor.RESUME_VOLUME=None
        self.volume=65
    def set_volume(self,value,persist=True):
        self.volume=value
        return True
    def test_mute_edit_unmute(self):
        with patch.object(monitor,'get_volume_percent',side_effect=lambda:self.volume),patch.object(monitor,'set_volume_percent',side_effect=self.set_volume):
            self.assertTrue(monitor.apply_control('set_mute',True))
            self.assertEqual(self.volume,0)
            self.assertTrue(monitor.apply_control('set_mute',True))
            self.assertEqual(monitor.RESUME_VOLUME,65)
            self.assertTrue(monitor.apply_control('set_volume',42))
            self.assertEqual(self.volume,0)
            self.assertTrue(monitor.apply_control('set_mute',False))
            self.assertEqual(self.volume,42)
    def test_failure_does_not_confirm(self):
        with patch.object(monitor,'get_volume_percent',return_value=65),patch.object(monitor,'set_volume_percent',return_value=False):
            self.assertFalse(monitor.apply_control('set_mute',True))
            self.assertFalse(monitor.MUTED)
            self.assertFalse(monitor.apply_control('set_volume',30))
    def test_invalid_values(self):
        for value in (-1,101,2.5,True,'50',None):
            self.assertFalse(monitor.apply_control('set_volume',value))
        self.assertFalse(monitor.apply_control('set_mute','true'))
    def test_readback_must_match(self):
        with patch.object(monitor,'get_volume_percent',return_value=65),patch.object(monitor,'set_volume_percent',return_value=True):
            self.assertFalse(monitor.apply_control('set_volume',30))

if __name__=='__main__': unittest.main()
