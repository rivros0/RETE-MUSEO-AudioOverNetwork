#!/usr/bin/env python3
"""Durable TX-first fleet updates, executed outside the monitor's systemd unit."""
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

ROOT=Path('/var/lib/roc-museum/updates')
CONFIG=Path('/etc/roc-museum.conf')
SERVICE='roc-museum-update.service'
REPOSITORY='https://github.com/rivros0/RETE-MUSEO-AudioOverNetwork.git'
BRANCH='main'
BUSY={'queued','running'}
SECRETS=Path('/run/roc-museum-update-job.json')


def version(value):
    if not isinstance(value,str) or not re.fullmatch(r'\d+(?:\.\d+)*',value):
        raise ValueError('Versione numerica non valida')
    parts=[int(v) for v in value.split('.')]
    while len(parts)>1 and parts[-1]==0: parts.pop()
    return tuple(parts)


def read_config(path=CONFIG):
    result={}
    for line in Path(path).read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key,value=line.split('=',1)
            tokens=shlex.split(value,comments=True)
            if len(tokens)==1: result[key]=tokens[0]
    return result


def atomic(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,name=tempfile.mkstemp(dir=path.parent,prefix='.state-')
    try:
        with os.fdopen(fd,'w') as stream:
            json.dump(data,stream,ensure_ascii=False);stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name): os.unlink(name)


def read_json(path,default):
    try: return json.loads(Path(path).read_text())
    except FileNotFoundError: return default


@contextlib.contextmanager
def lock(root,blocking=False):
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (root/'lock').open('a') as stream:
        try: fcntl.flock(stream,fcntl.LOCK_EX|(0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError: raise ValueError('Operazione di aggiornamento già in corso') from None
        yield


def targets(text):
    if not isinstance(text,str) or len(text)>8192: raise ValueError('Elenco RX non valido')
    result=[]
    for item in text.splitlines():
        item=item.strip()
        if not item: continue
        if not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]*@[0-9.]+',item):
            raise ValueError('Inserire un RX per riga nel formato utente@IPv4')
        ipaddress.IPv4Address(item.split('@')[1])
        if item in result: raise ValueError('RX duplicato')
        result.append(item)
    if len(result)>32: raise ValueError('Massimo 32 RX')
    return result


def command(argv,timeout=60,input=None):
    result=subprocess.run(argv,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if result.returncode:
        print(result.stderr.decode('utf-8',errors='replace'),file=sys.stderr,flush=True)
        raise RuntimeError('Comando fallito: '+Path(argv[0]).name+' (consultare il log aggiornamenti)')
    return result.stdout.decode('utf-8',errors='replace')


def ssh(host,script,input=None,timeout=60):
    return command(['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
                    '-o','ConnectTimeout=12','-o','ServerAliveInterval=15',
                    '-o','ServerAliveCountMax=3',host,script],timeout=timeout,input=input)


class PasswordSSH:
    """One in-memory SSH connection; passwords never appear in commands or logs."""
    def __init__(self, address, credentials):
        import paramiko
        self.client=paramiko.SSHClient()
        self.client.load_system_host_keys()
        # Unknown LAN hosts are trusted for this connection only. Known changed keys fail.
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.credentials=credentials
        try:
            self.client.connect(address, username=credentials['username'], password=credentials['password'],
                                look_for_keys=False, allow_agent=False, timeout=12, auth_timeout=15, banner_timeout=15)
        except Exception:
            self.client.close()
            raise RuntimeError('Connessione SSH fallita: verificare credenziali e chiave host') from None
    def close(self): self.client.close()
    def __call__(self, host, script, input=None, timeout=60):
        stdin,stdout,stderr=self.client.exec_command(script,timeout=timeout)
        if input: stdin.write(input);stdin.flush()
        stdin.channel.shutdown_write()
        # Drain both streams concurrently to avoid SSH window deadlocks.
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            out=pool.submit(stdout.read);err=pool.submit(stderr.read)
            result=out.result();err.result()
        if stdout.channel.recv_exit_status():
            raise RuntimeError('Comando remoto fallito (consultare il log sul ricevitore)')
        return result.decode('utf-8',errors='replace')
    def privileged(self, host, script, timeout=60):
        if self.credentials['username']=='root': return self(host,script,timeout=timeout)
        # su reads the root password from a terminal, without exposing it in argv.
        stdin,stdout,stderr=self.client.exec_command('su - root -c '+shlex.quote(script),get_pty=True,timeout=timeout)
        import select
        channel=stdout.channel;output=b'';sent=False;deadline=time.monotonic()+timeout
        while True:
            if time.monotonic()>deadline:
                channel.close();raise RuntimeError('Timeout comando amministrativo RX')
            if channel.recv_ready():
                output+=channel.recv(4096)
                if not sent and (b':' in output or b'password' in output.lower()):
                    channel.sendall((self.credentials['root_password']+'\n').encode());sent=True
                # Keep only a short prompt buffer; never log terminal output.
                output=output[-1024:]
            elif channel.exit_status_ready(): break
            else: select.select([channel],[],[],0.1)
        if channel.recv_exit_status(): raise RuntimeError('Accesso root o comando amministrativo RX fallito')


def credential(value):
    if not isinstance(value,dict): raise ValueError('Credenziali RX mancanti')
    user=value.get('username','');password=value.get('password','');root=value.get('root_password') or password
    if not isinstance(user,str) or not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]*',user):
        raise ValueError('Nome utente SSH non valido')
    for secret in (password,root):
        if not isinstance(secret,str) or not secret or len(secret)>1024 or any(c in secret for c in ('\n','\r','\0')):
            raise ValueError('Password RX mancante o non valida')
    return {'username':user,'password':password,'root_password':root}


REMOTE_CONFIG="""import json,shlex
from pathlib import Path
result={}
for line in Path('/etc/roc-museum.conf').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key,value=line.split('=',1); tokens=shlex.split(value,comments=True)
        if len(tokens)==1: result[key]=tokens[0]
print(json.dumps(result))
"""


def remote_config(host, connection=None):
    return json.loads((connection or ssh)(host,'python3 -c '+shlex.quote(REMOTE_CONFIG)))


def fetch_candidate(directory):
    repo=Path(directory)/'repo'
    command(['git','-c','core.hooksPath=/dev/null','clone','--depth','1','--branch',BRANCH,'--',REPOSITORY,str(repo)],timeout=180)
    commit=command(['git','-C',str(repo),'rev-parse','HEAD']).strip()
    if not re.fullmatch('[0-9a-f]{40}',commit): raise ValueError('Commit GitHub non valido')
    artifact=repo/'setup_roc_museum.sh'
    if artifact.is_symlink() or not artifact.is_file() or artifact.stat().st_size>4*1024*1024:
        raise ValueError('Installer GitHub non valido')
    content=artifact.read_bytes()
    match=re.search(rb'(?m)^VERSION="(\d+(?:\.\d+)*)"$',content)
    if not match: raise ValueError('Versione GitHub non disponibile')
    latest=match[1].decode();version(latest)
    command(['bash','-n',str(artifact)])
    return artifact,latest,commit,hashlib.sha256(content).hexdigest()


def local_install(artifact,config,log):
    with log.open('ab') as stream:
        result=subprocess.run(['bash',str(artifact),'--role','tx','--name',config['NODE_NAME']],stdout=stream,stderr=subprocess.STDOUT,timeout=3600)
    if result.returncode: raise RuntimeError('Aggiornamento TX fallito: consultare il log')


def verify_local(latest):
    if version(read_config().get('SOFTWARE_VERSION',''))!=version(latest):
        raise ValueError('Versione TX dopo installazione diversa da quella attesa')
    for service in ('roc-museum.service','roc-museum-monitor.service'):
        command(['systemctl','is-active','--quiet',service])
    # Readiness includes the HTTP monitor, not only systemd's process state.
    import urllib.request
    for attempt in range(15):
        try:
            with urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=3) as response:
                if response.status==200 and response.read(16)==b'ok\n': return
        except OSError: pass
        time.sleep(2)
    raise RuntimeError('TX aggiornato ma regia non disponibile; propagazione RX fermata')


def install_rx(host,artifact,latest,digest,connection=None):
    run=connection or ssh
    config=remote_config(host,connection) if connection else remote_config(host)
    if config.get('ROLE')!='rx': raise ValueError('Il dispositivo non è un RX')
    current=config.get('SOFTWARE_VERSION','');version(current)
    if version(current)>=version(latest): return 'Già aggiornato ('+current+')'
    directory=run(host,'mktemp -d /tmp/roc-museum-update.XXXXXXXX').strip()
    if not re.fullmatch(r'/tmp/roc-museum-update\.[a-zA-Z0-9]+',directory): raise ValueError('Directory remota non valida')
    remote=directory+'/setup.sh'
    try:
        run(host,'cat > '+shlex.quote(remote),input=artifact.read_bytes(),timeout=120)
        actual=run(host,'sha256sum -- '+shlex.quote(remote)).split()[0]
        if actual!=digest: raise ValueError('Integrità installer RX non valida')
        ipaddress.IPv4Address(config['TX_IP'])
        invocation=['bash',remote,'--role','rx','--tx-ip',config['TX_IP'],'--name',config['NODE_NAME']]
        script=shlex.join(invocation)+' > '+shlex.quote(directory+'/install.log')+' 2>&1'
        if connection: connection.privileged(host,script,timeout=3600)
        else: run(host,'sudo -n '+script,timeout=3600)
        after=remote_config(host,connection) if connection else remote_config(host)
        if after.get('ROLE')!='rx' or version(after.get('SOFTWARE_VERSION',''))!=version(latest):
            raise ValueError('Verifica versione RX fallita')
        run(host,'systemctl is-active --quiet roc-museum.service && systemctl is-active --quiet roc-museum-monitor.service')
        run(host,'rm -rf -- '+shlex.quote(directory))
        return 'Aggiornato a '+latest
    except Exception:
        # Preserve logs and installer when outcome needs manual inspection.
        raise RuntimeError('Aggiornamento RX fallito; log su RX: '+directory+'/install.log') from None


class Manager:
    def __init__(self,root=ROOT,discover=None,secrets=SECRETS):
        self.root=Path(root);self.discover=discover or (lambda: []);self.secrets=Path(secrets)
    def receivers(self):
        result=[];seen=set()
        for node in self.discover():
            if node.get('role')!='rx': continue
            try: address=str(ipaddress.IPv4Address(node.get('source_ip','')))
            except (ValueError,TypeError): continue
            if address in seen: continue
            seen.add(address)
            result.append({'ip':address,'name':str(node.get('name',address))[:100],
                           'online':time.time()-node.get('received_at',0)<=15})
        return result[:32]
    def state(self): return read_json(self.root/'status.json',{'state':'idle','message':'Nessun controllo eseguito','nodes':[]})
    def snapshot(self):
        if read_config().get('ROLE')!='tx': raise ValueError('Aggiornamenti disponibili soltanto sul TX')
        state=self.state()
        if state['state'] in BUSY and time.time()-state.get('updated_at',0)>20:
            active=command(['systemctl','show',SERVICE,'--property=ActiveState','--value']).strip()
            if active not in ('active','activating','reloading'):
                try:
                    with lock(self.root):
                        state=self.state()
                        if state['state'] in BUSY:
                            state.update(state='failed',message='Operazione interrotta: controllare log e versioni prima di riprovare',updated_at=time.time())
                            atomic(self.root/'status.json',state)
                            self.secrets.unlink(missing_ok=True)
                except ValueError: pass
        return {**state,'installed':read_config().get('SOFTWARE_VERSION',''),
                'receivers':self.receivers()}
    def request(self,action,data):
        if read_config().get('ROLE')!='tx': raise ValueError('Aggiornamenti disponibili soltanto sul TX')
        if action not in ('check','update'): raise ValueError('Azione aggiornamento non valida')
        with lock(self.root):
            if self.state()['state'] in BUSY: raise ValueError('Operazione già in corso')
            active=command(['systemctl','show',SERVICE,'--property=ActiveState','--value']).strip()
            if active in ('active','activating','reloading'): raise ValueError('Servizio di aggiornamento già in corso')
            if action=='update':
                known={n['ip'] for n in self.receivers() if n['online']}
                selected=data.get('receivers')
                if not isinstance(selected,list) or not selected or len(selected)>32:
                    raise ValueError('Selezionare almeno un RX online')
                if any(not isinstance(ip,str) or ip not in known for ip in selected) or len(set(selected))!=len(selected):
                    raise ValueError('Elenco RX cambiato: riaprire la finestra di aggiornamento')
                scope=data.get('scope')
                if scope not in ('all','individual'): raise ValueError('Modalità credenziali non valida')
                values=data.get('credentials')
                if not isinstance(values,dict): raise ValueError('Credenziali RX mancanti')
                job=[{'ip':ip,'credentials':credential(values if scope=='all' else values.get(ip))} for ip in selected]
                self.secrets.parent.mkdir(parents=True,exist_ok=True)
                atomic(self.secrets,job)
            atomic(self.root/'status.json',{'state':'queued','action':action,'message':'Operazione in avvio',
                                          'updated_at':time.time(),'nodes':[]})
            try: command(['systemctl','start','--no-block',SERVICE])
            except Exception:
                self.secrets.unlink(missing_ok=True)
                atomic(self.root/'status.json',{'state':'failed','message':'Avvio aggiornamento fallito','nodes':[]})
                raise
        return {'ok':True}
    def worker(self):
        with lock(self.root,blocking=True):
            state=self.state()
            if state.get('state')!='queued': raise ValueError('Nessuna operazione in attesa')
            def progress(message,**extra):
                state.update(message=message,updated_at=time.time(),**extra)
                atomic(self.root/'status.json',state)
            connections={}
            try:
                job=read_json(self.secrets,None) if state['action']=='update' else None
                if state['action']=='update' and job is None: raise ValueError('Credenziali scadute: avviare nuovamente l’aggiornamento')
                for item in job or []:
                    host=item['ip'];progress('Verifica accesso SSH e root '+host,state='running')
                    conn=PasswordSSH(host,item['credentials']);connections[host]=conn
                    if remote_config(host,conn).get('ROLE')!='rx': raise ValueError('Il dispositivo non è un RX: '+host)
                    conn.privileged(host,'true')
                progress('Controllo versione su GitHub',state='running')
                config=read_config()
                if config.get('ROLE')!='tx': raise ValueError('Il dispositivo non è un TX')
                with tempfile.TemporaryDirectory(prefix='release-',dir=self.root) as temp:
                    artifact,latest,commit,digest=fetch_candidate(temp)
                    receivers=[item['ip'] for item in job] if job is not None else []
                    nodes=[{'host':host,'state':'pending','message':'In attesa'} for host in receivers]
                    progress('Versione GitHub '+latest,latest=latest,commit=commit,sha256=digest,nodes=nodes)
                    if state['action']=='check':
                        progress('Controllo completato',state='checked');return
                    current=config.get('SOFTWARE_VERSION','');version(current)
                    if version(current)>version(latest):
                        raise ValueError('TX più recente di GitHub: aggiornamento fermato per evitare versioni miste')
                    if version(current)<version(latest):
                        progress('Aggiornamento TX in corso; la regia si riconnetterà dopo il riavvio')
                        # Backup of configuration only; live SQLite databases are preserved by setup.
                        (self.root/'tx-config.backup').write_text(CONFIG.read_text())
                        local_install(artifact,config,self.root/'tx-install.log')
                    progress('Verifica TX prima della propagazione')
                    verify_local(latest)
                    failures=False
                    for node in nodes:
                        progress('Aggiornamento '+node['host'])
                        node.update(state='running',message='Connessione SSH')
                        progress(state['message'])
                        try:
                            node.update(message=install_rx(node['host'],artifact,latest,digest,connections[node['host']]),state='completed')
                        except Exception as error:
                            node.update(state='failed',message=str(error));failures=True
                        progress('Esito '+node['host'])
                    progress('Aggiornamento completato con errori RX' if failures else 'TX e RX aggiornati',
                             state='partial' if failures else 'completed')
            except Exception as error:
                progress(str(error),state='failed')
                raise
            finally:
                for conn in connections.values(): conn.close()
                self.secrets.unlink(missing_ok=True)


if __name__=='__main__':
    if sys.argv[1:]!=['worker']: raise SystemExit('Uso interno: updater.py worker')
    Manager().worker()
