#!/usr/bin/env python3
"""TX studio: one Roc sender, durable schedule, constrained USB explorer."""
import datetime as dt
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
    def __init__(self,config,media='/var/lib/roc-museum/media',state='/var/lib/roc-museum/studio',usb_root='/run/roc-museum-usb',copy_lock=None):
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

    def start(self):
        # Recover the physical input after an interrupted previous monitor process.
        self._live()
        self.thread=threading.Thread(target=self._worker,daemon=True);self.thread.start()

    def close(self):
        self.shutdown.set()
        if self.thread: self.thread.join(timeout=5)
        with self.lock:
            self._terminate();self.db.close()

    def _setting(self,key,default='false'):
        row=self.db.execute('SELECT value FROM settings WHERE key=?',(key,)).fetchone()
        return json.loads(row[0]) if row else json.loads(default)

    def _store_setting(self,key,value):
        self.db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(key,json.dumps(value)));self.db.commit()

    def _terminate(self):
        processes=[p for p in (self.encoder,self.sender) if p]
        for p in processes:
            if p.poll() is None: p.terminate()
        for p in processes:
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill();p.wait(timeout=3)
        self.encoder=None;self.sender=None
        if self.error_log: self.error_log.close();self.error_log=None

    def _live(self):
        self._terminate()
        run(['systemctl','start','roc-museum.service'])
        self.status='live';self.origin='mixer';self.position=0;self.track=None;self.duration=0

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

    def _play(self,name,position=0,origin='manual',loop=False):
        info=self.info(name)
        if not isinstance(position,(int,float)) or isinstance(position,bool) or not math.isfinite(position) or not 0<=position<info['duration']:
            raise ValueError('Posizione fuori dalla durata del brano')
        self._terminate()
        try:
            # Stop the live sender first: never send two different sources together.
            run(['systemctl','stop','roc-museum.service'])
            self.error_log=tempfile.TemporaryFile()
            self.encoder=subprocess.Popen(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-protocol_whitelist','file,pipe','-format_whitelist','wav,mp3,flac,ogg,mov,aac','-re','-ss',str(position),'-i',str(self.media/name),'-map','0:a:0','-threads','1','-vn','-ac','2','-ar',self.config.get('SAMPLE_RATE','44100'),'-c:a','pcm_s16le','-f','wav','pipe:1'],stdout=subprocess.PIPE,stderr=self.error_log)
            self.sender=subprocess.Popen(['roc-send','-i','file:-','--input-format','wav','-s','rtp://'+self.config.get('MULTICAST_ADDR','239.30.0.1')+':'+self.config.get('RTP_PORT','10001'),'--frame-len='+self.config.get('FRAME_LEN','4ms')],stdin=self.encoder.stdout,stdout=subprocess.DEVNULL,stderr=self.error_log)
            self.encoder.stdout.close()
        except Exception:
            self._live();raise
        self.track=name;self.duration=info['duration'];self.position=position;self.started=time.monotonic()
        self.status='playing';self.origin=origin;self.loop=loop;self.error=''

    def _position(self):
        return min(self.duration,self.position+(time.monotonic()-self.started if self.status=='playing' else 0))

    def command(self,data):
        with self.lock:
            command=data.get('command')
            if command=='automation':
                enabled=data.get('enabled')
                if type(enabled) is not bool: raise ValueError('Stato calendario non valido')
                if enabled and self.manual_hold: self._live()
                self._store_setting('enabled',enabled);self.manual_hold=False
                if not enabled:
                    self.queue=[]
                    if self.origin.startswith('calendar:'): self._live()
            elif command=='play':
                self._play(data.get('name'),origin='manual',loop=data.get('loop') is True);self.manual_hold=True
            elif command=='pause':
                if self.status!='playing': raise ValueError('Nessuna traccia in riproduzione')
                self.position=min(self._position(),max(0,self.duration-0.01));self._terminate();self.status='paused';self.manual_hold=True
            elif command=='resume':
                if self.status!='paused': raise ValueError('Nessuna traccia in pausa')
                self._play(self.track,self.position,'manual',self.loop);self.manual_hold=True
            elif command=='seek':
                if self.status not in ('playing','paused'): raise ValueError('Nessuna traccia selezionata')
                value=data.get('position');was_paused=self.status=='paused'
                self._play(self.track,value,'manual',self.loop);self.manual_hold=True
                if was_paused:
                    self.position=float(value);self._terminate();self.status='paused'
            elif command=='loop':
                if type(data.get('enabled')) is not bool: raise ValueError('Loop non valido')
                self.loop=data['enabled']
                if self.status in ('playing','paused'): self.manual_hold=True
            elif command=='stop':
                self._live();self.manual_hold=True
            else: raise ValueError('Comando player non valido')
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            rows=self.db.execute('SELECT event,occurrence,time,state,message FROM runs ORDER BY time DESC LIMIT 30').fetchall()
            return {'status':self.status,'track':self.track,'position':round(self._position(),2),'duration':self.duration,'loop':self.loop,'origin':self.origin,'error':self.error,'automation_enabled':self._setting('enabled'),'manual_hold':self.manual_hold,'queue':[e['name'] for e in self.queue],'timezone':'Europe/Rome','events':self.events(),'next_events':self.next_events(),'sender_running':bool(self.sender and self.sender.poll() is None),'history':[dict(zip(('event','occurrence','time','state','message'),r)) for r in rows]}

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
            track=audio_name(data.get('track'));self.info(track)
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
            event={'id':event_id,'name':name.strip(),'track':track,'start':start.isoformat(timespec='minutes'),'recurrence':recurrence,'weekdays':sorted(set(weekdays)),'policy':policy,'enabled':enabled}
            self.db.execute('INSERT OR REPLACE INTO schedules VALUES(?,?)',(event_id,json.dumps(event)));self.db.commit()
            self.queue=[e for e in self.queue if e['id']!=event_id]
            return event

    def delete_event(self,event_id):
        if not isinstance(event_id,str) or not re_id(event_id): raise ValueError('Identificativo evento non valido')
        with self.lock:
            self.db.execute('DELETE FROM schedules WHERE id=?',(event_id,));self.db.commit()
            self.queue=[e for e in self.queue if e['id']!=event_id]

    @staticmethod
    def occurrence(event,now):
        local=now.astimezone(ZoneInfo('Europe/Rome'))
        start=dt.datetime.fromisoformat(event['start'])
        if local.date()<start.date(): return None
        if event['recurrence']=='once' and local.date()!=start.date(): return None
        if event['recurrence']=='weekly' and local.weekday() not in event['weekdays']: return None
        if (local.hour,local.minute)!=(start.hour,start.minute): return None
        # Local occurrence identity intentionally ignores fold: once at fall DST.
        return local.strftime('%Y-%m-%dT%H:%M')

    def _record(self,event,occurrence,state,message=''):
        self.db.execute('INSERT OR REPLACE INTO runs VALUES(?,?,?,?,?)',(event['id'],occurrence,time.time(),state,message));self.db.commit()

    def _fire(self,event,occurrence):
        try:
            self._play(event['track'],origin='calendar:'+event['id'])
            self._record(event,occurrence,'started')
        except Exception as error:
            self.error=str(error);self._record(event,occurrence,'failed',str(error))

    def tick(self,now=None):
        with self.lock:
            now=now or dt.datetime.now(dt.timezone.utc)
            if self.status=='playing' and self.sender and self.sender.poll() is not None:
                good=self.sender.returncode==0 and self.encoder.wait(timeout=3)==0
                track=self.track;loop=self.loop;origin=self.origin
                if not good:
                    if self.error_log:
                        self.error_log.seek(0,2);length=self.error_log.tell();self.error_log.seek(max(0,length-2000));self.error=self.error_log.read().decode(errors='replace')
                    self._live()
                elif loop: self._play(track,origin=origin,loop=True)
                else: self._live()
            if not self._setting('enabled'): return
            for event in sorted(self.events(),key=lambda e:(e['start'],e['id'])):
                if not event['enabled']: continue
                occurrence=self.occurrence(event,now)
                if occurrence is None: continue
                with self.db:
                    cursor=self.db.execute('INSERT OR IGNORE INTO runs VALUES(?,?,?,?,?)',(event['id'],occurrence,time.time(),'claimed',''))
                if not cursor.rowcount: continue
                if self.manual_hold:
                    self._record(event,occurrence,'skipped','Regia manuale attiva');continue
                busy=self.status in ('playing','paused')
                if busy and event['policy']=='skip': self._record(event,occurrence,'skipped','Player occupato')
                elif busy and event['policy']=='wait':
                    event=dict(event,occurrence=occurrence,queued_at=now.timestamp());self.queue.append(event);self._record(event,occurrence,'waiting')
                else: self._fire(event,occurrence)
            for event in list(self.queue):
                if now.timestamp()-event['queued_at']>900:
                    self._record(event,event['occurrence'],'skipped','Attesa oltre 15 minuti');self.queue.remove(event)
            if not self.manual_hold and self.status=='live' and self.queue:
                event=self.queue.pop(0);self._fire(event,event['occurrence'])
            # Bound persistent history; old scheduled days cannot be replayed.
            with self.db: self.db.execute('DELETE FROM runs WHERE time<?',(time.time()-90*86400,))

    def _worker(self):
        while not self.shutdown.is_set():
            try: self.tick()
            except Exception as error:
                with self.lock: self.error=str(error)
            self.shutdown.wait(1)

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
