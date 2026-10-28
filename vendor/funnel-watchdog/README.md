# Tailscale Funnel Watchdog

Watchdog per Linux con systemd, estratto da OrarioCalendar e riutilizzabile con un servizio HTTP locale. Controlla il percorso pubblico di Tailscale Funnel e prova a ripristinarlo quando il backend risponde ma il servizio pubblico non è raggiungibile.

## Funzionamento

1. Controlla il backend locale: se non risponde HTTP 200 termina senza modificare Funnel.
2. Risolve il nome pubblico tramite DNS over HTTPS (Google e Cloudflare), scartando gli IPv4 non globali. Usa `curl --resolve` per evitare che MagicDNS faccia passare il controllo attraverso la tailnet.
3. Dopo tre tentativi pubblici falliti, verifica nuovamente il backend.
4. Disattiva e riattiva il proxy Funnel HTTPS sulla porta 443, quindi verifica il risultato.

Il timer parte due minuti dopo il boot e ripete il controllo cinque minuti dopo la conclusione del precedente. Non esegue un reset globale di Tailscale e non riavvia il backend.

## Requisiti e limiti

- Linux con systemd, Bash, Python 3, curl, GNU timeout e Tailscale già installato e autenticato.
- Funnel già abilitato e configurato per il servizio desiderato.
- Una sola configurazione gestita per host, HTTPS pubblico sulla porta 443 e DNS pubblico IPv4.
- Endpoint locale e pubblico che rispondano direttamente HTTP 200: i redirect non sono considerati sani.
- Accesso in uscita ai resolver DNS over HTTPS. Un problema di rete o dei resolver può provocare un tentativo di ripristino anche quando Funnel è sano.

Il ripristino interessa l'intero proxy HTTPS sulla porta 443: usare questo watchdog solo quando quella porta è dedicata al servizio configurato. Altri percorsi sulla stessa porta possono essere rimossi dalla disattivazione. Non installare contemporaneamente questo timer e un precedente watchdog che gestisce lo stesso Funnel.

## Installazione

```bash
git clone https://github.com/rivros0/tailscale-funnel-watchdog.git
cd tailscale-funnel-watchdog
cp watchdog.conf.example watchdog.conf
nano watchdog.conf
sudo bash scripts/install.sh watchdog.conf
```

Personalizzare tutti e tre gli URL prima dell'installazione. `PUBLIC_URL` deve avere la forma `https://nome.ts.net/percorso`, senza credenziali né porta esplicita. `LOCAL_URL` indica il controllo di salute; `FUNNEL_TARGET` indica il servizio da pubblicare. La configurazione è letta da systemd come `EnvironmentFile`, non come script shell.

L'installer copia script e unità con proprietario root, salva la configurazione in `/etc/tailscale-funnel-watchdog.conf` (permessi 600), abilita il timer ed esegue un primo controllo. Quel controllo può ripristinare subito il proxy se rileva un guasto. Una configurazione precedente viene conservata con suffisso `.bak`.

## Diagnostica e aggiornamenti

```bash
systemctl status tailscale-funnel-watchdog.timer
sudo journalctl -u tailscale-funnel-watchdog.service -n 100 --no-pager
sudo systemctl start tailscale-funnel-watchdog.service
```

I log sono disponibili anche in `/var/log/tailscale-funnel/watchdog.log`; se presente, logrotate conserva 12 rotazioni settimanali. Codici di uscita: `0` controllo riuscito o ripristino riuscito; `1` backend non disponibile o errore di configurazione/esecuzione; `2` ripristino o verifica finale falliti.

Per aggiornare: `git pull`, poi `sudo bash scripts/install.sh`. Senza argomento viene conservata la configurazione installata. Dopo una modifica della configurazione, il controllo successivo la rilegge automaticamente.

Per cambiare la frequenza usare `sudo systemctl edit tailscale-funnel-watchdog.timer`, impostando sotto `[Timer]` prima `OnUnitInactiveSec=` (vuoto) e poi `OnUnitInactiveSec=10min`, quindi riavviare il timer.

## Disinstallazione

```bash
sudo systemctl disable --now tailscale-funnel-watchdog.timer
sudo systemctl stop tailscale-funnel-watchdog.service
sudo rm -f /etc/systemd/system/tailscale-funnel-watchdog.service /etc/systemd/system/tailscale-funnel-watchdog.timer
sudo rm -f /usr/local/sbin/check-tailscale-funnel.sh /etc/logrotate.d/tailscale-funnel
sudo systemctl daemon-reload
```

Configurazione, eventuali override systemd e log restano disponibili e possono essere rimossi separatamente. La disinstallazione non modifica Funnel.

## Test

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q
```

I test simulano curl, tailscale, timeout e sleep: non contattano servizi esterni e non modificano un Funnel reale. Coprono backend indisponibile, guasti transitori, ripristino, errori di riattivazione, redirect e DNS pubblico non valido.
