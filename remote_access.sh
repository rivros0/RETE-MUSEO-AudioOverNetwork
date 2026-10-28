#!/usr/bin/env bash
# Gestisce soltanto il mapping HTTPS 443 della regia; non modifica SSH o audio.
set -euo pipefail
TARGET=http://127.0.0.1:8080
WATCHDOG=/usr/local/lib/roc-museum/funnel-watchdog
require_tx() {
    [ "$(id -u)" -eq 0 ] || { echo 'Eseguire con sudo.' >&2; exit 1; }
    grep -qx 'ROLE="tx"' /etc/roc-museum.conf || { echo 'Consentito soltanto sul TX.' >&2; exit 1; }
    command -v tailscale >/dev/null || { echo 'Installare Tailscale e autenticare il TX con tailscale up.' >&2; exit 1; }
}
case "${1:-status}" in
    enable)
        require_tx
        # Non pubblicare una regia senza credenziali configurate.
        python3 - <<'PY'
import json
from pathlib import Path
record=json.loads(Path('/var/lib/roc-museum/auth.json').read_text())
assert record.get('salt') and record.get('hash'), 'Configurare prima la password regia'
PY
        config=$(mktemp)
        trap 'rm -f -- "$config"' EXIT
        tailscale status --json | python3 -c '
import json,re,sys
name=json.load(sys.stdin)["Self"]["DNSName"].rstrip(".")
if not re.fullmatch(r"[a-zA-Z0-9.-]+\.ts\.net",name): raise SystemExit("Nome Tailscale non valido")
print("PUBLIC_URL=https://"+name+"/healthz")
print("LOCAL_URL=http://127.0.0.1:8080/healthz")
print("FUNNEL_TARGET=http://127.0.0.1:8080")
' > "$config"
        tailscale funnel --bg --https=443 "$TARGET"
        bash "$WATCHDOG/scripts/install.sh" "$config"
        ;;
    check)
        require_tx
        systemctl start tailscale-funnel-watchdog.service
        ;;
    disable)
        require_tx
        systemctl disable --now tailscale-funnel-watchdog.timer
        systemctl stop tailscale-funnel-watchdog.service
        tailscale funnel --https=443 off
        ;;
    status)
        require_tx
        tailscale funnel status
        systemctl status tailscale-funnel-watchdog.timer --no-pager || true
        ;;
    *) echo 'Uso: sudo roc-museum-remote enable|disable|status|check' >&2; exit 2 ;;
esac
