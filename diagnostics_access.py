"""Read-only RX diagnostic transport. The TX is the only accepted LAN peer."""
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import subprocess
import threading
import time

ROOT = Path('/var/lib/roc-museum/diagnostics')
MAX_BYTES = 16 * 1024 * 1024
FILES = {'event.json': 'application/json', 'reference.wav': 'audio/wav', 'return.wav': 'audio/wav'}
EVENT = re.compile(r'event-[0-9]{1,24}\Z')
SLOTS = threading.BoundedSemaphore(3)


def read_artifact(event, filename, root=ROOT):
    if not isinstance(event, str) or not isinstance(filename, str) or not EVENT.fullmatch(event) or filename not in FILES:
        raise ValueError('Evidenza non valida')
    # Open each path component without following links, including the event directory.
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        folder = os.open(event, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        try:
            fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder)
            with os.fdopen(fd, 'rb') as stream:
                import stat
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
                    raise ValueError('File non regolare o troppo grande')
                return stream.read(MAX_BYTES + 1)
        finally:
            os.close(folder)
    finally:
        os.close(directory)


def collect(request, root=ROOT):
    action = request.get('action')
    if action == 'events':
        events = []
        if root.exists():
            for folder in sorted(root.iterdir(), key=lambda p: p.name, reverse=True):
                if not EVENT.fullmatch(folder.name) or folder.is_symlink() or not folder.is_dir():
                    continue
                try:
                    data = json.loads(read_artifact(folder.name, 'event.json', root))
                    events.append({'id': folder.name, 'saved_at': data.get('saved_at'),
                                   'triggered_at': data.get('triggered_at'),
                                   'status': data.get('analysis', {}).get('status', 'unknown')})
                except (OSError, ValueError):
                    continue
                if len(events) >= 20:
                    break
        return 'application/json', json.dumps({'events': events, 'generated_at': time.time()}).encode()
    if action == 'file':
        filename = request.get('file', '')
        data = read_artifact(request.get('event', ''), filename, root)
        return FILES[filename], data
    if action == 'journal':
        window = request.get('window', '15m')
        unit = request.get('unit', 'roc-museum')
        if window not in ('15m', '1h', '24h') or unit not in ('roc-museum', 'roc-museum-monitor'):
            raise ValueError('Intervallo o servizio non valido')
        result = subprocess.run(['journalctl', '-u', unit + '.service', '--since=-' + window,
                                 '-n', '5001', '--no-pager', '-o', 'short-iso-precise'],
                                capture_output=True, timeout=8, check=False)
        if result.returncode:
            raise ValueError('Journal non disponibile: ' + result.stderr.decode(errors='replace')[-1000:])
        lines = result.stdout.splitlines(keepends=True)
        raw = b''.join(lines[-5000:])
        truncated = len(lines) > 5000 or len(raw) > 512 * 1024
        text = raw[-512 * 1024:].decode(errors='replace')
        return 'application/json', json.dumps({'text': text, 'truncated': truncated,
            'window': window, 'unit': unit, 'generated_at': time.time(),
            'limit_lines': 5000, 'limit_bytes': 512 * 1024}).encode()
    raise ValueError('Richiesta diagnostica non valida')


def fetch(host, port, request):
    with socket.create_connection((host, port), timeout=4) as connection:
        connection.settimeout(15)
        connection.sendall(json.dumps(request).encode() + b'\n')
        with connection.makefile('rb') as stream:
            header = json.loads(stream.readline(4097))
            if not header.get('ok'):
                raise ValueError(header.get('message', 'Diagnostica non disponibile'))
            length = header.get('length')
            if type(length) is not int or not 0 <= length <= MAX_BYTES:
                raise ValueError('Dimensione risposta non valida')
            if header.get('content_type') not in ('application/json', 'audio/wav'):
                raise ValueError('Formato risposta non valido')
            data = stream.read(length)
            if len(data) != length:
                raise ValueError('Trasferimento evidenza incompleto')
            return header['content_type'], data


class DiagnosticHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(15)
        try:
            raw = self.rfile.readline(4097)
            if len(raw) > 4096:
                raise ValueError('Richiesta troppo grande')
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError('Richiesta non valida')
            content_type, data = collect(request)
            self.wfile.write(json.dumps({'ok': True, 'length': len(data), 'content_type': content_type}).encode() + b'\n')
            self.wfile.write(data)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.wfile.write(json.dumps({'ok': False, 'message': str(error)[:400]}).encode() + b'\n')


class DiagnosticServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def verify_request(self, request, address):
        return address[0] == self.tx_ip

    def process_request(self, request, address):
        if not SLOTS.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            SLOTS.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            SLOTS.release()


def serve(config):
    with DiagnosticServer(('0.0.0.0', int(config.get('CONTROL_PORT', '19091'))), DiagnosticHandler) as server:
        server.tx_ip = config.get('TX_IP', '')
        server.serve_forever()
