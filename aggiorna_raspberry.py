#!/usr/bin/env python3
"""Controlla e aggiorna i nodi Roc Museum dalla repository configurata."""
import argparse
import getpass
import json
import os
import ipaddress
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# CONFIGURAZIONE: URL HTTPS o SSH Git, ramo (vuoto = ramo predefinito).
REPOSITORY = "https://github.com/rivros0/RETE-MUSEO-AudioOverNetwork.git"
RAMO = "main"
PERCORSO_SETUP = "setup_roc_museum.sh"
# Password personali nel file locale ignorato da Git, non in questo sorgente.
RASPBERRY = {
    "pi@192.168.1.91": "",  # RX1
    "pi@192.168.1.92": "",  # RX2
    "pi@192.168.1.90": "",  # TX
}
CONFIG_LOCALE = Path(__file__).resolve().with_name("aggiorna_raspberry.local.json")
PORTA_SSH = 22
TIMEOUT_SSH = 12
TIMEOUT_AGGIORNAMENTO = 1800


class ErroreNodo(Exception):
    pass


def versione(text, installed=False):
    key = "SOFTWARE_VERSION" if installed else "VERSION"
    match = re.search(r'^' + key + r'=[\"\']?(\d+(?:\.\d+)*)[\"\']?\s*$', text, re.M)
    if installed and not match:
        match = re.search(r'^# RETE MUSEO .*setup v(\d+(?:\.\d+)*)\s*$', text, re.M)
    if not match:
        raise ErroreNodo("Versione assente o non numerica")
    return match.group(1)


def numero(value):
    parts = [int(part) for part in value.split('.')]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def configurazione(text):
    result = {}
    for line in text.splitlines():
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        if key in ('ROLE', 'NODE_NAME', 'TX_IP'):
            try:
                parsed = shlex.split(value, comments=True)
            except ValueError as error:
                raise ErroreNodo("Configurazione remota non valida") from error
            if len(parsed) != 1:
                raise ErroreNodo("Campo remoto non valido: " + key)
            result[key] = parsed[0]
    if result.get('ROLE') not in ('tx', 'rx') or not re.fullmatch(r'[\w .-]+', result.get('NODE_NAME', ''), re.ASCII):
        raise ErroreNodo("Ruolo o nome nodo mancante/non valido")
    if result['ROLE'] == 'rx':
        try:
            ipaddress.IPv4Address(result.get('TX_IP', ''))
        except ValueError as error:
            raise ErroreNodo("IP TX mancante/non valido") from error
    return result


class Terminale:
    def __init__(self, hosts):
        self.rows = {host: ['—', 'In attesa', ''] for host in hosts}
        self.online = '—'
        self.last = 0

    def mostra(self, host=None, stato=None, dettaglio='', versione_locale=None, force=True):
        if host:
            row = self.rows[host]
            if versione_locale is not None:
                row[0] = versione_locale
            if stato:
                row[1] = stato
            row[2] = dettaglio
        if not force and time.monotonic() - self.last < 1:
            return
        self.last = time.monotonic()
        if sys.stdout.isatty():
            print('\033[2J\033[H', end='')
        print('RETE MUSEO · Gestore aggiornamenti | Versione online: ' + self.online)
        print(f'{"RASPBERRY":32} {"VERSIONE":12} {"STATO":24} DETTAGLIO')
        print('─' * 100)
        for name, (local, status, detail) in self.rows.items():
            clean = re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', detail)
            print(f'{name:32} {local:12} {status:24} {clean[:80]}')
        print(flush=True)


def comando(client, command, password=None, progress=None, timeout=60):
    stdin, stdout, stderr = client.exec_command(command)
    channel = stdout.channel
    if password is not None:
        stdin.write(password + '\n')
        stdin.flush()
    channel.shutdown_write()
    output = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        for ready, receive in ((channel.recv_ready, channel.recv),
                               (channel.recv_stderr_ready, channel.recv_stderr)):
            if ready():
                data = receive(65536)
                output.extend(data)
                if len(output) > 2_000_000:
                    del output[:-1_000_000]
                if progress and data:
                    lines = data.decode('utf-8', 'replace').splitlines()
                    if lines:
                        progress(lines[-1])
        if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
            break
        if time.monotonic() > deadline:
            channel.close()
            raise ErroreNodo('Timeout comando; verificare il nodo prima di riprovare')
        time.sleep(0.1)
    code = channel.recv_exit_status()
    text = output.decode('utf-8', 'replace')
    if code:
        raise ErroreNodo('Comando remoto fallito (codice ' + str(code) + ')')
    return text


def aggiorna(client, password, setup, config, progress):
    remote_dir = comando(client, 'mktemp -d /tmp/roc-museum.XXXXXXXX').strip()
    if not re.fullmatch(r'/tmp/roc-museum\.[a-zA-Z0-9]+', remote_dir):
        raise ErroreNodo('Directory temporanea remota non valida')
    remote = remote_dir + '/setup_roc_museum.sh'
    try:
        with client.open_sftp() as sftp:
            sftp.put(str(setup), remote)
        script = r'''
set -eu
backup=$(mktemp -d /var/backups/roc-museum-$(date +%Y%m%d-%H%M%S).XXXXXXXX)
for file in /etc/roc-museum.conf /etc/systemd/system/roc-museum.service /etc/systemd/system/roc-museum-monitor.service /usr/local/sbin/roc-museum-run /usr/local/sbin/roc-museum-monitor /usr/local/lib/roc-museum /usr/local/share/roc-museum /var/lib/roc-museum/auth.json /var/lib/roc-museum/volume /boot/firmware/config.txt /boot/config.txt; do
    if [ -e "$file" ]; then cp -a --parents "$file" "$backup/"; fi
done
# Backup SQLite coerente anche con il calendario attivo. La libreria audio
# resta sul posto: duplicarla potrebbe esaurire la microSD durante l'update.
python3 - "$backup" <<'PY_BACKUP'
import pathlib, sqlite3, sys
source=pathlib.Path('/var/lib/roc-museum/studio/calendar.sqlite')
if source.exists():
    target=pathlib.Path(sys.argv[1])/source.relative_to('/')
    target.parent.mkdir(parents=True,exist_ok=True)
    original=sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)
    backup=sqlite3.connect(target)
    try: original.backup(backup)
    finally: backup.close();original.close()
PY_BACKUP
printf '\nBackup salvato in: %s\n' "$backup"
bash "$@"
printf '\nVerifica finale dei servizi\n'
sleep 3
systemctl is-active roc-museum.service
systemctl is-active roc-museum-monitor.service
'''
        args = [remote, '--role', config['ROLE'], '--name', config['NODE_NAME']]
        if config['ROLE'] == 'rx':
            args += ['--tx-ip', config['TX_IP']]
        command = 'sudo -S -p "" bash -c ' + shlex.quote(script) + ' bash ' + shlex.join(args)
        comando(client, command, password=password, progress=progress,
                timeout=TIMEOUT_AGGIORNAMENTO)
    finally:
        try:
            comando(client, 'rm -f -- ' + shlex.quote(remote) + '; rmdir ' + shlex.quote(remote_dir), timeout=20)
        except Exception:
            pass


def esamina(host, password, setup, latest, ui, check_only, paramiko):
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    # Mantiene la verifica delle chiavi presenti in ~/.ssh/known_hosts.
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    try:
        ui.mostra(host, 'Connessione SSH')
        user, address = host.split('@', 1)
        client.connect(address, port=PORTA_SSH, username=user, password=password,
                       timeout=TIMEOUT_SSH, auth_timeout=TIMEOUT_SSH,
                       banner_timeout=TIMEOUT_SSH, look_for_keys=False, allow_agent=False)
        text = comando(client, 'cat /etc/roc-museum.conf')
        local = versione(text, installed=True)
        ui.mostra(host, 'Confronto versioni', versione_locale=local)
        if numero(local) >= numero(latest):
            status = 'Già aggiornato' if numero(local) == numero(latest) else 'Versione più recente'
            ui.mostra(host, status)
            return True
        if check_only:
            ui.mostra(host, 'Da aggiornare', local + ' → ' + latest)
            return True
        config = configurazione(text)
        ui.mostra(host, 'Aggiornamento', local + ' → ' + latest)
        aggiorna(client, password, setup, config,
                 lambda line: ui.mostra(host, 'Aggiornamento', line, force=False))
        installed = versione(comando(client, 'cat /etc/roc-museum.conf'), installed=True)
        if numero(installed) != numero(latest):
            raise ErroreNodo('Versione dopo aggiornamento diversa da quella attesa')
        ui.mostra(host, 'Aggiornato', local + ' → ' + installed + '; servizi attivi', versione_locale=installed)
        return True
    except paramiko.AuthenticationException:
        ui.mostra(host, 'Credenziali errate')
    except paramiko.BadHostKeyException:
        ui.mostra(host, 'Chiave host cambiata', 'Verificare la chiave SSH del dispositivo')
    except (socket.timeout, TimeoutError, socket.gaierror, ConnectionError, paramiko.ssh_exception.NoValidConnectionsError):
        ui.mostra(host, 'Non raggiungibile', 'Connessione SSH assente o scaduta')
    except paramiko.SSHException:
        ui.mostra(host, 'Errore SSH', 'Verificare servizio SSH e chiave in known_hosts')
    except (ErroreNodo, OSError) as error:
        ui.mostra(host, 'Errore', str(error).replace(password, '***') if password else str(error))
    finally:
        client.close()
    return False


def scarica_repository(target):
    command = ['git', 'clone', '--depth', '1']
    if RAMO:
        command += ['--branch', RAMO]
    command += ['--', REPOSITORY, str(target)]
    subprocess.run(command, check=True, capture_output=True, timeout=120,
                   env={**__import__('os').environ, 'GIT_TERMINAL_PROMPT': '0'})
    setup = (target / PERCORSO_SETUP).resolve()
    if not setup.is_relative_to(target.resolve()) or not setup.is_file():
        raise ErroreNodo('PERCORSO_SETUP non trovato nella repository')
    latest = versione(setup.read_text())
    subprocess.run(['bash', '-n', str(setup)], check=True, capture_output=True, timeout=15)
    return setup, latest


def carica_credenziali(path):
    if not path.exists(): return dict(RASPBERRY)
    try:
        data=json.loads(path.read_text())
        nodes=data['raspberry']
        if not isinstance(nodes,dict) or not nodes: raise ValueError()
        for host,password in nodes.items():
            if not isinstance(host,str) or not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*',host): raise ValueError()
            if not isinstance(password,str) or '\n' in password or '\r' in password: raise ValueError()
        return nodes
    except (OSError,ValueError,TypeError,KeyError):
        raise ErroreNodo('Configurazione locale non valida: controllare il file JSON') from None


def salva_credenziali(path,nodes):
    path=Path(path)
    if path.is_symlink(): raise ErroreNodo('Il file credenziali non può essere un link simbolico')
    fd,temporary=tempfile.mkstemp(prefix='.roc-credentials-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as target:
            json.dump({'raspberry':nodes},target,indent=2);target.write('\n')
            target.flush();os.fsync(target.fileno())
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def configura_password(path,nodes):
    updated=dict(nodes)
    for host,previous in nodes.items():
        password=getpass.getpass('Password SSH/sudo per '+host+(' (Invio: mantieni)' if previous else '')+': ')
        if not password and previous: continue
        if not password or '\n' in password or '\r' in password:
            raise ErroreNodo('Password mancante o non valida per '+host)
        updated[host]=password
    salva_credenziali(path,updated)
    print('Credenziali salvate nel file locale escluso da Git: '+str(path))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,default=CONFIG_LOCALE,help='File locale delle credenziali')
    parser.add_argument('--configure',action='store_true',help='Imposta le password con inserimento nascosto e salvale localmente')
    parser.add_argument('--check-only', '--dry-run', action='store_true',
                        help='Confronta le versioni senza modificare i Raspberry')
    args = parser.parse_args(argv)
    try:
        nodes=carica_credenziali(args.config)
        if args.configure:
            configura_password(args.config,nodes);return 0
    except (ErroreNodo,OSError) as error:
        parser.error(str(error))
    if not REPOSITORY or not nodes:
        parser.error('Compilare REPOSITORY e il dizionario RASPBERRY all’inizio dello script')
    if not 1 <= PORTA_SSH <= 65535:
        parser.error('PORTA_SSH fuori intervallo')
    for host, password in nodes.items():
        if not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*', host):
            parser.error('Destinazione non valida: usare utente@IP o utente@hostname')
        if not isinstance(password, str) or not password or '\n' in password or '\r' in password:
            parser.error('Password mancante o non valida per ' + host + ': eseguire --configure')
    if not shutil.which('git') or not shutil.which('bash'):
        parser.error('Servono git e bash sul computer locale')
    try:
        import paramiko
    except ImportError:
        parser.error('Dipendenza mancante: installare paramiko (vedere README)')
    ui = Terminale(nodes)
    ui.mostra()
    print('Lettura ultima versione dalla repository...', flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix='roc-repository-') as directory:
            setup, latest = scarica_repository(Path(directory) / 'repo')
            ui.online = latest
            ui.mostra()
            results = [esamina(host, password, setup, latest, ui, args.check_only, paramiko)
                       for host, password in nodes.items()]
    except (subprocess.SubprocessError, OSError, ErroreNodo):
        print('Errore repository: verificare URL, ramo, accesso Git e percorso setup.', file=sys.stderr)
        return 1
    print('Controllo completato.' if args.check_only else 'Aggiornamento completato.', flush=True)
    return 0 if all(results) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt,EOFError):
        sys.exit('Operazione interrotta: verificare eventuali aggiornamenti remoti in corso.')
