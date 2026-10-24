# RETE MUSEO - AudioOverNetwork

Sistema sperimentale di distribuzione audio su LAN basato su **Roc Toolkit** e Raspberry Pi.

## Architettura

- 1 Raspberry Pi **TX** collegato a una Focusrite Scarlett 2i4;
- 3 Raspberry Pi **RX** con uscita analogica minijack verso casse attive;
- audio RTP multicast su LAN;
- dashboard Web centralizzata sul TX;
- heartbeat di monitoraggio RX → TX via UDP unicast;
- servizi `systemd` con avvio automatico e restart automatico.

## Installazione consigliata via SSH

La manutenzione ordinaria è pensata per essere completamente guidata. Non è necessario ricordare argomenti o parametri.

Sul Raspberry:

```bash
chmod +x setup_roc_museum.sh
sudo ./setup_roc_museum.sh
```

Il wizard:

1. rileva automaticamente l'interfaccia Ethernet e l'IPv4 locale;
2. verifica se esiste già una configurazione precedente e propone di riutilizzarla;
3. chiede solo se il nodo deve essere **TX** o **RX**;
4. se il nodo è RX, chiede soltanto l'**IP del TX**;
5. genera automaticamente il nome del nodo;
6. mostra un riepilogo prima di procedere;
7. visualizza l'avanzamento in 9 fasi con feedback `[OK]`, `[ATTENZIONE]` ed `[ERRORE]`;
8. installa Roc Toolkit e le dipendenze;
9. verifica l'hardware audio previsto;
10. crea configurazione, monitor e servizi;
11. abilita e avvia automaticamente tutti i servizi;
12. mostra stato finale, dashboard e comandi di diagnostica;
13. se necessario, propone direttamente il riavvio del Raspberry.

### TX

Per il TX il wizard rileva automaticamente:

- Ethernet;
- IPv4 locale;
- Focusrite Scarlett/Scarlett 2i4 tramite ALSA.

Il nome predefinito del nodo è `TX`.

Dashboard:

```text
http://IP_TX:8080/
```

API JSON:

```text
http://IP_TX:8080/api/status
```

È importante mantenere stabile l'indirizzo IP del TX, preferibilmente tramite prenotazione DHCP.

### RX

Per un RX l'unico dato richiesto è l'indirizzo IPv4 del TX.

Il nome del ricevitore viene generato automaticamente, ad esempio:

```text
RX-51
```

se il Raspberry ha indirizzo `192.168.1.51`.

L'uscita analogica integrata viene abilitata automaticamente quando necessario. Se la modifica richiede un reboot, il wizard propone il riavvio e i servizi ripartono automaticamente.

## Aggiornamento / reinstallazione

Se il setup viene rilanciato su un Raspberry già configurato, rileva `/etc/roc-museum.conf` e mostra la configurazione precedente.

È sufficiente premere **Invio** per mantenerla e procedere con la reinstallazione/aggiornamento.

Per riconfigurare completamente il nodo si può scegliere `R`.

## Modalità avanzata

Gli argomenti restano disponibili esclusivamente per automazioni o interventi avanzati:

```bash
sudo ./setup_roc_museum.sh --role tx
```

oppure:

```bash
sudo ./setup_roc_museum.sh --role rx --tx-ip 192.168.1.50
```

Nell'uso ordinario è preferibile utilizzare sempre il wizard senza argomenti.

## Parametri iniziali

| Parametro | Valore |
|---|---|
| Audio multicast | `239.30.0.1` |
| Porta RTP | `10001` |
| Sample rate | `44100 Hz` |
| Target latency RX | `100 ms` |
| I/O latency | `20 ms` |
| Frame length | `4 ms` |
| Heartbeat RX → TX | UDP `19090` |
| Dashboard TX | TCP `8080` |

I valori sono volutamente prudenti per la fase di test iniziale.

## Servizi

Il setup crea, abilita e avvia automaticamente:

```text
roc-museum.service
roc-museum-monitor.service
```

Entrambi usano `Restart=always`.

Stato:

```bash
systemctl status roc-museum --no-pager
systemctl status roc-museum-monitor --no-pager
```

Log audio:

```bash
journalctl -u roc-museum -f
```

Log monitor:

```bash
journalctl -u roc-museum-monitor -f
```

## Monitoraggio

La dashboard TX visualizza per ciascun nodo:

- online/offline;
- stato del servizio Roc;
- processo `roc-send` / `roc-recv`;
- Ethernet e velocità link;
- IPv4;
- presenza dispositivo audio;
- stato multicast;
- temperatura CPU;
- load medio;
- ultimo heartbeat.

Un RX che non invia heartbeat per 15 secondi viene considerato offline.

## Hardware di test

### TX

- Raspberry Pi 3;
- Focusrite Scarlett 2i4;
- ingresso line proveniente dal mixer.

### RX

- Raspberry Pi 3;
- uscita minijack analogica integrata;
- collegamento corto verso la cassa attiva.

L'uscita minijack è adeguata per il prototipo; potrà essere sostituita in seguito da un DAC dedicato se necessario.

## Meter audio (v4.6)

La dashboard mostra picco e RMS L/R in dBFS (0 = fondo scala digitale),
calcolati su una finestra mobile di 5 secondi. I dati seguono l'heartbeat
(circa 5 secondi più il tempo della diagnostica); la pagina si aggiorna ogni 2 secondi.

- **TX:** audio digitalizzato dalla Scarlett, osservato nel flusso RTP trasmesso.
- **RX:** livello **post-fader stimato**, ottenuto dal livello RTP ricevuto e dal
  guadagno in dB del controllo ALSA PCM, incluso il mute. Non si converte la
  percentuale del cursore direttamente in dB: viene letto il guadagno ALSA.
- Giallo sopra −3 dBFS; avviso rosso per 30 secondi dopo campioni a fondo scala.
  Sugli RX questo avviso indica clipping **a monte** del fader: attenuare un
  segnale già distorto non lo ripara.
- Silenzio è mostrato al limite inferiore di −96 dBFS; assenza di pacchetti,
  nodo offline o guadagno ALSA sconosciuto sono indicati come indisponibili.

La stima RX applica il volume attuale alla finestra audio precedente: dopo un
movimento del cursore attendere un heartbeat. Non misura il segnale analogico,
la distorsione del DAC/amplificatore, né eventuali alterazioni introdotte dalla
riproduzione Roc. Un segnale già distorto può restare sotto 0 dBFS.
Per diagnosticare, confrontare i meter con gli avvisi xrun/underrun di Roc e
ridurre il gain fisico della Scarlett se il TX raggiunge ripetutamente fondo scala.

La cattura è passiva su Ethernet, senza aprire ALSA, occupare la porta UDP di Roc,
salvare audio o modificare il percorso audio. Supporta RTP PCM L16 standard
(PT 10 stereo / PT 11 mono); formati diversi non vengono interpretati come L16.
Il monitor richiede Linux e CAP_NET_RAW, già disponibile nel servizio esistente
eseguito come root. La cattura di rete include i pacchetti uscenti del TX.

Per aggiornare, copiare il nuovo `setup_roc_museum.sh` su **TX e tutti gli RX**
e rilanciarlo con `sudo`, mantenendo la configurazione proposta. Il setup
riavvia i servizi, con una breve interruzione audio. I vecchi RX restano visibili
ma mostrano l'invito ad aggiornare il monitor.

Verifica locale senza hardware:

```bash
bash -n setup_roc_museum.sh
python3 -m unittest discover -s tests -v
```

Il formato RTP è descritto nel [riferimento Roc](https://roc-streaming.org/toolkit/doxygen/namespaceroc_1_1rtp.html).

## Controlli RX (v4.7)

Il volume si imposta esclusivamente dalla casella numerica **0–100%**, premendo
**Invio** oppure **Applica**. Il refresh mantiene il valore che si sta scrivendo.

- **✓ grigia — Inviato:** il TX ha inviato il comando UDP.
- **✓ blu — Confermato RX:** il ricevitore ha applicato il comando e restituito
  una conferma con identificativo univoco, dopo la lettura di verifica ALSA.
- Se manca la conferma entro circa 9 secondi, compare un errore; il comando
  potrebbe comunque essere stato applicato (UDP non garantisce la consegna).
- I messaggi scompaiono dopo 5 secondi dal risultato.

**Mute** porta temporaneamente il volume a zero; **Riattiva audio** ripristina
il valore precedente. Durante il mute la casella modifica il volume da
ripristinare senza riattivare l'audio. Il mute è temporaneo: al riavvio del
monitor/nodo viene ripristinato il volume salvato su disco.

Aggiornare **sia TX sia RX**: i ricevitori precedenti non supportano mute e
conferme, quindi il solo invio non produrrà una spunta blu. Le conferme tornano
sulla porta heartbeat UDP 19090; non sono necessarie nuove porte.

## Aggiornare i Raspberry dal computer

`aggiorna_raspberry.py` legge l'ultima versione dalla repository configurata,
confronta numericamente le versioni installate e aggiorna solo i nodi più vecchi.
Mostra una tabella nel terminale con versione locale/online, avanzamento ed esito;
un nodo irraggiungibile viene segnalato senza impedire il controllo dei successivi.

La configurazione di progetto è già ripristinata:

- Repository: `https://github.com/rivros0/RETE-MUSEO-AudioOverNetwork.git`
- Ramo: `main`; installer: `setup_roc_museum.sh`.
- RX1: `pi@192.168.1.91`; RX2: `pi@192.168.1.92`; TX: `pi@192.168.1.90`.

Le password sono nel file **locale** `aggiorna_raspberry.local.json`, escluso da
Git e creato con permessi `0600`. Gli aggiornamenti del sorgente non sostituiscono
quel file. Non inserire password nel sorgente da pubblicare. Il file
`aggiorna_raspberry.example.json` contiene soltanto indirizzi e password vuote.
Le password non presenti nelle copie storiche non sono recuperabili dal gestore.

Per configurarle senza mostrarle a schermo:

```bash
python3 aggiorna_raspberry.py --configure
```

Se una password è già salvata, Invio la mantiene. Per aggiungere o cambiare nodi,
modificare il dizionario `raspberry` nel file locale. `--config /percorso/file.json`
permette di usare un altro file personale; non pubblicarlo nella repository.
La stessa password viene utilizzata per SSH e sudo, come nel gestore originale.

Serve Paramiko sul computer che esegue il programma, oltre a Git e Bash:

```bash
sudo apt install python3-paramiko
python3 aggiorna_raspberry.py --check-only
python3 aggiorna_raspberry.py
```

In alternativa installare Paramiko in un ambiente virtuale. Non usare pip globale
con `sudo`. `--check-only` (alias `--dry-run`) scarica il setup e legge le versioni
via SSH senza modificare i Raspberry. Senza opzioni esegue gli aggiornamenti.
Prima del primo uso verificare e registrare normalmente le chiavi dei Raspberry
con `ssh utente@IP`; il gestore rifiuta chiavi sconosciute o cambiate.

L'aggiornamento non richiede il wizard: conserva ruolo, nome e IP TX dai dati del
nodo. Crea un backup in `/var/backups/roc-museum-DATA-ORA.XXXXXXXX` dei programmi,
della configurazione, delle credenziali della regia e del calendario SQLite,
con l'API di backup SQLite. I file audio restano sul posto e non sono duplicati
nel backup. Il ripristino è manuale. Infine verifica versione installata e servizi.
Gli RX vengono controllati prima del TX. L'audio si interrompe durante il setup;
il programma non riavvia automaticamente i Raspberry. Un timeout può lasciare
un comando remoto attivo: verificare il nodo prima di riprovare.

## Login regia e caricamento audio dal browser

Lo stato dei dispositivi (`/` e `/api/status`) resta pubblico. Volume, mute,
conferme dei comandi e libreria richiedono una sessione autenticata.
Il TX continua a distribuire un solo segnale a tutti gli RX.

Dopo aver aggiornato il TX con il setup, impostare la password tramite SSH:

```bash
sudo /usr/local/sbin/roc-museum-monitor --set-password
```

L'utente è `admin`; la password richiede almeno 12 caratteri, viene richiesta
senza mostrarla e salvata come hash PBKDF2 in un file leggibile solo da root.
Non esiste una password predefinita: fino alla configurazione i comandi restano
bloccati. Lo stesso comando permette di cambiare la password; riavviare poi
`roc-museum-monitor` per invalidare subito tutte le sessioni già aperte.
Le sessioni durano 8 ore e vengono invalidate anche dal riavvio del servizio.

Nella dashboard, dopo il login, scegliere un file dal computer o telefono e
premere **Carica sul TX**. I file sono salvati in `/var/lib/roc-museum/media`
e restano disponibili dopo il riavvio. Sono accettate estensioni WAV, MP3,
FLAC, OGG, M4A e AAC fino a 512 MB per file; l'estensione non certifica che
il contenuto sia decodificabile. Non vengono sovrascritti nomi esistenti.
La copia avviene a blocchi e diventa visibile solo al completamento; vengono
lasciati almeno 256 MB liberi. Un solo caricamento alla volta.

Il caricamento funziona da qualsiasi browser che possa raggiungere il TX:
rete locale o accesso remoto tramite VPN. L'HTTP attuale non cifra password
e audio: per accesso su reti non fidate usare VPN oppure un reverse proxy HTTPS;
non pubblicare direttamente la porta 8080 su Internet.

I file caricati entrano nella libreria: non avviano automaticamente la
riproduzione. Player, calendario ed explorer USB sono descritti qui sotto.

Test dedicati: `python3 -m unittest discover -s tests -p test_auth_upload.py -v`.


## Regia TX · v4.9

Dopo il login compaiono player, calendario ed explorer USB. Il monitor dei nodi
rimane consultabile senza login; tutte le nuove API di regia richiedono sessione,
e le operazioni di modifica richiedono anche il token CSRF della sessione.
Il setup installa automaticamente FFmpeg, gli strumenti USB e i dati dei fusi orari.
Non servono librerie Python aggiuntive. Versione minima Python: 3.9.

### Player

Selezionare un file dalla libreria e premere **Riproduci selezione**. Sono
disponibili pausa, ripresa, ricerca a una posizione in secondi, avanzamento e
ripetizione della singola traccia. Tutti gli RX ricevono lo stesso segnale.
Il browser è soltanto il telecomando: il servizio sul TX continua a funzionare
anche chiudendo la pagina, e più browser osservano lo stesso stato.

FFmpeg decodifica la musica in PCM stereo. Un bus Python mantiene aperta
l'acquisizione `arecord` della Scarlett e un solo sender Roc, miscelando microfono
e musica. Il microfono rimane udibile durante play, pausa, stop, ricerca, cambio
traccia e intervalli del calendario. La scheda esterna deve ricevere soltanto
il segnale degli annunci, senza rimandare la stessa musica del player al TX.
La posizione del player conta i campioni letti, non misura la latenza analogica RX.

Il bus è avviato dal monitor TX; `roc-museum.service` rimane attivo come
coordinatore senza aprire una seconda acquisizione ALSA. Il file runtime
`/run/roc-museum-bus` identifica il processo proprietario. Se il monitor termina,
il runner ripristina automaticamente il percorso originale Scarlett → Roc.
Se il bus fallisce, il monitor lo chiude e rilascia la scheda prima di tornare
all'ingresso diretto. Se manca la Scarlett, la musica può continuare; la pagina
segnala la mancanza del microfono e l'acquisizione tenta la riconnessione.
Il riavvio/aggiornamento dei servizi può comunque provocare una breve interruzione.

### Annunci e ducking

Il ducking agisce **soltanto sulla musica**, non sul segnale del microfono.
La pagina mostra stato dell'ingresso, livello RMS in dBFS e attenuazione musicale.
I parametri sono salvati sul TX e si applicano subito senza riavviare il flusso:

- Abilitazione (attiva inizialmente).
- Soglia RMS voce: −36 dBFS iniziali, regolabile da −60 a −6 dBFS.
- Attenuazione musica: −18 dB iniziali, regolabile da −40 a 0 dB.

L'attacco è circa 30 ms; il mantenimento dopo voce è 500 ms, con ritorno graduale
al livello normale (costante di rilascio 800 ms). Un limitatore digitale evita
l'overflow quando si sommano le sorgenti. Non elimina clipping già presente nella
Scarlett: regolare correttamente il gain analogico. Per evitare attivazioni sul
rumore di fondo, alzare la soglia nella regia. Verificare sull'impianto reale la
soglia, l'intelligibilità degli annunci, il margine audio, il carico del Pi 3 e la
latenza introdotta dall'acquisizione/miscelazione prima dell'uso al pubblico.

### Libreria e cancellazione

Ogni file caricato ha un pulsante **Elimina traccia**, con conferma prima della
cancellazione definitiva. Sono protette le tracce attive/in pausa, quelle del
gruppo in corso e quelle referenziate da qualsiasi evento, anche disabilitato.
Prima di cancellarle occorre fermare il player e modificare/eliminare gli eventi
che le usano. La cancellazione condivide il blocco di upload/import USB, quindi
non opera mentre una copia è in corso. Non elimina file dalla pennetta.

### Ora del sistema

La pagina pubblica mostra **Ora TX**, ottenuta dal timestamp del Raspberry via
`/api/status`, anche senza login. Il browser la aggiorna ogni secondo e la
risincronizza con il server ogni due secondi: non usa il proprio orologio come
riferimento per la programmazione. Visualizzazione e calendario usano Europe/Rome.

### Calendario

Gli eventi persistono in `/var/lib/roc-museum/studio/calendar.sqlite`. I vecchi
eventi restano compatibili e sono interpretati come una singola traccia eseguita
una volta. Ogni evento può contenere una traccia oppure un **gruppo ordinato**
di massimo 100 tracce; i pulsanti ↑/↓ cambiano l'ordine. La stessa traccia può
comparire più volte. La ricorrenza può essere singola, giornaliera o settimanale.

Oltre alla data/ora iniziale è possibile indicare **ora fine fascia**:

- La fine uguale o precedente all'inizio indica il giorno successivo.
- A fine fascia la musica si ferma anche se il brano non è terminato; il microfono
  continua a funzionare.
- **Passaggi del gruppo**: 1 esegue una volta, 2 due volte, 0 ripete fino alla fine
  della fascia. Il valore 0 richiede un'ora di fine.
- **Intervallo tra passaggi**: pausa in secondi dopo tutto il gruppo, non fra le
  singole tracce; anche durante la pausa il microfono rimane udibile.

Esempio: inizio 09:00, fine 18:00, gruppo A → B → C, passaggi 0, intervallo 15 s:
riproduce A/B/C, attende 15 secondi e ricomincia fino alle 18:00.
Un numero di passaggi finito può terminare prima della fine fascia.

Il calendario generale è disabilitato inizialmente. **Abilita / riprendi programma**
attiva gli eventi. L'abilitazione persiste dopo il riavvio. I comandi manuali
sospendono il calendario fino a quel pulsante: la fascia ancora attiva riparte
dall'inizio del gruppo. La sospensione manuale è temporanea, non persiste dopo
un riavvio. Le fasce attive ripartono dall'inizio anche al riavvio del monitor;
gli eventi istantanei dei minuti precedenti non vengono recuperati.

Se un altro programma è attivo si può scegliere **Salta**, **Attendi** (massimo
15 minuti e comunque non oltre fine fascia) o **Interrompi**. Il solo microfono
non occupa il player. Un programma in attesa fra due passaggi mantiene occupata
la fascia. Dopo un annuncio musicale interrompente, una fascia di sottofondo
ancora attiva può ripartire dall'inizio. Un annuncio dal microfono non interrompe
il gruppo: abbassa la musica con il ducking e la riproduzione continua.

Il motore controlla gli eventi ogni 100 ms. Il bus audio applica il limite di fine
fascia anche fra due controlli del calendario. Il registro persistente evita di
rieseguire un evento istantaneo dopo riavvio o cambio dell'ora. Le fasce notturne
usano il giorno d'inizio per la ricorrenza settimanale; gli orari di inizio
inesistenti al passaggio primaverile vengono saltati. La pagina mostra le ultime
30 occorrenze e conserva 90 giorni di storico. Non c'è garanzia di esecuzione in
caso di blackout. L'orologio del Raspberry deve essere sincronizzato (NTP o RTC
per installazioni isolate). Internet non è richiesto per l'esecuzione locale.

### Explorer USB

Premere **Rileva pennette**, selezionare un dispositivo e **Apri**. Il TX riconosce
i filesystem FAT, exFAT, NTFS, ext2/3/4 e ISO9660 su dispositivi USB. Esclude i
dischi usati dal sistema operativo. Le nuove unità sono montate con
`ro,nosuid,nodev,noexec` sotto `/run/roc-museum-usb`; le unità già montate in
`/media` o `/run/media` possono essere consultate senza modificarne il mount.
Non vengono mostrati file nascosti o link simbolici; i percorsi restano confinati
al dispositivo selezionato, anche durante l'apertura del file.

Aprire le cartelle e premere **Importa** accanto al brano. La copia è completata
e resa visibile nella libreria prima di poterla riprodurre. Limiti di dimensione,
spazio libero e nomi duplicati sono gli stessi dell'upload dal browser. La copia
USB e l'upload condividono il blocco: uno solo può essere attivo alla volta.
**Espelli** smonta le unità montate dalla regia; per quelle montate dal desktop
occorre l'espulsione dal sistema operativo. Rimozione improvvisa o copia fallita
non lasciano un brano parziale visibile nella libreria.

### Sviluppo e verifica

`studio.py`, `audio_bus.py` e `studio.html` sono i sorgenti della regia. Dopo una modifica,
rigenerare la copia incorporata nell'installer autonomo:

```bash
python3 tools/embed_studio.py
bash -n setup_roc_museum.sh
python3 -m unittest discover -s tests -v
```

La suite verifica login, CSRF, upload, cancellazione protetta, gruppi, fasce,
ripetizioni, persistenza, ora legale, confinamento USB, ducking e continuità del
microfono durante i comandi musicali. Se disponibile un eseguibile Roc, attivare
anche il test reale su UDP localhost:

```bash
ROC_SEND_BINARY=/usr/bin/roc-send python3 -m unittest discover -s tests -p test_studio.py -v
```

Il test usa il vero decoder FFmpeg e il vero sender Roc, verifica i pacchetti RTP
L16 e un segnale microfono simulato durante la pausa, senza toccare ALSA o servizi
reali. Rimangono necessari il collaudo Scarlett/Pi 3, una prova prolungata e la
taratura del ducking sull'impianto. Il setup resta unico per TX e RX, incluse le
dipendenze, come concordato.
