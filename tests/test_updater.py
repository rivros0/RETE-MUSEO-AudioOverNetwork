"""Test the current OpenSSH updater CLI; no network or Raspberry required."""
import argparse
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock,patch

spec=importlib.util.spec_from_file_location('updater',Path(__file__).resolve().parents[1]/'aggiorna_raspberry.py')
updater=importlib.util.module_from_spec(spec);spec.loader.exec_module(updater)

class UpdaterTests(unittest.TestCase):
    def test_destinations_reject_shell_and_options(self):
        for invalid in ('-oProxyCommand=x','pi@host;touch x','host/path','pi@host:22','a b','$(id)'):
            with self.assertRaises(argparse.ArgumentTypeError): updater.destinazione(invalid)
        for valid in ('pi@192.168.1.50','tx.local','museo-tx'):
            self.assertEqual(updater.destinazione(valid),valid)

    def test_dry_run_never_invokes_process(self):
        with patch.object(updater.subprocess,'run') as command,patch('builtins.print'):
            updater.aggiorna('pi@tx',Path('/tmp/setup.sh'),22,None,True)
        command.assert_not_called()

    def test_update_copies_installs_and_cleans(self):
        with patch.object(updater.subprocess,'run',return_value=Mock(stdout='/tmp/roc-museum.Ab12\n')) as command:
            updater.aggiorna('pi@tx',Path('/tmp/setup.sh'),2222,Path('/tmp/key'),False)
        calls=[c.args[0] for c in command.call_args_list]
        self.assertEqual([c[0] for c in calls],['ssh','scp','ssh','ssh'])
        self.assertIn('2222',calls[0]);self.assertIn('/tmp/key',calls[0])
        self.assertIn('pi@tx:/tmp/roc-museum.Ab12/setup_roc_museum.sh',calls[1])
        self.assertIn('sudo bash -c',calls[2][-1]);self.assertIn('/var/backups/roc-museum-',calls[2][-1])
        self.assertIn('systemctl is-active roc-museum-monitor.service',calls[2][-1])
        self.assertIn('rmdir',calls[3][-1])

    def test_untrusted_remote_temp_rejected(self):
        with patch.object(updater.subprocess,'run',return_value=Mock(stdout='/tmp/bad; touch /x')) as command:
            with self.assertRaises(RuntimeError): updater.aggiorna('pi@tx',Path('setup'),22,None,False)
        self.assertEqual(command.call_count,1)

    def test_failed_copy_still_cleans(self):
        failure=subprocess.CalledProcessError(1,['scp'])
        with patch.object(updater.subprocess,'run',side_effect=[Mock(stdout='/tmp/roc-museum.Ab12'),failure,Mock()]) as command:
            with self.assertRaises(subprocess.CalledProcessError): updater.aggiorna('pi@tx',Path('setup'),22,None,False)
        self.assertIn('rmdir',command.call_args.args[0][-1])

    def test_cleanup_timeout_preserves_original_error(self):
        with patch.object(updater.subprocess,'run',side_effect=[Mock(stdout='/tmp/roc-museum.Ab12'),subprocess.CalledProcessError(1,['scp']),subprocess.TimeoutExpired('ssh',25)]),patch('builtins.print'):
            with self.assertRaises(subprocess.CalledProcessError): updater.aggiorna('pi@tx',Path('setup'),22,None,False)

    def test_main_stops_after_failed_node(self):
        with tempfile.TemporaryDirectory() as directory:
            setup=Path(directory)/'setup.sh';setup.write_text('# setup')
            with patch.object(updater.shutil,'which',return_value='/usr/bin/ssh'),patch.object(updater,'aggiorna',side_effect=RuntimeError('offline')) as update,patch('builtins.print'):
                self.assertEqual(updater.main(['--setup',str(setup),'pi@one','pi@two']),1)
            self.assertEqual(update.call_count,1)

    def test_main_deduplicates_hosts(self):
        with tempfile.TemporaryDirectory() as directory:
            setup=Path(directory)/'setup.sh';setup.write_text('# setup')
            with patch.object(updater.shutil,'which',return_value='/usr/bin/ssh'),patch.object(updater,'aggiorna') as update,patch('builtins.print'):
                self.assertEqual(updater.main(['--setup',str(setup),'--dry-run','pi@one','pi@one','pi@two']),0)
            self.assertEqual(update.call_count,2)

if __name__=='__main__': unittest.main()
