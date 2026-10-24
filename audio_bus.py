#!/usr/bin/env python3
"""Continuous stereo PCM bus: microphone always on, music-only ducking, one RTP sender."""
from array import array
from collections import deque
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time


def pcm_samples(data):
    samples=array('h');samples.frombytes(data)
    if sys.byteorder!='little': samples.byteswap()
    return samples


class Ducker:
    def __init__(self,rate=44100):
        self.rate=rate;self.gain=1.;self.limiter=1.;self.hold=0.
        self.enabled=True;self.threshold_db=-36.;self.reduction_db=-18.
        self.input_db=-96.;self.active=False

    def mix(self,music,microphone):
        mic=pcm_samples(microphone);song=pcm_samples(music)
        duration=len(mic)/(2*self.rate)
        rms=math.sqrt(sum(x*x for x in mic)/max(1,len(mic)))/32768
        self.input_db=max(-96.,20*math.log10(max(rms,1e-12)))
        if self.enabled and self.input_db>=self.threshold_db: self.hold=.5
        else: self.hold=max(0.,self.hold-duration)
        self.active=self.enabled and self.hold>0
        target=10**(self.reduction_db/20) if self.active else 1.
        previous=self.gain
        tau=.03 if target<previous else .8
        self.gain=target+(previous-target)*math.exp(-duration/tau)
        # Gain ramp avoids discontinuities; the mic is never multiplied by the duck gain.
        raw=[int(m+(song[i] if i<len(song) else 0)*(previous+(self.gain-previous)*i/max(1,len(mic)-1))) for i,m in enumerate(mic)]
        peak=max((abs(v) for v in raw),default=0)
        limit=min(1.,32760/max(1,peak))
        self.limiter=min(limit,self.limiter+(1-self.limiter)*duration/.2)
        out=array('h',(max(-32768,min(32767,int(v*self.limiter))) for v in raw))
        if sys.byteorder!='little': out.byteswap()
        return out.tobytes()


class AudioBus:
    def __init__(self,config,capture_enabled=True):
        self.config=config;self.rate=int(config.get('SAMPLE_RATE','44100'))
        self.frames=max(1,self.rate//100);self.block_bytes=self.frames*4
        self.lock=threading.RLock();self.stop=threading.Event();self.threads=[]
        self.sender=None;self.capture=None;self.log=None;self.error=''
        self.mic_error='Ingresso microfono in attesa';self.mic_online=False
        self.mic_queue=deque(maxlen=10);self.ducker=Ducker(self.rate)
        self.music=None;self.music_buffer=b'';self.music_eof=False;self.paused=False
        self.position=0.;self.deadline=None;self.deadline_hit=False
        self.capture_enabled=capture_enabled

    def configure(self,settings):
        with self.lock:
            self.ducker.enabled=settings['enabled'];self.ducker.threshold_db=settings['threshold_db'];self.ducker.reduction_db=settings['reduction_db']

    def start(self):
        self.log=tempfile.TemporaryFile()
        try:
            self.sender=subprocess.Popen(['roc-send','-i','file:-','--input-format','wav','-s','rtp://'+self.config.get('MULTICAST_ADDR','239.30.0.1')+':'+self.config.get('RTP_PORT','10001'),'--frame-len='+self.config.get('FRAME_LEN','4ms')],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=self.log,bufsize=0)
            # Unbounded streaming WAV, PCM S16LE stereo. Roc clocks the RTP output.
            self.sender.stdin.write(struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',0xffffffff,b'WAVE',b'fmt ',16,1,2,self.rate,self.rate*4,4,16,b'data',0xffffffff))
            os.set_blocking(self.sender.stdin.fileno(),False)
            self.threads=[threading.Thread(target=self._pump,daemon=True)]
            if self.capture_enabled: self.threads.append(threading.Thread(target=self._capture,daemon=True))
            for thread in self.threads: thread.start()
        except BaseException:
            self.close();raise

    @staticmethod
    def kill(process):
        if process is None: return
        if process.poll() is None: process.terminate()
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired: process.kill();process.wait(timeout=2)
        for pipe in (process.stdin,process.stdout):
            if pipe:
                try: pipe.close()
                except OSError: pass

    def close(self):
        self.stop.set()
        self.kill(self.capture);self.kill(self.sender)
        for thread in self.threads:
            if thread is not threading.current_thread(): thread.join(timeout=4)
        self.capture=None;self.sender=None
        if self.log: self.log.close();self.log=None

    def attach(self,stream,position=0,deadline=None):
        with self.lock:
            os.set_blocking(stream.fileno(),False)
            self.music=stream;self.music_buffer=b'';self.music_eof=False;self.paused=False
            self.position=position;self.deadline=deadline;self.deadline_hit=False

    def detach(self):
        with self.lock:
            self.music=None;self.music_buffer=b'';self.music_eof=False;self.paused=False;self.deadline=None;self.deadline_hit=False

    def set_deadline(self,value):
        with self.lock: self.deadline=value;self.deadline_hit=False

    def pause(self,value):
        with self.lock: self.paused=value

    def snapshot(self):
        with self.lock:
            return {'active':bool(self.sender and self.sender.poll() is None and not self.error),'microphone_online':self.mic_online,'microphone_error':self.mic_error,'microphone_dbfs':round(self.ducker.input_db,1),'ducking_active':self.ducker.active,'music_gain_db':round(20*math.log10(max(self.ducker.gain,1e-12)),1),'position':self.position,'music_eof':self.music_eof,'deadline_hit':self.deadline_hit,'error':self.error}

    def _music_block(self):
        if self.music is None or self.paused: return bytes(self.block_bytes)
        if self.deadline is not None and time.time()>=self.deadline:
            self.deadline_hit=True;return bytes(self.block_bytes)
        while len(self.music_buffer)<self.block_bytes and not self.music_eof:
            try: data=os.read(self.music.fileno(),self.block_bytes-len(self.music_buffer))
            except BlockingIOError: break
            if not data: self.music_eof=True;break
            self.music_buffer+=data
        size=min(len(self.music_buffer),self.block_bytes)//4*4
        data=self.music_buffer[:size];self.music_buffer=self.music_buffer[size:]
        self.position+=size/(4*self.rate)
        return data+bytes(self.block_bytes-size)

    def _pump(self):
        pending=b'';blocked_since=None;next_block=time.monotonic()
        try:
            while not self.stop.is_set():
                if self.sender.poll() is not None: raise OSError('Il trasmettitore Roc si è fermato')
                if not pending:
                    with self.lock:
                        mic=self.mic_queue.popleft() if self.mic_queue else bytes(self.block_bytes)
                        pending=self.ducker.mix(self._music_block(),mic)
                try:
                    count=os.write(self.sender.stdin.fileno(),pending)
                    pending=pending[count:];blocked_since=None
                except BlockingIOError:
                    blocked_since=blocked_since or time.monotonic()
                    if time.monotonic()-blocked_since>1: raise OSError('Trasmissione audio bloccata')
                    self.stop.wait(.002);continue
                if pending: continue
                next_block+=self.frames/self.rate
                if next_block<time.monotonic()-.1: next_block=time.monotonic()
                self.stop.wait(max(0,next_block-time.monotonic()))
        except (OSError,ValueError) as error:
            if not self.stop.is_set(): self.error=str(error)

    def _capture(self):
        while not self.stop.is_set():
            process=None
            try:
                listing=subprocess.run(['arecord','-l'],check=True,capture_output=True,text=True,timeout=4,env={**os.environ,'LC_ALL':'C'}).stdout
                card=next((re.search(r'card (\d+):\s*([^\s\[]+)',line) for line in listing.splitlines() if re.search('scarlett|focusrite',line,re.I)),None)
                if not card: raise OSError('Scarlett non rilevata; riconnessione automatica')
                device='plughw:CARD='+card.group(2)+',DEV=0'
                with tempfile.TemporaryFile() as log:
                    process=subprocess.Popen(['arecord','-q','-D',device,'-t','raw','-f','S16_LE','-r',str(self.rate),'-c','2','--period-time=10000','--buffer-time=80000'],stdout=subprocess.PIPE,stderr=log,bufsize=0)
                    self.capture=process;buffer=b''
                    while not self.stop.is_set():
                        data=process.stdout.read(self.block_bytes-len(buffer))
                        if not data: raise OSError('Ingresso microfono interrotto; riconnessione automatica')
                        buffer+=data
                        if len(buffer)==self.block_bytes:
                            with self.lock:
                                self.mic_queue.append(buffer);self.mic_online=True;self.mic_error=''
                            buffer=b''
            except (OSError,subprocess.SubprocessError) as error:
                with self.lock:
                    self.mic_online=False;self.mic_error=str(error);self.mic_queue.clear()
            finally:
                self.kill(process)
                if self.capture is process: self.capture=None
            self.stop.wait(2)
