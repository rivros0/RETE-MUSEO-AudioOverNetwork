#!/usr/bin/env python3
"""TX studio: one Roc sender, durable schedule, constrained USB explorer."""
import datetime as dt
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from zoneinfo import ZoneInfo

AUDIO_EXTENSIONS={'.wav','.mp3','.flac','.ogg','.m4a','.aac'}
MAX_FILE=512*1024*1024
RESERVE=256*1024*1024


def run(argv, timeout=20):
    return subprocess.run(argv,check=True,capture_output=True,text=True,timeout=timeout)


def audio_name(name):
    if not isinstance(name,str) or not name or name.startswith('.') or len(name.encode())>200 or any(c in name for c in '/\\\0') or any(ord(c)<32 for c in name) or Path(name).suffix.lower() not in AUDIO_EXTENSIONS:
        raise ValueError('Nome audio non valido')
    return name


def confined_open(root, relative='', directory=False):
    """Walk with dir_fd and O_NOFOLLOW: symlinks can never escape the mount."""
    if not isinstance(relative,str) or relative.startswith('/') or any(p in ('.','..','') for p in relative.split('/') if relative):
        raise ValueError('Percorso USB non valido')
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        parts=relative.split('/') if relative else []
        for index,part in enumerate(parts):
            flags=os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK
            if index<len(parts)-1 or directory: flags|=os.O_DIRECTORY
            child=os.open(part,flags,dir_fd=fd)
            os.close(fd);fd=child
        mode=os.fstat(fd).st_mode
        if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
            raise ValueError('Tipo di file non consentito')
        return fd
    except BaseException:
        os.close(fd);raise


class Studio:
    def __init__(self,config,media='/var/lib/roc-museum/media',state='/var/lib/roc-museum/studio',usb_root='/run/roc-museum-usb',copy_lock=None,audio_factory=None,bus_marker="/run/roc-museum-bus"):
        self.config=config
        self.media=Path(media);self.state=Path(state);self.usb_root=Path(usb_root)
        self.media.mkdir(parents=True,exist_ok=True,mode=0o750)
        self.state.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.lock=threading.RLock();self.copy_lock=copy_lock or threading.Lock()
        self.db=sqlite3.connect(self.state/'calendar.sqlite',check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS schedules(id TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS runs(event TEXT, occurrence TEXT, time REAL, state TEXT, message TEXT, PRIMARY KEY(event,occurrence));
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);''')
        self.db.commit()
        self.encoder=None;self.sender=None;self.error_log=None
        self.track=None;self.duration=0;self.position=0;self.started=0;self.status='live';self.loop=False
        self.origin='mixer';self.error='';self.queue=[];self.manual_hold=False
        self.shutdown=threading.Event();self.metadata={};self.thread=None
        self.bus=None;self.audio_factory=audio_factory;self.plan=None;self.bus_marker=Path(bus_marker)
        self.resume_saved=0.;self.restore_thread=None

    def start(self):
        try:
            self._ensure_audio()
        except Exception as error:
            self.error=str(error)
            try: self._live(clear_resume=False)
            except Exception as fallback:
                self.error=str(error)+' · fallback live: '+str(fallback)
        self.thread=threading.Thread(target=self._worker,daemon=True);self.thread.start()
        # Never block dashboard startup while probing/decoding the saved track.
        self.restore_thread=threading.Thread(target=self._restore_after_start,daemon=True)
        self.restore_thread.start()

    def _restore_after_start(self):
        try:
            with self.lock:
                if self.shutdown.is_set(): return
                self._restore_playback_resume()
        except Exception as error:
            with self.lock:
                self.error='Ripristino player non riuscito: '+str(error)

    def close(self):
        self.shutdown.set()
        if self.thread: self.thread.join(timeout=5)
        if self.restore_thread and self.restore_thread is not threading.current_thread():
            self.restore_thread.join(timeout=5)
        with self.lock:
            if self.status in ('playing','paused') and self.origin=='manual':
                self._save_playback_resume(force=True)
            self._terminate()
            if self.bus: self.bus.close();self.bus=None
            self.bus_marker.unlink(missing_ok=True)
            self.sender=None;self.db.close()

    def ducking(self):
        return self._setting('ducking','{"enabled":true,"threshold_db":-36,"reduction_db":-18}')

    def _ensure_audio(self):
        if self.bus and self.bus.snapshot()['active']: return
        if self.bus: self.bus.close();self.bus=None
        run(['systemctl','stop','roc-museum.service'])
        try:
            if self.audio_factory is None:
                spec=importlib.util.spec_from_file_location('museum_audio_bus',Path(__file__).with_name('audio_bus.py'))
                module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
                factory=module.AudioBus
            else: factory=self.audio_factory
            # The audio unit stays active as a coordinator; on monitor death it
            # automatically resumes the original ALSA microphone path.
            fd=os.open(self.bus_marker,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as marker: marker.write(str(os.getpid())+'\n')
            bus=factory(self.config);bus.configure(self.ducking());bus.set_volume(self._setting("music_volume","100"),self._setting("music_muted"));bus.start()
            self.bus=bus;self.sender=bus.sender
            run(['systemctl','start','roc-museum.service'])
        except Exception:
            if self.bus: self.bus.close();self.bus=None
            self.sender=None;self.bus_marker.unlink(missing_ok=True)
            run(['systemctl','start','roc-museum.service']);raise

    def _setting(self,key,default='false'):
        row=self.db.execute('SELECT value FROM settings WHERE key=?',(key,)).fetchone()
        return json.loads(row[0]) if row else json.loads(default)

    def _store_setting(self,key,value):
        self.db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(key,json.dumps(value)));self.db.commit()

    def _clear_playback_resume(self):
        self._store_setting('resume_playback',None)
        self.resume_saved=0.

    def _save_playback_resume(self,force=False):
        now=time.time()
        if not force and now-self.resume_saved<2:
            return
        if self.status not in ('playing','paused') or self.origin!='manual' or not self.track:
            return
        state={'status':self.status,'track':self.track,'position':round(self._position(),2),
               'loop':bool(self.loop),'manual_hold':bool(self.manual_hold),'saved_at':now}
        self._store_setting('resume_playback',state)
        self.resume_saved=now

    def _restore_playback_resume(self):
        state=self._setting('resume_playback','null')
        if not isinstance(state,dict):
            return False
        try:
            status=state.get('status')
            track=audio_name(state.get('track'))
            position=state.get('position')
            loop=state.get('loop')
            if status not in ('playing','paused') or type(loop) is not bool:
                raise ValueError('Stato player salvato non valido')
            if type(position) not in (int,float) or isinstance(position,bool) or not math.isfinite(position) or position<0:
                raise ValueError('Posizione player salvata non valida')
            info=self.info(track)
            if position>=info['duration']:
                if loop:
                    position=0.
                else:
                    self._clear_playback_resume()
                    return False
            self._play(track,position,origin='manual',loop=loop,persist=False)
            self.manual_hold=bool(state.get('manual_hold',True))
            if status=='paused':
                self.bus.pause(True);self.status='paused';self.position=position
            self._save_playback_resume(force=True)
            return True
        except (OSError,ValueError,subprocess.SubprocessError) as error:
            self.error='Ripristino player non riuscito: '+str(error)
            self._clear_playback_resume()
            return False

    def _terminate(self):
        if self.bus: self.bus.detach()
        if self.encoder:
            if self.encoder.poll() is None: self.encoder.terminate()
            try: self.encoder.wait(timeout=3)
            except subprocess.TimeoutExpired: self.encoder.kill();self.encoder.wait(timeout=3)
            if self.encoder.stdout: self.encoder.stdout.close()
        self.encoder=None
        if self.error_log: self.error_log.close();self.error_log=None

    def _live(self,clear_resume=True):
        self._terminate();self.plan=None
        if not self.bus or not self.bus.snapshot()['active']:
            if self.bus: self.bus.close();self.bus=None
            self.sender=None;self.bus_marker.unlink(missing_ok=True)
            run(['systemctl','start','roc-museum.service'])
        self.status='live';self.origin='mixer';self.position=0;self.track=None;self.duration=0
        if clear_resume: self._clear_playback_resume()

    def delete_media(self,name):
        name=audio_name(name)
        if not self.copy_lock.acquire(blocking=False): raise ValueError('Attendere il completamento della copia')
        try:
            with self.lock:
                if name==self.track or self.plan and name in self.plan['tracks']:
                    raise ValueError('Traccia in uso: fermare prima il player')
                for event in self.events():
                    if name in event.get('tracks',[event['track']]):
                        raise ValueError('Traccia utilizzata dall’evento: '+event['name']+'. Modificare o eliminare prima l’evento.')
                fd=confined_open(self.media,name);os.close(fd)
                (self.media/name).unlink()
                self.metadata={k:v for k,v in self.metadata.items() if k[0]!=name}
                return {'ok':True,'message':'Traccia eliminata','name':name}
        finally: self.copy_lock.release()

    def info(self,name):
        name=audio_name(name);path=self.media/name
        fd=confined_open(self.media,name)
        os.close(fd)
        key=(name,path.stat().st_size,path.stat().st_mtime_ns)
        if key not in self.metadata:
            data=json.loads(run(['ffprobe','-v','error','-protocol_whitelist','file,pipe','-format_whitelist','wav,mp3,flac,ogg,mov,aac','-select_streams','a:0','-show_entries','stream=codec_type:format=duration','-of','json',str(path)]).stdout)
            duration=float(data.get('format',{}).get('duration',0))
            if not data.get('streams') or not math.isfinite(duration) or duration<=0:
                raise ValueError('File senza traccia audio o durata valida')
            self.metadata[key]={'name':name,'duration':round(duration,3),'size':path.stat().st_size}
        return dict(self.metadata[key])

    def library(self):
        result=[]
        for p in sorted(self.media.iterdir()):
            if p.is_file() and not p.is_symlink() and p.suffix.lower() in AUDIO_EXTENSIONS and not p.name.startswith('.'):
                result.append({'name':p.name,'size':p.stat().st_size})
        return result

    def _play(self,name,position=0,origin='manual',loop=False,deadline=None,persist=True):
        info=self.info(name)
        if not isinstance(position,(int,float)) or isinstance(position,bool) or not math.isfinite(position) or not 0<=position<info['duration']:
            raise ValueError('Posizione fuori dalla durata del brano')
        self._ensure_audio();self._terminate()
        try:
            self.error_log=tempfile.TemporaryFile()
            self.encoder=subprocess.Popen(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-protocol_whitelist','file,pipe','-format_whitelist','wav,mp3,flac,ogg,mov,aac','-ss',str(position),'-i',str(self.media/name),'-map','0:a:0','-threads','1','-vn','-ac','2','-ar',self.config.get('SAMPLE_RATE','44100'),'-c:a','pcm_s16le','-f','s16le','pipe:1'],stdout=subprocess.PIPE,stderr=self.error_log,bufsize=0)
            self.bus.attach(self.encoder.stdout,position,deadline)
        except Exception:
            self._live();raise
        self.track=name;self.duration=info['duration'];self.position=position;self.started=time.monotonic()
        self.status='playing';self.origin=origin;self.loop=loop;self.error=''
        if persist and origin=='manual': self._save_playback_resume(force=True)

    def _position(self):
        if self.bus and self.status in ('playing','paused'): return min(self.duration,self.bus.snapshot()['position'])
        return self.position

    def _cancel_plan(self,state='interrupted'):
        if self.plan:
            self._record(self.plan['event'],self.plan['occurrence'],state)
            if self.bus: self.bus.set_deadline(None)
            self.plan=None

    def command(self,data):
        with self.lock:
            command=data.get('command')
            if command=='music_volume':
                value=data.get('value')
                if type(value) is not int or not 0<=value<=100: raise ValueError('Volume musica: valore intero tra 0 e 100')
                self._store_setting('music_volume',value)
                if value>0: self._store_setting('music_muted',False)
                if self.bus: self.bus.set_volume(value,self._setting('music_muted'))
            elif command=='music_muted':
                enabled=data.get('enabled')
                if type(enabled) is not bool: raise ValueError('Mute musica non valido')
                self._store_setting('music_muted',enabled)
                if self.bus: self.bus.set_volume(self._setting('music_volume','100'),enabled)
            elif command=='ducking':
                settings={k:data.get(k,v) for k,v in self.ducking().items()}
                if type(settings['enabled']) is not bool: raise ValueError('Ducking non valido')
                for key,low,high in (('threshold_db',-60,-6),('reduction_db',-40,0)):
                    value=settings[key]
                    if type(value) not in (int,float) or not math.isfinite(value) or not low<=value<=high: raise ValueError('Parametro ducking non valido')
                self._store_setting('ducking',settings)
                if self.bus: self.bus.configure(settings)
            elif command=='automation':
                enabled=data.get('enabled')
                if type(enabled) is not bool: raise ValueError('Stato calendario non valido')
                if enabled and self.manual_hold: self._live()
                self._store_setting('enabled',enabled);self.manual_hold=False
                if not enabled:
                    self.queue=[]
                    if self.plan or self.origin.startswith('calendar:'):
                        self._cancel_plan('suspended');self._live()
            elif command=='play':
                # Validate before interrupting an existing programme.
                self.info(data.get('name'))
                self._cancel_plan('suspended')
                self._play(data.get('name'),origin='manual',loop=data.get('loop') is True);self.manual_hold=True
            elif command=='pause':
                if self.status!='playing': raise ValueError('Nessuna traccia in riproduzione')
                self.position=self._position();self.bus.pause(True);self.status='paused';self.manual_hold=True
                self._cancel_plan('suspended');self.origin='manual';self._save_playback_resume(force=True)
            elif command=='resume':
                if self.status!='paused': raise ValueError('Nessuna traccia in pausa')
                self.bus.pause(False);self.status='playing';self.origin='manual';self.manual_hold=True
                self._save_playback_resume(force=True)
            elif command=='seek':
                if self.status not in ('playing','paused'): raise ValueError('Nessuna traccia selezionata')
                value=data.get('position');was_paused=self.status=='paused'
                # _play validates position before changing the decoder.
                self._play(self.track,value,'manual',self.loop);self.manual_hold=True
                self._cancel_plan('suspended')
                if was_paused:
                    self.bus.pause(True);self.status='paused';self._save_playback_resume(force=True)
            elif command=='loop':
                if type(data.get('enabled')) is not bool: raise ValueError('Loop non valido')
                self.loop=data['enabled']
                if self.status in ('playing','paused'):
                    self._cancel_plan('suspended');self.manual_hold=True;self.origin='manual'
                    self._save_playback_resume(force=True)
            elif command=='stop':
                self._cancel_plan('suspended');self._live();self.manual_hold=True
            else: raise ValueError('Comando player non valido')
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            rows=self.db.execute('SELECT event,occurrence,time,state,message FROM runs ORDER BY time DESC LIMIT 30').fetchall()
            return {'status':self.status,'track':self.track,'position':round(self._position(),2),'duration':self.duration,'loop':self.loop,'origin':self.origin,'error':self.error,'automation_enabled':self._setting('enabled'),'manual_hold':self.manual_hold,'queue':[e['name'] for e in self.queue],'timezone':'Europe/Rome','events':self.events(),'next_events':self.next_events(),'sender_running':bool(self.sender and self.sender.poll() is None),'audio_bus':self.bus.snapshot() if self.bus else None,'ducking':self.ducking(),'music_volume':self._setting('music_volume','100'),'music_muted':self._setting('music_muted'),'system_time':dt.datetime.now(ZoneInfo('Europe/Rome')).isoformat(),'plan':{k:v for k,v in self.plan.items() if k!='event'} if self.plan else None,'history':[dict(zip(('event','occurrence','time','state','message'),r)) for r in rows]}

    def events(self):
        with self.lock:
            return [json.loads(row[0]) for row in self.db.execute('SELECT data FROM schedules ORDER BY id')]

    def next_events(self,now=None):
        now=now or dt.datetime.now(dt.timezone.utc)
        zone=ZoneInfo('Europe/Rome');today=now.astimezone(zone).date();result=[]
        for event in self.events():
            if not event['enabled']: continue
            start=dt.datetime.fromisoformat(event['start'])
            day=max(today,start.date())
            for offset in range(8):
                date=day+dt.timedelta(days=offset)
                if event['recurrence']=='once' and date!=start.date(): continue
                if event['recurrence']=='weekly' and date.weekday() not in event['weekdays']: continue
                candidate=dt.datetime.combine(date,start.time(),zone)
                # Nonexistent spring DST times are skipped; ambiguous fall times run once.
                if candidate.astimezone(dt.timezone.utc).astimezone(zone).replace(tzinfo=None)!=candidate.replace(tzinfo=None): continue
                key=candidate.strftime('%Y-%m-%dT%H:%M')
                claimed=self.db.execute('SELECT 1 FROM runs WHERE event=? AND occurrence=?',(event['id'],key)).fetchone()
                if candidate.astimezone(dt.timezone.utc)>=now and not claimed:
                    result.append({'id':event['id'],'name':event['name'],'at':candidate.isoformat()});break
        return sorted(result,key=lambda e:e['at'])[:5]

    def save_event(self,data):
        with self.lock:
            if not isinstance(data,dict): raise ValueError('Evento non valido')
            name=data.get('name','')
            if not isinstance(name,str) or not 1<=len(name.strip())<=100: raise ValueError('Titolo evento obbligatorio (max 100 caratteri)')
            tracks=data.get('tracks',[data.get('track')])
            if not isinstance(tracks,list) or not 1<=len(tracks)<=100: raise ValueError('Scegliere da 1 a 100 tracce nel gruppo')
            tracks=[audio_name(track) for track in tracks]
            for track in tracks: self.info(track)
            track=tracks[0]
            end_time=data.get('end_time','')
            if not isinstance(end_time,str): raise ValueError('Orario di fine non valido')
            if end_time:
                try:
                    end=dt.time.fromisoformat(end_time)
                    if end.tzinfo or end.second or end.microsecond or len(end_time)!=5: raise ValueError()
                except (ValueError,TypeError): raise ValueError('Orario di fine non valido')
            repetitions=data.get('repetitions',1);interval=data.get('interval_seconds',0)
            if type(repetitions) is not int or not 0<=repetitions<=10000: raise ValueError('Passaggi gruppo: da 0 a 10000')
            if repetitions==0 and not end_time: raise ValueError('La ripetizione continua richiede un orario di fine')
            if type(interval) is not int or not 0<=interval<=86400: raise ValueError('Intervallo non valido (0–86400 secondi)')
            try:
                start=dt.datetime.fromisoformat(data.get('start',''))
                if start.tzinfo or start.second or start.microsecond: raise ValueError()
            except (ValueError,TypeError): raise ValueError('Data e ora locali non valide: precisione al minuto')
            recurrence=data.get('recurrence','once');policy=data.get('policy','skip')
            if recurrence not in ('once','daily','weekly') or policy not in ('interrupt','wait','skip'): raise ValueError('Ricorrenza o priorità non valida')
            weekdays=data.get('weekdays',[start.weekday()])
            if not isinstance(weekdays,list) or not weekdays or any(type(day) is not int or not 0<=day<=6 for day in weekdays): raise ValueError('Giorni settimanali non validi')
            enabled=data.get('enabled',True)
            if type(enabled) is not bool: raise ValueError('Abilitazione non valida')
            event_id=data.get('id') or uuid.uuid4().hex
            if not isinstance(event_id,str) or not re_id(event_id): raise ValueError('Identificativo evento non valido')
            if data.get('id') and not self.db.execute('SELECT 1 FROM schedules WHERE id=?',(event_id,)).fetchone(): raise ValueError('Evento non trovato')
            if not data.get('id') and self.db.execute('SELECT count(*) FROM schedules').fetchone()[0]>=200: raise ValueError('Massimo 200 eventi')
            event={'id':event_id,'name':name.strip(),'track':track,'start':start.isoformat(timespec='minutes'),'recurrence':recurrence,'weekdays':sorted(set(weekdays)),'policy':policy,'enabled':enabled,'tracks':tracks,'end_time':end_time,'repetitions':repetitions,'interval_seconds':interval}
            self.db.execute('INSERT OR REPLACE INTO schedules VALUES(?,?)',(event_id,json.dumps(event)));self.db.commit()
            self.queue=[e for e in self.queue if e['id']!=event_id]
            if self.plan and self.plan['event']['id']==event_id:
                self._cancel_plan('interrupted');self._live()
            return event

    def delete_event(self,event_id):
        if not isinstance(event_id,str) or not re_id(event_id): raise ValueError('Identificativo evento non valido')
        with self.lock:
            if self.plan and self.plan['event']['id']==event_id:
                self._cancel_plan('cancelled');self._live()
            self.db.execute('DELETE FROM schedules WHERE id=?',(event_id,));self.db.commit()
            self.queue=[e for e in self.queue if e['id']!=event_id]

    @staticmethod
    def window(event,now):
        if not event.get('end_time'): return None
        zone=ZoneInfo('Europe/Rome');local=now.astimezone(zone);start=dt.datetime.fromisoformat(event['start'])
        for date in (local.date(),local.date()-dt.timedelta(days=1)):
            if date<start.date(): continue
            if event['recurrence']=='once' and date!=start.date(): continue
            if event['recurrence']=='weekly' and date.weekday() not in event['weekdays']: continue
            begin=dt.datetime.combine(date,start.time(),zone)
            if begin.astimezone(dt.timezone.utc).astimezone(zone).replace(tzinfo=None)!=begin.replace(tzinfo=None): continue
            end=dt.datetime.combine(date,dt.time.fromisoformat(event['end_time']),zone)
            if end<=begin: end+=dt.timedelta(days=1)
            if begin.timestamp()<=now.timestamp()<end.timestamp(): return begin,end
        return None

    @staticmethod
    def occurrence(event,now):
        if event.get('end_time'):
            window=Studio.window(event,now)
            return window[0].strftime('%Y-%m-%dT%H:%M') if window else None
        local=now.astimezone(ZoneInfo('Europe/Rome'));start=dt.datetime.fromisoformat(event['start'])
        if local.date()<start.date(): return None
        if event['recurrence']=='once' and local.date()!=start.date(): return None
        if event['recurrence']=='weekly' and local.weekday() not in event['weekdays']: return None
        if (local.hour,local.minute)!=(start.hour,start.minute): return None
        return local.strftime('%Y-%m-%dT%H:%M')

    def _record(self,event,occurrence,state,message=''):
        self.db.execute('INSERT OR REPLACE INTO runs VALUES(?,?,?,?,?)',(event['id'],occurrence,time.time(),state,message));self.db.commit()

    def _fire(self,event,occurrence,now=None):
        now=now or dt.datetime.now(dt.timezone.utc)
        window=self.window(event,now)
        if event.get('end_time') and not window:
            self._record(event,occurrence,'skipped','Fascia terminata');return
        self._cancel_plan()
        plan={'event':event,'event_id':event['id'],'occurrence':occurrence,'tracks':event.get('tracks',[event['track']]),'index':0,'cycle':1,'repetitions':event.get('repetitions',1),'interval_seconds':event.get('interval_seconds',0),'next_at':None,'end_at':window[1].timestamp() if window else None}
        try:
            self._play(plan['tracks'][0],origin='calendar:'+event['id'],deadline=plan['end_at'])
            self.plan=plan
            self.queue=[e for e in self.queue if e['id']!=event['id']]
            self._record(event,occurrence,'started')
        except Exception as error:
            self.error=str(error);self.plan=None;self._record(event,occurrence,'failed',str(error))

    def _next_track(self,now):
        plan=self.plan
        plan['index']+=1
        if plan['index']>=len(plan['tracks']):
            if plan['repetitions'] and plan['cycle']>=plan['repetitions']:
                self._record(plan['event'],plan['occurrence'],'completed');self._live();return
            plan['index']=0;plan['cycle']+=1
            if plan['interval_seconds']:
                self._terminate();self.status='live';self.track=None;self.duration=0;self.position=0
                plan['next_at']=now.timestamp()+plan['interval_seconds'];return
        self._play(plan['tracks'][plan['index']],origin='calendar:'+plan['event_id'],deadline=plan['end_at'])

    def tick(self,now=None):
        with self.lock:
            now=now or dt.datetime.now(dt.timezone.utc)
            if self.bus and not self.bus.snapshot()['active']:
                self.error=self.bus.snapshot()['error'] or 'Bus audio non disponibile'
                self._cancel_plan('failed');self._live()
            if self.plan and self.plan['end_at'] is not None and now.timestamp()>=self.plan['end_at']:
                self._record(self.plan['event'],self.plan['occurrence'],'completed','Fine fascia');self._live()
            if self.plan and self.plan['next_at'] is not None and now.timestamp()>=self.plan['next_at']:
                self.plan['next_at']=None
                try: self._play(self.plan['tracks'][self.plan['index']],origin='calendar:'+self.plan['event_id'],deadline=self.plan['end_at'])
                except (OSError,ValueError,subprocess.SubprocessError) as error:
                    self.error=str(error);self._cancel_plan('failed');self._live()
            if self.status=='playing' and self.bus and self.bus.snapshot()['music_eof'] and self.encoder and self.encoder.poll() is not None:
                if self.encoder.returncode!=0:
                    self.error='Decodifica audio fallita';self._cancel_plan('failed');self._live()
                elif self.plan:
                    try: self._next_track(now)
                    except (OSError,ValueError,subprocess.SubprocessError) as error:
                        self.error=str(error);self._cancel_plan('failed');self._live()
                elif self.loop: self._play(self.track,origin=self.origin,loop=True)
                else: self._live()
            self._save_playback_resume()
            if not self._setting('enabled'): return
            for event in sorted(self.events(),key=lambda e:(e['start'],e['id'])):
                if not event['enabled']: continue
                occurrence=self.occurrence(event,now)
                if occurrence is None: continue
                row=self.db.execute('SELECT state FROM runs WHERE event=? AND occurrence=?',(event['id'],occurrence)).fetchone()
                busy=self.status in ('playing','paused') or self.plan is not None
                if row:
                    # An active background window can restart after a monitor restart or manual override.
                    if event.get('end_time') and row[0] in ('started','interrupted','suspended') and not busy and not self.manual_hold:
                        self._fire(event,occurrence,now)
                    continue
                if self.manual_hold and event.get('end_time'): continue
                with self.db:
                    cursor=self.db.execute('INSERT OR IGNORE INTO runs VALUES(?,?,?,?,?)',(event['id'],occurrence,time.time(),'claimed',''))
                if not cursor.rowcount: continue
                if self.manual_hold:
                    self._record(event,occurrence,'skipped','Regia manuale attiva');continue
                if busy and event['policy']=='skip': self._record(event,occurrence,'skipped','Player occupato')
                elif busy and event['policy']=='wait':
                    self.queue.append(dict(event,occurrence=occurrence,queued_at=now.timestamp()));self._record(event,occurrence,'waiting')
                else: self._fire(event,occurrence,now)
            for event in list(self.queue):
                expired=now.timestamp()-event['queued_at']>900 or event.get('end_time') and not self.window(event,now)
                if expired:
                    self._record(event,event['occurrence'],'skipped','Attesa scaduta o fascia terminata');self.queue.remove(event)
            if not self.manual_hold and self.status=='live' and not self.plan and self.queue:
                event=self.queue.pop(0);self._fire(event,event['occurrence'],now)
            with self.db: self.db.execute('DELETE FROM runs WHERE time<?',(time.time()-90*86400,))

    def _worker(self):
        while not self.shutdown.is_set():
            try: self.tick()
            except Exception as error:
                with self.lock: self.error=str(error)
            self.shutdown.wait(.1)

    def devices(self):
        tree=json.loads(run(['lsblk','--json','--paths','--output','NAME,PATH,TYPE,TRAN,RM,FSTYPE,LABEL,MOUNTPOINTS']).stdout)
        result=[]
        def walk(node,usb=False):
            usb=usb or node.get('tran')=='usb'
            mounts=[m for m in (node.get('mountpoints') or []) if m]
            if usb and node.get('fstype') in ('vfat','exfat','ntfs','ntfs3','ext4','ext3','ext2','iso9660') and node.get('type') in ('part','disk'):
                path=node.get('path',node['name'])
                allowed=all(m.startswith(('/media/','/run/media/',str(self.usb_root)+'/')) for m in mounts)
                if allowed and path.startswith('/dev/') and Path(path).name.replace('-','').replace('_','').isalnum():
                    result.append({'id':Path(path).name,'device':path,'label':node.get('label') or Path(path).name,'filesystem':node['fstype'],'mount':mounts[0] if mounts else None})
            for child in node.get('children',[]): walk(child,usb)
        def system_disk(node):
            if any(m and not m.startswith(('/media/','/run/media/',str(self.usb_root)+'/')) for m in (node.get('mountpoints') or [])): return True
            return any(system_disk(child) for child in node.get('children',[]))
        for node in tree.get('blockdevices',[]):
            if not system_disk(node): walk(node)
        return result

    def _device(self,device_id):
        matches=[d for d in self.devices() if d['id']==device_id]
        if not matches: raise ValueError('Pennetta non presente o dispositivo non consentito')
        return matches[0]

    def mount(self,device_id):
        with self.lock:
            device=self._device(device_id)
            if device['mount']: return device['mount']
            self.usb_root.mkdir(parents=True,exist_ok=True,mode=0o700)
            target=self.usb_root/device['id'];target.mkdir(exist_ok=True,mode=0o700)
            if target.is_symlink(): raise ValueError('Punto di montaggio non valido')
            run(['mount','-o','ro,nosuid,nodev,noexec','--',device['device'],str(target)])
            return str(target)

    def browse(self,device_id,relative=''):
        with self.lock:
            root=self.mount(device_id);fd=confined_open(root,relative,directory=True)
            try:
                entries=[]
                with os.scandir(fd) as iterator:
                    for entry in iterator:
                        if entry.name.startswith('.') or entry.is_symlink(): continue
                        if len(entries)>=2000: raise ValueError('Cartella troppo grande: organizzare i file in sottocartelle')
                        if entry.is_dir(follow_symlinks=False): entries.append({'name':entry.name,'directory':True})
                        elif entry.is_file(follow_symlinks=False) and Path(entry.name).suffix.lower() in AUDIO_EXTENSIONS:
                            entries.append({'name':entry.name,'directory':False,'size':entry.stat(follow_symlinks=False).st_size})
                return {'device':device_id,'path':relative,'entries':sorted(entries,key=lambda e:(not e['directory'],e['name'].casefold()))}
            finally: os.close(fd)

    def import_usb(self,device_id,relative):
        if not self.copy_lock.acquire(blocking=False): raise ValueError('Un caricamento è già in corso')
        temporary=None;fd=None
        try:
            with self.lock:
                root=self.mount(device_id);fd=confined_open(root,relative)
            name=audio_name(Path(relative).name);size=os.fstat(fd).st_size
            if not 0<size<=MAX_FILE: raise ValueError('Massimo 512 MB per file')
            if shutil.disk_usage(self.media).free<size+RESERVE: raise ValueError('Spazio insufficiente sul TX')
            if (self.media/name).exists(): raise ValueError('Nome già presente in libreria')
            out,temporary=tempfile.mkstemp(prefix='.upload-',dir=self.media)
            with os.fdopen(out,'wb') as target:
                remaining=size
                while remaining:
                    chunk=os.read(fd,min(remaining,1024*1024))
                    if not chunk: raise ValueError('Pennetta rimossa o file incompleto')
                    target.write(chunk);remaining-=len(chunk)
                target.flush();os.fsync(target.fileno())
            os.link(temporary,self.media/name)
            return {'name':name,'size':size}
        finally:
            if fd is not None: os.close(fd)
            if temporary and os.path.exists(temporary): os.unlink(temporary)
            self.copy_lock.release()

    def eject(self,device_id):
        if not self.copy_lock.acquire(blocking=False): raise ValueError('Attendere il completamento del caricamento')
        try:
            with self.lock:
                device=self._device(device_id)
                if device['mount']:
                    if not device['mount'].startswith(str(self.usb_root)+'/'):
                        raise ValueError('Pennetta montata dal sistema: espellerla dal sistema operativo')
                    run(['umount','--',device['mount']])
        finally: self.copy_lock.release()


def re_id(value):
    return len(value)==32 and all(c in '0123456789abcdef' for c in value)
