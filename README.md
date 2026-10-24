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


## Regia TX · v4.8

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

FFmpeg decodifica il file come PCM stereo al sample rate configurato e lo passa
via WAV su standard input a Roc. Il TX ferma prima il servizio Roc dell'ingresso
mixer, così non trasmette due sorgenti contemporaneamente. Alla fine di una
traccia non ripetuta, o premendo **Stop / ingresso mixer**, riavvia l'ingresso
Scarlett. In pausa il sender del player è fermo: gli RX restano senza segnale.
La posizione visualizzata è una stima del tempo trascorso sul TX, non una misura
dell'istante di uscita analogica degli RX.

Cambio sorgente, ricerca, ripresa e ripetizione possono avere una breve pausa:
questa versione non implementa dissolvenze, transizioni senza interruzioni,
playlist o sovrapposizione di annuncio e sottofondo. Un errore di avvio del player
ripristina l'ingresso mixer. Il riavvio o arresto del monitor ripristina il mixer;
le tracce interrotte non ripartono da sole. Senza Scarlett il servizio ingresso
rimane in attesa del dispositivo, mentre il player può usare i file locali.

### Calendario

Gli eventi persistono in `/var/lib/roc-museum/studio/calendar.sqlite` e possono
essere creati, modificati, disabilitati o eliminati dalla pagina. Ogni evento
indica una traccia, una data/ora iniziale nell'ora italiana (`Europe/Rome`) e una
ricorrenza: una volta, giornaliera oppure settimanale nei giorni selezionati.
Il calendario generale è **disabilitato per impostazione iniziale** e va attivato
con **Abilita / riprendi programma**. La sua abilitazione persiste al riavvio.

I comandi manuali di riproduzione, pausa, ricerca, stop o loop durante una traccia
sospendono l'esecuzione degli eventi. **Abilita / riprendi programma** conclude
l'eventuale traccia manuale, torna al mixer e libera l'automazione. La sospensione
manuale è temporanea e non persiste dopo un riavvio del monitor.

Quando il player è occupato, la priorità dell'evento può essere:

- **Salta**: registra l'evento come saltato.
- **Attendi**: mette l'evento in coda fino a fine traccia, per massimo 15 minuti.
- **Interrompi**: interrompe la traccia attuale e avvia quella programmata.

Il mixer è considerato sorgente disponibile, non player occupato. Le tracce
interrotte non vengono riprese automaticamente e una traccia programmata torna
al mixer al termine. Gli eventi nello stesso minuto vengono ordinati per data
iniziale e identificativo. Un loop occupa il player fino al comando manuale o a
un evento interrompente. Disabilitare il calendario ferma una traccia avviata dal
calendario e cancella la coda; non ferma una traccia manuale.

Il servizio controlla gli eventi ogni secondo. Un evento può partire durante
il minuto indicato (ritardo massimo normale inferiore a un secondo, se il TX è
libero); al riavvio non recupera minuti già passati né la coda precedente.
Un registro persistente impedisce di eseguire due volte la stessa occorrenza,
anche dopo un riavvio o al ritorno dall'ora legale. Nell'ora primaverile inesistente
l'evento viene saltato. Il registro mostra gli ultimi 30 eventi e conserva 90
giorni di storico. Non è una garanzia di esecuzione in caso di blackout: il
registro viene salvato prima dell'avvio per evitare duplicazioni.

L'orologio del Raspberry deve essere corretto. Verificare la sincronizzazione
NTP; per installazioni isolate dalla rete valutare un RTC. Nessun collegamento
a Internet è richiesto per riprodurre brani o leggere il calendario locale.

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

`studio.py` e `studio.html` sono i sorgenti della regia. Dopo una modifica,
rigenerare la copia incorporata nell'installer autonomo:

```bash
python3 tools/embed_studio.py
bash -n setup_roc_museum.sh
python3 -m unittest discover -s tests -v
```

La suite verifica login, CSRF, upload, priorità, persistenza, ora legale,
confinamento USB, copia e ripristino del mixer. Se disponibile un eseguibile Roc,
attivare anche il test di integrazione reale su UDP localhost:

```bash
ROC_SEND_BINARY=/usr/bin/roc-send python3 -m unittest discover -s tests -p test_studio.py -v
```

Il test reale usa FFmpeg e verifica la ricezione di pacchetti RTP L16; non usa
ALSA, non cambia servizi reali e non contatta i Raspberry. Rimane da collaudare
sull'hardware il passaggio Scarlett/player, il comportamento degli RX durante
le pause e il montaggio/espulsione delle pennette effettivamente in uso.
