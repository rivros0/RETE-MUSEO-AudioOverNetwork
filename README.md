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

L’aggiornatore è un progetto indipendente:
[SSH-Update-Manager](https://github.com/rivros0/SSH-Update-Manager).
Il tool generico e i suoi test sono gestiti nella repository separata.
Le copie preesistenti dell’aggiornatore specifico e le credenziali locali restano
sul computer, escluse da Git, per preservare l’avvio già configurato.
Questa repository mantiene l’applicazione AON e l’installer
`setup_roc_museum.sh`, che l’aggiornatore scarica e distribuisce ai Raspberry.
Le istruzioni e la configurazione delle credenziali sono nel README del tool;
le password restano soltanto nel file locale escluso da Git.

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


## Regia TX · v4.10

Dopo il login compaiono player, calendario ed explorer USB. Il monitor dei nodi
rimane consultabile senza login; tutte le nuove API di regia richiedono sessione,
e le operazioni di modifica richiedono anche il token CSRF della sessione.
Il setup installa automaticamente FFmpeg, gli strumenti USB e i dati dei fusi orari.
Non servono librerie Python aggiuntive. Versione minima Python: 3.9.

### Player

Il lettore è un pannello richiudibile ispirato a VLC, con barra temporale,
contatori, pausa/ripresa, stop, salto di dieci secondi e traccia precedente/successiva.
La playlist permette ricerca, selezione e doppio clic per avviare una traccia.
La chiusura del pannello viene ricordata dal browser e non interrompe l’audio.
Volume e silenziamento agiscono soltanto sulla musica e vengono salvati sul TX:
gli annunci della Scarlett rimangono udibili.

Selezionare un file dalla libreria e premere **Riproduci selezione**. Sono
disponibili pausa, ripresa, ricerca a una posizione in secondi, avanzamento e
ripetizione della singola traccia. Tutti gli RX ricevono lo stesso segnale.
Il browser è soltanto il telecomando: il servizio sul TX continua a funzionare
anche chiudendo la pagina, e più browser osservano lo stesso stato.

Dalla **v4.10** la riproduzione manuale è persistente rispetto a riavvii del TX
o del servizio: il sistema salva periodicamente brano, posizione, stato play/pausa
e loop. Se il TX si riavvia mentre una traccia manuale è in riproduzione, al ritorno
riprende automaticamente dallo stesso brano e da una posizione prossima a quella
salvata. Se era in pausa, torna in pausa. Un comando **Stop** esplicito cancella
lo stato da ripristinare. Le fasce del calendario continuano invece a usare la
logica già prevista: una fascia ancora valida può ripartire secondo il proprio
programma, mentre una fascia scaduta non viene riattivata.


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

## Accesso remoto TX e manutenzione RX · v4.16

L'installer autonomo installa `roc-museum-remote` e include il watchdog
[esistente](https://github.com/rivros0/tailscale-funnel-watchdog), fissato al commit
`eb6beb4717bdd21461b5c5fb5e5084f82fc47a5e` (sorgenti in `vendor/funnel-watchdog`).
L'accesso pubblico si attiva esplicitamente dopo l'aggiornamento del TX.

Sul TX installare e autenticare Tailscale; abilitare MagicDNS, HTTPS e il permesso
Funnel nella tailnet. Impostare la password regia, se non è già presente:

```bash
sudo roc-museum-monitor --set-password
sudo roc-museum-remote enable
sudo roc-museum-remote status
```

`enable` pubblica `http://127.0.0.1:8080` su HTTPS 443 e configura automaticamente
il watchdog con l'hostname Tailscale del TX. Aprire l'URL mostrato da `status`:
player, calendario, upload e comandi RX usano la stessa regia e lo stesso login.
Lo stato dei nodi resta pubblico, come sulla LAN. La porta HTTPS 443 di Funnel
va dedicata a questa applicazione: l'attivazione e il ripristino ne gestiscono
il mapping. Non eseguire altri watchdog sullo stesso mapping.

Il timer `tailscale-funnel-watchdog.timer` verifica `/healthz` sia localmente sia
tramite DNS pubblico e ripristina il proxy dopo i tentativi previsti dal watchdog.
Non riavvia audio o monitor. Se il backend è guasto, lo segnala senza modificare
Funnel; il restart del monitor resta affidato a systemd. Il controllo pubblico
richiede Internet e DNS over HTTPS. Configurazione e log seguono il README del
watchdog incluso. Per un controllo manuale o per disabilitare l'accesso:

```bash
sudo roc-museum-remote check
sudo journalctl -u tailscale-funnel-watchdog.service -n 100 --no-pager
sudo roc-museum-remote disable
```

Funnel serve la regia web. Per gli aggiornamenti SSH il computer di gestione deve
entrare nella tailnet e raggiungere il servizio SSH del TX. Gli RX possono restare
sulla sola LAN: l'aggiornatore usa un tunnel SSH attraverso il TX. Sul TX occorre
consentire il forwarding TCP in sshd verso gli indirizzi RX; verificare le chiavi
host di TX e RX prima dell'uso. Non occorre pubblicare SSH tramite Funnel.

Nel progetto `ssh-update-manager`, copiare `config.museo-rx.example.json` in un
profilo locale, sostituire utente, hostname Tailscale TX e indirizzi RX, poi usare:

```bash
python3 ssh_update.py --profile config.local.json --configure
python3 ssh_update.py --profile config.local.json --check-only
python3 ssh_update.py --profile config.local.json
```

Il profilo aggiorna solo RX e conserva nome e IP TX dalla configurazione remota;
prevede backup e verifica dei servizi. L'aggiornamento interrompe brevemente
l'audio del singolo RX. Le modifiche sorgente devono essere pubblicate nella
repository configurata prima di distribuirle con questo profilo.

## Aggiornamenti dalla regia amministrativa · v4.16

Dopo il login, la sezione richiudibile **Aggiornamento dispositivi · TX e RX**
permette di controllare la versione GitHub e aggiornare l’intero impianto.

1. In **Ricevitori da aggiornare** salvare un RX per riga, per esempio
   `nino@192.168.1.51`. Si usa la porta SSH standard 22.
2. **Controlla versione GitHub** legge l’installer dal ramo `main` della repository
   `rivros0/RETE-MUSEO-AudioOverNetwork` e mostra versione e commit, senza installare.
3. **Aggiorna TX e propaga agli RX** controlla nuovamente GitHub, aggiorna prima
   il TX, verifica versione, servizi e risposta della regia, poi aggiorna gli RX
   uno alla volta usando esattamente lo stesso installer e verificandone SHA-256.

I nodi già alla versione attesa o superiore vengono saltati. Se il TX è più
recente di GitHub, la distribuzione si ferma per evitare un downgrade del TX e
una propagazione di una release più vecchia. Un errore TX ferma la propagazione;
un errore su un RX viene registrato e non impedisce il tentativo sugli altri RX.
Il profilo dei ricevitori persiste e si modifica soltanto dall’amministrazione;
non si deducono destinazioni SSH dai pacchetti heartbeat.

Il lavoro gira in `roc-museum-update.service`, separato dal monitor: prosegue
anche dopo la chiusura del browser e durante il riavvio della regia. Dopo il
riavvio occorre accedere di nuovo per leggere l’esito persistente e gli stati di
ciascun RX. Audio, libreria, calendario, password e configurazione Funnel sono
conservati dall’installer; l’aggiornamento comporta una breve interruzione audio.
Il nome del nodo e l’IP del TX sugli RX vengono mantenuti. Per ogni nuova release
incrementare `VERSION` nell’installer prima di pubblicarla su GitHub.

### Preparazione una tantum dell’accesso SSH dal TX

Il servizio gira come root sul TX e usa OpenSSH con `BatchMode=yes` e verifica
obbligatoria delle chiavi host. Preparare una chiave dedicata sul TX, se non è già
presente, e installarne la parte pubblica negli `authorized_keys` degli utenti RX.
Per esempio, sul TX:

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
sudo ssh-copy-id nino@192.168.1.51
sudo ssh -o BatchMode=yes -o StrictHostKeyChecking=yes nino@192.168.1.51 'sudo -n true'
```

Se esiste già `/root/.ssh/id_ed25519`, riutilizzarla senza sovrascriverla. La chiave
usata dal servizio deve poter funzionare senza una richiesta interattiva di
passphrase. Durante il primo collegamento confrontare l’impronta della chiave host
con quella del ricevitore prima di accettarla. Ripetere per ogni RX. Gli utenti RX
devono poter eseguire l’installer con `sudo -n`; l’esempio di verifica controlla
un accesso sudo senza richiesta di password. Non vengono salvate password SSH
nel browser o nella regia.

Per usare questa funzione occorre installare una prima volta la v4.16 sul TX col
setup aggiornato. I successivi aggiornamenti partono dal pulsante, purché la
release sia pubblicata nel ramo GitHub configurato. Non viene eseguito alcun push
su GitHub dalla regia.

### Diagnostica

Stato, elenco RX e backup della configurazione TX sono in
`/var/lib/roc-museum/updates`, leggibile soltanto da root. Il log dell’installazione
TX è `tx-install.log`; gli errori SSH/Git e del worker si consultano con:

```bash
sudo journalctl -u roc-museum-update.service -n 100 --no-pager
```

In caso di errore RX, il pannello indica la directory del log lasciata sul nodo.
Non è previsto rollback automatico: dopo timeout o perdita della connessione
verificare l’esito sul nodo prima di riprovare. Un job interrotto da reboot o da
arresto del servizio è segnalato come interrotto e non riparte automaticamente.
Le API `/api/updates` richiedono login; le azioni POST richiedono anche CSRF.

### Scaletta manuale · v4.17

Le checkbox nella libreria definiscono i brani della scaletta, in ordine alfabetico.
**Avvia scaletta** riproduce soltanto quelli spuntati. Le modifiche alle checkbox
si applicano dal prossimo cambio traccia: il brano corrente termina normalmente.
Senza **Loop scaletta**, dopo l’ultimo brano la musica si ferma; con il loop
riparte dal primo selezionato. Una selezione vuota ferma la scaletta al cambio.
**Loop brano** ripete il singolo brano; i due loop sono alternativi.
Il doppio clic o Riproduci selezione avvia un brano singolo e interrompe la
scaletta, senza riprenderla automaticamente al termine. Per ripartire serve
**Avvia scaletta**. Selezione e modalità loop sono salvate sul TX e condivise
tra browser; la scaletta attiva viene ripristinata insieme al player al riavvio.
Nuovi file restano esclusi dopo il primo salvataggio esplicito delle checkbox.
Calendario, ducking e ingresso annunci rimangono indipendenti dalla selezione.
