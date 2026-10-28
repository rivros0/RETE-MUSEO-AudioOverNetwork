#!/bin/bash
set -euo pipefail

: "${PUBLIC_URL:?Configurare PUBLIC_URL nel file /etc/tailscale-funnel-watchdog.conf}"
LOCAL_URL=${LOCAL_URL:-http://127.0.0.1:8000/login}
FUNNEL_TARGET=${FUNNEL_TARGET:-http://127.0.0.1:8000}

log() {
    local line
    line="$(date --iso-8601=seconds) $*"
    printf '%s\n' "$line"
    if [[ -n ${LOG_FILE:-} ]]; then printf '%s\n' "$line" >> "$LOG_FILE"; fi
}
started=$SECONDS
finish() { log "Fine controllo: codice=$? durata=$((SECONDS-started))s"; }
trap finish EXIT
log 'Inizio controllo watchdog.'
public_probe() {
    local host answer ip code
    host=${PUBLIC_URL#https://}; host=${host%%/*}
    # DNS over HTTPS bypassa MagicDNS; --resolve forza il percorso pubblico.
    for resolver in 'https://dns.google/resolve' 'https://cloudflare-dns.com/dns-query'; do
        if ! answer=$(curl --noproxy '*' --silent --show-error --fail --connect-timeout 5 --max-time 10 \
            -H 'accept: application/dns-json' "$resolver?name=$host&type=A" 2>&1); then
            log "DNS pubblico non interrogabile ($resolver): $answer"
            continue
        fi
        if ! ip=$(printf '%s' "$answer" | python3 -c '
import ipaddress,json,sys
try:
    data=json.load(sys.stdin)
    addresses=[str(ipaddress.IPv4Address(a["data"])) for a in data.get("Answer",[]) if a.get("type")==1 and ipaddress.IPv4Address(a["data"]).is_global]
    if data.get("Status") != 0 or not addresses:
        raise ValueError("status=%s, nessun IPv4 pubblico" % data.get("Status"))
    print(addresses[0])
except Exception as exc:
    print(str(exc),file=sys.stderr)
    sys.exit(1)
' 2>&1); then
            log "DNS pubblico fallito ($resolver): $ip"
            continue
        fi
        if ! code=$(curl --noproxy '*' --silent --show-error --output /dev/null --write-out '%{http_code}' \
            --resolve "$host:443:$ip" --connect-timeout 5 --max-time 15 "$PUBLIC_URL" 2>&1); then
            log "HTTPS pubblico fallito (IP=$ip): $code"
            continue
        fi
        if [[ $code == 200 ]]; then
            log "Controllo pubblico riuscito: DNS=$resolver IP=$ip HTTP=200"
            return 0
        fi
        log "HTTPS pubblico fallito (IP=$ip): HTTP=$code"
    done
    return 1
}
probe() {
    local code
    code=$(curl --noproxy '*' --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 5 --max-time 15 "$1") || return 1
    [[ "$code" == 200 ]]
}

if ! probe "$LOCAL_URL"; then
    log 'Backend locale non disponibile: Funnel non modificato.'
    exit 1
fi
log 'Backend locale disponibile: HTTP=200.'
for attempt in 1 2 3; do
    if public_probe; then exit 0; fi
    log "Controllo pubblico fallito ($attempt/3)."
    if [[ "$attempt" != 3 ]]; then sleep 5; fi
done
# Il backend potrebbe essere in riavvio dopo il primo controllo.
if ! probe "$LOCAL_URL"; then
    log 'Backend locale non più disponibile: ripristino annullato.'
    exit 1
fi

# Agisce sul proxy HTTPS di questa applicazione, senza un reset globale.
log 'Ripristino del proxy Funnel HTTPS sulla porta 443: tre controlli pubblici falliti, backend locale disponibile. Vedere le cause DNS/HTTPS precedenti.'
if ! timeout 30 tailscale funnel --https=443 off; then
    log 'Disattivazione del proxy fallita; tentativo di riattivazione comunque eseguito.'
fi
if ! timeout 30 tailscale funnel --bg --https=443 "$FUNNEL_TARGET"; then
    log 'ERRORE: riattivazione Funnel fallita.'
    exit 2
fi
sleep 5
if public_probe; then
    log 'Funnel ripristinato correttamente.'
    exit 0
fi
log 'ERRORE: il controllo pubblico fallisce ancora dopo il ripristino.'
exit 2
