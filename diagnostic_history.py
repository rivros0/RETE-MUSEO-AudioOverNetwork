"""TX-only persistent incident history; never carries PCM or runs on RX."""
import hashlib
import json
from pathlib import Path
import sqlite3
import threading
import time


class History:
    def __init__(self, path='/var/lib/roc-museum/diagnostic-history.sqlite3', limit=1000):
        self.path=Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.limit=limit
        self.lock=threading.Lock()
        self.active={}
        self.error=''
        with self.connection() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY, identity TEXT UNIQUE, node TEXT NOT NULL,
                source TEXT NOT NULL, code TEXT NOT NULL, severity TEXT NOT NULL,
                summary TEXT NOT NULL, started_at REAL NOT NULL, last_seen REAL NOT NULL,
                ended_at REAL, observations INTEGER NOT NULL, details TEXT NOT NULL,
                resolution TEXT NOT NULL DEFAULT '')''')
            # A restart is a gap in observation, not evidence of recovery.
            db.execute("UPDATE events SET ended_at=last_seen, resolution='monitor_restart' WHERE ended_at IS NULL")

    def connection(self):
        # Explicit close as well as commit; sqlite's context manager alone doesn't close.
        class Transaction:
            def __enter__(inner):
                inner.db=sqlite3.connect(self.path,timeout=1)
                return inner.db
            def __exit__(inner,kind,error,tb):
                try:
                    if kind is None: inner.db.commit()
                    else: inner.db.rollback()
                finally: inner.db.close()
        return Transaction()

    @staticmethod
    def issues(node):
        name=str(node.get('name','?'))[:128]
        if not node.get('online',True):
            return [(name,'node','OFFLINE','warning','Nodo offline',{})]
        issues=[]
        digital=node.get('transport_diagnosis') or node.get('audio_diagnosis') or {}
        if digital.get('severity') in ('warning','critical') or digital.get('code')=='TX_MONITOR_STALL_UNCONFIRMED':
            issues.append((name,'transport',str(digital.get('code','UNKNOWN'))[:100],
                           digital['severity'],str(digital.get('summary',''))[:600],
                           {'detail':str(digital.get('detail',''))[:1200],
                            'rtp':node.get('audio_meter',{}).get('integrity',{}),
                            'power':node.get('throttled'), 'network':node.get('network',{})}))
        waveform=node.get('waveform_diagnostics') or {}
        waveform_faults=('dropout','mismatch','missing_return','missing_channel','possible_channel_swap',
                         'return_clipping','reference_gaps','delay_jump','reference_timeout','capture_interrupted','error')
        if waveform.get('confirmed') or waveform.get('status') in waveform_faults:
            issues.append((name,'waveform',str(waveform.get('status','unknown'))[:100],
                           'warning' if waveform.get('confirmed') else 'info',
                           (('' if waveform.get('confirmed') else 'Osservazione da confermare: ')+str(waveform.get('message','')))[:600],
                           {k:waveform[k] for k in ('confirmed','estimated_delay_ms','delay_change_ms','channels','rtp',
                                                   'reference_coverage','confidence') if k in waveform}))
        analog=node.get('analog_return') or {}
        if analog.get('status') in ('missing_return','capture_clipping','audio_while_muted','unexpected_audio'):
            # A recent aligned comparison takes precedence over a stale level meter.
            if waveform.get('status') in (None,'unavailable','error') or analog['status'] in ('capture_clipping','audio_while_muted'):
                issues.append((name,'analog',analog['status'],'warning',str(analog.get('message',''))[:600],
                               {'channels':analog.get('channels',[])}))
        for key in ('roc_last_error','roc_last_warning'):
            message=str(node.get(key) or '')[:1200]
            if message:
                code=hashlib.sha256(message.encode()).hexdigest()[:16]
                issues.append((name,key,code,'warning',message,{}))
        return issues

    @staticmethod
    def details(value):
        encoded=json.dumps(value,ensure_ascii=False,allow_nan=False)
        # Bound untrusted heartbeat data before storing it.
        if len(encoded)>6000:
            encoded=json.dumps({'excerpt':encoded[:5500],'truncated':True},ensure_ascii=False)
        return encoded

    def observe(self, nodes, now=None):
        now=time.time() if now is None else now
        with self.lock:
            active=dict(self.active)
            current=set()
            offline={str(node.get('name','?'))[:128] for node in nodes if not node.get('online',True)}
            present={str(node.get('name','?'))[:128] for node in nodes}
            with self.connection() as db:
                for node in nodes:
                    for name,source,code,severity,summary,detail in self.issues(node):
                        key=(name,source,code)
                        current.add(key)
                        encoded=self.details(detail)
                        if key in active:
                            db.execute('''UPDATE events SET last_seen=?, observations=observations+1, details=?,
                                       summary=CASE WHEN severity IN ('warning','critical') AND ?='info' THEN summary ELSE ? END,
                                       severity=CASE WHEN severity='critical' OR (severity='warning' AND ?='info') THEN severity ELSE ? END
                                       WHERE id=?''',(now,encoded,severity,summary,severity,severity,active[key]))
                        else:
                            cursor=db.execute('''INSERT INTO events
                                (node,source,code,severity,summary,started_at,last_seen,observations,details)
                                VALUES (?,?,?,?,?,?,?,1,?)''',(name,source,code,severity,summary,now,now,encoded))
                            active[key]=cursor.lastrowid
                    # RX sends only its most recent evidence: persist it even if status recovered.
                    for artifact in (node.get('waveform_diagnostics') or {}).get('events',[])[:1]:
                        path=str(artifact.get('path',''))[:512]
                        if not path: continue
                        name=str(node.get('name','?'))[:128]
                        identity=hashlib.sha256((name+'\0'+path).encode()).hexdigest()
                        db.execute('''INSERT OR IGNORE INTO events
                            (identity,node,source,code,severity,summary,started_at,last_seen,ended_at,observations,details,resolution)
                            VALUES (?,?,?,?,?,?,?,?,?,1,?,?)''',
                            (identity,name,'evidence',str(artifact.get('status','unknown'))[:100],'warning',
                             'Evidenza audio salvata sulla RX',now,now,now,
                             self.details({'path':path,'rx_triggered_at':artifact.get('triggered_at')}),'artifact'))
                for key in list(active):
                    if key not in current:
                        resolution='node_offline' if key[0] in offline else ('observation_lost' if key[0] not in present else 'recovered')
                        db.execute('UPDATE events SET ended_at=?, resolution=? WHERE id=?',(now,resolution,active.pop(key)))
                db.execute('DELETE FROM events WHERE ended_at IS NOT NULL AND ended_at<?',(now-30*86400,))
                db.execute('''DELETE FROM events WHERE ended_at IS NOT NULL AND id NOT IN
                    (SELECT id FROM events ORDER BY id DESC LIMIT ?)''',(self.limit,))
            self.active=active
            self.error=''

    def query(self, node=None, limit=100):
        limit=max(1,min(1000,int(limit)))
        with self.lock, self.connection() as db:
            db.row_factory=sqlite3.Row
            where=' WHERE node=?' if node else ''
            params=(node,limit) if node else (limit,)
            records=[]
            for row in db.execute('SELECT * FROM events'+where+' ORDER BY id DESC LIMIT ?',params):
                record=dict(row);record.pop('identity',None)
                record['details']=json.loads(record['details'])
                record['active']=record['ended_at'] is None
                record['observed_duration_seconds']=round(max(0,(record['ended_at'] or record['last_seen'])-record['started_at']),1)
                records.append(record)
            return {'events':records,'retention_days':30,'limit':self.limit,'error':self.error,
                    'time_basis':'TX observation; durations are sampled, not exact audio fault lengths'}
