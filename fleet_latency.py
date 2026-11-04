"""One persistent target for all receivers, reconciled from TX heartbeats."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import uuid

STATE = Path('/var/lib/roc-museum/fleet-latency.json')


def validate(value):
    if type(value) is not int or not 20 <= value <= 2000:
        raise ValueError('Inserire una latenza intera tra 20 e 2000 ms')
    return value


def atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def apply_receiver(config, value, path='/etc/roc-museum.conf'):
    if not isinstance(value, dict): raise ValueError('Comando latenza non valido')
    target = str(validate(value.get('target_ms'))) + 'ms'
    revision = value.get('revision')
    if not isinstance(revision, str) or not re.fullmatch('[a-f0-9]{32}', revision):
        raise ValueError('Revisione latenza non valida')
    if config.get('TARGET_LATENCY') == target and config.get('FLEET_LATENCY_REVISION') == revision:
        return True
    path = Path(path)
    old = path.read_text()
    lines = [line for line in old.splitlines() if not re.match(r'^\s*(TARGET_LATENCY|FLEET_LATENCY_REVISION)\s*=', line)]
    atomic(path, '\n'.join(lines) + '\nTARGET_LATENCY="' + target + '"\nFLEET_LATENCY_REVISION="' + revision + '"\n')
    changed = config.get('TARGET_LATENCY') != target
    if changed:
        try:
            subprocess.run(['systemctl', 'restart', 'roc-museum.service'], check=True, timeout=15,
                           capture_output=True)
            subprocess.run(['systemctl', 'is-active', '--quiet', 'roc-museum.service'], check=True,
                           timeout=3, capture_output=True)
        except (OSError, subprocess.SubprocessError):
            atomic(path, old)
            try:
                subprocess.run(['systemctl', 'restart', 'roc-museum.service'], check=False,
                               timeout=15, capture_output=True)
            except (OSError, subprocess.SubprocessError): pass
            raise RuntimeError('Riavvio Roc fallito: ripristinata la configurazione precedente') from None
    config.update(TARGET_LATENCY=target, FLEET_LATENCY_REVISION=revision)
    return True


class Fleet:
    def __init__(self, discover, send, path=STATE):
        self.discover, self.send, self.path = discover, send, Path(path)
        self.lock = threading.RLock()
        self.attempts, self.errors = {}, {}
        try:
            self.desired = json.loads(self.path.read_text())
            validate(self.desired['target_ms'])
            if not re.fullmatch('[a-f0-9]{32}', self.desired['revision']): raise ValueError('Revisione non valida')
        except FileNotFoundError:
            self.desired = None

    def request(self, target):
        validate(target)
        with self.lock:
            desired = {'target_ms': target, 'revision': uuid.uuid4().hex, 'changed_at': time.time()}
            atomic(self.path, json.dumps(desired))
            self.desired = desired
            self.attempts.clear(); self.errors.clear()
        return self.snapshot()

    def snapshot(self):
        with self.lock:
            desired = dict(self.desired) if self.desired else None
            nodes = []
            for node in self.discover():
                if node.get('role') != 'rx': continue
                name = node.get('name', '?')
                online = time.time() - node.get('received_at', 0) <= 15
                state = 'non_impostata'
                if desired:
                    if not online: state = 'offline'
                    elif not node.get('latency_control_supported'): state = 'aggiornamento_richiesto'
                    elif node.get('latency_revision') == desired['revision'] and node.get('target_latency') == str(desired['target_ms']) + 'ms': state = 'confermato'
                    elif node.get('latency_control_error') or self.errors.get(name): state = 'errore'
                    else: state = 'in_attesa'
                nodes.append({'name': name, 'state': state, 'current': node.get('target_latency'),
                              'error': node.get('latency_control_error') or self.errors.get(name, '')})
            return {'desired': desired, 'nodes': nodes}

    def tick(self):
        with self.lock:
            if not self.desired: return
            for node in self.snapshot()['nodes']:
                name = node['name']
                if node['state'] not in ('in_attesa', 'errore'): continue
                if time.monotonic() - self.attempts.get(name, -1e9) < 30: continue
                self.attempts[name] = time.monotonic()
                try:
                    ok, message = self.send(name, 'set_latency', dict(self.desired))
                    self.errors[name] = '' if ok else str(message)
                except OSError as error:
                    self.errors[name] = str(error)

    def loop(self):
        while True:
            try: self.tick()
            except Exception as error: print('Latenza RX: ' + str(error), flush=True)
            time.sleep(5)
