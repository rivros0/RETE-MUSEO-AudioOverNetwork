#!/bin/bash
set -euo pipefail
if [[ $EUID != 0 ]]; then echo 'Eseguire con sudo bash scripts/install.sh [file configurazione].' >&2; exit 1; fi
if (( $# > 1 )); then echo 'Specificare al massimo un file configurazione.' >&2; exit 1; fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config=/etc/tailscale-funnel-watchdog.conf
for command in python3 curl tailscale timeout systemctl; do command -v "$command" >/dev/null; done
if [[ -n ${1:-} ]]; then
    [[ -f $1 ]] || { echo 'Configurazione non trovata.' >&2; exit 1; }
elif [[ ! -f $config ]]; then
    echo 'Copiare watchdog.conf.example, personalizzarlo e passarlo come argomento.' >&2
    exit 1
fi
systemctl stop tailscale-funnel-watchdog.timer tailscale-funnel-watchdog.service 2>/dev/null || true
if [[ -n ${1:-} && ! $1 -ef $config ]]; then
    if [[ -f $config ]]; then cp -p -- "$config" "$config.bak"; fi
    install -o root -g root -m 600 -- "$1" "$config"
fi
install -o root -g root -m 755 "$root/deploy/check-tailscale-funnel.sh" /usr/local/sbin/check-tailscale-funnel.sh
install -o root -g root -m 644 "$root/deploy/"*.service "$root/deploy/"*.timer /etc/systemd/system/
if [[ -d /etc/logrotate.d ]]; then
    install -o root -g root -m 644 "$root/deploy/tailscale-funnel.logrotate" /etc/logrotate.d/tailscale-funnel
fi
systemctl daemon-reload
systemctl enable --now tailscale-funnel-watchdog.timer
systemctl start tailscale-funnel-watchdog.service
systemctl is-active --quiet tailscale-funnel-watchdog.timer
echo 'Watchdog installato, controllo completato e timer attivo.'
