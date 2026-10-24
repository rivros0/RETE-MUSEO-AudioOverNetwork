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
