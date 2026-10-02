# Rete Museo

Repository dedicata all'infrastruttura tecnica del progetto **Rete Museo**.

## Roc Museum Audio

Sistema sperimentale di distribuzione audio su LAN basato su **Roc Toolkit** e Raspberry Pi.

Architettura prevista:

- 1 Raspberry Pi **TX** collegato a una Focusrite Scarlett 2i4;
- 3 Raspberry Pi **RX** con uscita analogica locale verso casse attive;
- audio distribuito tramite RTP multicast;
- dashboard Web centralizzata sul nodo TX;
- heartbeat di monitoraggio inviati dagli RX direttamente all'IP del TX;
- servizi gestiti da `systemd` e avviati automaticamente al boot.

## Installazione

Scaricare sul Raspberry il file:

```text
setup_roc_museum.sh
```

Rendere eseguibile lo script:

```bash
chmod +x setup_roc_museum.sh
```

Avviare il setup interattivo:

```bash
sudo ./setup_roc_museum.sh
```

Lo script permette di scegliere se configurare il Raspberry come **TX** oppure **RX**.

### Installazione TX

Esempio non interattivo:

```bash
sudo ./setup_roc_museum.sh --role tx --name TX
```

Il TX installa:

- `roc-send`;
- rilevamento della Scarlett/Focusrite tramite ALSA;
- trasmissione RTP multicast;
- dashboard Web centrale;
- API JSON di stato;
- ricezione degli heartbeat dagli RX.

La dashboard viene esposta sulla porta `8080`:

```text
http://IP_TX:8080/
```

API:

```text
http://IP_TX:8080/api/status
```

### Installazione RX

Esempio:

```bash
sudo ./setup_roc_museum.sh \
    --role rx \
    --name RX1 \
    --tx-ip 192.168.1.50
```

L'IP del TX serve al nodo RX per inviare direttamente la telemetria di monitoraggio.

L'audio continua invece a utilizzare multicast.

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

Questi valori sono volutamente prudenti per la prima fase di test.

## Servizi

Lo script configura e avvia automaticamente:

```text
roc-museum.service
roc-museum-monitor.service
```

Entrambi vengono abilitati al boot e configurati con riavvio automatico in caso di arresto.

Verifica stato:

```bash
systemctl status roc-museum
systemctl status roc-museum-monitor
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
- presenza del processo `roc-send` / `roc-recv`;
- stato Ethernet;
- velocità del link;
- IPv4;
- presenza del dispositivo audio;
- appartenenza al gruppo multicast;
- temperatura CPU;
- load medio;
- ultimo heartbeat ricevuto.

Un RX che non invia heartbeat per 15 secondi viene considerato offline.

## Hardware di test

### TX

- Raspberry Pi 3;
- Focusrite Scarlett 2i4;
- ingresso line proveniente dal mixer.

### RX

- Raspberry Pi 3;
- uscita minijack analogica integrata;
- collegamento corto verso una cassa attiva.

L'uscita minijack viene utilizzata nella fase di prototipo. In seguito potrà essere sostituita da un DAC dedicato, se necessario.

## Note operative

È consigliabile assegnare al TX un indirizzo IP stabile, preferibilmente tramite prenotazione DHCP.

Per gli RX, se l'uscita analogica integrata viene abilitata per la prima volta, può essere necessario un riavvio. I servizi sono già configurati per partire automaticamente dopo il reboot.

## Riferimento del progetto

[Conversazione di riferimento su ChatGPT](https://chatgpt.com/g/g-p-6a06197922d48191a69bbc0ae62503c7-rete-museo/c/6a93efa0-fe4c-83eb-83e3-cb23d4aa54cc)
