"""Bounded RX RTP/analog diagnostics. No playback, network or capture ownership."""
import json
import math
from pathlib import Path
import struct
import subprocess
import threading
import time
import wave
from collections import deque

try:
    import numpy as np
except ImportError:
    np = None


def decode_rtp(packet):
    """Static L16 RTP: PT 10 stereo / PT 11 mono, both 44100 Hz."""
    if len(packet) < 12 or packet[0] >> 6 != 2 or packet[1] & 127 not in (10, 11):
        return None
    channels = 2 if packet[1] & 127 == 10 else 1
    offset = 12 + 4 * (packet[0] & 15)
    if len(packet) < offset:
        return None
    if packet[0] & 16:
        if len(packet) < offset + 4:
            return None
        offset += 4 + 4 * struct.unpack_from('!H', packet, offset + 2)[0]
    end = len(packet)
    if packet[0] & 32:
        padding = packet[-1]
        if not padding or padding > end - offset:
            return None
        end -= padding
    if end <= offset or (end - offset) % (2 * channels):
        return None
    seq, stamp, ssrc = struct.unpack_from('!HII', packet, 2)
    return seq, stamp, ssrc, channels, packet[offset:end]


def resample(samples, rate, target=4000):
    """Low-pass before interpolation; only diagnostic copies are resampled."""
    taps = 81
    x = np.arange(taps) - taps // 2
    cutoff = 0.45 * target / rate
    kernel = 2 * cutoff * np.sinc(2 * cutoff * x) * np.hamming(taps)
    kernel /= kernel.sum()
    filtered = np.stack([np.convolve(samples[:, ch], kernel, mode='same')
                         for ch in range(samples.shape[1])], axis=1)
    positions = np.arange(int(len(samples) * target / rate)) * rate / target
    return np.stack([np.interp(positions, np.arange(len(samples)), filtered[:, ch])
                     for ch in range(samples.shape[1])], axis=1)


def match_channel(reference, observed):
    """Normalized FFT correlation over all valid reference offsets."""
    size = len(observed)
    centered = observed - observed.mean()
    energy = float(centered @ centered)
    count = len(reference) - size + 1
    if count <= 0 or energy < size * 10 ** (-55 / 10):
        return None
    nfft = 1 << (len(reference) + size - 2).bit_length()
    numerator = np.fft.irfft(np.fft.rfft(reference, nfft) *
                             np.fft.rfft(centered[::-1], nfft), nfft)[size-1:len(reference)]
    sums = np.r_[0., np.cumsum(reference)]
    squares = np.r_[0., np.cumsum(reference * reference)]
    window_energy = squares[size:] - squares[:-size] - (sums[size:] - sums[:-size]) ** 2 / size
    scores = numerator / np.sqrt(np.maximum(window_energy * energy, 1e-24))
    scores[window_energy < size * 10 ** (-55 / 10)] = 0
    index = int(np.argmax(np.abs(scores)))
    score = float(scores[index])
    # Similar peaks at substantially different delays make latency ambiguous.
    alternatives = np.abs(scores).copy()
    alternatives[max(0, index-80):index+81] = 0
    ambiguous = bool(alternatives.max(initial=0) > max(0.7, abs(score) * .95))
    segment = reference[index:index+size]
    segment = segment - segment.mean()
    gain = float(segment @ centered / max(float(segment @ segment), 1e-24))
    residual = centered - gain * segment
    residual_db = 10 * math.log10(max(float(residual @ residual) / energy, 1e-12))
    return {'offset': index, 'correlation': round(score, 4), 'ambiguous': ambiguous,
            'gain_db': round(20 * math.log10(max(abs(gain), 1e-9)), 2),
            'residual_db': round(residual_db, 2)}


def compare(reference, observed, reference_rate=44100, capture_rate=16000):
    """Compare a history reference to the last second of analog audio."""
    ref = resample(reference, reference_rate)
    heard = resample(observed, capture_rate)
    if len(heard) < 1000 or len(ref) < len(heard):
        return {'status': 'warming_up', 'message': 'Accumulo delle finestre di confronto'}
    results = []
    for channel in range(min(2, ref.shape[1], heard.shape[1])):
        result = match_channel(ref[:, channel], heard[:, channel])
        if result is None:
            results.append({'channel': channel, 'status': 'insufficient_signal'})
            continue
        result['channel'] = channel
        result['polarity_inverted'] = result['correlation'] < -.75
        result['status'] = 'matched' if abs(result['correlation']) >= .75 else 'mismatch'
        start = result['offset']
        expected = ref[start:start+len(heard), channel]
        actual = heard[:, channel]
        gain = 10 ** (result['gain_db'] / 20)
        # 10 ms blocks: report only silence against an active aligned reference.
        block = 40
        length = len(actual) // block * block
        erms = np.sqrt(np.mean(expected[:length].reshape(-1, block) ** 2, axis=1))
        arms = np.sqrt(np.mean(actual[:length].reshape(-1, block) ** 2, axis=1))
        active = erms * gain > 10 ** (-45 / 20)
        missing = active & (arms < np.maximum(10 ** (-65 / 20), erms * gain * .08))
        runs = []
        begin = None
        for i, flag in enumerate(np.r_[missing, False]):
            if flag and begin is None:
                begin = i
            elif not flag and begin is not None:
                if i - begin >= 2:
                    runs.append({'start_ms': begin * 10, 'duration_ms': (i-begin) * 10})
                begin = None
        result['dropouts'] = runs
        if runs and abs(result['correlation']) >= .5 and not result['ambiguous']:
            result['status'] = 'dropout'
        results.append(result)
    # A silent channel can only be checked at a delay established by the other channel.
    aligned = next((r for r in results if abs(r.get('correlation', 0)) >= .75 and not r.get('ambiguous')), None)
    if aligned:
        for channel, result in enumerate(results):
            if result['status'] == 'insufficient_signal':
                start = aligned['offset']
                expected = ref[start:start+len(heard), channel]
                if float(np.mean(expected**2)) > 10**(-45/10):
                    result['status'] = 'missing_channel'
    # A stronger match on the opposite channel suggests an L/R swap.
    if ref.shape[1] == heard.shape[1] == 2:
        for channel, result in enumerate(results):
            opposite = match_channel(ref[:, 1-channel], heard[:, channel])
            if opposite and abs(opposite['correlation']) > .85 and abs(opposite['correlation']) > abs(result.get('correlation', 0))+.2:
                result['opposite_channel_correlation'] = opposite['correlation']
                result['status'] = 'possible_channel_swap'
    usable = [r for r in results if 'correlation' in r]
    status = 'matched'
    message = 'Ritorno correlato al riferimento RTP'
    if not usable:
        status, message = 'insufficient_signal', 'Segnale insufficiente per confrontare le forme d’onda'
    elif any(r['status'] == 'missing_channel' for r in results):
        status, message = 'missing_channel', 'Un canale del ritorno è assente mentre il riferimento è attivo'
    elif any(r['status'] == 'dropout' for r in usable):
        status, message = 'dropout', 'Interruzione nel ritorno rispetto al riferimento allineato'
    elif any(r['status'] == 'possible_channel_swap' for r in usable):
        status, message = 'possible_channel_swap', 'Ritorno più correlato al canale opposto: possibile scambio L/R'
    elif any(r['status'] == 'mismatch' for r in usable):
        status, message = 'mismatch', 'Ritorno poco correlato: contenuto alterato o allineamento non affidabile'
    elif any(r['ambiguous'] for r in usable):
        status, message = 'ambiguous', 'Audio correlato ma ritardo ambiguo: contenuto ripetitivo'
    clipped = np.mean(np.abs(observed) >= 32760/32768, axis=0)
    if bool(np.any(clipped > .0001)):
        status, message = 'return_clipping', 'Saturazione rilevata nel ritorno acquisito: controllare anche il gain ADC'
    return {'status': status, 'message': message, 'channels': results, 'analysis_rate': 4000,
            'clipped_fraction': [round(float(v), 6) for v in clipped]}


class Diagnostics:
    HISTORY = 8
    def __init__(self, directory='/var/lib/roc-museum/diagnostics'):
        self.lock = threading.Lock()
        self.reference = deque(maxlen=5000)
        self.capture = deque(maxlen=100)
        self.directory = Path(directory)
        self.stream = None
        self.high_seq = None
        self.high_stamp = None
        self.seen = set()
        self.sequence_window = deque(maxlen=4096)
        self.stats = {'packets': 0, 'sequence_gaps': 0, 'out_of_order': 0, 'duplicates': 0, 'jitter_ms': 0.}
        self.transit = None
        self.result = {'status': 'warming_up', 'message': 'In attesa del ritorno Scarlett'}
        self.pending = None
        self.last_event = -1e9
        self.candidate = None
        self.hits = 0
        self.previous_delay = None
        self.previous_delay_time = None
        self.delay_history = deque(maxlen=120)
        self.trigger_buffers = None
        self.last_buffers = None
        self.context = {}
        self.last_context = 0
        self.events = deque(maxlen=5)
        self.storage_error = ''

    def feed_rtp(self, packet, now=None):
        decoded = decode_rtp(packet)
        if decoded is None or np is None:
            return
        seq, stamp, ssrc, channels, raw = decoded
        now = time.monotonic() if now is None else now
        samples = np.frombuffer(raw, dtype='>i2').astype(np.float32).reshape(-1, channels) / 32768
        with self.lock:
            if self.stream != (ssrc, channels) or (self.reference and now-self.reference[-1][0] > 2):
                self.reference.clear(); self.capture.clear()
                self.stream = (ssrc, channels)
                self.high_seq = None; self.high_stamp = None
                self.seen.clear(); self.sequence_window.clear(); self.transit = None
                self.previous_delay = None; self.previous_delay_time = None; self.delay_history.clear()
                self.last_buffers = None
            if self.high_seq is None:
                extended_seq = seq
                extended_stamp = stamp
            else:
                extended_seq = self.high_seq + ((seq - self.high_seq + 32768) % 65536 - 32768)
                extended_stamp = self.high_stamp + ((stamp - self.high_stamp + 2**31) % 2**32 - 2**31)
            if extended_seq in self.seen:
                self.stats['duplicates'] += 1
                return
            if len(self.sequence_window) == self.sequence_window.maxlen:
                self.seen.discard(self.sequence_window[0])
            self.sequence_window.append(extended_seq); self.seen.add(extended_seq)
            self.stats['packets'] += 1
            if self.high_seq is not None:
                if extended_seq > self.high_seq + 1:
                    self.stats['sequence_gaps'] += extended_seq-self.high_seq-1
                elif extended_seq < self.high_seq:
                    self.stats['out_of_order'] += 1
            if self.high_seq is None or extended_seq > self.high_seq:
                transit = now - extended_stamp / 44100
                if self.transit is not None:
                    delta = abs(transit-self.transit)*1000
                    self.stats['jitter_ms'] += (delta-self.stats['jitter_ms']) / 16
                self.transit = transit
                self.high_seq = extended_seq; self.high_stamp = extended_stamp
            self.reference.append((now, extended_stamp, samples))
            while self.reference and self.reference[0][0] < now-self.HISTORY:
                self.reference.popleft()

    def feed_capture(self, raw, now=None):
        if np is None:
            return
        now = time.monotonic() if now is None else now
        samples = np.frombuffer(raw, dtype='<i2').astype(np.float32).reshape(-1, 2) / 32768
        with self.lock:
            if self.capture and now-self.capture[-1][0] > 1:
                self.capture.clear()
            self.capture.append((now, samples))
            while self.capture and self.capture[0][0] < now-self.HISTORY:
                self.capture.popleft()

    def update_context(self, muted, reference, roc_error='', roc_warning=''):
        with self.lock:
            self.context = {'muted': muted, 'reference_meter': reference,
                            'roc_error': roc_error, 'roc_warning': roc_warning}
            self.last_context = time.monotonic()

    def snapshot(self):
        with self.lock:
            result = dict(self.result)
            result.update(rtp=dict(self.stats), events=list(self.events)[-1:], storage_error=self.storage_error)
        return result

    def buffers(self, now):
        with self.lock:
            packets = list(self.reference)
            captures = list(self.capture)
            stats = dict(self.stats)
            context = dict(self.context)
            context_age = now-self.last_context
        if not packets or not captures or now-packets[-1][0] > 2 or now-captures[-1][0] > 1:
            return None
        # RTP timestamps define sample positions, not packet arrival intervals.
        end = max(stamp+len(data) for _, stamp, data in packets)
        begin = max(min(stamp for _, stamp, _ in packets), end-self.HISTORY*44100)
        reference = np.zeros((end-begin, packets[-1][2].shape[1]), dtype=np.float32)
        coverage = np.zeros(end-begin, dtype=bool)
        for _, stamp, data in packets:
            lo, hi = max(begin, stamp), min(end, stamp+len(data))
            if hi > lo:
                reference[lo-begin:hi-begin] = data[lo-stamp:hi-stamp]
                coverage[lo-begin:hi-begin] = True
        observed = np.concatenate([data for _, data in captures])
        # End arrival time anchors an approximate delay; ADC/kernel buffering remains included.
        last_packet = max(packets, key=lambda p: p[1]+len(p[2]))
        reference_end_time = last_packet[0]
        return reference, observed, coverage, reference_end_time, captures[-1][0], stats, context, context_age

    def analyze(self, now=None):
        now = time.monotonic() if now is None else now
        if np is None:
            with self.lock:
                self.result = {'status': 'unavailable', 'message': 'NumPy non disponibile: reinstallare il setup aggiornato'}
            return
        buffers = self.buffers(now)
        if buffers is None:
            if self.pending and now >= self.pending['due']:
                self.pending['post_capture_unavailable'] = True
                self.save_event(self.trigger_buffers)
            with self.lock:
                reference_age = now-self.reference[-1][0] if self.reference else None
                capture_age = now-self.capture[-1][0] if self.capture else None
                context = dict(self.context)
                stats = dict(self.stats)
            status, message = 'unavailable', 'Riferimento RTP o ritorno analogico non recente'
            if self.last_buffers is not None:
                if reference_age is not None and reference_age > 2:
                    status, message = 'reference_timeout', 'Flusso RTP assente da oltre 2 secondi'
                elif capture_age is not None and capture_age > 1:
                    status, message = 'capture_interrupted', 'Ritorno ADC interrotto: verificare acquisizione Scarlett'
            fault = status in ('reference_timeout', 'capture_interrupted')
            with self.lock:
                self.result = {'status': status, 'message': message, 'confirmed': fault,
                               'reference_age_seconds': reference_age, 'capture_age_seconds': capture_age}
            if fault and self.pending is None and now-self.last_event >= 30:
                self.trigger_buffers = self.last_buffers
                self.pending = {'due': now+2, 'triggered_at': time.time(),
                                'analysis': dict(self.result), 'rtp_at_trigger': stats,
                                'context': context, 'post_capture_unavailable': True}
                self.last_event = now
            self.candidate = None; self.hits = 0
            return
        self.last_buffers = buffers
        reference, observed, coverage, ref_end, capture_end, stats, context, context_age = buffers
        tail = observed[-16000:]
        result = compare(reference, tail)
        result['updated_at'] = time.time()
        result['reference_coverage'] = round(float(coverage.mean()), 5)
        result['context_age_seconds'] = round(context_age, 1)
        result['delay_basis'] = 'RTP arrival to ADC capture; includes capture buffering'
        usable = [c for c in result.get('channels', []) if 'offset' in c]
        delays = []
        for channel in usable:
            delay = capture_end - len(tail)/16000 - (ref_end-len(reference)/44100+channel['offset']/4000)
            if abs(channel['correlation']) >= .75 and not channel['ambiguous'] and -0.1 <= delay <= 3:
                delays.append(delay*1000)
        if delays:
            delay = sum(delays)/len(delays)
            result['estimated_delay_ms'] = round(delay, 2)
            if self.previous_delay is not None:
                result['delay_change_ms'] = round(delay-self.previous_delay, 2)
                elapsed = now-self.previous_delay_time
                if elapsed > 0:
                    result['delay_slope_ppm'] = round((delay-self.previous_delay)/1000/elapsed*1e6, 1)
            self.previous_delay = delay; self.previous_delay_time = now
            self.delay_history.append((now, delay))
            if len(self.delay_history) >= 20 and now-self.delay_history[0][0] >= 30:
                history = np.array(self.delay_history)
                x = history[:, 0]-history[0, 0]
                slope, intercept = np.polyfit(x, history[:, 1], 1)
                scatter = float(np.std(history[:, 1]-(slope*x+intercept)))
                if scatter < 2:
                    result['delay_trend_ms_per_minute'] = round(float(slope)*60, 3)
                    result['clock_drift_estimate_ppm'] = round(float(slope)*1000, 1)
                    result['drift_note'] = 'Trend includes network/capture buffering; not a direct hardware clock measurement'
        # Do not attribute analog defects where the reference itself has holes.
        if result.get('reference_coverage', 0) < .995:
            result.update(status='reference_gaps', message='Buchi nel riferimento RTP: confronto analogico non conclusivo')
        if context_age > 12:
            result.update(status='context_stale', message='Stato mute/volume non recente: diagnosi sospesa')
        elif context.get('muted') or not context.get('reference_meter', {}).get('available'):
            result.update(status='suspended', message='Confronto sospeso: mute o riferimento post-fader non disponibile')
        elif all(c.get('rms_dbfs', -96) < -55 for c in context['reference_meter'].get('channels', [])):
            result.update(status='suspended', message='Confronto sospeso: livello di uscita atteso insufficiente')
        if result['status'] == 'insufficient_signal' and context_age <= 12 and not context.get('muted'):
            levels = context.get('reference_meter', {})
            # A 5-second meter can remain active after a legitimate pause. Check
            # the actual aligned reference before calling a silent return faulty.
            if self.previous_delay is not None and self.previous_delay_time is not None and now-self.previous_delay_time < 10:
                start = int((capture_end-len(tail)/16000-self.previous_delay/1000-
                             (ref_end-len(reference)/44100))*44100)
                expected = reference[max(0,start):max(0,start)+int(len(tail)/16000*44100)]
            else:
                expected = reference[-3*44100:]
            blocks = len(expected)//441
            consistently_active = False
            if blocks >= 50:
                power = np.mean(expected[:blocks*441].reshape(blocks,441,-1)**2, axis=1)
                consistently_active = bool(np.any(np.mean(power > 10**(-45/10), axis=0) > .9))
            if consistently_active and levels.get('available') and any(c.get('rms_dbfs', -96) > -45 for c in levels.get('channels', [])):
                result.update(status='missing_return', message='Ritorno silenzioso con riferimento di uscita attivo')
        if result['status'] == 'matched' and abs(result.get('delay_change_ms', 0)) > 20:
            result.update(status='delay_jump', message='Variazione improvvisa del ritardo stimato superiore a 20 ms')
        result['confidence'] = 'high' if result['status'] == 'matched' and delays else 'limited'
        fault = result['status'] in ('dropout', 'mismatch', 'reference_gaps', 'possible_channel_swap', 'missing_return', 'missing_channel', 'return_clipping', 'delay_jump')
        if fault and self.candidate == result['status']:
            self.hits += 1
        else:
            self.candidate = result['status'] if fault else None
            self.hits = 1 if fault else 0
        result['confirmed'] = fault and (self.hits >= 2 or result['status'] in ('dropout', 'delay_jump'))
        if result['confirmed'] and now-self.last_event >= 30 and self.pending is None:
            self.trigger_buffers = buffers
            self.pending = {'due': now+2, 'triggered_at': time.time(), 'analysis': dict(result),
                            'rtp_at_trigger': stats, 'context': context,
                            'trigger_reference_end_monotonic': ref_end,
                            'trigger_capture_end_monotonic': capture_end,
                            'trigger_reference_duration_seconds': len(reference)/44100,
                            'trigger_capture_duration_seconds': len(observed)/16000,
                            'stream': self.stream}
            if result['status'] == 'reference_gaps':
                self.pending['interpretation'] = 'Riferimento digitale incompleto: verificare trasporto e acquisizione pacchetti'
            elif context.get('roc_error') or context.get('roc_warning'):
                self.pending['interpretation'] = 'Anomalia analogica con messaggi Roc recenti: verificare le coincidenze nel journal'
            else:
                self.pending['interpretation'] = 'Anomalia nel ritorno con riferimento disponibile; causa digitale non ancora isolata'
            self.last_event = now
        with self.lock:
            self.result = result
        if self.pending and now >= self.pending['due']:
            if self.pending.get('stream', self.stream) != self.stream:
                self.pending['stream_changed_after_trigger'] = True
                self.save_event(self.trigger_buffers)
            else:
                self.save_event(buffers)

    def save_event(self, buffers):
        reference, observed, coverage, _, _, stats, context, _ = buffers
        event = self.pending
        self.pending = None
        self.trigger_buffers = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            name = 'event-' + str(time.time_ns())
            folder = self.directory / name
            folder.mkdir(mode=0o700)
            for filename, data, rate in (('reference.wav', reference, 44100), ('return.wav', observed, 16000)):
                with wave.open(str(folder / filename), 'wb') as wav:
                    wav.setnchannels(data.shape[1]); wav.setsampwidth(2); wav.setframerate(rate)
                    wav.writeframes(np.clip(data*32768, -32768, 32767).astype('<i2').tobytes())
            event.pop('due', None)
            event.update(rtp_after=stats, context_after=context, reference_coverage=float(coverage.mean()),
                         reference_end_monotonic=buffers[3], capture_end_monotonic=buffers[4],
                         saved_at=time.time(),
                         reference_duration_seconds=len(reference)/44100,
                         capture_duration_seconds=len(observed)/16000,
                         note='Independent WAV timelines; use correlation offsets, not WAV start times. '
                              'RTP holes are zero-filled. Sequence gaps are provisional, not final packet loss.')
            try:
                journal = subprocess.run(['journalctl', '-u', 'roc-museum.service',
                                          '--since=-15sec', '-n', '200', '--no-pager', '-o', 'short-iso-precise'],
                                         capture_output=True, text=True, timeout=4, check=False)
                event['roc_journal'] = journal.stdout[-64000:]
                event['journal_error'] = journal.stderr[-2000:] if journal.returncode else ''
            except (OSError, subprocess.SubprocessError) as error:
                event['journal_error'] = str(error)
            (folder / 'event.json').write_text(json.dumps(event, ensure_ascii=False, indent=2))
            # Only directories produced by this module are eligible for retention.
            folders = sorted(p for p in self.directory.glob('event-*') if p.is_dir() and not p.is_symlink() and p.name[6:].isdigit())
            for old in folders[:-20]:
                for filename in ('reference.wav', 'return.wav', 'event.json'):
                    (old / filename).unlink(missing_ok=True)
                try:
                    old.rmdir()
                except OSError:
                    pass
            with self.lock:
                self.events.append({'path': str(folder), 'triggered_at': event['triggered_at'],
                                    'status': event['analysis']['status']})
                self.storage_error = ''
        except OSError as error:
            with self.lock:
                self.storage_error = str(error)

    def loop(self, stop_event=None):
        stop_event = stop_event or threading.Event()
        while not stop_event.is_set():
            try:
                self.analyze()
            except Exception as error:
                with self.lock:
                    self.result = {'status': 'error', 'message': 'Diagnostica: '+str(error)}
            stop_event.wait(.5)
