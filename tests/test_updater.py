"""Verifiche del gestore, senza rete e senza modificare Raspberry."""
import importlib.util
import subprocess
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('updater', Path(__file__).resolve().parents[1] / 'aggiorna_raspberry.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdaterTests(unittest.TestCase):
    def test_numeric_versions(self):
        self.assertGreater(updater.numero('4.10'), updater.numero('4.9'))
        self.assertEqual(updater.numero('4.7.0'), updater.numero('4.7'))
        self.assertLess(updater.numero('4.7'), updater.numero('4.7.1'))

    def test_version_sources(self):
        self.assertEqual(updater.versione('VERSION="4.7"\n'), '4.7')
        self.assertEqual(updater.versione('SOFTWARE_VERSION="4.6"\n', True), '4.6')
        self.assertEqual(updater.versione('# RETE MUSEO - AudioOverNetwork - setup v4.5\n', True), '4.5')
        with self.assertRaises(updater.ErroreNodo):
            updater.versione('VERSION="unknown"')

    def test_config_does_not_execute_shell(self):
        with self.assertRaises(updater.ErroreNodo):
            updater.configurazione('ROLE="rx"\nNODE_NAME="$(touch /tmp/no)"\nTX_IP="192.168.1.50"')
        config = updater.configurazione('ROLE="rx"\nNODE_NAME="Sala 1"\nTX_IP="192.168.1.50"')
        self.assertEqual(config['NODE_NAME'], 'Sala 1')

    def run_node(self, local, latest, check=False, connection_error=None):
        class SSHError(Exception):
            pass
        class AuthError(SSHError):
            pass
        class KeyErrorSSH(SSHError):
            pass
        class NoConnection(SSHError):
            pass
        client = Mock()
        if connection_error:
            client.connect.side_effect = connection_error
        api = types.SimpleNamespace(SSHClient=Mock(return_value=client),
                                    RejectPolicy=Mock(), AuthenticationException=AuthError,
                                    BadHostKeyException=KeyErrorSSH, SSHException=SSHError,
                                    ssh_exception=types.SimpleNamespace(NoValidConnectionsError=NoConnection))
        ui = Mock()
        config = f'SOFTWARE_VERSION="{local}"\nROLE="tx"\nNODE_NAME="TX"\n'
        updated = f'SOFTWARE_VERSION="{latest}"\n'
        with patch.object(updater, 'comando', side_effect=[config, updated]), patch.object(updater, 'aggiorna') as update:
            result = updater.esamina('pi@192.168.1.50', 'secret', Path('setup'), latest, ui, check, api)
        client.close.assert_called_once()
        return result, update, ui

    def test_old_node_updated_and_verified(self):
        result, update, ui = self.run_node('4.6', '4.7')
        self.assertTrue(result)
        update.assert_called_once()
        self.assertEqual(ui.mostra.call_args.args[1], 'Aggiornato')

    def test_current_and_newer_nodes_skipped(self):
        for local in ('4.7', '4.10'):
            result, update, ui = self.run_node(local, '4.7')
            self.assertTrue(result)
            update.assert_not_called()

    def test_check_only_never_updates(self):
        result, update, ui = self.run_node('4.6', '4.7', check=True)
        self.assertTrue(result)
        update.assert_not_called()
        self.assertEqual(ui.mostra.call_args.args[1], 'Da aggiornare')

    def test_unreachable_reported(self):
        result, update, ui = self.run_node('4.6', '4.7', connection_error=TimeoutError())
        self.assertFalse(result)
        update.assert_not_called()
        self.assertEqual(ui.mostra.call_args.args[1], 'Non raggiungibile')

    def test_invalid_online_version_stops_before_nodes(self):
        with patch.object(updater.subprocess, 'run'), self.assertRaises(updater.ErroreNodo):
            with __import__('tempfile').TemporaryDirectory() as folder:
                target = Path(folder)
                (target / 'setup.sh').write_text('VERSION="invalid"')
                with patch.object(updater, 'PERCORSO_SETUP', 'setup.sh'):
                    updater.scarica_repository(target)

class LocalCredentialsTests(unittest.TestCase):
    def test_project_nodes_preserved(self):
        self.assertEqual(list(updater.RASPBERRY),['pi@192.168.1.91','pi@192.168.1.92','pi@192.168.1.90'])

    def test_passwords_stay_in_private_file(self):
        import tempfile,stat,json
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'private.json';nodes={'pi@host':'test-only-password'}
            updater.salva_credenziali(path,nodes)
            self.assertEqual(updater.carica_credenziali(path),nodes)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
            self.assertEqual(json.loads(path.read_text())['raspberry'],nodes)

    def test_configure_blank_keeps_existing_password(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'private.json'
            with patch.object(updater.getpass,'getpass',return_value=''),patch('builtins.print'):
                updater.configura_password(path,{'pi@host':'previous-test-only'})
            self.assertEqual(updater.carica_credenziali(path)['pi@host'],'previous-test-only')

    def test_invalid_config_does_not_echo_secret(self):
        import tempfile,json
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'private.json';path.write_text(json.dumps({'raspberry':{'bad host':'private-test-value'}}))
            with self.assertRaises(updater.ErroreNodo) as error: updater.carica_credenziali(path)
            self.assertNotIn('private-test-value',str(error.exception))

    def test_main_uses_local_passwords_not_empty_defaults(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'private.json';updater.salva_credenziali(path,{'pi@host':'local-test-only'})
            with patch.object(updater.shutil,'which',return_value='/tool'),patch.dict('sys.modules',{'paramiko':types.SimpleNamespace()}),patch.object(updater,'scarica_repository',return_value=(Path('setup'),'4.8')),patch.object(updater,'esamina',return_value=True) as inspect,patch('builtins.print'):
                self.assertEqual(updater.main(['--config',str(path),'--check-only']),0)
            self.assertEqual(inspect.call_args.args[1],'local-test-only')

    def test_newline_password_rejected(self):
        import tempfile,json
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'private.json';path.write_text(json.dumps({'raspberry':{'pi@host':'line\nbreak'}}))
            with self.assertRaises(updater.ErroreNodo): updater.carica_credenziali(path)


if __name__ == '__main__':
    unittest.main()
