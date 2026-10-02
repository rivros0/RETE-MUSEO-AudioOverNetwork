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
