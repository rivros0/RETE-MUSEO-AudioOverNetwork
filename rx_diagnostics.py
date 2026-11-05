"""Bounded RX RTP/analog diagnostics. No playback, network or capture ownership."""
import json
import math
import statistics
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


ANALYSIS_RATE=2000


class ClockModel:
    """Bounded affine sample-counter/host fit, not a hardware timestamp source."""
    def __init__(self, rate):
        self.rate=rate
        self.points=deque(maxlen=240)
        self.raw_origin=None
        self.fit=None
        self.span=0.
        self.scatter=None
        self.step_hits=0
        self.steps=0
        self.last_step=None

    def observe(self, count, now):
        if self.raw_origin is None: self.raw_origin=(count,now)
        if self.points and (count<=self.points[-1][0] or now-self.points[-1][1]<.4): return
        if self.fit is not None:
            residual=now-self.sample_time(count)
            if abs(residual)>.020:
                self.step_hits=self.step_hits+1 if self.last_step is not None and residual*self.last_step[0]>0 else 1
                self.last_step=(residual,now)
                if self.step_hits>=3:
                    self.steps+=1;self.points.clear();self.fit=None;self.span=0.;self.scatter=None;self.step_hits=0
            else: self.step_hits=0
        self.points.append((count,now))
        if len(self.points)<20: return
        self.span=(self.points[-1][0]-self.points[0][0])/self.rate
        if self.span<30: return
        base_count,base_time=self.points[0]
        points=[((c-base_count)/self.rate,t-base_time) for c,t in self.points]
        def fit(values):
            mx=sum(x for x,y in values)/len(values);my=sum(y for x,y in values)/len(values)
            variance=sum((x-mx)**2 for x,y in values)
            slope=sum((x-mx)*(y-my) for x,y in values)/max(variance,1e-12)
            return slope,my-slope*mx
        slope,intercept=fit(points)
        residuals=[y-(slope*x+intercept) for x,y in points]
        center=statistics.median(residuals)
        mad=statistics.median(abs(v-center) for v in residuals)
        keep=[point for point,residual in zip(points,residuals) if abs(residual-center)<=max(.002,4*mad)]
        if len(keep)<max(20,len(points)*.75): self.fit=None;return
        slope,intercept=fit(keep)
        residuals=sorted(abs(y-(slope*x+intercept)) for x,y in keep)
        self.scatter=residuals[min(len(residuals)-1,int(len(residuals)*.9))]
        # A fit outside 0.2% is not explained as normal clock drift.
        self.fit=(base_count,base_time,slope,intercept) if .998<=slope<=1.002 and self.scatter<.010 else None

    def sample_time(self, count):
        if self.fit is not None:
            base_count,base_time,slope,intercept=self.fit
            return base_time+intercept+slope*(count-base_count)/self.rate
        if self.points:
            base_count,base_time=self.points[0]
            return base_time+(count-base_count)/self.rate
        return None

    @property
    def effective_rate(self):
        return self.rate/self.fit[2] if self.fit is not None else self.rate

    def summary(self, count, now):
        raw=None if self.raw_origin is None else now-(self.raw_origin[1]+(count-self.raw_origin[0])/self.rate)
        predicted=self.sample_time(count)
        return {'fit_valid':self.fit is not None,'nominal_rate':self.rate,
                'effective_rate':round(self.effective_rate,5),
                'drift_ppm':None if self.fit is None else round((self.fit[2]-1)*1e6,2),
                'raw_offset_ms':None if raw is None else round(raw*1000,2),
                'residual_ms':None if predicted is None else round((now-predicted)*1000,2),
                'fit_jitter_ms':None if self.scatter is None else round(self.scatter*1000,2),
                'fit_span_seconds':round(self.span,2),'points':len(self.points),'delivery_steps':self.steps,
                'last_step_ms':None if self.last_step is None else round(self.last_step[0]*1000,2),
                'last_step_monotonic':None if self.last_step is None else self.last_step[1],
                'nominal_elapsed_seconds':None if self.raw_origin is None else round((count-self.raw_origin[0])/self.rate,3),
                'host_elapsed_seconds':None if self.raw_origin is None else round(now-self.raw_origin[1],3),
                'time_basis':'software delivery timestamps; rate estimate may include acquisition effects'}


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


def resample(samples, rate, target=ANALYSIS_RATE):
    """Two-stage antialias filtering; only diagnostic copies are resampled."""
    if rate/target>=7.5:
        x=np.arange(17)-8
        kernel=2*.1125*np.sinc(2*.1125*x)*np.hamming(17)
        kernel/=kernel.sum()
        samples=np.stack([np.convolve(samples[:,ch],kernel,mode='same')[::4]
                          for ch in range(samples.shape[1])],axis=1)
        rate/=4
    taps=max(17,int(16*rate/target)|1)
    x=np.arange(taps)-taps//2
    cutoff=.45*target/rate
    kernel=2*cutoff*np.sinc(2*cutoff*x)*np.hamming(taps)
    kernel/=kernel.sum()
    filtered=np.stack([np.convolve(samples[:,ch],kernel,mode='same')
                       for ch in range(samples.shape[1])],axis=1)
    positions=np.arange(int(len(samples)*target/rate))*rate/target
    return np.stack([np.interp(positions,np.arange(len(samples)),filtered[:,ch])
                     for ch in range(samples.shape[1])],axis=1)


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
    alternatives[max(0, index-int(.020*ANALYSIS_RATE)):index+int(.020*ANALYSIS_RATE)+1] = 0
    ambiguous = bool(alternatives.max(initial=0) > max(0.7, abs(score) * .95))
    segment = reference[index:index+size]
    segment = segment - segment.mean()
    gain = float(segment @ centered / max(float(segment @ segment), 1e-24))
    residual = centered - gain * segment
    residual_db = 10 * math.log10(max(float(residual @ residual) / energy, 1e-12))
    return {'offset': index, 'correlation': round(score, 4), 'ambiguous': ambiguous,
            'gain_db': round(20 * math.log10(max(abs(gain), 1e-9)), 2),
            'residual_db': round(residual_db, 2)}


def dropout_evidence(run, expected, actual, raw, raw_rate, correlation):
    """Check the same alignment on each flank and verify attenuation in raw PCM."""
    start = run['start_ms']
    end = start + run['duration_ms']
    duration = len(actual) * 1000 // ANALYSIS_RATE
    flanks = [(max(0, start-100), start), (end, min(duration, end+100))]
    scores = []
    levels = []
    for left, right in flanks:
        if right-left < 40:
            scores.append(None)
            continue
        window = slice(left*ANALYSIS_RATE//1000, right*ANALYSIS_RATE//1000)
        x, y = expected[window], actual[window]
        power = float(np.linalg.norm(x)*np.linalg.norm(y))
        score = float(np.dot(x,y))/power if power else 0
        scores.append(round(score if correlation >= 0 else -score, 3))
        samples = raw[left*raw_rate//1000:right*raw_rate//1000]
        levels.append(float(np.mean(samples**2)))
    gap = raw[start*raw_rate//1000:end*raw_rate//1000]
    contrast = None
    if len(levels) == 2 and min(levels) > 0:
        contrast = round(10*float(np.log10(max(float(np.mean(gap**2)), 1e-12)/min(levels))), 1)
    return {'flank_correlations': scores, 'raw_level_change_db': contrast,
            'corroborated': all(score is not None and score >= .6 for score in scores)
                            and contrast is not None and contrast <= -15}


def compare(reference, observed, reference_rate=44100, capture_rate=16000, channel_map=None, probe_mapping=True):
    """Compare a history reference to the last second of analog audio."""
    if len(reference)/reference_rate < .25 or len(observed)/capture_rate < .25:
        return {'status': 'warming_up', 'message': 'Accumulo delle finestre di confronto'}
    started=time.thread_time()
    ref = resample(reference, reference_rate)
    heard = resample(observed, capture_rate)
    resample_cpu=(time.thread_time()-started)*1000
    correlation_started=time.thread_time()
    if len(heard) < ANALYSIS_RATE//4 or len(ref) < len(heard):
        return {'status': 'warming_up', 'message': 'Accumulo delle finestre di confronto'}
    count = min(2, ref.shape[1], heard.shape[1])
    mapping = list(channel_map) if channel_map is not None and len(channel_map)==count else list(range(count))
    if sorted(mapping) != list(range(count)): mapping=list(range(count))
    pairs = [[match_channel(ref[:, source], heard[:, channel]) if probe_mapping or source==mapping[channel] else None
              for source in range(count)] for channel in range(count)]
    if count == 2 and probe_mapping:
        def mapping_score(order):
            chosen=[pairs[ch][source] for ch,source in enumerate(order)]
            if not all(item is not None and abs(item['correlation']) >= .5 for item in chosen): return None
            if abs(chosen[0]['offset']-chosen[1]['offset']) > .005*ANALYSIS_RATE: return None
            return sum(abs(item['correlation']) for item in chosen)/2
        direct, crossed=mapping_score([0,1]),mapping_score([1,0])
        if crossed is not None and crossed >= .75 and crossed > (direct or 0)+.05:
            mapping=[1,0]
        elif direct is not None and direct >= .75 and direct > (crossed or 0)+.05:
            mapping=[0,1]
    results = []
    for channel, source in enumerate(mapping):
        selected=pairs[channel][source]
        if selected is None:
            results.append({'channel': channel, 'reference_channel': source, 'status': 'insufficient_signal'})
            continue
        result=dict(selected)
        result['channel'] = channel
        result['reference_channel'] = source
        result['polarity_inverted'] = result['correlation'] < -.75
        result['status'] = 'matched' if abs(result['correlation']) >= .75 else 'mismatch'
        start = result['offset']
        expected = ref[start:start+len(heard), source]
        actual = heard[:, channel]
        gain = 10 ** (result['gain_db'] / 20)
        block = ANALYSIS_RATE//100
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
        for run in runs:
            run.update(dropout_evidence(run, expected, actual, observed[:, channel],
                                        capture_rate, result['correlation']))
        if runs:
            verified = abs(result['correlation']) >= .5 and not result['ambiguous']
            result['status'] = 'dropout' if verified and any(r['corroborated'] for r in runs) else 'dropout_candidate'
        results.append(result)
    # A silent channel can only be checked at a delay established by the other channel.
    aligned = next((r for r in results if abs(r.get('correlation', 0)) >= .75 and not r.get('ambiguous')), None)
    if aligned:
        for channel, result in enumerate(results):
            if result['status'] == 'insufficient_signal':
                start = aligned['offset']
                expected = ref[start:start+len(heard), mapping[channel]]
                if float(np.mean(expected**2)) > 10**(-45/10) and float(np.mean(observed[:,channel]**2)) < 10**(-55/10):
                    result['status'] = 'missing_channel'
    usable = [r for r in results if 'correlation' in r]
    status = 'matched'
    message = 'Ritorno correlato al riferimento RTP'
    if not usable:
        status, message = 'insufficient_signal', 'Segnale insufficiente per confrontare le forme d’onda'
    elif any(r['status'] == 'missing_channel' for r in results):
        status, message = 'missing_channel', 'Un canale del ritorno è assente mentre il riferimento è attivo'
    elif any(r['status'] == 'dropout' for r in usable):
        status, message = 'dropout', 'Interruzione nel ritorno rispetto al riferimento allineato'
    elif any(r['status'] == 'dropout_candidate' for r in usable):
        status, message = 'dropout_candidate', 'Calo rilevato con riscontro insufficiente nel PCM o nell’allineamento locale'
    elif any(r['status'] == 'mismatch' for r in usable):
        status, message = 'mismatch', 'Ritorno poco correlato: contenuto alterato o allineamento non affidabile'
    elif any(r['status']=='insufficient_signal' for r in results):
        status, message = 'partial_match', 'Solo parte dei canali è valutabile nella banda diagnostica'
    elif any(r['ambiguous'] for r in usable):
        status, message = 'ambiguous', 'Audio correlato ma ritardo ambiguo: contenuto ripetitivo'
    stereo_overlap_ms = 0
    if len(results) == 2 and all(r['status'] == 'dropout' for r in results):
        for left in results[0]['dropouts']:
            for right in results[1]['dropouts']:
                if left['corroborated'] and right['corroborated']:
                    overlap = min(left['start_ms']+left['duration_ms'], right['start_ms']+right['duration_ms'])
                    overlap -= max(left['start_ms'], right['start_ms'])
                    stereo_overlap_ms = max(stereo_overlap_ms, overlap)
    clipped = np.mean(np.abs(observed) >= 32760/32768, axis=0)
    if bool(np.any(clipped > .0001)):
        status, message = 'return_clipping', 'Saturazione rilevata nel ritorno acquisito: controllare anche il gain ADC'
    return {'status': status, 'message': message, 'channels': results, 'analysis_rate': ANALYSIS_RATE,
            'stereo_dropout_overlap_ms': stereo_overlap_ms,
            'stage_cpu_ms':{'resample':round(resample_cpu,2),
                            'compare':round((time.thread_time()-correlation_started)*1000,2)},
            'clipped_fraction': [round(float(v), 6) for v in clipped],
            'diagnostic_band_hz': [0,900],
            'full_band_return_active':bool(np.any(np.mean(observed**2,axis=0)>10**(-55/10))),
            'channel_map': mapping, 'channel_mapping': 'swapped' if mapping==[1,0] else 'direct'}


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
        self.channel_map = None
        self.capture_origin = None
        self.capture_frames = 0
        self.capture_blocks = 0
        self.capture_timing = {}
        self.workload = {}
        self.last_analyzed_capture = None
        self.last_analyzed_context = None
        self.capture_clock=ClockModel(16000)
        self.reference_clock=ClockModel(44100)
        self.capture_health={}
        self.buffer_clock={}
        self.last_mapping_check=-1e9
        self.analysis_interval=1.0
        self.clock_epoch=0
        self.clock_reset_reason='startup'

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
                self.channel_map = None; self.capture_origin = None; self.capture_frames = 0
                self.capture_clock=ClockModel(16000);self.reference_clock=ClockModel(44100)
                self.last_analyzed_capture=None;self.last_mapping_check=-1e9
                self.clock_epoch+=1;self.clock_reset_reason='rtp_stream_change'
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
                self.reference_clock.observe(extended_stamp+len(samples),now)
            self.reference.append((now, extended_stamp, samples))
            while self.reference and self.reference[0][0] < now-self.HISTORY:
                self.reference.popleft()

    def feed_capture(self, raw, now=None):
        if np is None:
            return
        now = time.monotonic() if now is None else now
        samples = np.frombuffer(raw, dtype='<i2').astype(np.float32).reshape(-1, 2) / 32768
        with self.lock:
            previous=self.capture[-1][0] if self.capture else None
            if previous is not None and now-previous > 1:
                self.capture.clear(); self.capture_origin=None; self.capture_frames=0
                self.capture_clock=ClockModel(16000)
                self.clock_epoch+=1;self.clock_reset_reason='capture_delivery_gap'
                self.previous_delay=None; self.previous_delay_time=None; self.delay_history.clear()
            if self.capture_origin is None:
                self.capture_origin=now-len(samples)/16000
            self.capture_frames+=len(samples)
            self.capture_blocks+=1
            self.capture_clock.observe(self.capture_frames,now)
            sample_end=self.capture_clock.sample_time(self.capture_frames)
            clock=self.capture_clock.summary(self.capture_frames,now)
            self.capture_timing={
                'delivery_offset_ms': clock['raw_offset_ms'],
                'captured_frames':self.capture_frames,'captured_blocks':self.capture_blocks,
                'delivery_interval_error_ms': None if previous is None else round((now-previous-len(samples)/16000)*1000,2),
                'clock_basis': 'sample_count_with_robust_rate_fit'}
            self.capture.append((now, samples, sample_end, self.capture_frames))
            while self.capture and self.capture[0][0] < now-self.HISTORY:
                self.capture.popleft()

    def update_capture_health(self, health):
        with self.lock:
            if health.get('xrun_events',0)>self.capture_health.get('xrun_events',0):
                self.capture_clock=ClockModel(16000)
                self.clock_epoch+=1;self.clock_reset_reason='capture_xrun'
                self.previous_delay=None;self.previous_delay_time=None;self.delay_history.clear()
            self.capture_health=dict(health)

    def update_context(self, muted, reference, roc_error='', roc_warning=''):
        with self.lock:
            self.context = {'muted': muted, 'reference_meter': reference,
                            'roc_error': roc_error, 'roc_warning': roc_warning}
            self.last_context = time.monotonic()

    def snapshot(self):
        with self.lock:
            result = dict(self.result)
            result.update(capture_health=dict(self.capture_health), schema_version=2, workload=dict(self.workload), capture_timing=dict(self.capture_timing), rtp=dict(self.stats), events=list(self.events)[-1:], storage_error=self.storage_error)
        return result

    def buffers(self, now):
        with self.lock:
            packets = list(self.reference)
            captures = list(self.capture)
            stats = dict(self.stats)
            context = dict(self.context)
            context_age = now-self.last_context
            if packets and captures:
                capture_end=self.capture_clock.sample_time(captures[-1][3])
                if capture_end is None: capture_end=captures[-1][2]
                self.buffer_clock={'epoch':self.clock_epoch,'reset_reason':self.clock_reset_reason,
                                   'capture_rate':self.capture_clock.effective_rate,
                                   'reference_rate':self.reference_clock.effective_rate,
                                   'adc':self.capture_clock.summary(captures[-1][3],captures[-1][0])}
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
        observed = np.concatenate([chunk[1] for chunk in captures])
        # End arrival time anchors an approximate delay; ADC/kernel buffering remains included.
        last_packet = max(packets, key=lambda p: p[1]+len(p[2]))
        with self.lock:
            reference_end_time=self.reference_clock.sample_time(end) if self.reference_clock.fit is not None else last_packet[0]
            self.buffer_clock['rtp']=self.reference_clock.summary(end,last_packet[0])
        return reference, observed, coverage, reference_end_time, capture_end, stats, context, context_age

    def analyze(self, now=None):
        now = time.monotonic() if now is None else now
        if np is None:
            with self.lock:
                self.result = {'status': 'unavailable', 'message': 'NumPy non disponibile: reinstallare il setup aggiornato'}
            return
        buffers_started=time.thread_time()
        buffers = self.buffers(now)
        buffers_cpu=(time.thread_time()-buffers_started)*1000
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
        # One analysis per second, with 250 ms overlap and only four seconds
        # filtered for DSP. Keep the full history for WAV evidence.
        fresh_capture=capture_end != self.last_analyzed_capture
        if not fresh_capture and context == self.last_analyzed_context: return
        self.last_analyzed_capture=capture_end
        self.last_analyzed_context=context
        capture_rate=self.buffer_clock['capture_rate'];reference_rate=self.buffer_clock['reference_rate']
        window=max(1.25,self.analysis_interval+.25)
        tail=observed[-int(window*capture_rate):]
        analysis_reference=reference[-int(max(4,window+1.5)*reference_rate):]
        mapping_due=self.channel_map is None or now-self.last_mapping_check>=30
        result=compare(analysis_reference,tail,reference_rate,capture_rate,self.channel_map,mapping_due)
        if mapping_due: self.last_mapping_check=now
        if 'channel_map' in result: self.channel_map=result['channel_map']
        result.setdefault('stage_cpu_ms',{})['buffers']=round(buffers_cpu,2)
        result['analysis_capture_start_monotonic']=capture_end-len(tail)/capture_rate
        result['analysis_reference_start_monotonic']=ref_end-len(analysis_reference)/reference_rate
        result['capture_timing']=dict(self.capture_timing)
        result['clock_diagnostics']=dict(self.buffer_clock)
        result['capture_health']=dict(self.capture_health)
        result['workload']=dict(self.workload)
        result['analysis_window_seconds']=round(len(tail)/capture_rate,3)
        result['updated_at'] = time.time()
        result['reference_coverage'] = round(float(coverage.mean()), 5)
        result['context_age_seconds'] = round(context_age, 1)
        result['delay_basis'] = 'software-fitted RTP/ADC sample timelines; includes delivery-buffer uncertainty'
        usable = [c for c in result.get('channels', []) if 'offset' in c]
        delays = []
        for channel in usable:
            delay = capture_end-len(tail)/capture_rate-(ref_end-len(analysis_reference)/reference_rate+channel['offset']/ANALYSIS_RATE)
            if result['status']=='matched' and abs(channel['correlation']) >= .85 and not channel['ambiguous'] and -0.1 <= delay <= 3:
                delays.append(delay*1000)
        if delays:
            delay = sum(delays)/len(delays)
            result['estimated_delay_ms'] = round(delay, 2)
            if self.previous_delay is not None:
                result['delay_change_ms'] = round(delay-self.previous_delay, 2)
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
        if result['status'] == 'insufficient_signal' and not result.get('full_band_return_active') and context_age <= 12 and not context.get('muted'):
            levels = context.get('reference_meter', {})
            # A 5-second meter can remain active after a legitimate pause. Check
            # the actual aligned reference before calling a silent return faulty.
            if self.previous_delay is not None and self.previous_delay_time is not None and now-self.previous_delay_time < 10:
                start = int((capture_end-len(tail)/capture_rate-self.previous_delay/1000-
                             (ref_end-len(reference)/reference_rate))*reference_rate)
                expected = reference[max(0,start):max(0,start)+int(len(tail)/capture_rate*reference_rate)]
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
            result['timing_observation']='capture_delay_change'
            result['timing_message']='Variazione della stima RTP → ADC oltre 20 ms; non prova di un dropout audio'
        if abs(self.buffer_clock['adc'].get('residual_ms') or 0)>20:
            result['timing_observation']='capture_delivery_jitter'
            result['timing_message']='Consegna PCM irregolare rispetto al clock stimato; non prova di un difetto in uscita'
        adc_clock=self.buffer_clock['adc']
        if adc_clock['delivery_steps'] and now-(adc_clock.get('last_step_monotonic') or -1e9)<5:
            result['timing_observation']='capture_delivery_step'
            result['timing_message']='Salto persistente nella consegna ADC: nuova calibrazione, causa non attribuita alla riproduzione'
        capture_error_age=now-self.capture_health.get('last_xrun_monotonic',-1e9)
        if capture_error_age<5:
            result['observed_audio_status']=result['status']
            result.update(status='capture_unreliable',message='Overrun/xrun della cattura spia: confronto di uscita non conclusivo')
            result['timing_observation']='capture_xrun'
            result['timing_message']='Errore ADC acquisito nello stderr arecord; verificare carico e cattura'
        clocks=result['clock_diagnostics']
        adc=clocks['adc'];rtp_clock=clocks['rtp']
        result['timing_confidence']='calibrated_estimate' if adc['fit_valid'] and rtp_clock['fit_valid'] and abs(adc['residual_ms'] or 0)<20 and abs(rtp_clock['residual_ms'] or 0)<20 else 'uncalibrated'
        if not result.get('timing_observation') and adc['fit_valid'] and abs(adc.get('drift_ppm') or 0)>100:
            result['timing_observation']='clock_drift_compensated'
            result['timing_message']='Deriva del contatore ADC stimata e compensata; lo scarto cumulativo non è ritardo di uscita'
        result['confidence']='high' if result['status']=='matched' and usable and all(abs(c['correlation'])>=.85 and not c['ambiguous'] for c in usable) else 'limited'
        fault = result['status'] in ('dropout', 'mismatch', 'reference_gaps', 'missing_return', 'missing_channel', 'return_clipping')
        if fault and self.candidate == result['status']:
            self.hits += int(fresh_capture)
        else:
            self.candidate = result['status'] if fault else None
            self.hits = 1 if fault else 0
        result['confirmed'] = fault and (self.hits >= 2 or result['status'] == 'dropout')
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
        event = self.pending
        _, _, _, _, _, stats, context, _ = buffers
        if self.trigger_buffers is not None:
            buffers = self.trigger_buffers
            event['wav_snapshot'] = 'trigger'
        reference, observed, coverage, _, _, _, _, _ = buffers
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
                         note='Independent WAV timelines; channel offsets are relative to analysis_reference_start_monotonic '
                              '+ offset/analysis_rate, not the WAV start. RTP holes are zero-filled. Sequence gaps are provisional, not final packet loss.')
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
        previous_start=None
        cpu_average=None
        while not stop_event.is_set():
            started=time.perf_counter()
            cpu_started=time.thread_time()
            try:
                self.analyze()
            except Exception as error:
                with self.lock:
                    self.result = {'status': 'error', 'message': 'Diagnostica: '+str(error)}
            elapsed=time.perf_counter()-started
            cpu=time.thread_time()-cpu_started
            period=1.0 if previous_start is None else max(.001,started-previous_start)
            cpu_average=cpu if cpu_average is None else .8*cpu_average+.2*cpu
            self.analysis_interval=max(1.0,min(2.5,cpu_average/.15))
            with self.lock:
                self.workload={'stage_cpu_ms':dict(self.result.get('stage_cpu_ms',{})),
                               'analysis_target_period_seconds':round(self.analysis_interval,3),
                               'analysis_gap_seconds':round(max(0,period-self.result.get('analysis_window_seconds',1.25)),3),
                               'analysis_wall_ms':round(elapsed*1000,2),
                               'analysis_cpu_ms':round(cpu*1000,2),
                               'analysis_core_percent':round(cpu/period*100,1),
                               'analysis_period_seconds':round(period,2),
                               'over_budget':cpu/period>.20 or elapsed/period>.5,
                               'sampled_at':time.time(),
                               'scope':'analysis worker only; excludes capture and RTP processing'}
            previous_start=started
            stop_event.wait(max(.05,self.analysis_interval-elapsed))
