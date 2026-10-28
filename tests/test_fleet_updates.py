"""Updater ordering, persistent results and HTTP boundaries, without real hosts."""
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock,patch
import test_auth_upload as access

spec=importlib.util.spec_from_file_location('fleet_updater',Path(__file__).resolve().parents[1]/'updater.py')
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)

class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.manager=u.Manager(self.root,discover=lambda:[{'role':'rx','source_ip':ip,'name':ip,'received_at':time.time()} for ip in ('192.168.1.51','192.168.1.52')],secrets=self.root/'secrets.json')
        self.config={'ROLE':'tx','NODE_NAME':'TX','SOFTWARE_VERSION':'4.10'}
        self.p=patch.object(u,'read_config',side_effect=lambda:dict(self.config));self.p.start();self.addCleanup(self.p.stop)
        self.configfile=self.root/'config';self.configfile.write_text('ROLE="tx"\n')
        self.p2=patch.object(u,'CONFIG',self.configfile);self.p2.start();self.addCleanup(self.p2.stop)
        self.connection=patch.object(u,'PasswordSSH',return_value=Mock());self.connection.start();self.addCleanup(self.connection.stop)
        self.remote=patch.object(u,'remote_config',return_value={'ROLE':'rx'});self.remote.start();self.addCleanup(self.remote.stop)
    def queued(self,action='update'):
        u.atomic(self.root/'status.json',{'state':'queued','action':action,'nodes':[]})
        if action=='update': u.atomic(self.manager.secrets,[{'ip':ip,'credentials':{'username':'root','password':'secret','root_password':'secret'}} for ip in ('192.168.1.51','192.168.1.52')])
    def test_numeric_versions_and_targets(self):
        self.assertLess(u.version('4.9'),u.version('4.11'))
        self.assertEqual(u.version('4.11.0'),u.version('4.11'))
        for invalid in ('pi@host;id','-oProxyCommand=id','pi@999.0.0.1','pi@1.2.3.4\npi@1.2.3.4'):
            with self.subTest(invalid=invalid),self.assertRaises(ValueError): u.targets(invalid)
    def test_check_never_installs(self):
        self.queued('check')
        with patch.object(u,'fetch_candidate',return_value=(Path('installer'),'4.11','a'*40,'hash')),patch.object(u,'local_install') as tx,patch.object(u,'install_rx') as rx:
            self.manager.worker()
        tx.assert_not_called();rx.assert_not_called()
        self.assertEqual(self.manager.state()['state'],'checked')
        self.assertEqual(self.manager.state()['latest'],'4.11')
    def test_tx_verification_precedes_rx_and_failures_continue(self):
        self.queued();events=[]
        def local(*args): events.append('tx')
        def verify(*args): events.append('verify')
        def receiver(host,*args):
            events.append(host)
            if host.endswith('51'): raise RuntimeError('SSH non disponibile')
            return 'Aggiornato'
        with patch.object(u,'fetch_candidate',return_value=(Path('installer'),'4.11','a'*40,'hash')),patch.object(u,'local_install',side_effect=local),patch.object(u,'verify_local',side_effect=verify),patch.object(u,'install_rx',side_effect=receiver):
            self.manager.worker()
        self.assertEqual(events,['tx','verify','192.168.1.51','192.168.1.52'])
        state=u.Manager(self.root).state()
        self.assertEqual(state['state'],'partial')
        self.assertEqual([n['state'] for n in state['nodes']],['failed','completed'])
    def test_failed_tx_stops_propagation(self):
        for failure in ('install','verify'):
            self.queued()
            with self.subTest(failure=failure),patch.object(u,'fetch_candidate',return_value=(Path('installer'),'4.11','commit','hash')),patch.object(u,'local_install',side_effect=RuntimeError('TX guasto') if failure=='install' else None),patch.object(u,'verify_local',side_effect=RuntimeError('non pronto') if failure=='verify' else None),patch.object(u,'install_rx') as rx:
                with self.assertRaises(RuntimeError): self.manager.worker()
                rx.assert_not_called();self.assertEqual(self.manager.state()['state'],'failed')
    def test_already_updated_tx_still_propagates(self):
        self.config['SOFTWARE_VERSION']='4.11';self.queued()
        with patch.object(u,'fetch_candidate',return_value=(Path('installer'),'4.11','commit','hash')),patch.object(u,'local_install') as tx,patch.object(u,'verify_local'),patch.object(u,'install_rx',return_value='OK') as rx:
            self.manager.worker()
        tx.assert_not_called();self.assertEqual(rx.call_count,2)
    def test_no_downgrade(self):
        self.config['SOFTWARE_VERSION']='5.0';self.queued()
        with patch.object(u,'fetch_candidate',return_value=(Path('installer'),'4.11','commit','hash')),patch.object(u,'local_install') as tx,patch.object(u,'install_rx') as rx:
            with self.assertRaises(ValueError): self.manager.worker()
        tx.assert_not_called();rx.assert_not_called()
    def test_busy_rejects_configuration_and_second_job(self):
        self.queued()
        for action in ('check','update','configure'):
            with self.subTest(action=action),self.assertRaises(ValueError): self.manager.request(action,{'receivers':''})
    def test_launches_independent_unit(self):
        with patch.object(u,'command',return_value='inactive') as command:
            self.manager.request('update',{'receivers':['192.168.1.51'],'scope':'all','credentials':{'username':'root','password':'secret'}})
        self.assertEqual(self.manager.state()['state'],'queued')
        self.assertEqual(command.call_args.args[0],['systemctl','start','--no-block',u.SERVICE])
    def test_discovery_uses_source_address_and_deduplicates(self):
        self.manager.discover=lambda:[{'role':'rx','source_ip':'192.168.1.51','name':'Sala','received_at':time.time()},
                                     {'role':'tx','source_ip':'192.168.1.1'},
                                     {'role':'rx','source_ip':'192.168.1.51'}, {'role':'rx','source_ip':'bad'}]
        nodes=self.manager.snapshot()['receivers']
        self.assertEqual(len(nodes),1);self.assertTrue(nodes[0]['online']);self.assertEqual(nodes[0]['name'],'Sala')
    def test_credentials_individual_and_secret_file_permissions(self):
        data={'receivers':['192.168.1.51','192.168.1.52'],'scope':'individual','credentials':{
            '192.168.1.51':{'username':'pi','password':'first','root_password':'root-secret'},
            '192.168.1.52':{'username':'root','password':'second'}}}
        with patch.object(u,'command',return_value='inactive'): self.manager.request('update',data)
        job=u.read_json(self.manager.secrets,[])
        self.assertEqual([i['credentials']['password'] for i in job],['first','second'])
        self.assertEqual(self.manager.secrets.stat().st_mode & 0o777,0o600)
        self.assertNotIn('root-secret',json.dumps(self.manager.snapshot()))
    def test_unknown_offline_or_missing_credentials_rejected(self):
        for addresses,values in [(['192.168.1.99'],{'username':'root','password':'secret'}),(['192.168.1.51'],{})]:
            with patch.object(u,'command',return_value='inactive'),self.assertRaises(ValueError):
                self.manager.request('update',{'receivers':addresses,'scope':'all','credentials':values})
        self.manager.discover=lambda:[{'role':'rx','source_ip':'192.168.1.51','received_at':0}]
        with patch.object(u,'command',return_value='inactive'),self.assertRaises(ValueError):
            self.manager.request('update',{'receivers':['192.168.1.51'],'scope':'all','credentials':{'username':'root','password':'secret'}})
    def test_auth_failure_stops_before_tx_and_erases_passwords(self):
        self.queued()
        with patch.object(u,'PasswordSSH',side_effect=RuntimeError('Accesso fallito')),patch.object(u,'local_install') as tx,patch.object(u,'fetch_candidate') as fetch:
            with self.assertRaises(RuntimeError): self.manager.worker()
        tx.assert_not_called();fetch.assert_not_called();self.assertFalse(self.manager.secrets.exists())
        self.assertEqual(self.manager.state()['state'],'failed')
    def test_start_failure_erases_credentials(self):
        with patch.object(u,'command',side_effect=['inactive',RuntimeError('start failed')]),self.assertRaises(RuntimeError):
            self.manager.request('update',{'receivers':['192.168.1.51'],'scope':'all','credentials':{'username':'root','password':'secret'}})
        self.assertFalse(self.manager.secrets.exists())
    def test_interrupted_job_marked_failed(self):
        u.atomic(self.root/'status.json',{'state':'running','updated_at':time.time()-60})
        with patch.object(u,'command',return_value='failed'):
            self.assertEqual(self.manager.snapshot()['state'],'failed')
    def test_non_rx_target_never_installed(self):
        with patch.object(u,'remote_config',return_value={'ROLE':'tx'}),patch.object(u,'ssh') as ssh:
            with self.assertRaises(ValueError): u.install_rx('pi@192.168.1.51',Path('artifact'),'4.11','hash')
        ssh.assert_not_called()
    def test_rx_equal_or_newer_is_skipped(self):
        for current in ('4.11','4.12'):
            with self.subTest(current=current),patch.object(u,'remote_config',return_value={'ROLE':'rx','SOFTWARE_VERSION':current}),patch.object(u,'ssh') as ssh:
                self.assertIn('Già aggiornato',u.install_rx('pi@192.168.1.51',Path('artifact'),'4.11','hash'))
                ssh.assert_not_called()
    def test_github_failure_is_durable(self):
        self.queued()
        with patch.object(u,'fetch_candidate',side_effect=RuntimeError('GitHub non raggiungibile')),patch.object(u,'local_install') as tx:
            with self.assertRaises(RuntimeError): self.manager.worker()
        tx.assert_not_called();self.assertEqual(u.Manager(self.root).state()['state'],'failed')
    def test_candidate_has_commit_version_and_checksum(self):
        def fake(argv,**kwargs):
            if 'clone' in argv:
                repo=Path(argv[-1]);repo.mkdir();(repo/'setup_roc_museum.sh').write_text('#!/bin/bash\nVERSION="4.12"\n')
            if 'rev-parse' in argv: return 'a'*40+'\n'
            return ''
        with tempfile.TemporaryDirectory() as temp,patch.object(u,'command',side_effect=fake):
            artifact,latest,commit,digest=u.fetch_candidate(temp)
            self.assertEqual(latest,'4.12');self.assertEqual(commit,'a'*40)
            self.assertEqual(digest,u.hashlib.sha256(artifact.read_bytes()).hexdigest())
    def test_worker_is_independent_of_monitor(self):
        installer=(Path(__file__).resolve().parents[1]/'setup_roc_museum.sh').read_text()
        unit=installer.split("<<'UNIT_UPDATE'\n",1)[1].split('\nUNIT_UPDATE',1)[0]
        self.assertIn('updater.py worker',unit)
        self.assertNotIn('PartOf=',unit)
        self.assertNotIn('Requires=roc-museum-monitor',unit)

    def test_hash_mismatch_never_executes_installer(self):
        artifact=self.root/'setup';artifact.write_text('data')
        with patch.object(u,'remote_config',return_value={'ROLE':'rx','SOFTWARE_VERSION':'4.9'}),patch.object(u,'ssh',side_effect=['/tmp/roc-museum-update.Abcd1234','','wrong file']) as ssh:
            with self.assertRaises(RuntimeError): u.install_rx('pi@192.168.1.51',artifact,'4.11','expected')
        self.assertFalse(any('sudo' in call.args[1] for call in ssh.call_args_list))

class PasswordTransportTests(unittest.TestCase):
    def connection(self):
        conn=u.PasswordSSH.__new__(u.PasswordSSH)
        conn.client=Mock();conn.credentials={'username':'pi','password':'ssh-secret','root_password':'root-secret'}
        return conn
    def test_root_password_sent_to_terminal_only(self):
        conn=self.connection();stdin=Mock();stdout=Mock();channel=stdout.channel
        conn.client.exec_command.return_value=(stdin,stdout,Mock())
        channel.recv_ready.side_effect=[True,True,False]
        channel.recv.side_effect=[b'Pass',b'word: ']
        channel.exit_status_ready.return_value=True;channel.recv_exit_status.return_value=0
        conn.privileged('192.168.1.51','true')
        channel.sendall.assert_called_once_with(b'root-secret\n')
        self.assertNotIn('root-secret',str(conn.client.exec_command.call_args))
        self.assertTrue(conn.client.exec_command.call_args.kwargs['get_pty'])
    def test_wrong_root_password_fails(self):
        conn=self.connection();stdout=Mock();conn.client.exec_command.return_value=(Mock(),stdout,Mock())
        stdout.channel.recv_ready.return_value=False;stdout.channel.exit_status_ready.return_value=True
        stdout.channel.recv_exit_status.return_value=1
        with self.assertRaisesRegex(RuntimeError,'Accesso root'):conn.privileged('192.168.1.51','true')
    def test_root_login_uses_no_su(self):
        conn=self.connection();conn.credentials['username']='root'
        stdout=Mock();stdout.read.return_value=b'';stdout.channel.recv_exit_status.return_value=0
        conn.client.exec_command.return_value=(Mock(),stdout,Mock())
        conn.privileged('192.168.1.51','true')
        self.assertEqual(conn.client.exec_command.call_args.args[0],'true')

class UpdateAccessTests(unittest.TestCase):
    setUp=access.AccessTests.setUp
    request=access.AccessTests.request
    headers=access.AccessTests.headers
    def test_updates_require_auth_and_csrf(self):
        for method in ('GET','POST'):
            self.assertEqual(self.request('/api/updates',method=method)[0],401)
        self.assertEqual(self.request('/api/updates',headers={'Cookie':'regia=test'})[0],403)
    def test_updates_delegate_authenticated_request(self):
        from test_meter import monitor
        manager=Mock();manager.request.return_value={'ok':True};manager.snapshot.return_value={'state':'idle'}
        with patch.object(monitor.Handler,'updater',manager):
            body=b'{"action":"check"}'
            self.assertEqual(self.request('/api/updates',body,self.headers(**{'Content-Length':str(len(body))}))[0],202)
            manager.request.assert_called_once_with('check',{'action':'check'})
            self.assertEqual(self.request('/api/updates',headers=self.headers(),method='GET')[0],200)
