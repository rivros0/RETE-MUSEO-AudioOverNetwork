#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RETE MUSEO - AudioOverNetwork
# Setup unico e guidato per Raspberry Pi TX/RX - v4.33
#
# Uso normale:
#   sudo ./setup_roc_museum.sh
#
# Gli argomenti restano disponibili solo per automazione avanzata:
#   --role tx|rx   --tx-ip A.B.C.D   --name NOME
# =============================================================================

VERSION="4.33"
MULTICAST_ADDR="239.30.0.1"
RTP_PORT="10001"
SAMPLE_RATE="44100"
TARGET_LATENCY="100ms"
FRAME_LEN="4ms"
MONITOR_PORT="19090"
CONTROL_PORT="19091"
MONITOR_HTTP_PORT="8080"
EXPECTED_RX_COUNT="3"
CONFIG_FILE="/etc/roc-museum.conf"
RUNNER="/usr/local/sbin/roc-museum-run"
MONITOR_TARGET="/usr/local/sbin/roc-museum-monitor"
AUDIO_SERVICE="/etc/systemd/system/roc-museum.service"
MONITOR_SERVICE="/etc/systemd/system/roc-museum-monitor.service"
ROLE=""
NODE_NAME=""
TX_IP=""
NETWORK_IFACE=""
REBOOT_REQUIRED="no"
INTERACTIVE_MODE="yes"
TOTAL_STEPS=9
CURRENT_STEP=0

if [ -t 1 ]; then
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[1;33m"
    C_RED="\033[0;31m"
    C_BLUE="\033[0;34m"
    C_BOLD="\033[1m"
    C_RESET="\033[0m"
else
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_BLUE=""
    C_BOLD=""
    C_RESET=""
fi

print_title() {
    clear 2>/dev/null || true
    echo
    echo -e "${C_BOLD}==============================================================${C_RESET}"
    echo -e "${C_BOLD} RETE MUSEO - AudioOverNetwork${C_RESET}"
    echo " Setup guidato Raspberry Pi TX / RX - v${VERSION}"
    echo -e "${C_BOLD}==============================================================${C_RESET}"
    echo
    echo "Il wizard configura automaticamente Roc Toolkit, audio, rete,"
    echo "monitoraggio, dashboard e avvio automatico dei servizi."
    echo
}

info() { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok() { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[ATTENZIONE]${C_RESET} $*" >&2; }
fail() { echo -e "${C_RED}[ERRORE]${C_RESET} $*" >&2; exit 1; }

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo
    echo -e "${C_BOLD}[${CURRENT_STEP}/${TOTAL_STEPS}] $*${C_RESET}"
    echo "--------------------------------------------------------------"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Eseguire lo script con sudo."
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

validate_ipv4() {
    local address="$1"
    local old_ifs="$IFS"
    local octet=""
    local -a parts=()
    IFS='.'
    read -r -a parts <<< "$address"
    IFS="$old_ifs"
    if [ "${#parts[@]}" -ne 4 ]; then return 1; fi
    for octet in "${parts[@]}"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]]; then return 1; fi
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then return 1; fi
    done
    return 0
}

get_ipv4() {
    local iface="$1"
    ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{split($4,v,"/"); print v[1]; exit}'
}

detect_network_interface() {
    if ip link show eth0 >/dev/null 2>&1; then
        NETWORK_IFACE="eth0"
        return
    fi
    NETWORK_IFACE="$(ip -o link show | awk -F': ' '$2 != "lo" {n=$2; sub(/@.*/,"",n); if(n ~ /^e/){print n; exit}}')"
    if [ -z "$NETWORK_IFACE" ]; then
        fail "Nessuna interfaccia Ethernet cablata rilevata."
    fi
}

parse_arguments() {
    if [ "$#" -gt 0 ]; then INTERACTIVE_MODE="no"; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --role) [ "$#" -ge 2 ] || fail "Manca --role"; ROLE="$2"; shift 2 ;;
            --name) [ "$#" -ge 2 ] || fail "Manca --name"; NODE_NAME="$2"; shift 2 ;;
            --tx-ip) [ "$#" -ge 2 ] || fail "Manca --tx-ip"; TX_IP="$2"; shift 2 ;;
            -h|--help)
                cat <<'HELP'
Uso consigliato:
  sudo ./setup_roc_museum.sh

Modalità avanzata opzionale:
  sudo ./setup_roc_museum.sh --role tx
  sudo ./setup_roc_museum.sh --role rx --tx-ip 192.168.1.50

Per l'uso ordinario non è necessario ricordare alcun argomento.
HELP
                exit 0
                ;;
            *) fail "Argomento non riconosciuto: $1" ;;
        esac
    done
}

load_existing_configuration() {
    local answer=""
    local saved_role=""
    local saved_name=""
    local saved_tx_ip=""
    if [ "$INTERACTIVE_MODE" != "yes" ]; then return; fi
    if [ ! -r "$CONFIG_FILE" ]; then return; fi
    echo "Configurazione esistente rilevata:"
    echo
    grep -E '^(ROLE|NODE_NAME|TX_IP|NETWORK_IFACE)=' "$CONFIG_FILE" | sed 's/^/  /' || true
    echo
    read -r -p "INVIO = mantieni configurazione; R = riconfigura: " answer
    if [ "$answer" = "R" ] || [ "$answer" = "r" ]; then return; fi
    saved_role="$(sed -n 's/^ROLE="\([^" ]*\)"$/\1/p' "$CONFIG_FILE" | head -n1)"
    saved_name="$(sed -n 's/^NODE_NAME="\([^"]*\)"$/\1/p' "$CONFIG_FILE" | head -n1)"
    saved_tx_ip="$(sed -n 's/^TX_IP="\([^" ]*\)"$/\1/p' "$CONFIG_FILE" | head -n1)"
    ROLE="$saved_role"
    NODE_NAME="$saved_name"
    TX_IP="$saved_tx_ip"
    ok "Configurazione precedente caricata."
}

choose_role() {
    local choice=""
    if [ -n "$ROLE" ]; then return; fi
    echo "Che funzione avrà questo Raspberry?"
    echo
    echo "  1) TX - trasmettitore principale"
    echo "         Scarlett 2i4 + multicast + dashboard"
    echo
    echo "  2) RX - ricevitore per una cassa"
    echo "         multicast + uscita minijack + telemetria"
    echo
    while true; do
        read -r -p "Selezione [1/2]: " choice
        if [ "$choice" = "1" ]; then ROLE="tx"; return; fi
        if [ "$choice" = "2" ]; then ROLE="rx"; return; fi
        echo "Inserire 1 oppure 2."
    done
}

validate_role() {
    if [ "$ROLE" != "tx" ] && [ "$ROLE" != "rx" ]; then
        fail "Ruolo non valido: usare tx oppure rx."
    fi
}

generate_node_name() {
    local local_ip=""
    local suffix=""
    if [ -n "$NODE_NAME" ]; then return; fi
    if [ "$ROLE" = "tx" ]; then NODE_NAME="TX"; return; fi
    local_ip="$(get_ipv4 "$NETWORK_IFACE")"
    if [ -n "$local_ip" ]; then
        suffix="${local_ip##*.}"
        NODE_NAME="RX-${suffix}"
        return
    fi
    suffix="$(tr -d '\n' < /etc/machine-id 2>/dev/null | cut -c1-6)"
    if [ -z "$suffix" ]; then suffix="$(hostname | tr -cd '[:alnum:]' | tail -c 7)"; fi
    NODE_NAME="RX-${suffix}"
}

ask_tx_ip() {
    local answer=""
    if [ "$ROLE" != "rx" ]; then return; fi
    if [ -n "$TX_IP" ]; then
        if ! validate_ipv4 "$TX_IP"; then fail "Indirizzo TX non valido: $TX_IP"; fi
        return
    fi
    echo
    echo "Per un RX serve soltanto l'indirizzo IP del Raspberry TX."
    echo "Conviene assegnare al TX un IP stabile o una prenotazione DHCP."
    echo
    while true; do
        read -r -p "IP del TX (es. 192.168.1.50): " answer
        if validate_ipv4 "$answer"; then TX_IP="$answer"; return; fi
        echo "Indirizzo IPv4 non valido."
    done
}

show_configuration() {
    local local_ip=""
    local answer=""
    local_ip="$(get_ipv4 "$NETWORK_IFACE")"
    echo
    echo "Riepilogo"
    echo "--------------------------------------------------------------"
    echo "Ruolo                : ${ROLE^^}"
    echo "Nome nodo            : $NODE_NAME"
    echo "Ethernet             : $NETWORK_IFACE"
    echo "IPv4 locale          : ${local_ip:-non assegnato}"
    echo "Audio multicast      : ${MULTICAST_ADDR}:${RTP_PORT}"
    if [ "$ROLE" = "tx" ]; then
        echo "Dashboard Web        : TCP/${MONITOR_HTTP_PORT}"
        echo "Heartbeat RX         : UDP/${MONITOR_PORT}"
    else
        echo "TX monitoraggio      : ${TX_IP}:${MONITOR_PORT}"
    fi
    echo "--------------------------------------------------------------"
    if [ "$INTERACTIVE_MODE" = "yes" ]; then
        read -r -p "Procedere? [S/n]: " answer
        if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
            echo "Installazione annullata."
            exit 0
        fi
    fi
}

install_packages() {
    info "Aggiornamento degli indici APT..."
    apt-get update
    ok "Indici APT aggiornati."
    if ! apt-cache show roc-toolkit-tools >/dev/null 2>&1; then
        fail "roc-toolkit-tools non disponibile. Usare Raspberry Pi OS recente basato su Debian Trixie."
    fi
    info "Installazione di Roc Toolkit e dipendenze..."
    apt-get install -y roc-toolkit-tools alsa-utils iproute2 python3 python3-numpy python3-paramiko curl git openssh-client ethtool ffmpeg util-linux mount exfatprogs ntfs-3g tzdata
    command_exists roc-send || fail "roc-send non installato."
    command_exists roc-recv || fail "roc-recv non installato."
    command_exists python3 || fail "python3 non installato."
    ok "Roc Toolkit e dipendenze installati."
}

enable_pi_analog_audio() {
    local boot_config=""
    if [ "$ROLE" != "rx" ]; then return; fi
    if [ -f /boot/firmware/config.txt ]; then boot_config="/boot/firmware/config.txt"; fi
    if [ -z "$boot_config" ] && [ -f /boot/config.txt ]; then boot_config="/boot/config.txt"; fi
    if [ -z "$boot_config" ]; then warn "config.txt non trovato; impossibile verificare l'audio analogico."; return; fi
    if ! grep -Eq '^[[:space:]]*dtparam=audio=on([[:space:]]|$)' "$boot_config"; then
        { echo; echo "# RETE MUSEO AudioOverNetwork"; echo "dtparam=audio=on"; } >> "$boot_config"
        REBOOT_REQUIRED="yes"
        ok "Uscita analogica abilitata in $boot_config."
    else
        ok "Uscita analogica già abilitata."
    fi
}

find_scarlett_capture_device() {
    local card=""
    card="$(LC_ALL=C arecord -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /scarlett|focusrite/{if(match($0,/card [0-9]+/)){v=substr($0,RSTART,RLENGTH);sub(/card /,"",v);print v;exit}}')"
    [ -n "$card" ] || return 1
    echo "plughw:${card},0"
}

find_headphones_playback_device() {
    local card=""
    card="$(LC_ALL=C aplay -l 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /headphones|bcm2835/{if(match($0,/card [0-9]+/)){v=substr($0,RSTART,RLENGTH);sub(/card /,"",v);print v;exit}}')"
    [ -n "$card" ] || return 1
    echo "plughw:${card},0"
}

check_hardware() {
    local device=""
    if [ "$ROLE" = "tx" ]; then
        if device="$(find_scarlett_capture_device)"; then ok "Scarlett rilevata: $device"; else warn "Scarlett non rilevata. Il servizio audio ritenterà automaticamente."; fi
        return
    fi
    if device="$(find_headphones_playback_device)"; then ok "Uscita analogica rilevata: $device"; else warn "Uscita analogica non ancora visibile; sarà verificata dopo il riavvio."; REBOOT_REQUIRED="yes"; fi
}

check_tx_reachability() {
    if [ "$ROLE" != "rx" ]; then return; fi
    info "Verifica raggiungibilità TX ${TX_IP}..."
    if ping -c 1 -W 1 "$TX_IP" >/dev/null 2>&1; then ok "TX raggiungibile."; else warn "TX non raggiungibile al ping. Il setup prosegue comunque."; fi
}

stop_existing_services() {
    systemctl stop roc-museum-monitor.service >/dev/null 2>&1 || true
    systemctl stop roc-museum.service >/dev/null 2>&1 || true
}

write_config() {
    local local_ip=""
    local_ip="$(get_ipv4 "$NETWORK_IFACE")"
    if [ "$ROLE" = "tx" ]; then TX_IP="$local_ip"; fi
    cat > "$CONFIG_FILE" <<EOF_CONFIG
# RETE MUSEO - AudioOverNetwork - setup v${VERSION}
ROLE="$ROLE"
NODE_NAME="$NODE_NAME"
NETWORK_IFACE="$NETWORK_IFACE"
TX_IP="$TX_IP"
MULTICAST_ADDR="$MULTICAST_ADDR"
RTP_PORT="$RTP_PORT"
SAMPLE_RATE="$SAMPLE_RATE"
TARGET_LATENCY="$TARGET_LATENCY"
FRAME_LEN="$FRAME_LEN"
MONITOR_PORT="$MONITOR_PORT"
CONTROL_PORT="$CONTROL_PORT"
MONITOR_HTTP_PORT="$MONITOR_HTTP_PORT"
EXPECTED_RX_COUNT="$EXPECTED_RX_COUNT"
SOFTWARE_VERSION="$VERSION"
EOF_CONFIG
    chmod 0644 "$CONFIG_FILE"
}

write_runner() {
    cat > "$RUNNER" <<'EOF_RUNNER'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="/etc/roc-museum.conf"
[ -r "$CONFIG_FILE" ] || { echo "Configurazione non trovata" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"
get_ipv4(){ ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{split($4,v,"/");print v[1];exit}'; }
find_card(){
    local mode="$1" pattern="$2" line="" card=""
    if [ "$mode" = "capture" ]; then line="$(LC_ALL=C arecord -l 2>/dev/null | grep -Ei "$pattern" | head -n1 || true)"; else line="$(LC_ALL=C aplay -l 2>/dev/null | grep -Ei "$pattern" | head -n1 || true)"; fi
    card="$(printf '%s\n' "$line" | sed -n 's/.*card \([0-9][0-9]*\).*/\1/p')"
    [ -n "$card" ] || return 1
    echo "plughw:${card},0"
}
ip route replace 239.0.0.0/8 dev "$NETWORK_IFACE"
if [ "$ROLE" = "tx" ]; then
    # While the monitor owns the continuous mic/music bus, keep this unit
    # active without opening ALSA a second time. Recover after a monitor crash.
    while [ -r /run/roc-museum-bus ]; do
        read -r BUS_PID < /run/roc-museum-bus || break
        case "$BUS_PID" in ''|*[!0-9]*) break ;; esac
        kill -0 "$BUS_PID" 2>/dev/null || break
        sleep 1
    done
    if [ -e /run/roc-museum-bus ]; then rm -f /run/roc-museum-bus; fi
    while ! INPUT_DEVICE="$(find_card capture 'Scarlett|Focusrite')"; do
        echo "TX: Focusrite Scarlett non rilevata; attesa collegamento USB..."
        sleep 5
    done
    echo "TX: ${INPUT_DEVICE} -> ${MULTICAST_ADDR}:${RTP_PORT}"
    exec roc-send -vv -i "alsa://${INPUT_DEVICE}" -s "rtp://${MULTICAST_ADDR}:${RTP_PORT}" --rate="$SAMPLE_RATE" --frame-len="$FRAME_LEN"
fi
if [ "$ROLE" = "rx" ]; then
    LOCAL_IP="$(get_ipv4 "$NETWORK_IFACE")"
    [ -n "$LOCAL_IP" ] || { echo "IPv4 non disponibile" >&2; exit 1; }
    OUTPUT_DEVICE="$(find_card playback 'Headphones|bcm2835')" || { echo "Uscita analogica Raspberry Pi non rilevata" >&2; exit 1; }
    echo "RX: ${MULTICAST_ADDR}:${RTP_PORT} -> ${OUTPUT_DEVICE}"
    exec roc-recv -vv -s "rtp://${MULTICAST_ADDR}:${RTP_PORT}" --miface="$LOCAL_IP" -o "alsa://${OUTPUT_DEVICE}" --rate="$SAMPLE_RATE" --target-latency="$TARGET_LATENCY" --frame-len="$FRAME_LEN"
fi
exit 1
EOF_RUNNER
    chmod 0755 "$RUNNER"
}

write_monitor() {
    cat > "$MONITOR_TARGET" <<'PY_MONITOR'
#!/usr/bin/env python3
import json
import uuid
import hashlib
import hmac
import secrets
import shutil
import tempfile
import sys
from pathlib import Path
from http.cookies import SimpleCookie
from urllib.parse import unquote, urlsplit, parse_qs
import math
import struct
from collections import deque
import os
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CONFIG_FILE="/etc/roc-museum.conf"
MONITOR_BUILD="4.33"
VOLUME_STATE_FILE="/var/lib/roc-museum/volume"
HEARTBEAT_INTERVAL=5
OFFLINE_AFTER=15
CONTROL_RESULTS={}
DEBUG_SLOTS=threading.BoundedSemaphore(3)
MUTED=False
RESUME_VOLUME=None
REGISTRY={}
STUDIO=None
HISTORY=None
HISTORY_ERROR=""
LATENCY_FLEET=None
REGISTRY_LOCK=threading.Lock()
# Installed alongside TX helpers; keep the standalone installer self-contained.
sys.path.insert(0,"/usr/local/lib/roc-museum")
DIAGNOSTICS=None
ANALOG_RETURN=None
ANALOG_PRESENT=False
ANALOG_LAST_ATTEMPT=-1e9

# Ultimo campione dei contatori Ethernet per calcolare incrementi recenti.
NETWORK_COUNTER_SAMPLES={}
NETWORK_COUNTER_LOCK=threading.Lock()

# Passive packet capture: never opens ALSA or binds Roc's UDP port.
# Requires CAP_NET_RAW (the existing systemd monitor runs as root).
class AudioMeter:
    """Meter audio e controllo passivo della continuità RTP."""

    INTEGRITY_WINDOW_SECONDS=60
    STALL_THRESHOLD_SECONDS=0.040
    RTP_CLOCK_RATE=44100.0

    def __init__(self):
        self.lock=threading.Lock()
        self.frames=deque()
        self.last_clip=None
        self.error="In attesa di RTP L16"

        # Stato della sessione RTP osservata. Il cambio SSRC azzera le metriche
        # di continuità per evitare di confondere due sender differenti.
        self.ssrc=None
        self.last_seq=None
        self.last_timestamp=None
        self.last_arrival=None
        self.jitter_seconds=0.0

        # Finestre mobili usate dall'autodiagnosi. Sono volutamente limitate
        # agli ultimi 60 secondi: i problemi vecchi non devono mantenere il nodo
        # in allarme dopo che il flusso è tornato stabile.
        self.packet_times=deque()
        self.sequence_gap_events=deque()
        self.out_of_order_events=deque()
        self.duplicate_events=deque()
        self.transport_stall_events=deque()
        self.packet_count=0

    def _reset_rtp_session(self,ssrc,seq,timestamp,now):
        self.ssrc=ssrc
        self.last_seq=seq
        self.last_timestamp=timestamp
        self.last_arrival=now
        self.jitter_seconds=0.0
        self.packet_times.clear()
        self.sequence_gap_events.clear()
        self.out_of_order_events.clear()
        self.duplicate_events.clear()
        self.transport_stall_events.clear()
        self.packet_count=0

    def _track_rtp(self,seq,timestamp,ssrc,now):
        if self.ssrc!=ssrc or self.last_seq is None:
            self._reset_rtp_session(ssrc,seq,timestamp,now)
            self.packet_count=1
            self.packet_times.append(now)
            return

        self.packet_count+=1
        self.packet_times.append(now)
        delta=(seq-self.last_seq)&0xffff

        if delta==0:
            self.duplicate_events.append(now)
            return

        # Delta >= 32768 indica normalmente un pacchetto arrivato in ritardo,
        # non un salto in avanti di decine di migliaia di pacchetti.
        if delta>=0x8000:
            self.out_of_order_events.append(now)
            return

        if delta>1:
            missing=delta-1
            self.sequence_gap_events.append((now,missing))

        if self.last_arrival is not None:
            arrival_delta=max(0.0,now-self.last_arrival)

            # Una pausa reale superiore a 40 ms è abbastanza lunga da essere
            # compatibile con il tipo di dropout udito nella registrazione RX.
            if arrival_delta>=self.STALL_THRESHOLD_SECONDS:
                self.transport_stall_events.append((now,arrival_delta*1000.0))

            if self.last_timestamp is not None:
                timestamp_delta=(timestamp-self.last_timestamp)&0xffffffff
                media_delta=timestamp_delta/self.RTP_CLOCK_RATE
                if 0.0<media_delta<2.0:
                    variation=abs(arrival_delta-media_delta)
                    self.jitter_seconds+=(variation-self.jitter_seconds)/16.0

        self.last_seq=seq
        self.last_timestamp=timestamp
        self.last_arrival=now

    def feed(self,packet,now=None):
        if now is None:
            now=time.monotonic()
        if len(packet)<12 or packet[0]>>6!=2:
            return

        pt=packet[1]&127
        if pt not in (10,11):
            with self.lock:
                self.error="Formato RTP non supportato (PT %d)"%pt
            return

        seq=struct.unpack_from("!H",packet,2)[0]
        timestamp=struct.unpack_from("!I",packet,4)[0]
        ssrc=struct.unpack_from("!I",packet,8)[0]

        channels=2
        if pt==11:
            channels=1

        offset=12+4*(packet[0]&15)
        if len(packet)<offset:
            return
        if packet[0]&16:
            if len(packet)<offset+4:
                return
            offset+=4+4*struct.unpack_from("!H",packet,offset+2)[0]

        end=len(packet)
        if packet[0]&32:
            padding=packet[-1]
            if not padding or padding>end-offset:
                return
            end-=padding

        if end<=offset or (end-offset)%(2*channels):
            return

        samples=struct.unpack("!%dh"%((end-offset)//2),packet[offset:end])
        stats=[]
        for channel in range(channels):
            values=samples[channel::channels]
            peak=max(abs(value) for value in values)
            square_sum=sum(value*value for value in values)
            full_scale=sum(value in (-32768,32767) for value in values)
            stats.append((peak,square_sum,len(values),full_scale))

        with self.lock:
            self.error=""
            self._track_rtp(seq,timestamp,ssrc,now)
            if any(value[3] for value in stats):
                self.last_clip=now
            self.frames.append((now,stats))
            self.prune(now)

    def prune(self,now):
        while self.frames and self.frames[0][0]<now-5:
            self.frames.popleft()

        # Bound memory even in case of excessive traffic.
        while len(self.frames)>10000:
            self.frames.popleft()

        cutoff=now-self.INTEGRITY_WINDOW_SECONDS
        while self.packet_times and self.packet_times[0]<cutoff:
            self.packet_times.popleft()
        while self.sequence_gap_events and self.sequence_gap_events[0][0]<cutoff:
            self.sequence_gap_events.popleft()
        while self.out_of_order_events and self.out_of_order_events[0]<cutoff:
            self.out_of_order_events.popleft()
        while self.duplicate_events and self.duplicate_events[0]<cutoff:
            self.duplicate_events.popleft()
        while self.transport_stall_events and self.transport_stall_events[0][0]<cutoff:
            self.transport_stall_events.popleft()

    def _integrity_snapshot(self,now,fresh):
        missing=sum(event[1] for event in self.sequence_gap_events)
        max_sequence_gap=0
        if self.sequence_gap_events:
            max_sequence_gap=max(event[1] for event in self.sequence_gap_events)

        max_transport_gap=0.0
        if self.transport_stall_events:
            max_transport_gap=max(event[1] for event in self.transport_stall_events)

        issue_times=[]
        if self.sequence_gap_events:
            issue_times.append(self.sequence_gap_events[-1][0])
        if self.out_of_order_events:
            issue_times.append(self.out_of_order_events[-1])
        if self.duplicate_events:
            issue_times.append(self.duplicate_events[-1])
        if self.transport_stall_events:
            issue_times.append(self.transport_stall_events[-1][0])

        last_issue_age=None
        if issue_times:
            last_issue_age=round(max(0.0,now-max(issue_times)),1)

        last_sequence_gap_age=None
        if self.sequence_gap_events:
            last_sequence_gap_age=round(max(0.0,now-self.sequence_gap_events[-1][0]),1)

        last_transport_stall_age=None
        if self.transport_stall_events:
            last_transport_stall_age=round(max(0.0,now-self.transport_stall_events[-1][0]),1)

        last_packet_age=None
        if self.packet_times:
            last_packet_age=round(max(0.0,now-self.packet_times[-1]),3)

        return {
            "available":fresh,
            "window_seconds":self.INTEGRITY_WINDOW_SECONDS,
            "ssrc":self.ssrc,
            "packets_total":self.packet_count,
            "packets_window":len(self.packet_times),
            "missing_packets":missing,
            "sequence_gap_events":len(self.sequence_gap_events),
            "max_sequence_gap":max_sequence_gap,
            "out_of_order_packets":len(self.out_of_order_events),
            "duplicate_packets":len(self.duplicate_events),
            "transport_stalls":len(self.transport_stall_events),
            "max_transport_gap_ms":round(max_transport_gap,1),
            "jitter_ms":round(self.jitter_seconds*1000.0,2),
            "last_issue_age_seconds":last_issue_age,
            "last_sequence_gap_age_seconds":last_sequence_gap_age,
            "last_transport_stall_age_seconds":last_transport_stall_age,
            "last_packet_age_seconds":last_packet_age
        }

    def snapshot(self):
        now=time.monotonic()
        with self.lock:
            self.prune(now)
            frames=list(self.frames)
            error=self.error
            clip_age=None
            if self.last_clip is not None:
                clip_age=round(now-self.last_clip,1)

            fresh=bool(frames and now-frames[-1][0]<2)
            integrity=self._integrity_snapshot(now,fresh)

        result={
            "available":fresh,
            "error":error if error else ("" if fresh else "Nessun pacchetto audio recente"),
            "window_seconds":5,
            "clip_age_seconds":clip_age,
            "channels":[],
            "integrity":integrity
        }
        if not fresh:
            return result

        channels=len(frames[-1][1])

        def db(value):
            if not value:
                return -96.0
            return round(max(-96,20*math.log10(value/32768)),1)

        for ch in range(channels):
            values=[frame[1][ch] for frame in frames if len(frame[1])==channels]
            peak=max(value[0] for value in values)
            rms=math.sqrt(sum(value[1] for value in values)/sum(value[2] for value in values))
            result["channels"].append({
                "peak_dbfs":db(peak),
                "rms_dbfs":db(rms),
                "full_scale_samples":sum(value[3] for value in values)
            })
        return result

METER=AudioMeter()

class AnalogReturn:
    """Optional Scarlett line return; independent of Roc playback device."""
    def __init__(self, device=None):
        self.lock=threading.Lock()
        self.stop_event=threading.Event()
        self.analysis_stop=threading.Event()
        self.analysis_thread=None
        self.thread=None
        self.process=None
        self.diagnostics=None
        self.analysis_error=""
        self.capture_health={"xrun_events":0,"stderr_messages":0}
        self.stderr_buffer=""
        self.updated=0
        self.device=device
        self.channels=[]
        self.error="Scarlett non rilevata: ritorno analogico opzionale"

    def feed(self, raw, now=None):
        received_at=time.monotonic() if now is None else now
        samples=struct.unpack("<%dh"%(len(raw)//2),raw)
        channels=[]
        for ch in range(2):
            values=samples[ch::2]
            rms=math.sqrt(sum(v*v for v in values)/len(values))
            channels.append({"rms_dbfs":round(20*math.log10(max(rms,0.52)/32768),1),
                             "clipped":any(abs(v)>=32760 for v in values)})
        if self.diagnostics is not None and not self.stop_event.is_set():
            self.diagnostics.update_capture_health(self.capture_health)
            self.diagnostics.feed_capture(raw,received_at)
        with self.lock:
            self.channels=channels;self.updated=received_at;self.error=""

    def snapshot(self, reference, muted=False):
        with self.lock:
            fresh=bool(self.updated and time.monotonic()-self.updated<2)
            result={"available":fresh,"device":self.device,"channels":list(self.channels) if fresh else [],
                    "status":"unavailable","message":self.error or "Acquisizione analogica interrotta",
                    "comparison":"levels_only"}
        if not fresh: return result
        heard=any(c["rms_dbfs"]>-55 for c in result["channels"])
        if any(c["clipped"] for c in result["channels"]):
            status,message="capture_clipping","Ingresso Scarlett vicino al fondo scala: controllare il gain del ritorno"
        elif muted:
            status,message=("audio_while_muted","Audio rilevato durante mute: verificare cablaggio e sorgenti") if heard else ("expected_silence","Mute: ritorno silenzioso")
        elif not reference.get("available"):
            status,message="reference_unavailable","Riferimento RTP/guadagno non disponibile: confronto impossibile"
        else:
            expected=any(c["rms_dbfs"]>-45 for c in reference.get("channels",[]))
            if expected and not heard:
                status,message="missing_return","Audio atteso ma ritorno silenzioso: verificare uscita RX, cavo e gain Scarlett"
            elif expected:
                status,message="signal_present","Ritorno presente; identità e integrità della forma d’onda non verificate"
            elif heard:
                status,message="unexpected_audio","Audio nel ritorno con riferimento basso: verificare sorgente, rumore e ritardo"
            else:
                status,message="expected_silence","Riferimento e ritorno silenziosi o sotto soglia"
        result.update(status=status,message=message)
        return result

    def note_stderr(self, raw):
        text=raw.decode("utf-8",errors="replace")
        self.stderr_buffer=(self.stderr_buffer+text)[-4096:]
        lines=self.stderr_buffer.split("\n")
        self.stderr_buffer=lines.pop()
        for line in lines:
            if not line.strip(): continue
            self.capture_health["stderr_messages"]+=1
            self.capture_health["last_message"]=line[-600:]
            self.capture_health["last_message_at"]=time.time()
            if re.search(r"\b(?:overruns?|underruns?|xruns?)\b",line,re.I):
                self.capture_health["xrun_events"]+=1
                self.capture_health["last_xrun_monotonic"]=time.monotonic()
                self.capture_health["last_xrun_at"]=time.time()
            print("Acquisizione spia: "+line[-600:],flush=True)
        if self.diagnostics is not None: self.diagnostics.update_capture_health(self.capture_health)

    def enable_analysis(self):
        global DIAGNOSTICS
        if self.stop_event.is_set(): return
        try:
            # Load NumPy only after the selected ADC has delivered PCM.
            from rx_diagnostics import Diagnostics, np
            if np is None: raise ImportError("NumPy non disponibile")
            diagnostics=Diagnostics()
            with self.lock:
                if self.stop_event.is_set(): return
                self.diagnostics=diagnostics
                DIAGNOSTICS=diagnostics
                self.analysis_thread=threading.Thread(target=diagnostics.loop,args=(self.analysis_stop,),daemon=True)
                self.analysis_thread.start()
        except ImportError as error:
            self.analysis_error="Analisi forme d’onda non disponibile: "+str(error)

    def stop(self):
        global DIAGNOSTICS
        with self.lock:
            self.stop_event.set();self.analysis_stop.set()
            if DIAGNOSTICS is self.diagnostics: DIAGNOSTICS=None
            process=self.process
        if process is not None and process.poll() is None:
            try: process.terminate()
            except OSError: pass

    def loop(self):
        global DIAGNOSTICS
        process=None
        try:
            if not self.device or self.stop_event.is_set(): return
            process=subprocess.Popen(["arecord","-q","-D",self.device,"-t","raw","-f","S16_LE",
                                      "-r","16000","-c","2","--period-time=20000","--buffer-time=100000"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
            with self.lock: self.process=process
            if self.stop_event.is_set(): return
            import select
            buffer=b"";analysis_started=False
            readers=[process.stdout,process.stderr]
            while not self.stop_event.is_set():
                ready,_,_=select.select(readers,[],[],3)
                if not ready: raise OSError("Timeout acquisizione Scarlett")
                if process.stderr in ready:
                    message=os.read(process.stderr.fileno(),4096)
                    if message: self.note_stderr(message)
                    else: readers.remove(process.stderr)
                if process.stdout not in ready: continue
                raw=os.read(process.stdout.fileno(),32000-len(buffer))
                if not raw: raise OSError("Acquisizione Scarlett interrotta o dispositivo occupato")
                received_at=time.monotonic()
                buffer+=raw
                if len(buffer)==32000:
                    if not analysis_started:
                        self.enable_analysis();analysis_started=True
                    self.feed(buffer,received_at);buffer=b""
        except (OSError,subprocess.SubprocessError) as error:
            with self.lock:
                self.error=str(error)+(": "+self.capture_health["last_message"] if self.capture_health.get("last_message") else "");self.updated=0;self.channels=[]
        finally:
            if self.stderr_buffer: self.note_stderr(b"\n")
            self.stop()
            if process is not None:
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired: process.kill();process.wait()
                process.stdout.close()
                process.stderr.close()
            if self.analysis_thread is not None: self.analysis_thread.join(timeout=5)
            with self.lock:
                self.process=None;self.diagnostics=None
                self.channels=[];self.updated=0


def refresh_analog_return(config):
    """Reuse the existing heartbeat for hotplug discovery; no idle worker."""
    global ANALOG_RETURN, ANALOG_PRESENT, ANALOG_LAST_ATTEMPT
    if config.get("ROLE")!="rx": return
    # Reading procfs is cheap; no ALSA process, import or PCM buffer when absent.
    ANALOG_PRESENT=bool(re.search("scarlett|focusrite",read_text("/proc/asound/cards"),re.I))
    capture=ANALOG_RETURN
    if not ANALOG_PRESENT:
        if capture is not None:
            capture.stop()
            if capture.thread is None or not capture.thread.is_alive(): ANALOG_RETURN=None
        ANALOG_LAST_ATTEMPT=-1e9
        return
    if capture is not None and capture.thread is not None and capture.thread.is_alive(): return
    now=time.monotonic()
    if now-ANALOG_LAST_ATTEMPT<30: return
    ANALOG_LAST_ATTEMPT=now
    try:
        listing=subprocess.run(["arecord","-l"],capture_output=True,text=True,check=True,timeout=1,
                               env={**os.environ,"LC_ALL":"C"}).stdout
        devices=[]
        for line in listing.splitlines():
            if re.search("scarlett|focusrite",line,re.I):
                match=re.search(r"card \d+:\s*([^\s\[]+).*device (\d+):",line)
                if match: devices.append("plughw:CARD=%s,DEV=%s"%match.groups())
        devices=list(dict.fromkeys(devices))
        if len(devices)!=1: return
        capture=AnalogReturn(devices[0]);ANALOG_RETURN=capture
        capture.thread=threading.Thread(target=capture.loop,daemon=True)
        capture.thread.start()
    except (OSError,subprocess.SubprocessError):
        pass


def analog_snapshot_fields(meter, muted, roc_error="", roc_warning=""):
    capture=ANALOG_RETURN
    if not ANALOG_PRESENT or capture is None: return {}
    fields={"analog_return":capture.snapshot(meter,muted)}
    diagnostics=DIAGNOSTICS
    if diagnostics is not None:
        diagnostics.update_context(muted,meter,roc_error,roc_warning)
        fields["waveform_diagnostics"]=diagnostics.snapshot()
    elif capture.analysis_error:
        fields["waveform_diagnostics"]={"status":"unavailable","message":capture.analysis_error}
    return fields

def meter_loop(config):
    group=socket.inet_aton(config.get("MULTICAST_ADDR","239.30.0.1"))
    port=int(config.get("RTP_PORT","10001"))
    while True:
        try:
            # Linux cooked capture exposes IP packets, including outgoing TX packets.
            with socket.socket(socket.AF_PACKET,socket.SOCK_DGRAM,socket.htons(0x0003)) as sock:
                sock.bind((config.get("NETWORK_IFACE","eth0"),0))
                while True:
                    packet=sock.recv(65535)
                    if len(packet)<28 or packet[0]>>4!=4 or packet[9]!=17 or packet[16:20]!=group: continue
                    ihl=(packet[0]&15)*4
                    if ihl<20 or len(packet)<ihl+8: continue
                    if struct.unpack_from("!H",packet,6)[0]&0x3fff: continue
                    if struct.unpack_from("!H",packet,ihl+2)[0]!=port: continue
                    length=struct.unpack_from("!H",packet,ihl+4)[0]
                    if length<8 or ihl+length>len(packet): continue
                    audio_packet=packet[ihl+8:ihl+length]
                    METER.feed(audio_packet)
                    diagnostics=DIAGNOSTICS
                    if diagnostics is not None: diagnostics.feed_rtp(audio_packet)
        except OSError as exc:
            with METER.lock: METER.error="Meter non disponibile: "+str(exc)
            time.sleep(5)

def read_config():
    config={}
    with open(CONFIG_FILE,"r",encoding="utf-8") as handle:
        for raw in handle:
            line=raw.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            key,value=line.split("=",1)
            value=value.strip()
            if len(value)>=2 and value[0]=='"' and value[-1]=='"': value=value[1:-1]
            config[key]=value
    return config

def run(command):
    try:
        completed=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=2,check=False)
        return completed.returncode,completed.stdout.strip()
    except (OSError,subprocess.TimeoutExpired):
        return 127,""

def esc_html(value):
    return str(value).replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;").replace("'","&#39;")

def read_text(path):
    try:
        with open(path,"r",encoding="utf-8") as handle: return handle.read().strip()
    except OSError: return ""

def local_ipv4(interface):
    code,output=run(["ip","-4","-o","addr","show","dev",interface,"scope","global"])
    if code!=0: return ""
    for line in output.splitlines():
        fields=line.split()
        if len(fields)>=4: return fields[3].split("/")[0]
    return ""

def service_details():
    code,output=run(["systemctl","show","roc-museum.service","--property=ActiveState,SubState,Result,NRestarts","--no-pager"])
    details={"active":"unknown","sub":"unknown","result":"","restarts":0}
    if output:
        for line in output.splitlines():
            if "=" not in line:
                continue
            key,value=line.split("=",1)
            if key=="ActiveState": details["active"]=value or "unknown"
            elif key=="SubState": details["sub"]=value or "unknown"
            elif key=="Result": details["result"]=value
            elif key=="NRestarts":
                try: details["restarts"]=int(value)
                except ValueError: details["restarts"]=0
    return details

def recent_roc_messages():
    code,output=run(["journalctl","-u","roc-museum.service","--since=-5min","-n","80","--no-pager","-o","cat"])
    if not output:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]

def last_roc_error():
    matches=[]
    for line in recent_roc_messages():
        low=line.lower()
        if "[err]" in low or " error" in low or "failed" in low or "can't " in low or "cannot " in low or "unbound variable" in low:
            matches.append(line)
    if not matches:
        return ""
    return matches[-1][-240:]

def last_roc_warning():
    matches=[]
    for line in recent_roc_messages():
        low=line.lower()
        if "[wrn]" in low or "underrun" in low or "overrun" in low or "xrun" in low:
            matches.append(line)
    if not matches:
        return ""
    return matches[-1][-240:]

def network_rtt_ms(target):
    if not target:
        return None
    code,output=run(["ping","-c","1","-W","1",target])
    if code!=0:
        return None
    match=re.search(r"time[=<]([0-9.]+)",output)
    if match is None:
        return None
    try:
        return round(float(match.group(1)),2)
    except ValueError:
        return None

def process_state(role):
    process_name="roc-recv"
    if role=="tx": process_name="roc-send"
    code,output=run(["pgrep","-x",process_name])
    if code==0 and output: return True
    return False

def audio_device_state(role):
    if role=="tx":
        code,output=run(["arecord","-l"])
        if code==0 and re.search(r"scarlett|focusrite",output,re.IGNORECASE): return True
        return False
    code,output=run(["aplay","-l"])
    if code==0 and re.search(r"headphones|bcm2835",output,re.IGNORECASE): return True
    return False

def output_card():
    code,output=run(["aplay","-l"])
    for line in output.splitlines():
        if re.search(r"headphones|bcm2835",line,re.I):
            match=re.search(r"card (\d+):",line)
            if match: return match.group(1)
    return None

def output_mixer():
    card=output_card()
    if card is None: return ""
    code,output=run(["amixer","-c",card,"get","PCM"])
    return output if code==0 else ""

def post_fader_meter(meter, mixer):
    meter=dict(meter)
    meter["position"]="post_fader_estimate"
    gains=[]
    for line in mixer.splitlines():
        if "Playback" not in line or "%]" not in line: continue
        match=re.search(r"\[(-?[0-9.]+)dB\]",line)
        if match:
            gains.append((float(match.group(1)),"[off]" in line))
    channels=meter.get("channels",[])
    if not gains or len(gains) not in (1,len(channels)):
        meter.update(available=False,error="Guadagno ALSA in dB non disponibile",channels=[])
        return meter
    converted=[]
    for index,channel in enumerate(channels):
        gain,muted=gains[0 if len(gains)==1 else index]
        converted.append({"peak_dbfs":-96.0 if muted else round(max(-96,channel["peak_dbfs"]+gain),1),
                          "rms_dbfs":-96.0 if muted else round(max(-96,channel["rms_dbfs"]+gain),1),
                          "gain_db":gain,"muted":muted,
                          "input_full_scale_samples":channel["full_scale_samples"]})
    meter["channels"]=converted
    meter["input_clip_age_seconds"]=meter.pop("clip_age_seconds",None)
    return meter

def get_volume_percent():
    output=output_mixer()
    if not output:
        return None
    match=re.search(r"\[(\d{1,3})%\]",output)
    if match is None:
        return None
    try:
        return max(0,min(100,int(match.group(1))))
    except ValueError:
        return None

def set_volume_percent(value,persist=True):
    try:
        value=max(0,min(100,int(value)))
    except (TypeError,ValueError):
        return False
    card=output_card()
    if card is None: return False
    code,output=run(["amixer","-c",card,"sset","PCM",str(value)+"%"])
    if code!=0:
        return False
    if persist:
        try:
            os.makedirs(os.path.dirname(VOLUME_STATE_FILE),exist_ok=True)
            with open(VOLUME_STATE_FILE,"w",encoding="utf-8") as handle:
                handle.write(str(value)+"\n")
        except OSError:
            pass
    return True

def restore_saved_volume():
    try:
        with open(VOLUME_STATE_FILE,"r",encoding="utf-8") as handle:
            value=int(handle.read().strip())
    except (OSError,ValueError):
        return
    set_volume_percent(value,persist=False)

def network_state(interface):
    path=os.path.join("/sys/class/net",interface)
    result={"interface":interface,"ipv4":local_ipv4(interface),"carrier":False,"speed_mbps":None,
            "rx_errors":0,"rx_dropped":0,"tx_errors":0,"tx_dropped":0,
            "rx_errors_delta":0,"rx_dropped_delta":0,"tx_errors_delta":0,"tx_dropped_delta":0,
            "counter_window_seconds":0.0}

    if not os.path.isdir(path):
        return result

    if read_text(os.path.join(path,"carrier"))=="1":
        result["carrier"]=True

    speed=read_text(os.path.join(path,"speed"))
    try:
        result["speed_mbps"]=int(speed)
    except ValueError:
        result["speed_mbps"]=None

    counters={}
    for counter in ("rx_errors","rx_dropped","tx_errors","tx_dropped"):
        raw=read_text(os.path.join(path,"statistics",counter))
        try:
            counters[counter]=int(raw)
        except ValueError:
            counters[counter]=0
        result[counter]=counters[counter]

    now=time.monotonic()
    with NETWORK_COUNTER_LOCK:
        previous=NETWORK_COUNTER_SAMPLES.get(interface)
        NETWORK_COUNTER_SAMPLES[interface]={"time":now,"counters":dict(counters)}

    if previous is not None:
        result["counter_window_seconds"]=round(max(0.0,now-previous["time"]),1)
        old=previous["counters"]
        for counter in ("rx_errors","rx_dropped","tx_errors","tx_dropped"):
            current=counters[counter]
            before=old.get(counter,current)
            delta=current-before
            # Un reset/reboot dell'interfaccia può riportare il contatore a zero:
            # in quel caso non generare un falso incremento negativo o enorme.
            if delta<0:
                delta=0
            result[counter+"_delta"]=delta

    return result

def multicast_state(role,interface,group,roc_process):
    if role=="tx":
        if roc_process: return "sending"
        return "stopped"
    code,output=run(["ip","maddr","show","dev",interface])
    if code==0 and group in output: return "joined"
    return "not_joined"

def temperature():
    raw=read_text("/sys/class/thermal/thermal_zone0/temp")
    try: return round(float(raw)/1000.0,1)
    except ValueError: return None

def throttled():
    code,output=run(["vcgencmd","get_throttled"])
    if code!=0:
        return None
    match=re.search(r"0x[0-9a-fA-F]+",output)
    if match is None:
        return None

    raw=match.group(0)
    try:
        value=int(raw,16)
    except ValueError:
        return {"raw":raw,"active":False,"historical":False,"current_flags":[],"historical_flags":[]}

    current_map=(
        (0x1,"undervoltage"),
        (0x2,"frequenza CPU limitata"),
        (0x4,"throttling"),
        (0x8,"limite termico soft")
    )
    historical_map=(
        (0x10000,"undervoltage"),
        (0x20000,"frequenza CPU limitata"),
        (0x40000,"throttling"),
        (0x80000,"limite termico soft")
    )

    current_flags=[]
    for bit,label in current_map:
        if value & bit:
            current_flags.append(label)

    historical_flags=[]
    for bit,label in historical_map:
        if value & bit:
            historical_flags.append(label)

    return {
        "raw":raw,
        "active":bool(current_flags),
        "historical":bool(historical_flags),
        "current_flags":current_flags,
        "historical_flags":historical_flags
    }

def build_snapshot(config):
    role=config.get("ROLE","")
    interface=config.get("NETWORK_IFACE","eth0")
    roc_process=process_state(role)
    service=service_details()
    snapshot={"name":config.get("NODE_NAME",socket.gethostname()),"hostname":socket.gethostname(),"role":role,"software_version":config.get("SOFTWARE_VERSION",""),"timestamp":time.time(),"roc_service":service.get("active","unknown"),"roc_service_sub":service.get("sub","unknown"),"roc_result":service.get("result",""),"roc_restarts":service.get("restarts",0),"roc_process":roc_process,"roc_last_error":last_roc_error(),"roc_last_warning":last_roc_warning(),"audio_device":audio_device_state(role),"volume_percent":get_volume_percent() if role=="rx" else None,"target_latency":config.get("TARGET_LATENCY",""),"network_rtt_ms":network_rtt_ms(config.get("TX_IP","")) if role=="rx" else 0.0,"network":network_state(interface),"multicast":{"group":config.get("MULTICAST_ADDR",""),"state":multicast_state(role,interface,config.get("MULTICAST_ADDR",""),roc_process)},"temperature_c":temperature(),"throttled":throttled()}
    try: snapshot["load_1m"]=round(os.getloadavg()[0],2)
    except OSError: snapshot["load_1m"]=None
    meter=METER.snapshot()
    if role=="rx" and meter["available"]:
        meter=post_fader_meter(meter,output_mixer())
    snapshot["muted"]=MUTED if role=="rx" else False
    if role=="rx" and MUTED: snapshot["volume_percent"]=RESUME_VOLUME
    snapshot["audio_meter"]=meter
    if role=="rx":
        snapshot.update(analog_snapshot_fields(meter,MUTED,snapshot["roc_last_error"],snapshot["roc_last_warning"]))
    if role=="rx":
        snapshot.update(probe_mode=bool(ANALOG_PRESENT),latency_control_supported=True,latency_revision=config.get("FLEET_LATENCY_REVISION",""),
                        latency_control_error=config.get("_LATENCY_ERROR",""))
    return snapshot

def heartbeat_loop(config):
    role=config.get("ROLE","")
    tx_ip=config.get("TX_IP","")
    port=int(config.get("MONITOR_PORT","19090"))
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    while True:
        refresh_analog_return(config)
        snapshot=build_snapshot(config)
        if role=="tx":
            snapshot["received_at"]=time.time()
            with REGISTRY_LOCK: REGISTRY[snapshot["name"]]=snapshot
        else:
            payload=json.dumps(snapshot,separators=(",",":")).encode("utf-8")
            try: sock.sendto(payload,(tx_ip,port))
            except OSError: pass
        if role=="tx": record_diagnostic_history(config)
        time.sleep(HEARTBEAT_INTERVAL)

def listener_loop(config):
    port=int(config.get("MONITOR_PORT","19090"))
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    sock.bind(("0.0.0.0",port))
    while True:
        payload,source=sock.recvfrom(65535)
        try: snapshot=json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError,json.JSONDecodeError): continue
        if not isinstance(snapshot,dict): continue
        if snapshot.get("type")=="control_ack":
            with REGISTRY_LOCK:
                pending=CONTROL_RESULTS.get(str(snapshot.get("id")))
                if pending and pending["ip"]==source[0]:
                    pending.update(state="confirmed" if snapshot.get("ok") is True else "failed",
                                   muted=snapshot.get("muted"),volume_percent=snapshot.get("volume_percent"))
            continue
        snapshot["source_ip"]=source[0]
        snapshot["received_at"]=time.time()
        name=snapshot.get("name",source[0])
        with REGISTRY_LOCK: REGISTRY[name]=snapshot

def apply_control(command,value,config=None):
    global MUTED,RESUME_VOLUME
    if command=="set_latency" and config is not None:
        try:
            from fleet_latency import apply_receiver
            result=apply_receiver(config,value,CONFIG_FILE)
            config.pop("_LATENCY_ERROR",None)
            return result
        except (ValueError,OSError,RuntimeError) as error:
            config["_LATENCY_ERROR"]=str(error)
            return False
    if command=="set_mute" and isinstance(value,bool):
        if value==MUTED: return True
        if value:
            previous=get_volume_percent()
            if previous is None or not set_volume_percent(0,persist=False): return False
            if get_volume_percent()!=0: return False
            RESUME_VOLUME=previous
            MUTED=True
        else:
            if RESUME_VOLUME is None or not set_volume_percent(RESUME_VOLUME): return False
            if get_volume_percent()!=RESUME_VOLUME: return False
            MUTED=False
        return True
    if command=="set_volume" and type(value)==int and 0<=value<=100:
        if MUTED:
            # Change the recall level without making a muted receiver audible.
            RESUME_VOLUME=value
            return True
        return set_volume_percent(value) and get_volume_percent()==value
    return False

def command_listener_loop(config):
    port=int(config.get("CONTROL_PORT","19091"))
    tx_ip=config.get("TX_IP","")
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0",port))
    while True:
        payload,source=sock.recvfrom(4096)
        if source[0]!=tx_ip: continue
        try: message=json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError,json.JSONDecodeError): continue
        if not isinstance(message,dict): continue
        ok=apply_control(message.get("command"),message.get("value"),config)
        ack={"type":"control_ack","id":message.get("id"),"ok":ok,
             "muted":MUTED,"volume_percent":RESUME_VOLUME if MUTED else get_volume_percent()}
        try: sock.sendto(json.dumps(ack).encode(),(tx_ip,int(config.get("MONITOR_PORT","19090"))))
        except OSError: pass

def send_control(config,node_name,command,value=None):
    port=int(config.get("CONTROL_PORT","19091"))
    with REGISTRY_LOCK:
        node=dict(REGISTRY.get(node_name,{}) or {})
    if not node or node.get("role")!="rx":
        return False,"RX non trovato"
    source_ip=node.get("source_ip") or node.get("network",{}).get("ipv4")
    if not source_ip:
        return False,"IP RX non disponibile"
    received_at=node.get("received_at",node.get("timestamp",0))
    if time.time()-received_at>OFFLINE_AFTER:
        return False,"RX offline"
    command_id=uuid.uuid4().hex
    with REGISTRY_LOCK:
        for key in list(CONTROL_RESULTS):
            if time.time()-CONTROL_RESULTS[key]["created"]>60: del CONTROL_RESULTS[key]
        CONTROL_RESULTS[command_id]={"ip":source_ip,"created":time.time(),"state":"sent"}
    message={"command":command,"id":command_id}
    if value is not None:
        message["value"]=value
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    try:
        sock.sendto(json.dumps(message,separators=(",",":")).encode("utf-8"),(source_ip,port))
    except OSError as exc:
        return False,str(exc)
    finally:
        sock.close()
    return True,command_id

def analog_return_problem(node):
    analog=node.get("analog_return",{}) or {}
    waveform=node.get("waveform_diagnostics",{}) or {}
    status=analog.get("status")
    if status in ("capture_clipping","audio_while_muted"):
        return True
    # Let aligned analysis decide silence transitions when it is available.
    if waveform.get("status") not in (None,"unavailable","error"):
        return False
    return status in ("missing_return","unexpected_audio")

def apply_audio_diagnosis(nodes):
    """Classifica il punto più probabile della catena in cui nasce il dropout."""

    tx_node=None
    for node in nodes:
        if node.get("role")=="tx":
            tx_node=node
            break

    tx_integrity={}
    tx_meter={}
    if tx_node is not None:
        tx_meter=tx_node.get("audio_meter",{}) or {}
        tx_integrity=tx_meter.get("integrity",{}) or {}

    # Il monitor TX usa una cattura AF_PACKET in user space. Una singola pausa
    # nei tempi di osservazione può essere causata dallo scheduling del monitor
    # anche quando il kernel continua a trasmettere regolarmente. Per attribuire
    # il problema al TX serve quindi una conferma temporale dagli RX.
    online_rx=[]
    for candidate in nodes:
        if candidate.get("role")!="rx" or not candidate.get("online",True):
            continue
        candidate_meter=candidate.get("audio_meter",{}) or {}
        if candidate_meter.get("available"):
            online_rx.append(candidate)

    required_confirmations=1
    if len(online_rx)>=2:
        required_confirmations=2

    def correlated_issue(tx_age,rx_age,tolerance=5.0):
        if tx_age is None or rx_age is None:
            return False
        return abs(float(tx_age)-float(rx_age))<=tolerance

    sequence_confirmations=0
    stall_confirmations=0
    tx_sequence_age=tx_integrity.get("last_sequence_gap_age_seconds")
    tx_stall_age=tx_integrity.get("last_transport_stall_age_seconds")

    for candidate in online_rx:
        rx_integrity=(candidate.get("audio_meter",{}) or {}).get("integrity",{}) or {}
        if rx_integrity.get("missing_packets",0)>0 and correlated_issue(
                tx_sequence_age,rx_integrity.get("last_sequence_gap_age_seconds")):
            sequence_confirmations+=1
        if rx_integrity.get("transport_stalls",0)>0 and correlated_issue(
                tx_stall_age,rx_integrity.get("last_transport_stall_age_seconds")):
            stall_confirmations+=1

    tx_sequence_observed=tx_integrity.get("missing_packets",0)>0
    tx_stall_observed=tx_integrity.get("transport_stalls",0)>0
    tx_sequence_confirmed=tx_sequence_observed and sequence_confirmations>=required_confirmations
    tx_stall_confirmed=tx_stall_observed and stall_confirmations>=required_confirmations
    tx_has_confirmed_transport_problem=tx_sequence_confirmed or tx_stall_confirmed
    tx_has_unconfirmed_observation=(tx_sequence_observed or tx_stall_observed) and not tx_has_confirmed_transport_problem

    for node in nodes:
        meter=node.get("audio_meter",{}) or {}
        integrity=meter.get("integrity",{}) or {}
        warning=(node.get("roc_last_warning") or "").lower()
        throttled_state=node.get("throttled") or {}
        if not isinstance(throttled_state,dict):
            throttled_state={"raw":str(throttled_state),"active":False,"historical":False,
                             "current_flags":[],"historical_flags":[]}

        diagnosis={"severity":"ok","code":"RTP_CONTINUOUS",
                   "summary":"RTP regolare negli ultimi 60 s",
                   "detail":"Nessuna discontinuità RTP rilevata nella finestra di osservazione."}

        if not node.get("online",True):
            diagnosis={"severity":"info","code":"NODE_OFFLINE",
                       "summary":"Nodo offline",
                       "detail":"Autodiagnosi sospesa finché il nodo non torna online."}
        elif not meter.get("available"):
            if node.get("role")=="rx" and tx_meter.get("available"):
                diagnosis={"severity":"critical","code":"RX_NO_RTP",
                           "summary":"RX online ma senza RTP recente",
                           "detail":"Il TX vede il flusso; controllare multicast, porta switch, IGMP e roc-recv di questo RX."}
            else:
                diagnosis={"severity":"critical","code":"NO_RTP",
                           "summary":"Nessun RTP audio recente",
                           "detail":"Controllare sender Roc, bus audio e instradamento multicast."}
        elif throttled_state.get("active"):
            flags=throttled_state.get("current_flags",[])
            if flags==["limite termico soft"]:
                diagnosis={"severity":"warning","code":"THERMAL_SOFT_LIMIT",
                           "summary":"Limite termico soft Raspberry attivo",
                           "detail":"La CPU ha raggiunto il limite termico soft. Non è un errore di alimentazione; verificare temperatura, ventilazione e carico CPU."}
            elif "undervoltage" in flags:
                current=", ".join(flags)
                diagnosis={"severity":"warning","code":"POWER_UNDERVOLTAGE",
                           "summary":"Sottotensione Raspberry attiva",
                           "detail":"Segnalazione corrente Raspberry: "+current+". Verificare alimentatore, cavo e caduta di tensione."}
            else:
                current=", ".join(flags) or "anomalia termica/prestazioni"
                diagnosis={"severity":"warning","code":"POWER_THERMAL_STATE",
                           "summary":"Limitazione Raspberry attualmente attiva",
                           "detail":"Segnalazione corrente Raspberry: "+current+". Verificare temperatura, alimentazione e carico CPU."}
        elif "underrun" in warning or "overrun" in warning or "xrun" in warning:
            diagnosis={"severity":"warning","code":"RX_BUFFER_XRUN",
                       "summary":"Possibile underrun/overrun audio",
                       "detail":"Roc/ALSA ha segnalato un xrun recente; controllare carico CPU e aumentare la latenza RX se necessario."}
        elif node.get("role")=="tx" and tx_has_confirmed_transport_problem:
            diagnosis={"severity":"warning","code":"TX_RTP_DISCONTINUITY_CONFIRMED",
                       "summary":"Discontinuità TX confermata dagli RX",
                       "detail":"La stessa anomalia RTP è stata osservata temporalmente su più ricevitori: controllare bus TX, player, roc-send e carico CPU."}
        elif node.get("role")=="tx" and tx_has_unconfirmed_observation:
            diagnosis={"severity":"info","code":"TX_MONITOR_STALL_UNCONFIRMED",
                       "summary":"Pausa osservata sul monitor TX, non confermata dagli RX",
                       "detail":"Gli RX non mostrano la stessa anomalia. Può trattarsi di scheduling della cattura locale e non di una reale interruzione del flusso."}
        elif node.get("role")=="rx" and tx_has_confirmed_transport_problem:
            diagnosis={"severity":"warning","code":"UPSTREAM_TX_DISCONTINUITY_CONFIRMED",
                       "summary":"Discontinuità TX confermata su più RX",
                       "detail":"L'anomalia è coerente tra TX e ricevitori ed è quindi probabilmente a monte della rete RX."}
        elif node.get("role")=="rx" and integrity.get("missing_packets",0)>0:
            diagnosis={"severity":"warning","code":"NETWORK_SEQUENCE_GAPS",
                       "summary":"Pacchetti RTP mancanti o arrivati troppo tardi sull'RX",
                       "detail":"Il TX è regolare ma questo RX presenta salti di sequenza: controllare Ethernet, switch, IGMP e multicast."}
        elif node.get("role")=="rx" and integrity.get("transport_stalls",0)>0:
            diagnosis={"severity":"warning","code":"NETWORK_BURST_STALL",
                       "summary":"Pause anomale nell'arrivo RTP sull'RX",
                       "detail":"Rilevate pause superiori a 40 ms; compatibile con burst di rete, scheduling o starvation del ricevitore."}
        elif node.get("role")=="rx" and integrity.get("jitter_ms",0)>20:
            diagnosis={"severity":"warning","code":"HIGH_RTP_JITTER",
                       "summary":"Jitter RTP elevato",
                       "detail":"Il jitter osservato supera 20 ms; valutare rete e TARGET_LATENCY dell'RX."}
        elif node.get("role")=="rx":
            net=node.get("network",{}) or {}
            recent_errors=(net.get("rx_errors_delta",0)+net.get("rx_dropped_delta",0)+
                           net.get("tx_errors_delta",0)+net.get("tx_dropped_delta",0))
            if recent_errors>0:
                window=net.get("counter_window_seconds",0)
                diagnosis={"severity":"warning","code":"ETHERNET_ERRORS_ACTIVE",
                           "summary":"Nuovi errori/drop Ethernet rilevati",
                           "detail":"I contatori Ethernet sono aumentati nell'ultimo campione ("+str(window)+" s). Verificare cavo, porta switch e interfaccia."}
            else:
                diagnosis={"severity":"ok","code":"RX_RTP_CLEAN",
                           "summary":"RTP regolare sull'RX",
                           "detail":"Nessun nuovo errore Ethernet nel campione recente. Se il dropout è udibile, concentrare la diagnosi su roc-recv, ALSA, DAC, jack o amplificatore."}

        # Keep the v4.25 transport diagnosis, then add physical-output evidence.
        node["transport_diagnosis"]=dict(diagnosis)
        waveform=node.get("waveform_diagnostics",{}) or {}
        analog=node.get("analog_return",{}) or {}
        analog_fault=analog_return_problem(node)
        if node.get("role")=="rx" and node.get("online",True) and (waveform.get("confirmed") or analog_fault):
            evidence=waveform if waveform.get("confirmed") else analog
            message=evidence.get("message","Anomalia nel ritorno analogico RX")
            if diagnosis["severity"] in ("ok","info"):
                diagnosis={"severity":"warning","code":"RX_OUTPUT_"+evidence.get("status","unknown").upper(),
                           "summary":message,"detail":diagnosis["summary"]+". "+diagnosis["detail"]}
            else:
                diagnosis=dict(diagnosis)
                diagnosis["detail"]+=" Ritorno RX: "+message
        node["audio_diagnosis"]=diagnosis

def system_status(config):
    now=time.time()
    with REGISTRY_LOCK: nodes=[dict(item) for item in REGISTRY.values()]
    for node in nodes:
        received_at=node.get("received_at",node.get("timestamp",0))
        age=max(0,now-received_at)
        online=age<=OFFLINE_AFTER
        problems=[]
        source_owned=False
        if node.get("role")=="tx" and STUDIO is not None:
            player=STUDIO.snapshot()
            node["studio_source"]=player["status"]
            source_owned=bool(player.get("audio_bus",{} ) and player["audio_bus"]["active"])
            if source_owned:
                node["roc_service_sub"]="bus microfono + musica"
                node["microphone_online"]=player["audio_bus"]["microphone_online"]
                if not node["microphone_online"]: problems.append("microphone")
                node["roc_process"]=player["sender_running"]
                node["roc_last_error"]=player["error"]
        waiting_audio=(node.get("role")=="tx" and online and node.get("roc_service")=="active" and not node.get("audio_device") and not node.get("roc_process") and node.get("network",{}).get("carrier"))
        if not online: problems.append("offline")
        if node.get("roc_service")!="active" and not source_owned: problems.append("roc_service")
        if not node.get("roc_process") and not waiting_audio and node.get("studio_source")!="paused": problems.append("roc_process")
        if not node.get("audio_device") and not waiting_audio and not source_owned: problems.append("audio_device")
        if not node.get("network",{}).get("carrier"): problems.append("ethernet")
        if analog_return_problem(node):
            problems.append("analog_return")
        if node.get("waveform_diagnostics",{}).get("confirmed"):
            problems.append("waveform_diagnostics")
        state="OK"
        if waiting_audio: state="ATTESA_AUDIO"
        elif problems: state="ATTENZIONE"
        if "offline" in problems: state="OFFLINE"
        if waiting_audio:
            node["roc_last_error"]=""
        node["age_seconds"]=round(age,1)
        node["online"]=online
        node["problems"]=problems
        node["state"]=state
    apply_audio_diagnosis(nodes)

    def sort_key(node):
        priority=1
        if node.get("role")=="tx": priority=0
        return priority,node.get("name","")
    nodes.sort(key=sort_key)
    return {"system":"RETE MUSEO - AudioOverNetwork","generated_at":now,"software_version":config.get("SOFTWARE_VERSION",""),"monitor_build":MONITOR_BUILD,"expected_rx":int(config.get("EXPECTED_RX_COUNT","3")),"nodes":nodes}

def record_diagnostic_history(config):
    global HISTORY_ERROR
    if HISTORY is None: return
    try:
        HISTORY.observe(system_status(config)["nodes"])
        HISTORY_ERROR=""
    except Exception as error:
        message=str(error)
        if message!=HISTORY_ERROR: print("Storico diagnostico: "+message,flush=True)
        HISTORY_ERROR=message

PAGE=r'''<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>RETE MUSEO - AudioOverNetwork</title><style>body{font-family:system-ui,sans-serif;background:#111827;color:#e5e7eb;margin:0;padding:24px}main{max-width:1150px;margin:auto}.titlebar{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;margin-bottom:6px}h1{margin:0}.versionBadge{display:inline-flex;align-items:center;background:#1d4ed8;color:#dbeafe;border:1px solid #3b82f6;border-radius:999px;padding:7px 12px;font-size:14px;font-weight:800;letter-spacing:.02em;white-space:nowrap}.sub{color:#9ca3af;margin-bottom:22px}.summary,.grid{display:grid;gap:14px}.summary{grid-template-columns:repeat(auto-fit,minmax(150px,1fr));margin-bottom:18px}.grid{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.box,.card{background:#1f2937;border:1px solid #374151;border-radius:12px;padding:16px}.num{font-size:28px;font-weight:700}.head{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}.badge{font-size:12px;font-weight:700;padding:5px 9px;border-radius:999px}.OK{background:#064e3b;color:#a7f3d0}.ATTENZIONE{background:#78350f;color:#fde68a}.OFFLINE{background:#7f1d1d;color:#fecaca}.row{display:flex;justify-content:space-between;gap:12px;border-top:1px solid #374151;padding:8px 0;font-size:14px}.label{color:#9ca3af}.value{text-align:right}footer{color:#6b7280;margin-top:22px;font-size:13px}code{color:#93c5fd}.volume{border-top:1px solid #374151;padding:12px 0}.volumeHead{display:flex;justify-content:space-between;gap:12px;margin-bottom:8px}.volumeNumber{width:75px;padding:7px;background:#111827;color:#fff;border:1px solid #6b7280;border-radius:5px}.volume button{padding:7px;margin-top:8px;cursor:pointer}.muteButton[aria-pressed=true]{background:#b91c1c;color:white}.volumeMsg{min-height:18px;color:#9ca3af;font-size:12px;margin-top:4px}.diag{border-top:1px solid #374151;padding-top:10px;margin-top:4px}.diag summary{cursor:pointer;color:#9ca3af;font-size:13px}.diagBody{padding-top:8px}.latency{border-top:1px solid #374151;padding:8px 0;font-size:14px}.meter{border-top:1px solid #374151;padding:12px 0}.meter progress{width:100%;height:14px;accent-color:#34d399}.meter.hot progress{accent-color:#fbbf24}.meter.clip progress{accent-color:#f87171}.meter small{display:block;color:#9ca3af;margin-top:6px}.autodiag{border-top:1px solid #374151;padding:12px 0}.autodiag strong{display:block;margin-bottom:7px}.autodiag.ok strong{color:#a7f3d0}.autodiag.warning strong{color:#fde68a}.autodiag.critical strong{color:#fecaca}.autodiag.info strong{color:#bfdbfe}.probeCard{background:#292044;border:2px solid #a78bfa}.probeBadge{color:#ddd6fe;font-weight:700;font-size:13px;margin-bottom:10px}</style></head><body><main><div class="titlebar"><h1>RETE MUSEO - AudioOverNetwork</h1><span id="versionBadge" class="versionBadge">Versione installata: …</span></div><div class="sub">Monitor centrale TX · monitoraggio e controllo RX</div><div id="publicDashboardHome"><div id="summary" class="summary"></div><div id="nodes" class="grid"></div><footer id="footer"></footer></div><script>function esc(value){var text='';if(value!=null){text=String(value);}return text.replace(/[&<>"']/g,function(c){var map={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'};return map[c];});}function boolLabel(value,okText,koText){return value?okText:koText;}function multicastLabel(state){var map={sending:'trasmissione attiva',joined:'gruppo agganciato',stopped:'trasmissione ferma',not_joined:'gruppo non agganciato'};return map[state]||state||'n/d';}var drafts={},feedback={},pending={},knownMute={},confirmed={};
function volumeBlock(n){if(n.role!=='rx')return '';if(confirmed[n.name]&&Date.now()<confirmed[n.name].until){n=Object.assign({},n,confirmed[n.name]);}var value=Object.prototype.hasOwnProperty.call(drafts,n.name)?drafts[n.name]:(n.volume_percent==null?'':n.volume_percent);knownMute[n.name]=!!n.muted;
return '<div class="volume"><form class="volumeForm" data-node="'+esc(n.name)+'"><label>Volume uscita (%) <input class="volumeNumber" type="number" min="0" max="100" step="1" required value="'+esc(value)+'" aria-label="Volume '+esc(n.name)+'" '+(!n.online?'disabled':'')+'></label> <button '+(!n.online||pending[n.name]?'disabled':'')+'>Applica</button> <button type="button" class="muteButton" aria-pressed="'+!!n.muted+'" '+(!n.online||pending[n.name]?'disabled':'')+'>'+(n.muted?'Riattiva audio':'Mute')+'</button></form><div role="status" aria-live="polite" class="volumeMsg" id="vol-msg-'+esc(n.name)+'">'+(feedback[n.name]||'')+'</div></div>';}
function latencyBlock(n){if(n.role!=='rx'){return '';}var target=n.target_latency||'n/d';var rtt=(n.network_rtt_ms==null)?'n/d':esc(n.network_rtt_ms)+' ms';return '<div class="latency"><div class="row"><span class="label">Latenza Roc target</span><span class="value">'+esc(target)+'</span></div><div class="row"><span class="label">RTT rete verso TX</span><span class="value">'+rtt+'</span></div></div>';}function audioDiagnosisBlock(n){var d=n.audio_diagnosis||{};var m=n.audio_meter||{};var i=m.integrity||{};var p=n.throttled||{};if(!d.summary)return '';var html='<section class="autodiag '+esc(d.severity||'info')+'"><strong>Autodiagnosi audio · '+esc(d.summary)+'</strong><small>'+esc(d.detail||'')+'</small>';if(i.window_seconds){html+='<div class="row"><span class="label">RTP ultimi '+esc(i.window_seconds)+' s</span><span class="value">'+esc(i.packets_window||0)+' pacchetti</span></div><div class="row"><span class="label">Pacchetti mancanti/ritardati</span><span class="value">'+esc(i.missing_packets||0)+' · gap max '+esc(i.max_sequence_gap||0)+'</span></div><div class="row"><span class="label">Fuori ordine / duplicati</span><span class="value">'+esc(i.out_of_order_packets||0)+' / '+esc(i.duplicate_packets||0)+'</span></div><div class="row"><span class="label">Pause RTP >40 ms</span><span class="value">'+esc(i.transport_stalls||0)+' · max '+esc(i.max_transport_gap_ms||0)+' ms</span></div><div class="row"><span class="label">Jitter stimato</span><span class="value">'+esc(i.jitter_ms||0)+' ms</span></div>';}if(p.raw){var power='OK';if(p.active){power='ATTIVO: '+(p.current_flags||[]).join(', ');}else if(p.historical){power='OK ora · storico: '+(p.historical_flags||[]).join(', ');}html+='<div class="row"><span class="label">Alimentazione/termica</span><span class="value">'+esc(power)+' · '+esc(p.raw)+'</span></div>';}var net=n.network||{};var delta=(net.rx_errors_delta||0)+(net.rx_dropped_delta||0)+(net.tx_errors_delta||0)+(net.tx_dropped_delta||0);var total=(net.rx_errors||0)+(net.rx_dropped||0)+(net.tx_errors||0)+(net.tx_dropped||0);html+='<div class="row"><span class="label">Ethernet errori/drop</span><span class="value">nuovi '+esc(delta)+' · totale '+esc(total)+'</span></div>';html+='</section>';return html;}
function diagnosticsBlock(n){var body='';var d=n.waveform_diagnostics;if(d){if(d.channel_mapping){body+='<div class="row"><span class="label">Mappa ritorno</span><span class="value">'+(d.channel_mapping==='swapped'?'L/R invertiti · compensazione attiva':'L/R diretti')+'</span></div>';}if(d.timing_observation){body+='<div class="row"><span class="label">Misura temporale · informazione</span><span class="value">'+esc(d.timing_message)+'</span></div>';}if(d.capture_timing){body+='<div class="row"><span class="label">Scarto cumulativo ADC · non è la latenza</span><span class="value">'+esc(d.capture_timing.delivery_offset_ms)+' ms</span></div>';}if(d.clock_diagnostics){var a=d.clock_diagnostics.adc||{},r=d.clock_diagnostics.rtp||{};body+='<div class="row"><span class="label">Clock ADC / RTP</span><span class="value">'+esc(a.drift_ppm)+' / '+esc(r.drift_ppm)+' ppm · '+(a.fit_valid&&r.fit_valid?'stima calibrata':'calibrazione in corso')+'</span></div><div class="row"><span class="label">Residuo consegna ADC</span><span class="value">'+esc(a.residual_ms)+' ms · '+esc(d.timing_confidence)+'</span></div>';}if(d.capture_health&&d.capture_health.xrun_events){body+='<div class="row"><span class="label">Overrun/xrun cattura spia</span><span class="value">'+esc(d.capture_health.xrun_events)+' · '+esc(d.capture_health.last_message)+'</span></div>';}if(d.workload){body+='<div class="row"><span class="label">Analisi spia · solo worker</span><span class="value">'+esc(d.workload.analysis_wall_ms)+' ms · periodo '+esc(d.workload.analysis_target_period_seconds)+' s · CPU '+esc(d.workload.analysis_core_percent)+'% di un core'+(d.workload.over_budget?' · costo elevato':'')+'</span></div>';}body+='<div class="row"><span class="label">Confronto forme d’onda · '+esc(d.status)+'</span><span class="value">'+esc(d.message)+' · confidenza '+esc(d.confidence||'n/d')+'</span></div>';if(d.estimated_delay_ms!=null){body+='<div class="row"><span class="label">Ritardo stimato RTP → ADC</span><span class="value">'+esc(d.estimated_delay_ms)+' ms · variazione '+esc(d.delay_change_ms)+' ms</span></div>';}if(d.delay_trend_ms_per_minute!=null){body+='<div class="row"><span class="label">Deriva del ritardo stimato</span><span class="value">'+esc(d.delay_trend_ms_per_minute)+' ms/min</span></div>';}if(d.rtp){body+='<div class="row"><span class="label">RTP · jitter / gap / fuori ordine</span><span class="value">'+esc(Number(d.rtp.jitter_ms).toFixed(2))+' ms / '+esc(d.rtp.sequence_gaps)+' / '+esc(d.rtp.out_of_order)+'</span></div>';}if(d.workload&&d.workload.stage_cpu_ms){body+='<div class="row"><span class="label">CPU filtro / confronto / buffer</span><span class="value">'+esc(d.workload.stage_cpu_ms.resample)+' / '+esc(d.workload.stage_cpu_ms.compare)+' / '+esc(d.workload.stage_cpu_ms.buffers)+' ms</span></div>';}if(d.channels){d.channels.forEach(function(c){body+='<div class="row"><span class="label">Canale '+esc(c.channel+1)+'</span><span class="value">'+esc(c.status)+' · correlazione '+esc(c.correlation)+' · gain '+esc(c.gain_db)+' dB · residuo '+esc(c.residual_db)+' dB</span></div>';});}if(d.events&&d.events.length){var e=d.events[d.events.length-1];body+='<div class="row"><span class="label">Ultima evidenza su RX</span><span class="value">'+esc(e.status)+' · '+esc(e.path)+'</span></div>';}if(d.storage_error){body+='<div class="row"><span class="label">Errore archivio diagnostico</span><span class="value">'+esc(d.storage_error)+'</span></div>';}}if(n.analog_return){body+='<div class="row"><span class="label">Ritorno analogico · '+esc(n.analog_return.status)+'</span><span class="value">'+esc(n.analog_return.message)+'</span></div>';}if(n.roc_last_error){body+='<div class="row"><span class="label">Ultimo errore Roc</span><span class="value">'+esc(n.roc_last_error)+'</span></div>';}if(n.roc_last_warning){body+='<div class="row"><span class="label">Ultimo avviso Roc</span><span class="value">'+esc(n.roc_last_warning)+'</span></div>';}if(!body){body='<div class="row"><span class="label">Roc</span><span class="value">nessun errore recente</span></div>';}return '<details class="diag"><summary>Diagnostica Roc e ritorno analogico</summary><div class="diagBody">'+body+'</div></details>';}function meterBlock(n){
var m=n.audio_meter;var rx=n.role==='rx';var title=rx?'Uscita RX':'Trasmissione TX · microfono + musica';
if(!n.online||!m||!m.available){return '<section class="meter"><strong>'+title+'</strong><small>'+esc(!n.online?'Nodo offline':m?m.error:'Aggiornare il monitor del nodo')+'</small></section>';}
var age=rx?m.input_clip_age_seconds:m.clip_age_seconds;var clipped=age!=null&&age<30;
var hot=m.channels.some(function(c){return c.peak_dbfs>=-3;});
var html='<section class="meter '+(clipped?'clip':hot?'hot':'')+'"><strong>'+title+'</strong>';
m.channels.forEach(function(c,i){var label=m.channels.length===1?'Mono':i===0?'L':'R';var value=Math.max(0,Math.min(60,60+c.peak_dbfs));
html+='<div class="row"><span>'+label+'</span><span>Picco '+esc(c.peak_dbfs)+' · RMS '+esc(c.rms_dbfs)+' dBFS</span></div><progress max="60" value="'+value+'" aria-label="Picco '+label+'"></progress>';
if(rx){html+='<small>Guadagno ALSA '+esc(c.gain_db)+' dB'+(c.muted?' · MUTE':'')+'</small>';}
else{html+='<small>Fondo scala: '+esc(c.full_scale_samples)+' campioni / 5 s</small>';}});
html+='<small>'+(clipped?(rx?'FONDO SCALA a monte del fader':'FONDO SCALA rilevato')+' · '+esc(age)+' s fa':hot?'Attenzione: margine inferiore a 3 dB':'Nessun fondo scala recente')+' · scala −60…0 dBFS</small>';
html+='<small>'+(rx?'Stima: livello RTP degli ultimi 5 s + guadagno ALSA attuale. Abbassare il fader non elimina il clipping a monte.':'Picco/RMS degli ultimi 5 s.')+' Non misura distorsione analogica.</small></section>';return html;}
function isProbe(n){return n.role==='rx'&&(n.probe_mode===true||!!n.analog_return);}
function probeBadge(n){return isProbe(n)?'<div class=probeBadge>SPIA · scheda audio esterna'+(n.analog_return&&n.analog_return.available?' · acquisizione attiva':' · acquisizione non disponibile')+'</div>':'';}
function nodeCard(n){var net=n.network||{};var multi=n.multicast||{};var speed='';if(net.speed_mbps){speed=' · '+esc(net.speed_mbps)+' Mb/s';}var temp='n/d';if(n.temperature_c!=null){temp=esc(n.temperature_c)+' °C';}var service=esc(n.roc_service||'n/d');if(n.roc_service_sub){service+=' / '+esc(n.roc_service_sub);}return '<article class="card'+(isProbe(n)?' probeCard':'')+'">'+probeBadge(n)+'<div class="head"><strong>'+esc(n.name)+' · '+esc((n.role||'').toUpperCase())+'</strong><span class="badge '+esc(n.state)+'">'+esc(n.state)+'</span></div><div class="row"><span class="label">IPv4</span><span class="value">'+esc(net.ipv4||'n/d')+'</span></div><div class="row"><span class="label">Ethernet</span><span class="value">'+boolLabel(net.carrier,'collegata','non collegata')+speed+'</span></div><div class="row"><span class="label">Servizio Roc</span><span class="value">'+service+'</span></div><div class="row"><span class="label">Processo Roc</span><span class="value">'+boolLabel(n.roc_process,'in esecuzione','non in esecuzione')+'</span></div><div class="row"><span class="label">Riavvii Roc</span><span class="value">'+esc(n.roc_restarts||0)+'</span></div><div class="row"><span class="label">Dispositivo audio</span><span class="value">'+boolLabel(n.audio_device,'rilevato','non rilevato')+'</span></div><div class="row"><span class="label">Multicast</span><span class="value"><code>'+esc(multi.group)+'</code> · '+esc(multicastLabel(multi.state))+'</span></div>'+(n.role==='tx'?'<div class="row"><span class="label">Sorgente</span><span>'+esc(({playing:'Player',paused:'Player in pausa',live:'Ingresso mixer'}[n.studio_source])||'Ingresso mixer')+'</span></div>':'')+audioDiagnosisBlock(n)+meterBlock(n)+latencyBlock(n)+volumeBlock(n)+'<div class="row"><span class="label">Temperatura</span><span class="value">'+temp+'</span></div><div class="row"><span class="label">Load 1m</span><span class="value">'+esc(n.load_1m)+'</span></div><div class="row"><span class="label">Heartbeat</span><span class="value">'+esc(n.age_seconds)+' s fa</span></div>'+diagnosticsBlock(n)+'</article>';}async function refresh(){try{var response=await fetch('/api/status',{cache:'no-store'});var data=await response.json();var version=data.software_version||data.monitor_build||'n/d';var monitor=data.monitor_build&&data.monitor_build!==version?' · monitor '+data.monitor_build:'';document.getElementById('versionBadge').textContent='Versione installata: v'+String(version).replace(/^v/,'')+monitor;var okCount=0;var offCount=0;for(var i=0;i<data.nodes.length;i++){if(data.nodes[i].state==='OK'){okCount++;}if(data.nodes[i].state==='OFFLINE'){offCount++;}}document.getElementById('summary').innerHTML='<div class="box"><div class="label">Nodi</div><div class="num">'+data.nodes.length+'</div></div><div class="box"><div class="label">OK</div><div class="num">'+okCount+'</div></div><div class="box"><div class="label">Offline</div><div class="num">'+offCount+'</div></div><div class="box"><div class="label">RX previsti</div><div class="num">'+data.expected_rx+'</div></div>';var html='';for(var j=0;j<data.nodes.length;j++){html+=nodeCard(data.nodes[j]);}if(!html){html='<div class="box">Nessun nodo rilevato.</div>';}var active=document.activeElement;var focusedNode=active&&active.classList.contains('volumeNumber')?active.closest('form').dataset.node:null;document.getElementById('nodes').innerHTML=html;bindVolumeControls();if(focusedNode){document.querySelectorAll('.volumeForm').forEach(function(f){if(f.dataset.node===focusedNode)f.querySelector('input').focus();});}document.getElementById('footer').textContent='Aggiornato '+new Date().toLocaleTimeString()+' · refresh 2 s · offline dopo 15 s';}catch(error){document.getElementById('footer').textContent='Errore dashboard: '+error;}}function showFeedback(node,text){feedback[node]=text;var el=document.getElementById('vol-msg-'+node);if(el)el.innerHTML=text;}
async function sendCommand(node,command,value){if(pending[node])return;pending[node]=true;showFeedback(node,'Invio…');
try{var response=await fetch('/api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({node:node,command:command,value:value})});var result=await response.json();if(!response.ok||!result.ok)throw new Error(result.message||'Invio fallito');
showFeedback(node,'<span style="color:#9ca3af">✓ Inviato</span>');
for(var attempt=0;attempt<18;attempt++){await new Promise(function(resolve){setTimeout(resolve,500);});var ackResponse=await fetch('/api/control/'+encodeURIComponent(result.id),{cache:'no-store'});if(!ackResponse.ok)throw new Error('Verifica fallita');var ack=await ackResponse.json();
if(ack.state==='confirmed'){confirmed[node]={muted:ack.muted,volume_percent:ack.volume_percent,until:Date.now()+15000};knownMute[node]=ack.muted;showFeedback(node,'<span style="color:#60a5fa">✓ Confermato RX</span>');delete drafts[node];return;}
if(ack.state==='failed')throw new Error('RX: applicazione non confermata');if(ack.state==='timeout')break;}
throw new Error('Inviato, conferma RX non ricevuta');
}catch(error){showFeedback(node,'<span style="color:#fca5a5">'+esc(error.message)+'</span>');}
finally{delete pending[node];var completedFeedback=feedback[node];setTimeout(function(){if(!pending[node]&&feedback[node]===completedFeedback)showFeedback(node,'');},5000);}}
function bindVolumeControls(){document.querySelectorAll('.volumeForm').forEach(function(form){var node=form.dataset.node;var input=form.querySelector('input');input.addEventListener('input',function(){drafts[node]=input.value;});form.addEventListener('submit',function(event){event.preventDefault();if(form.reportValidity())sendCommand(node,'set_volume',Number(input.value));});form.querySelector('.muteButton').addEventListener('click',function(){sendCommand(node,'set_mute',!knownMute[node]);});});}
refresh();setInterval(refresh,2000);</script></main></body></html>'''

AUTH_FILE=Path("/var/lib/roc-museum/auth.json")
MEDIA_DIR=Path("/var/lib/roc-museum/media")
SESSIONS={}
AUTH_LOCK=threading.Lock()
UPLOAD_LOCK=threading.Lock()
LOGIN_ATTEMPTS={}
MAX_UPLOAD=512*1024*1024

def set_password():
    import getpass
    password=getpass.getpass("Nuova password regia (almeno 12 caratteri): ")
    if len(password)<12 or password!=getpass.getpass("Ripeti password: "):
        raise SystemExit("Password troppo breve o conferma diversa")
    salt=secrets.token_hex(16)
    record={"salt":salt,"hash":hashlib.pbkdf2_hmac("sha256",password.encode(),salt.encode(),600000).hex()}
    AUTH_FILE.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(dir=AUTH_FILE.parent)
    try:
        with os.fdopen(fd,"w") as f: json.dump(record,f)
        os.replace(name,AUTH_FILE)
    finally:
        if os.path.exists(name): os.unlink(name)
    print("Password aggiornata. Utente: admin. Riavviare roc-museum-monitor per revocare le sessioni esistenti.")

REGIA_UI=r'''<section class="box" style="margin-bottom:18px"><h2>Accesso regia</h2>
<form id="login"><label>Utente <input name="username" value="admin" autocomplete="username" required></label>
<label>Password <input name="password" type="password" autocomplete="current-password" required></label> <button>Accedi</button></form>
<div id="studio" hidden><button id="logout">Esci</button><h3>Libreria audio TX</h3>
<form id="upload"><input id="audiofile" type="file" accept=".wav,.mp3,.flac,.ogg,.m4a,.aac" required><button>Carica sul TX</button></form>
<progress id="uploadProgress" max="100" value="0" hidden></progress><ul id="library"></ul></div><p id="authMessage" role="status"></p></section>
<script>
var csrf='',authorized=false;
async function library(){var r=await fetch('/api/media');if(!r.ok)return;var d=await r.json();document.getElementById('library').replaceChildren();d.files.forEach(function(f){var li=document.createElement('li');li.textContent=f.name+' ('+(f.size/1048576).toFixed(1)+' MB)';document.getElementById('library').appendChild(li);});}
async function session(){var r=await fetch('/api/session');var d=await r.json();authorized=d.authenticated;csrf=d.csrf||'';document.getElementById('login').hidden=authorized;document.getElementById('studio').hidden=!authorized;if(authorized)await library();if(typeof placeDashboard==='function')placeDashboard();if(authorized&&typeof refreshAudioMonitor==='function')refreshAudioMonitor();refresh();}
document.getElementById('login').onsubmit=async function(e){e.preventDefault();var f=new FormData(e.target);try{var r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json','X-Regia-Request':'1'},body:JSON.stringify(Object.fromEntries(f))});var d=await r.json();document.getElementById('authMessage').textContent=d.message||'';e.target.password.value='';await session();}catch(e){document.getElementById('authMessage').textContent='Connessione non riuscita';}};
document.getElementById('logout').onclick=async function(){await fetch('/api/logout',{method:'POST',headers:{'X-CSRF-Token':csrf}});await session();};
document.getElementById('upload').onsubmit=function(e){e.preventDefault();var file=document.getElementById('audiofile').files[0];if(!file)return;var x=new XMLHttpRequest();x.open('POST','/api/upload');x.setRequestHeader('X-CSRF-Token',csrf);x.setRequestHeader('X-Filename',encodeURIComponent(file.name));var bar=document.getElementById('uploadProgress');bar.hidden=false;bar.value=0;x.upload.onprogress=function(e){if(e.lengthComputable)bar.value=e.loaded/e.total*100;};x.onload=function(){try{document.getElementById('authMessage').textContent=JSON.parse(x.responseText).message;}catch(e){document.getElementById('authMessage').textContent='Caricamento fallito';}library();};x.onerror=function(){document.getElementById('authMessage').textContent='Connessione interrotta: riprovare il caricamento';};x.send(file);};
session();
</script>'''
PAGE=PAGE.replace('<div id="summary"',REGIA_UI+'<div id="summary"')
# Run auth initialization only after the dashboard functions have been defined.
PAGE=PAGE.replace('session();\n</script>','window.addEventListener("DOMContentLoaded",session);\n</script>')
PAGE=PAGE.replace("if(n.role!=='rx')return '';", "if(n.role!=='rx')return '';if(!authorized)return '<div class=volume>Accedi alla regia per modificare volume e mute.</div>';")
PAGE=PAGE.replace("headers:{'Content-Type':'application/json'},body:JSON.stringify({node:","headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({node:")

PAGE=PAGE.replace('<div class="sub">','<p id="systemClock" role="timer">Ora TX: in attesa…</p><div class="sub">')
CLOCK_JS=r'''var txClock=null,txClockSample=0;
function syncTxClock(timestamp){txClock=timestamp*1000;txClockSample=performance.now();renderTxClock();}
function renderTxClock(){var el=document.getElementById('systemClock');if(el&&txClock!==null)el.textContent='Ora TX: '+new Date(txClock+performance.now()-txClockSample).toLocaleString('it-IT',{timeZone:'Europe/Rome'})+' · Europe/Rome';}
setInterval(renderTxClock,1000);
'''
PAGE=PAGE.replace('<script>function esc','<script>'+CLOCK_JS+'function esc',1)
PAGE=PAGE.replace("var data=await response.json();", "var data=await response.json();syncTxClock(data.generated_at);",1)

HISTORY_UI=r'''<details id="diagnosticHistory" class="box" style="margin-top:18px"><summary>Storico diagnostico · eventi conservati dopo il rientro</summary><p>Orari del TX · durata osservata a campioni, non durata esatta del difetto audio. Ultimi 100 eventi; conservazione 30 giorni / 1000 eventi conclusi.</p><label>Nodo <input id="historyNode" placeholder="Tutti i nodi" aria-label="Filtra storico per nome nodo"></label> <button type="button" id="historyRefresh">Aggiorna storico</button> <a id="historyExport" href="/api/diagnostics/history?limit=1000" download="storico-diagnostico.json">Scarica JSON</a> · <a id="historyReport" href="/api/diagnostics/report" download="rapporto-spia.json">Scarica rapporto spia</a><p id="historyMessage" role="status"></p><div id="historyRows"></div></details>'''
HISTORY_JS=r'''var historyLast=0,historyBusy=false;
function historyTime(value){return value==null?'—':new Date(value*1000).toLocaleString('it-IT',{timeZone:'Europe/Rome'});}
async function loadDiagnosticHistory(force){var panel=document.getElementById('diagnosticHistory');if(!panel||!panel.open||historyBusy||(!force&&Date.now()-historyLast<10000))return;historyBusy=true;try{var node=document.getElementById('historyNode').value.trim();var query=node?'&node='+encodeURIComponent(node):'';document.getElementById('historyExport').href='/api/diagnostics/history?limit=1000'+query;document.getElementById('historyReport').href='/api/diagnostics/report'+(node?'?node='+encodeURIComponent(node):'');var response=await fetch('/api/diagnostics/history?limit=100'+query,{cache:'no-store'});var data=await response.json();if(!response.ok)throw new Error(data.error||'Storico non disponibile');var html='';(data.events||[]).forEach(function(e){var state=e.active?'In corso':e.resolution==='monitor_restart'?'Monitor riavviato: esito non osservato':e.resolution==='artifact'?'Evidenza salvata':e.resolution==='node_offline'?'Osservazione interrotta: nodo offline':e.resolution==='observation_lost'?'Osservazione interrotta':'Rientrato';html+='<article class="diag"><strong>'+esc(e.node)+' · '+esc(e.summary)+'</strong><div class="row"><span>'+esc(e.source)+' · '+esc(e.code)+'</span><span>'+esc(state)+'</span></div><div>Inizio '+esc(historyTime(e.started_at))+' · ultima osservazione '+esc(historyTime(e.last_seen))+' · fine '+esc(historyTime(e.ended_at))+'</div><div>Durata osservata '+esc(e.observed_duration_seconds)+' s · campioni '+esc(e.observations)+'</div><details><summary>Dettagli ed evidenze</summary><pre style="white-space:pre-wrap;overflow-wrap:anywhere">'+esc(JSON.stringify(e.details,null,2))+'</pre></details></article>';});document.getElementById('historyRows').innerHTML=html||'<p>Nessun evento registrato.</p>';document.getElementById('historyMessage').textContent=(data.error?'Errore salvataggio: '+data.error+' · ':'')+'Aggiornato '+new Date().toLocaleTimeString('it-IT');historyLast=Date.now();}catch(error){document.getElementById('historyMessage').textContent='Errore storico: '+error.message;}finally{historyBusy=false;}}
window.addEventListener('DOMContentLoaded',function(){var panel=document.getElementById('diagnosticHistory');if(!panel)return;panel.addEventListener('toggle',function(){loadDiagnosticHistory(true);});document.getElementById('historyRefresh').onclick=function(){loadDiagnosticHistory(true);};document.getElementById('historyNode').onchange=function(){loadDiagnosticHistory(true);};setInterval(function(){loadDiagnosticHistory(false);},10000);});
'''
PAGE=PAGE.replace('<footer id="footer">',HISTORY_UI+'<footer id="footer">',1)
PAGE=PAGE.replace('<script>function esc','<script>'+HISTORY_JS+'function esc',1)
# CLOCK_JS may already have been inserted before esc.
if HISTORY_JS not in PAGE: PAGE=PAGE.replace('<script>','<script>'+HISTORY_JS,1)

def build_tx_page():
    page=PAGE
    # Defensive composition: login must always be present on the TX page.
    if 'id="login"' not in page:
        page=page.replace('<div id="summary"',REGIA_UI+'<div id="summary"',1)
    try:
        snippet=Path("/usr/local/share/roc-museum/studio.html").read_text()
        if 'id="studioTools"' not in page:
            page=page.replace('<div id="summary"',snippet+'<div id="summary"',1)
    except Exception as error:
        if 'id="studioTools"' not in page:
            message='<section class="box"><h2>Regia TX</h2><p>Interfaccia player non disponibile: '+esc_html(str(error))+'</p></section>'
            page=page.replace('<div id="summary"',message+'<div id="summary"',1)
    return page

class Handler(BaseHTTPRequestHandler):
    config={}
    studio=None
    updater=None
    def update_manager(self):
        if self.updater is None:
            import importlib.util
            spec=importlib.util.spec_from_file_location("roc_updater","/usr/local/lib/roc-museum/updater.py")
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            def discovered():
                with REGISTRY_LOCK: return [dict(node) for node in REGISTRY.values()]
            type(self).updater=module.Manager(discover=discovered)
        return self.updater
    def log_message(self,fmt,*args): return
    def reply(self,code,content_type,payload):
        self.send_response(code);self.send_header("Content-Type",content_type);self.send_header("Cache-Control","no-store");self.send_header("Content-Length",str(len(payload)));self.end_headers();self.wfile.write(payload)
    def json_reply(self,code,data):
        self.reply(code,"application/json; charset=utf-8",json.dumps(data).encode())
    def session(self):
        try:
            cookie=SimpleCookie(self.headers.get("Cookie",""))
            token=cookie["regia"].value if "regia" in cookie else ""
        except Exception: return None
        with AUTH_LOCK:
            now=time.monotonic()
            for key in list(SESSIONS):
                if SESSIONS[key]["expires"]<=now: del SESSIONS[key]
            return SESSIONS.get(token)
    def require_auth(self,write=False):
        session=self.session()
        if not session:
            self.json_reply(401,{"ok":False,"message":"Accesso richiesto"});return False
        if write and not hmac.compare_digest(self.headers.get("X-CSRF-Token","").encode("utf-8"),session["csrf"].encode("utf-8")):
            self.json_reply(403,{"ok":False,"message":"Sessione non valida: accedere nuovamente"});return False
        return True
    def studio_reply(self,action):
        if self.studio is None:
            self.json_reply(503,{"message":"Regia non disponibile"});return
        try: self.json_reply(200,action())
        except (ValueError,TypeError,KeyError,OSError,subprocess.SubprocessError) as error:
            self.json_reply(400,{"message":str(error)})
    def diagnostic_reply(self):
        if not self.require_auth(): return
        if self.config.get("ROLE")!="tx":
            self.json_reply(404,{"message":"Diagnostica disponibile sul TX"});return
        query=parse_qs(urlsplit(self.path).query)
        node_name=query.get("node",[""])[0]
        action=query.get("action",["events"])[0]
        request={"action":action}
        if action=="file":
            request.update(event=query.get("event",[""])[0],file=query.get("file",[""])[0])
        elif action=="journal":
            request.update(window=query.get("window",["15m"])[0],unit=query.get("unit",["roc-museum"])[0])
        elif action!="events":
            self.json_reply(400,{"message":"Richiesta non valida"});return
        if not DEBUG_SLOTS.acquire(blocking=False):
            self.json_reply(429,{"message":"Diagnostica occupata: riprovare"});return
        try:
            import diagnostics_access
            if node_name==self.config.get("NODE_NAME","TX"):
                content_type,data=diagnostics_access.collect(request)
            else:
                with REGISTRY_LOCK: node=dict(REGISTRY.get(node_name,{}) or {})
                if node.get("role")!="rx" or not node.get("source_ip"):
                    self.json_reply(404,{"message":"RX non trovato"});return
                if time.time()-node.get("received_at",0)>OFFLINE_AFTER:
                    self.json_reply(503,{"message":"RX offline; le evidenze restano sul ricevitore"});return
                content_type,data=diagnostics_access.fetch(node["source_ip"],int(self.config.get("CONTROL_PORT","19091")),request)
            self.reply(200,content_type,data)
        except (OSError,ValueError,subprocess.SubprocessError) as error:
            self.json_reply(502,{"message":"Diagnostica non disponibile. Verificare aggiornamento TX/RX e collegamento TCP sulla porta di controllo. "+str(error)[:400]})
        finally:
            DEBUG_SLOTS.release()

    def do_GET(self):
        if urlsplit(self.path).path=="/api/diagnostics/report":
            try:
                query=parse_qs(urlsplit(self.path).query)
                node=query.get("node",[""])[0][:128] or None
                status=system_status(self.config)
                nodes=[item for item in status["nodes"] if node is None or item.get("name")==node]
                if node is not None and not nodes:
                    self.json_reply(404,{"error":"Nodo non presente nel registro TX"});return
                history=HISTORY.query(node,20) if HISTORY is not None else {"events":[]}
                self.json_reply(200,{"schema_version":2,"generated_at":status["generated_at"],
                    "software_version":status["software_version"],"nodes":nodes,
                    "recent_history":history,"history_error":HISTORY_ERROR,
                    "notes":["Orari e durate sono osservazioni campionate del TX",
                             "La stima dei clock usa timestamp software: può includere effetti di acquisizione",
                             "workload misura il solo worker, non tutta la CPU del Raspberry",
                             "Nessun PCM audio è incluso nel rapporto"]})
            except Exception as error:
                self.json_reply(503,{"error":"Rapporto non disponibile: "+str(error)})
            return
        if self.path=="/api/latency":
            if not self.require_auth(): return
            if LATENCY_FLEET is None:
                self.json_reply(503,{"message":"Gestione latenza non disponibile"});return
            self.json_reply(200,LATENCY_FLEET.snapshot());return
        if urlsplit(self.path).path=="/api/diagnostics/debug":
            self.diagnostic_reply();return
        if urlsplit(self.path).path=="/api/diagnostics/history":
            if HISTORY is None:
                self.json_reply(503,{"events":[],"error":HISTORY_ERROR or "Storico disponibile sul TX aggiornato"});return
            try:
                query=parse_qs(urlsplit(self.path).query)
                node=query.get("node",[""])[0][:128] or None
                limit=int(query.get("limit",["100"])[0])
                if not 1<=limit<=1000: raise ValueError("Limite non valido")
                result=HISTORY.query(node,limit)
                result["error"]=HISTORY_ERROR
                self.json_reply(200,result)
            except ValueError:
                self.json_reply(400,{"error":"Parametri non validi"})
            except Exception as error:
                self.json_reply(503,{"events":[],"error":str(error)})
            return
        if self.path=="/api/updates":
            if not self.require_auth(): return
            try: self.json_reply(200,self.update_manager().snapshot())
            except (ValueError,OSError,RuntimeError,subprocess.SubprocessError) as error:
                self.json_reply(400,{"message":str(error)})
            return
        if self.path in ("/api/studio","/api/usb"):
            if not self.require_auth(): return
            self.studio_reply(lambda: self.studio.snapshot() if self.path=="/api/studio" else {"devices":self.studio.devices()});return
        if self.path=="/api/session":
            session=self.session()
            self.json_reply(200,{"authenticated":bool(session),"csrf":session["csrf"] if session else None});return
        if self.path=="/api/media":
            if not self.require_auth(): return
            files=[]
            if MEDIA_DIR.exists():
                files=[{"name":p.name,"size":p.stat().st_size} for p in sorted(MEDIA_DIR.iterdir()) if p.is_file() and not p.is_symlink() and not p.name.startswith(".")]
            self.json_reply(200,{"files":files});return
        if self.path=="/" or self.path=="/index.html":
            page=build_tx_page() if self.config.get("ROLE")=="tx" else PAGE
            self.reply(200,"text/html; charset=utf-8",page.encode("utf-8"));return
        if self.path=="/api/version":
            self.json_reply(200,{"monitor_build":MONITOR_BUILD,"software_version":self.config.get("SOFTWARE_VERSION",""),"role":self.config.get("ROLE","")});return
        if self.path=="/api/status": self.reply(200,"application/json; charset=utf-8",json.dumps(system_status(self.config),indent=2).encode("utf-8"));return
        if self.path.startswith("/api/control/"):
            if not self.require_auth(): return
            with REGISTRY_LOCK: result=dict(CONTROL_RESULTS.get(self.path.rsplit("/",1)[-1],{}))
            if result.get("state")=="sent" and time.time()-result["created"]>8: result["state"]="timeout"
            result.pop("ip",None)
            self.reply(200,"application/json",json.dumps(result).encode());return
        if self.path=="/healthz": self.reply(200,"text/plain; charset=utf-8",b"ok\n");return
        self.reply(404,"text/plain; charset=utf-8",b"Not found\n")
    def do_POST(self):
        self.connection.settimeout(60)
        if self.path=="/api/login":
            if self.headers.get("X-Regia-Request")!="1":
                self.json_reply(403,{"message":"Richiesta non valida"});return
            ip=self.client_address[0];now=time.monotonic()
            with AUTH_LOCK:
                for key in list(LOGIN_ATTEMPTS):
                    if now-LOGIN_ATTEMPTS[key][0]>300: del LOGIN_ATTEMPTS[key]
                attempt=LOGIN_ATTEMPTS.setdefault(ip,[now,0]);attempt[1]+=1
                limited=attempt[1]>10
            if limited:
                self.json_reply(429,{"message":"Troppi tentativi: attendere 5 minuti"});return
            try:
                length=int(self.headers.get("Content-Length","0"))
                if not 0<length<=4096: raise ValueError()
                data=json.loads(self.rfile.read(length))
                record=json.loads(AUTH_FILE.read_text())
                password=data.get("password","")
                digest=hashlib.pbkdf2_hmac("sha256",password.encode(),record["salt"].encode(),600000).hex()
                valid=data.get("username")=="admin" and hmac.compare_digest(digest,record["hash"])
            except FileNotFoundError:
                self.json_reply(503,{"message":"Configurare la password sul TX: sudo roc-museum-monitor --set-password"});return
            except (ValueError,TypeError,AttributeError,KeyError,OSError): valid=False
            if not valid:
                self.json_reply(401,{"message":"Credenziali non valide"});return
            token=secrets.token_urlsafe(32)
            with AUTH_LOCK:
                LOGIN_ATTEMPTS.pop(ip,None)
                if len(SESSIONS)>=100: SESSIONS.pop(next(iter(SESSIONS)))
                SESSIONS[token]={"expires":now+28800,"csrf":secrets.token_urlsafe(32)}
            self.send_response(200)
            self.send_header("Set-Cookie","regia="+token+"; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800")
            self.send_header("Content-Length","2");self.send_header("Cache-Control","no-store");self.end_headers();self.wfile.write(b"{}");return
        if not self.require_auth(write=True): return
        if self.path=="/api/latency":
            try:
                if LATENCY_FLEET is None: raise ValueError("Gestione latenza non disponibile")
                length=int(self.headers.get("Content-Length","0"))
                if not 0<length<=1024 or self.headers.get("Transfer-Encoding"): raise ValueError("Richiesta non valida")
                data=json.loads(self.rfile.read(length))
                if not isinstance(data,dict): raise ValueError("Richiesta non valida")
                self.json_reply(202,LATENCY_FLEET.request(data.get("target_ms")))
            except (ValueError,OSError) as error:
                self.json_reply(400,{"message":str(error)})
            return
        if self.path=="/api/updates":
            try:
                length=int(self.headers.get("Content-Length","0"))
                if not 0<length<=131072 or self.headers.get("Transfer-Encoding"): raise ValueError("Richiesta non valida")
                data=json.loads(self.rfile.read(length))
                if not isinstance(data,dict): raise ValueError("Richiesta non valida")
                result=self.update_manager().request(data.get("action"),data)
                self.json_reply(202,result)
            except (ValueError,OSError,RuntimeError,subprocess.SubprocessError) as error:
                self.json_reply(409,{"message":str(error)})
            return
        if self.path=="/api/logout":
            session=self.session()
            with AUTH_LOCK:
                for token in list(SESSIONS):
                    if SESSIONS[token] is session: del SESSIONS[token]
            self.json_reply(200,{"ok":True});return
        if self.path=="/api/upload":
            self.upload();return
        if self.path in ("/api/media/delete","/api/player","/api/calendar/save","/api/calendar/delete","/api/usb/browse","/api/usb/import","/api/usb/eject"):
            try:
                length=int(self.headers.get("Content-Length","0"))
                if not 0<length<=16384 or self.headers.get("Transfer-Encoding"): raise ValueError()
                data=json.loads(self.rfile.read(length))
                if not isinstance(data,dict): raise ValueError()
            except (ValueError,UnicodeDecodeError):
                self.json_reply(400,{"message":"Richiesta JSON non valida"});return
            def action():
                if self.path=="/api/media/delete": return self.studio.delete_media(data.get("name"))
                if self.path=="/api/player": return self.studio.command(data)
                if self.path=="/api/calendar/save": return self.studio.save_event(data)
                if self.path=="/api/calendar/delete":
                    self.studio.delete_event(data.get("id"));return {"ok":True}
                if self.path=="/api/usb/browse": return self.studio.browse(data.get("device"),data.get("path",""))
                if self.path=="/api/usb/import": return self.studio.import_usb(data.get("device"),data.get("path",""))
                self.studio.eject(data.get("device"));return {"ok":True}
            self.studio_reply(action);return
        if self.path!="/api/control":
            self.reply(404,"application/json; charset=utf-8",b'{"ok":false,"message":"Not found"}');return
        try:
            length=min(int(self.headers.get("Content-Length","0")),4096)
            data=json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError,UnicodeDecodeError,json.JSONDecodeError):
            self.reply(400,"application/json; charset=utf-8",b'{"ok":false,"message":"Richiesta non valida"}');return
        if not isinstance(data,dict):
            self.reply(400,"application/json",b'{"ok":false}');return
        node=str(data.get("node",""))
        command=str(data.get("command",""))
        if command not in ("set_volume","set_mute"):
            self.reply(400,"application/json; charset=utf-8",b'{"ok":false,"message":"Comando non supportato"}');return
        value=data.get("value")
        valid=(command=="set_mute" and isinstance(value,bool)) or (command=="set_volume" and type(value)==int and 0<=value<=100)
        if not valid:
            self.reply(400,"application/json",b'{"ok":false,"message":"Valore non valido"}');return
        ok,message=send_control(self.config,node,command,value)
        payload=json.dumps({"ok":ok,"message":"Comando inviato" if ok else message,"id":message if ok else None}).encode()
        self.reply(200 if ok else 409,"application/json; charset=utf-8",payload)

    def upload(self):
        name=unquote(self.headers.get("X-Filename",""))
        if not name or name.startswith(".") or len(name.encode())>200 or any(c in name for c in ("/","\\","\x00")) or any(ord(c)<32 for c in name) or Path(name).suffix.lower() not in (".wav",".mp3",".flac",".ogg",".m4a",".aac"):
            self.json_reply(400,{"message":"Nome o estensione audio non validi"});return
        try: length=int(self.headers.get("Content-Length","0"))
        except ValueError: length=0
        if self.headers.get("Transfer-Encoding") or not 0<length<=MAX_UPLOAD:
            self.json_reply(413,{"message":"Dimensione non valida: massimo 512 MB per file"});return
        if not UPLOAD_LOCK.acquire(blocking=False):
            self.json_reply(409,{"message":"Un caricamento è già in corso"});return
        temporary=None
        try:
            MEDIA_DIR.mkdir(parents=True,exist_ok=True,mode=0o750)
            destination=MEDIA_DIR/name
            if destination.exists():
                self.json_reply(409,{"message":"Nome già presente nella libreria"});return
            if shutil.disk_usage(MEDIA_DIR).free<length+256*1024*1024:
                self.json_reply(507,{"message":"Spazio insufficiente sul TX"});return
            fd,temporary=tempfile.mkstemp(prefix=".upload-",dir=MEDIA_DIR)
            with os.fdopen(fd,"wb") as f:
                remaining=length
                while remaining:
                    chunk=self.rfile.read(min(remaining,1024*1024))
                    if not chunk: raise OSError("Caricamento interrotto")
                    f.write(chunk);remaining-=len(chunk)
                f.flush();os.fsync(f.fileno())
            os.link(temporary,destination)
            self.json_reply(201,{"ok":True,"message":"File caricato sul TX","name":name})
        except (OSError,TimeoutError):
            self.json_reply(400,{"message":"Caricamento non completato"})
        finally:
            if temporary and os.path.exists(temporary): os.unlink(temporary)
            UPLOAD_LOCK.release()

def main():
    global STUDIO, HISTORY, HISTORY_ERROR, LATENCY_FLEET
    if sys.argv[1:]==["--set-password"]:
        set_password();return
    config=read_config();role=config.get("ROLE","")
    if sys.argv[1:]==["--restore-live"]:
        if role=="tx": subprocess.run(["systemctl","--no-block","start","roc-museum.service"],check=False,timeout=15)
        return
    if role=="rx":
        restore_saved_volume()
    if role=="tx":
        try:
            from diagnostic_history import History
            HISTORY=History()
        except Exception as error:
            HISTORY_ERROR=str(error)
            print("Storico diagnostico non disponibile: "+HISTORY_ERROR,flush=True)
    if role=="tx":
        from fleet_latency import Fleet
        def latency_nodes():
            with REGISTRY_LOCK: return [dict(node) for node in REGISTRY.values()]
        try:
            LATENCY_FLEET=Fleet(latency_nodes,lambda name,command,value:send_control(config,name,command,value))
            threading.Thread(target=LATENCY_FLEET.loop,daemon=True).start()
        except (OSError,ValueError,KeyError,TypeError) as error:
            print("Configurazione latenza non disponibile: "+str(error),flush=True)
    threading.Thread(target=meter_loop,args=(config,),daemon=True).start()
    heartbeat=threading.Thread(target=heartbeat_loop,args=(config,),daemon=True);heartbeat.start()
    if role=="tx":
        listener=threading.Thread(target=listener_loop,args=(config,),daemon=True);listener.start()
        Handler.config=config
        try:
            import importlib.util
            spec=importlib.util.spec_from_file_location("roc_studio","/usr/local/lib/roc-museum/studio.py")
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            engine=module.Studio(config,media=MEDIA_DIR,copy_lock=UPLOAD_LOCK)
            STUDIO=engine;Handler.studio=engine
            engine.start()
        except Exception as error:
            print("Regia non disponibile: "+str(error),flush=True)
        port=int(config.get("MONITOR_HTTP_PORT","8080"))
        server=ThreadingHTTPServer(("0.0.0.0",port),Handler)
        print("Dashboard in ascolto sulla porta "+str(port),flush=True)
        server.serve_forever();return
    def serve_diagnostics():
        try:
            from diagnostics_access import serve
            serve(config)
        except Exception as error:
            print("Accesso diagnostico RX non disponibile: "+str(error),flush=True)
    threading.Thread(target=serve_diagnostics,daemon=True).start()
    commands=threading.Thread(target=command_listener_loop,args=(config,),daemon=True);commands.start()
    while True: time.sleep(3600)
if __name__=="__main__": main()
PY_MONITOR
    chmod 0755 "$MONITOR_TARGET"
    install -d -m 0755 /usr/local/lib/roc-museum /usr/local/share/roc-museum
    cat > /usr/local/lib/roc-museum/fleet_latency.py <<'PY_FLEET_LATENCY'
"""One persistent target for all receivers, reconciled from TX heartbeats."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import uuid

STATE = Path('/var/lib/roc-museum/fleet-latency.json')


def validate(value):
    if type(value) is not int or not 20 <= value <= 2000:
        raise ValueError('Inserire una latenza intera tra 20 e 2000 ms')
    return value


def atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def apply_receiver(config, value, path='/etc/roc-museum.conf'):
    if not isinstance(value, dict): raise ValueError('Comando latenza non valido')
    target = str(validate(value.get('target_ms'))) + 'ms'
    revision = value.get('revision')
    if not isinstance(revision, str) or not re.fullmatch('[a-f0-9]{32}', revision):
        raise ValueError('Revisione latenza non valida')
    if config.get('TARGET_LATENCY') == target and config.get('FLEET_LATENCY_REVISION') == revision:
        return True
    path = Path(path)
    old = path.read_text()
    lines = [line for line in old.splitlines() if not re.match(r'^\s*(TARGET_LATENCY|FLEET_LATENCY_REVISION)\s*=', line)]
    atomic(path, '\n'.join(lines) + '\nTARGET_LATENCY="' + target + '"\nFLEET_LATENCY_REVISION="' + revision + '"\n')
    changed = config.get('TARGET_LATENCY') != target
    if changed:
        try:
            subprocess.run(['systemctl', 'restart', 'roc-museum.service'], check=True, timeout=15,
                           capture_output=True)
            subprocess.run(['systemctl', 'is-active', '--quiet', 'roc-museum.service'], check=True,
                           timeout=3, capture_output=True)
        except (OSError, subprocess.SubprocessError):
            atomic(path, old)
            try:
                subprocess.run(['systemctl', 'restart', 'roc-museum.service'], check=False,
                               timeout=15, capture_output=True)
            except (OSError, subprocess.SubprocessError): pass
            raise RuntimeError('Riavvio Roc fallito: ripristinata la configurazione precedente') from None
    config.update(TARGET_LATENCY=target, FLEET_LATENCY_REVISION=revision)
    return True


class Fleet:
    def __init__(self, discover, send, path=STATE):
        self.discover, self.send, self.path = discover, send, Path(path)
        self.lock = threading.RLock()
        self.attempts, self.errors = {}, {}
        try:
            self.desired = json.loads(self.path.read_text())
            validate(self.desired['target_ms'])
            if not re.fullmatch('[a-f0-9]{32}', self.desired['revision']): raise ValueError('Revisione non valida')
        except FileNotFoundError:
            self.desired = None

    def request(self, target):
        validate(target)
        with self.lock:
            desired = {'target_ms': target, 'revision': uuid.uuid4().hex, 'changed_at': time.time()}
            atomic(self.path, json.dumps(desired))
            self.desired = desired
            self.attempts.clear(); self.errors.clear()
        return self.snapshot()

    def snapshot(self):
        with self.lock:
            desired = dict(self.desired) if self.desired else None
            nodes = []
            for node in self.discover():
                if node.get('role') != 'rx': continue
                name = node.get('name', '?')
                online = time.time() - node.get('received_at', 0) <= 15
                state = 'non_impostata'
                if desired:
                    if not online: state = 'offline'
                    elif not node.get('latency_control_supported'): state = 'aggiornamento_richiesto'
                    elif node.get('latency_revision') == desired['revision'] and node.get('target_latency') == str(desired['target_ms']) + 'ms': state = 'confermato'
                    elif node.get('latency_control_error') or self.errors.get(name): state = 'errore'
                    else: state = 'in_attesa'
                nodes.append({'name': name, 'state': state, 'current': node.get('target_latency'),
                              'error': node.get('latency_control_error') or self.errors.get(name, '')})
            return {'desired': desired, 'nodes': nodes}

    def tick(self):
        with self.lock:
            if not self.desired: return
            for node in self.snapshot()['nodes']:
                name = node['name']
                if node['state'] not in ('in_attesa', 'errore'): continue
                if time.monotonic() - self.attempts.get(name, -1e9) < 30: continue
                self.attempts[name] = time.monotonic()
                try:
                    ok, message = self.send(name, 'set_latency', dict(self.desired))
                    self.errors[name] = '' if ok else str(message)
                except OSError as error:
                    self.errors[name] = str(error)

    def loop(self):
        while True:
            try: self.tick()
            except Exception as error: print('Latenza RX: ' + str(error), flush=True)
            time.sleep(5)
PY_FLEET_LATENCY
    chmod 0644 /usr/local/lib/roc-museum/fleet_latency.py
    cat > /usr/local/lib/roc-museum/diagnostics_access.py <<'PY_DIAGNOSTICS_ACCESS'
"""Read-only RX diagnostic transport. The TX is the only accepted LAN peer."""
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import subprocess
import threading
import time

ROOT = Path('/var/lib/roc-museum/diagnostics')
MAX_BYTES = 16 * 1024 * 1024
FILES = {'event.json': 'application/json', 'reference.wav': 'audio/wav', 'return.wav': 'audio/wav'}
EVENT = re.compile(r'event-[0-9]{1,24}\Z')
SLOTS = threading.BoundedSemaphore(3)


def read_artifact(event, filename, root=ROOT):
    if not isinstance(event, str) or not isinstance(filename, str) or not EVENT.fullmatch(event) or filename not in FILES:
        raise ValueError('Evidenza non valida')
    # Open each path component without following links, including the event directory.
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        folder = os.open(event, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        try:
            fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder)
            with os.fdopen(fd, 'rb') as stream:
                import stat
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
                    raise ValueError('File non regolare o troppo grande')
                return stream.read(MAX_BYTES + 1)
        finally:
            os.close(folder)
    finally:
        os.close(directory)


def collect(request, root=ROOT):
    action = request.get('action')
    if action == 'events':
        events = []
        if root.exists():
            for folder in sorted(root.iterdir(), key=lambda p: p.name, reverse=True):
                if not EVENT.fullmatch(folder.name) or folder.is_symlink() or not folder.is_dir():
                    continue
                try:
                    data = json.loads(read_artifact(folder.name, 'event.json', root))
                    events.append({'id': folder.name, 'saved_at': data.get('saved_at'),
                                   'triggered_at': data.get('triggered_at'),
                                   'status': data.get('analysis', {}).get('status', 'unknown')})
                except (OSError, ValueError):
                    continue
                if len(events) >= 20:
                    break
        return 'application/json', json.dumps({'events': events, 'generated_at': time.time()}).encode()
    if action == 'file':
        filename = request.get('file', '')
        data = read_artifact(request.get('event', ''), filename, root)
        return FILES[filename], data
    if action == 'journal':
        window = request.get('window', '15m')
        unit = request.get('unit', 'roc-museum')
        if window not in ('15m', '1h', '24h') or unit not in ('roc-museum', 'roc-museum-monitor'):
            raise ValueError('Intervallo o servizio non valido')
        result = subprocess.run(['journalctl', '-u', unit + '.service', '--since=-' + window,
                                 '-n', '5001', '--no-pager', '-o', 'short-iso-precise'],
                                capture_output=True, timeout=8, check=False)
        if result.returncode:
            raise ValueError('Journal non disponibile: ' + result.stderr.decode(errors='replace')[-1000:])
        lines = result.stdout.splitlines(keepends=True)
        raw = b''.join(lines[-5000:])
        truncated = len(lines) > 5000 or len(raw) > 512 * 1024
        text = raw[-512 * 1024:].decode(errors='replace')
        return 'application/json', json.dumps({'text': text, 'truncated': truncated,
            'window': window, 'unit': unit, 'generated_at': time.time(),
            'limit_lines': 5000, 'limit_bytes': 512 * 1024}).encode()
    raise ValueError('Richiesta diagnostica non valida')


def fetch(host, port, request):
    with socket.create_connection((host, port), timeout=4) as connection:
        connection.settimeout(15)
        connection.sendall(json.dumps(request).encode() + b'\n')
        with connection.makefile('rb') as stream:
            header = json.loads(stream.readline(4097))
            if not header.get('ok'):
                raise ValueError(header.get('message', 'Diagnostica non disponibile'))
            length = header.get('length')
            if type(length) is not int or not 0 <= length <= MAX_BYTES:
                raise ValueError('Dimensione risposta non valida')
            if header.get('content_type') not in ('application/json', 'audio/wav'):
                raise ValueError('Formato risposta non valido')
            data = stream.read(length)
            if len(data) != length:
                raise ValueError('Trasferimento evidenza incompleto')
            return header['content_type'], data


class DiagnosticHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(15)
        try:
            raw = self.rfile.readline(4097)
            if len(raw) > 4096:
                raise ValueError('Richiesta troppo grande')
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError('Richiesta non valida')
            content_type, data = collect(request)
            self.wfile.write(json.dumps({'ok': True, 'length': len(data), 'content_type': content_type}).encode() + b'\n')
            self.wfile.write(data)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.wfile.write(json.dumps({'ok': False, 'message': str(error)[:400]}).encode() + b'\n')


class DiagnosticServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def verify_request(self, request, address):
        return address[0] == self.tx_ip

    def process_request(self, request, address):
        if not SLOTS.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            SLOTS.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            SLOTS.release()


def serve(config):
    with DiagnosticServer(('0.0.0.0', int(config.get('CONTROL_PORT', '19091'))), DiagnosticHandler) as server:
        server.tx_ip = config.get('TX_IP', '')
        server.serve_forever()
PY_DIAGNOSTICS_ACCESS
    chmod 0644 /usr/local/lib/roc-museum/diagnostics_access.py
    cat > /usr/local/lib/roc-museum/diagnostic_history.py <<'PY_DIAGNOSTIC_HISTORY'
"""TX-only persistent incident history; never carries PCM or runs on RX."""
import hashlib
import json
from pathlib import Path
import sqlite3
import threading
import time


class History:
    def __init__(self, path='/var/lib/roc-museum/diagnostic-history.sqlite3', limit=1000):
        self.path=Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.limit=limit
        self.lock=threading.Lock()
        self.active={}
        self.error=''
        with self.connection() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY, identity TEXT UNIQUE, node TEXT NOT NULL,
                source TEXT NOT NULL, code TEXT NOT NULL, severity TEXT NOT NULL,
                summary TEXT NOT NULL, started_at REAL NOT NULL, last_seen REAL NOT NULL,
                ended_at REAL, observations INTEGER NOT NULL, details TEXT NOT NULL,
                resolution TEXT NOT NULL DEFAULT '')''')
            # A restart is a gap in observation, not evidence of recovery.
            db.execute("UPDATE events SET ended_at=last_seen, resolution='monitor_restart' WHERE ended_at IS NULL")

    def connection(self):
        # Explicit close as well as commit; sqlite's context manager alone doesn't close.
        class Transaction:
            def __enter__(inner):
                inner.db=sqlite3.connect(self.path,timeout=1)
                return inner.db
            def __exit__(inner,kind,error,tb):
                try:
                    if kind is None: inner.db.commit()
                    else: inner.db.rollback()
                finally: inner.db.close()
        return Transaction()

    @staticmethod
    def issues(node):
        name=str(node.get('name','?'))[:128]
        if not node.get('online',True):
            return [(name,'node','OFFLINE','warning','Nodo offline',{})]
        issues=[]
        digital=node.get('transport_diagnosis') or node.get('audio_diagnosis') or {}
        if digital.get('severity') in ('warning','critical') or digital.get('code')=='TX_MONITOR_STALL_UNCONFIRMED':
            issues.append((name,'transport',str(digital.get('code','UNKNOWN'))[:100],
                           digital['severity'],str(digital.get('summary',''))[:600],
                           {'detail':str(digital.get('detail',''))[:1200],
                            'rtp':node.get('audio_meter',{}).get('integrity',{}),
                            'power':node.get('throttled'), 'network':node.get('network',{})}))
        waveform=node.get('waveform_diagnostics') or {}
        waveform_faults=('dropout','dropout_candidate','mismatch','missing_return','missing_channel','possible_channel_swap',
                         'return_clipping','reference_gaps','delay_jump','reference_timeout','capture_interrupted','error')
        if waveform.get('confirmed') or waveform.get('status') in waveform_faults:
            issues.append((name,'waveform',str(waveform.get('status','unknown'))[:100],
                           'warning' if waveform.get('confirmed') else 'info',
                           (('' if waveform.get('confirmed') else 'Osservazione da confermare: ')+str(waveform.get('message','')))[:600],
                           {k:waveform[k] for k in ('confirmed','estimated_delay_ms','delay_change_ms','channels','stereo_dropout_overlap_ms','rtp',
                                                   'reference_coverage','confidence','channel_mapping','channel_map','capture_timing','workload','clock_diagnostics','capture_health','timing_confidence','observed_audio_status') if k in waveform}))
        if waveform.get('timing_observation'):
            issues.append((name,'probe_timing',str(waveform['timing_observation'])[:100],'info',
                           str(waveform.get('timing_message','Variazione della misura temporale'))[:600],
                           {k:waveform[k] for k in ('estimated_delay_ms','delay_change_ms','capture_timing','workload','clock_diagnostics','capture_health','timing_confidence','observed_audio_status') if k in waveform}))
        if waveform.get('workload',{}).get('over_budget'):
            issues.append((name,'probe_runtime','ANALYSIS_COST','info','Costo elevato del worker di analisi spia',
                           waveform['workload']))
        analog=node.get('analog_return') or {}
        if analog.get('status') in ('missing_return','capture_clipping','audio_while_muted','unexpected_audio'):
            # A recent aligned comparison takes precedence over a stale level meter.
            if waveform.get('status') in (None,'unavailable','error') or analog['status'] in ('capture_clipping','audio_while_muted'):
                issues.append((name,'analog',analog['status'],'warning',str(analog.get('message',''))[:600],
                               {'channels':analog.get('channels',[])}))
        for key in ('roc_last_error','roc_last_warning'):
            message=str(node.get(key) or '')[:1200]
            if message:
                code=hashlib.sha256(message.encode()).hexdigest()[:16]
                issues.append((name,key,code,'warning',message,{}))
        return issues

    @staticmethod
    def details(value):
        encoded=json.dumps(value,ensure_ascii=False,allow_nan=False)
        # Bound untrusted heartbeat data before storing it.
        if len(encoded)>6000:
            encoded=json.dumps({'excerpt':encoded[:5500],'truncated':True},ensure_ascii=False)
        return encoded

    def observe(self, nodes, now=None):
        now=time.time() if now is None else now
        with self.lock:
            active=dict(self.active)
            current=set()
            offline={str(node.get('name','?'))[:128] for node in nodes if not node.get('online',True)}
            present={str(node.get('name','?'))[:128] for node in nodes}
            with self.connection() as db:
                for node in nodes:
                    for name,source,code,severity,summary,detail in self.issues(node):
                        key=(name,source,code)
                        current.add(key)
                        encoded=self.details(detail)
                        if key in active:
                            db.execute('''UPDATE events SET last_seen=?, observations=observations+1, details=?,
                                       summary=CASE WHEN severity IN ('warning','critical') AND ?='info' THEN summary ELSE ? END,
                                       severity=CASE WHEN severity='critical' OR (severity='warning' AND ?='info') THEN severity ELSE ? END
                                       WHERE id=?''',(now,encoded,severity,summary,severity,severity,active[key]))
                        else:
                            cursor=db.execute('''INSERT INTO events
                                (node,source,code,severity,summary,started_at,last_seen,observations,details)
                                VALUES (?,?,?,?,?,?,?,1,?)''',(name,source,code,severity,summary,now,now,encoded))
                            active[key]=cursor.lastrowid
                    # RX sends only its most recent evidence: persist it even if status recovered.
                    for artifact in (node.get('waveform_diagnostics') or {}).get('events',[])[:1]:
                        path=str(artifact.get('path',''))[:512]
                        if not path: continue
                        name=str(node.get('name','?'))[:128]
                        identity=hashlib.sha256((name+'\0'+path).encode()).hexdigest()
                        db.execute('''INSERT OR IGNORE INTO events
                            (identity,node,source,code,severity,summary,started_at,last_seen,ended_at,observations,details,resolution)
                            VALUES (?,?,?,?,?,?,?,?,?,1,?,?)''',
                            (identity,name,'evidence',str(artifact.get('status','unknown'))[:100],'warning',
                             'Evidenza audio salvata sulla RX',now,now,now,
                             self.details({'path':path,'rx_triggered_at':artifact.get('triggered_at')}),'artifact'))
                for key in list(active):
                    if key not in current:
                        resolution='node_offline' if key[0] in offline else ('observation_lost' if key[0] not in present else 'recovered')
                        db.execute('UPDATE events SET ended_at=?, resolution=? WHERE id=?',(now,resolution,active.pop(key)))
                db.execute('DELETE FROM events WHERE ended_at IS NOT NULL AND ended_at<?',(now-30*86400,))
                db.execute('''DELETE FROM events WHERE ended_at IS NOT NULL AND id NOT IN
                    (SELECT id FROM events ORDER BY id DESC LIMIT ?)''',(self.limit,))
            self.active=active
            self.error=''

    def query(self, node=None, limit=100):
        limit=max(1,min(1000,int(limit)))
        with self.lock, self.connection() as db:
            db.row_factory=sqlite3.Row
            where=' WHERE node=?' if node else ''
            params=(node,limit) if node else (limit,)
            records=[]
            for row in db.execute('SELECT * FROM events'+where+' ORDER BY id DESC LIMIT ?',params):
                record=dict(row);record.pop('identity',None)
                record['details']=json.loads(record['details'])
                record['active']=record['ended_at'] is None
                record['observed_duration_seconds']=round(max(0,(record['ended_at'] or record['last_seen'])-record['started_at']),1)
                records.append(record)
            return {'events':records,'retention_days':30,'limit':self.limit,'error':self.error,
                    'time_basis':'TX observation; durations are sampled, not exact audio fault lengths'}
PY_DIAGNOSTIC_HISTORY
    chmod 0644 /usr/local/lib/roc-museum/diagnostic_history.py
    cat > /usr/local/lib/roc-museum/rx_diagnostics.py <<'PY_RX_DIAGNOSTICS'
"""Bounded RX RTP/analog diagnostics. No playback, network or capture ownership."""
import json
import math
import statistics
from pathlib import Path
import struct
import subprocess
import threading
import time
import wave
from collections import deque

try:
    import numpy as np
except ImportError:
    np = None


ANALYSIS_RATE=2000


class ClockModel:
    """Bounded affine sample-counter/host fit, not a hardware timestamp source."""
    def __init__(self, rate):
        self.rate=rate
        self.points=deque(maxlen=240)
        self.raw_origin=None
        self.fit=None
        self.span=0.
        self.scatter=None
        self.step_hits=0
        self.steps=0
        self.last_step=None

    def observe(self, count, now):
        if self.raw_origin is None: self.raw_origin=(count,now)
        if self.points and (count<=self.points[-1][0] or now-self.points[-1][1]<.4): return
        if self.fit is not None:
            residual=now-self.sample_time(count)
            if abs(residual)>.020:
                self.step_hits=self.step_hits+1 if self.last_step is not None and residual*self.last_step[0]>0 else 1
                self.last_step=(residual,now)
                if self.step_hits>=3:
                    self.steps+=1;self.points.clear();self.fit=None;self.span=0.;self.scatter=None;self.step_hits=0
            else: self.step_hits=0
        self.points.append((count,now))
        if len(self.points)<20: return
        self.span=(self.points[-1][0]-self.points[0][0])/self.rate
        if self.span<30: return
        base_count,base_time=self.points[0]
        points=[((c-base_count)/self.rate,t-base_time) for c,t in self.points]
        def fit(values):
            mx=sum(x for x,y in values)/len(values);my=sum(y for x,y in values)/len(values)
            variance=sum((x-mx)**2 for x,y in values)
            slope=sum((x-mx)*(y-my) for x,y in values)/max(variance,1e-12)
            return slope,my-slope*mx
        slope,intercept=fit(points)
        residuals=[y-(slope*x+intercept) for x,y in points]
        center=statistics.median(residuals)
        mad=statistics.median(abs(v-center) for v in residuals)
        keep=[point for point,residual in zip(points,residuals) if abs(residual-center)<=max(.002,4*mad)]
        if len(keep)<max(20,len(points)*.75): self.fit=None;return
        slope,intercept=fit(keep)
        residuals=sorted(abs(y-(slope*x+intercept)) for x,y in keep)
        self.scatter=residuals[min(len(residuals)-1,int(len(residuals)*.9))]
        # A fit outside 0.2% is not explained as normal clock drift.
        self.fit=(base_count,base_time,slope,intercept) if .998<=slope<=1.002 and self.scatter<.010 else None

    def sample_time(self, count):
        if self.fit is not None:
            base_count,base_time,slope,intercept=self.fit
            return base_time+intercept+slope*(count-base_count)/self.rate
        if self.points:
            base_count,base_time=self.points[0]
            return base_time+(count-base_count)/self.rate
        return None

    @property
    def effective_rate(self):
        return self.rate/self.fit[2] if self.fit is not None else self.rate

    def summary(self, count, now):
        raw=None if self.raw_origin is None else now-(self.raw_origin[1]+(count-self.raw_origin[0])/self.rate)
        predicted=self.sample_time(count)
        return {'fit_valid':self.fit is not None,'nominal_rate':self.rate,
                'effective_rate':round(self.effective_rate,5),
                'drift_ppm':None if self.fit is None else round((self.fit[2]-1)*1e6,2),
                'raw_offset_ms':None if raw is None else round(raw*1000,2),
                'residual_ms':None if predicted is None else round((now-predicted)*1000,2),
                'fit_jitter_ms':None if self.scatter is None else round(self.scatter*1000,2),
                'fit_span_seconds':round(self.span,2),'points':len(self.points),'delivery_steps':self.steps,
                'last_step_ms':None if self.last_step is None else round(self.last_step[0]*1000,2),
                'last_step_monotonic':None if self.last_step is None else self.last_step[1],
                'nominal_elapsed_seconds':None if self.raw_origin is None else round((count-self.raw_origin[0])/self.rate,3),
                'host_elapsed_seconds':None if self.raw_origin is None else round(now-self.raw_origin[1],3),
                'time_basis':'software delivery timestamps; rate estimate may include acquisition effects'}


def decode_rtp(packet):
    """Static L16 RTP: PT 10 stereo / PT 11 mono, both 44100 Hz."""
    if len(packet) < 12 or packet[0] >> 6 != 2 or packet[1] & 127 not in (10, 11):
        return None
    channels = 2 if packet[1] & 127 == 10 else 1
    offset = 12 + 4 * (packet[0] & 15)
    if len(packet) < offset:
        return None
    if packet[0] & 16:
        if len(packet) < offset + 4:
            return None
        offset += 4 + 4 * struct.unpack_from('!H', packet, offset + 2)[0]
    end = len(packet)
    if packet[0] & 32:
        padding = packet[-1]
        if not padding or padding > end - offset:
            return None
        end -= padding
    if end <= offset or (end - offset) % (2 * channels):
        return None
    seq, stamp, ssrc = struct.unpack_from('!HII', packet, 2)
    return seq, stamp, ssrc, channels, packet[offset:end]


def resample(samples, rate, target=ANALYSIS_RATE):
    """Two-stage antialias filtering; only diagnostic copies are resampled."""
    if rate/target>=7.5:
        x=np.arange(17)-8
        kernel=2*.1125*np.sinc(2*.1125*x)*np.hamming(17)
        kernel/=kernel.sum()
        samples=np.stack([np.convolve(samples[:,ch],kernel,mode='same')[::4]
                          for ch in range(samples.shape[1])],axis=1)
        rate/=4
    taps=max(17,int(16*rate/target)|1)
    x=np.arange(taps)-taps//2
    cutoff=.45*target/rate
    kernel=2*cutoff*np.sinc(2*cutoff*x)*np.hamming(taps)
    kernel/=kernel.sum()
    filtered=np.stack([np.convolve(samples[:,ch],kernel,mode='same')
                       for ch in range(samples.shape[1])],axis=1)
    positions=np.arange(int(len(samples)*target/rate))*rate/target
    return np.stack([np.interp(positions,np.arange(len(samples)),filtered[:,ch])
                     for ch in range(samples.shape[1])],axis=1)


def match_channel(reference, observed):
    """Normalized FFT correlation over all valid reference offsets."""
    size = len(observed)
    centered = observed - observed.mean()
    energy = float(centered @ centered)
    count = len(reference) - size + 1
    if count <= 0 or energy < size * 10 ** (-55 / 10):
        return None
    nfft = 1 << (len(reference) + size - 2).bit_length()
    numerator = np.fft.irfft(np.fft.rfft(reference, nfft) *
                             np.fft.rfft(centered[::-1], nfft), nfft)[size-1:len(reference)]
    sums = np.r_[0., np.cumsum(reference)]
    squares = np.r_[0., np.cumsum(reference * reference)]
    window_energy = squares[size:] - squares[:-size] - (sums[size:] - sums[:-size]) ** 2 / size
    scores = numerator / np.sqrt(np.maximum(window_energy * energy, 1e-24))
    scores[window_energy < size * 10 ** (-55 / 10)] = 0
    index = int(np.argmax(np.abs(scores)))
    score = float(scores[index])
    # Similar peaks at substantially different delays make latency ambiguous.
    alternatives = np.abs(scores).copy()
    alternatives[max(0, index-int(.020*ANALYSIS_RATE)):index+int(.020*ANALYSIS_RATE)+1] = 0
    ambiguous = bool(alternatives.max(initial=0) > max(0.7, abs(score) * .95))
    segment = reference[index:index+size]
    segment = segment - segment.mean()
    gain = float(segment @ centered / max(float(segment @ segment), 1e-24))
    residual = centered - gain * segment
    residual_db = 10 * math.log10(max(float(residual @ residual) / energy, 1e-12))
    return {'offset': index, 'correlation': round(score, 4), 'ambiguous': ambiguous,
            'gain_db': round(20 * math.log10(max(abs(gain), 1e-9)), 2),
            'residual_db': round(residual_db, 2)}


def dropout_evidence(run, expected, actual, raw, raw_rate, correlation):
    """Check the same alignment on each flank and verify attenuation in raw PCM."""
    start = run['start_ms']
    end = start + run['duration_ms']
    duration = len(actual) * 1000 // ANALYSIS_RATE
    flanks = [(max(0, start-100), start), (end, min(duration, end+100))]
    scores = []
    levels = []
    for left, right in flanks:
        if right-left < 40:
            scores.append(None)
            continue
        window = slice(left*ANALYSIS_RATE//1000, right*ANALYSIS_RATE//1000)
        x, y = expected[window], actual[window]
        power = float(np.linalg.norm(x)*np.linalg.norm(y))
        score = float(np.dot(x,y))/power if power else 0
        scores.append(round(score if correlation >= 0 else -score, 3))
        samples = raw[left*raw_rate//1000:right*raw_rate//1000]
        levels.append(float(np.mean(samples**2)))
    gap = raw[start*raw_rate//1000:end*raw_rate//1000]
    contrast = None
    if len(levels) == 2 and min(levels) > 0:
        contrast = round(10*float(np.log10(max(float(np.mean(gap**2)), 1e-12)/min(levels))), 1)
    return {'flank_correlations': scores, 'raw_level_change_db': contrast,
            'corroborated': all(score is not None and score >= .6 for score in scores)
                            and contrast is not None and contrast <= -15}


def compare(reference, observed, reference_rate=44100, capture_rate=16000, channel_map=None, probe_mapping=True):
    """Compare a history reference to the last second of analog audio."""
    if len(reference)/reference_rate < .25 or len(observed)/capture_rate < .25:
        return {'status': 'warming_up', 'message': 'Accumulo delle finestre di confronto'}
    started=time.thread_time()
    ref = resample(reference, reference_rate)
    heard = resample(observed, capture_rate)
    resample_cpu=(time.thread_time()-started)*1000
    correlation_started=time.thread_time()
    if len(heard) < ANALYSIS_RATE//4 or len(ref) < len(heard):
        return {'status': 'warming_up', 'message': 'Accumulo delle finestre di confronto'}
    count = min(2, ref.shape[1], heard.shape[1])
    mapping = list(channel_map) if channel_map is not None and len(channel_map)==count else list(range(count))
    if sorted(mapping) != list(range(count)): mapping=list(range(count))
    pairs = [[match_channel(ref[:, source], heard[:, channel]) if probe_mapping or source==mapping[channel] else None
              for source in range(count)] for channel in range(count)]
    if count == 2 and probe_mapping:
        def mapping_score(order):
            chosen=[pairs[ch][source] for ch,source in enumerate(order)]
            if not all(item is not None and abs(item['correlation']) >= .5 for item in chosen): return None
            if abs(chosen[0]['offset']-chosen[1]['offset']) > .005*ANALYSIS_RATE: return None
            return sum(abs(item['correlation']) for item in chosen)/2
        direct, crossed=mapping_score([0,1]),mapping_score([1,0])
        if crossed is not None and crossed >= .75 and crossed > (direct or 0)+.05:
            mapping=[1,0]
        elif direct is not None and direct >= .75 and direct > (crossed or 0)+.05:
            mapping=[0,1]
    results = []
    for channel, source in enumerate(mapping):
        selected=pairs[channel][source]
        if selected is None:
            results.append({'channel': channel, 'reference_channel': source, 'status': 'insufficient_signal'})
            continue
        result=dict(selected)
        result['channel'] = channel
        result['reference_channel'] = source
        result['polarity_inverted'] = result['correlation'] < -.75
        result['status'] = 'matched' if abs(result['correlation']) >= .75 else 'mismatch'
        start = result['offset']
        expected = ref[start:start+len(heard), source]
        actual = heard[:, channel]
        gain = 10 ** (result['gain_db'] / 20)
        block = ANALYSIS_RATE//100
        length = len(actual) // block * block
        erms = np.sqrt(np.mean(expected[:length].reshape(-1, block) ** 2, axis=1))
        arms = np.sqrt(np.mean(actual[:length].reshape(-1, block) ** 2, axis=1))
        active = erms * gain > 10 ** (-45 / 20)
        missing = active & (arms < np.maximum(10 ** (-65 / 20), erms * gain * .08))
        runs = []
        begin = None
        for i, flag in enumerate(np.r_[missing, False]):
            if flag and begin is None:
                begin = i
            elif not flag and begin is not None:
                if i - begin >= 2:
                    runs.append({'start_ms': begin * 10, 'duration_ms': (i-begin) * 10})
                begin = None
        result['dropouts'] = runs
        for run in runs:
            run.update(dropout_evidence(run, expected, actual, observed[:, channel],
                                        capture_rate, result['correlation']))
        if runs:
            verified = abs(result['correlation']) >= .5 and not result['ambiguous']
            result['status'] = 'dropout' if verified and any(r['corroborated'] for r in runs) else 'dropout_candidate'
        results.append(result)
    # A silent channel can only be checked at a delay established by the other channel.
    aligned = next((r for r in results if abs(r.get('correlation', 0)) >= .75 and not r.get('ambiguous')), None)
    if aligned:
        for channel, result in enumerate(results):
            if result['status'] == 'insufficient_signal':
                start = aligned['offset']
                expected = ref[start:start+len(heard), mapping[channel]]
                if float(np.mean(expected**2)) > 10**(-45/10) and float(np.mean(observed[:,channel]**2)) < 10**(-55/10):
                    result['status'] = 'missing_channel'
    usable = [r for r in results if 'correlation' in r]
    status = 'matched'
    message = 'Ritorno correlato al riferimento RTP'
    if not usable:
        status, message = 'insufficient_signal', 'Segnale insufficiente per confrontare le forme d’onda'
    elif any(r['status'] == 'missing_channel' for r in results):
        status, message = 'missing_channel', 'Un canale del ritorno è assente mentre il riferimento è attivo'
    elif any(r['status'] == 'dropout' for r in usable):
        status, message = 'dropout', 'Interruzione nel ritorno rispetto al riferimento allineato'
    elif any(r['status'] == 'dropout_candidate' for r in usable):
        status, message = 'dropout_candidate', 'Calo rilevato con riscontro insufficiente nel PCM o nell’allineamento locale'
    elif any(r['status'] == 'mismatch' for r in usable):
        status, message = 'mismatch', 'Ritorno poco correlato: contenuto alterato o allineamento non affidabile'
    elif any(r['status']=='insufficient_signal' for r in results):
        status, message = 'partial_match', 'Solo parte dei canali è valutabile nella banda diagnostica'
    elif any(r['ambiguous'] for r in usable):
        status, message = 'ambiguous', 'Audio correlato ma ritardo ambiguo: contenuto ripetitivo'
    stereo_overlap_ms = 0
    if len(results) == 2 and all(r['status'] == 'dropout' for r in results):
        for left in results[0]['dropouts']:
            for right in results[1]['dropouts']:
                if left['corroborated'] and right['corroborated']:
                    overlap = min(left['start_ms']+left['duration_ms'], right['start_ms']+right['duration_ms'])
                    overlap -= max(left['start_ms'], right['start_ms'])
                    stereo_overlap_ms = max(stereo_overlap_ms, overlap)
    clipped = np.mean(np.abs(observed) >= 32760/32768, axis=0)
    if bool(np.any(clipped > .0001)):
        status, message = 'return_clipping', 'Saturazione rilevata nel ritorno acquisito: controllare anche il gain ADC'
    return {'status': status, 'message': message, 'channels': results, 'analysis_rate': ANALYSIS_RATE,
            'stereo_dropout_overlap_ms': stereo_overlap_ms,
            'stage_cpu_ms':{'resample':round(resample_cpu,2),
                            'compare':round((time.thread_time()-correlation_started)*1000,2)},
            'clipped_fraction': [round(float(v), 6) for v in clipped],
            'diagnostic_band_hz': [0,900],
            'full_band_return_active':bool(np.any(np.mean(observed**2,axis=0)>10**(-55/10))),
            'channel_map': mapping, 'channel_mapping': 'swapped' if mapping==[1,0] else 'direct'}


class Diagnostics:
    HISTORY = 8
    def __init__(self, directory='/var/lib/roc-museum/diagnostics'):
        self.lock = threading.Lock()
        self.reference = deque(maxlen=5000)
        self.capture = deque(maxlen=100)
        self.directory = Path(directory)
        self.stream = None
        self.high_seq = None
        self.high_stamp = None
        self.seen = set()
        self.sequence_window = deque(maxlen=4096)
        self.stats = {'packets': 0, 'sequence_gaps': 0, 'out_of_order': 0, 'duplicates': 0, 'jitter_ms': 0.}
        self.transit = None
        self.result = {'status': 'warming_up', 'message': 'In attesa del ritorno Scarlett'}
        self.pending = None
        self.last_event = -1e9
        self.candidate = None
        self.hits = 0
        self.previous_delay = None
        self.previous_delay_time = None
        self.delay_history = deque(maxlen=120)
        self.trigger_buffers = None
        self.last_buffers = None
        self.context = {}
        self.last_context = 0
        self.events = deque(maxlen=5)
        self.storage_error = ''
        self.channel_map = None
        self.capture_origin = None
        self.capture_frames = 0
        self.capture_blocks = 0
        self.capture_timing = {}
        self.workload = {}
        self.last_analyzed_capture = None
        self.last_analyzed_context = None
        self.capture_clock=ClockModel(16000)
        self.reference_clock=ClockModel(44100)
        self.capture_health={}
        self.buffer_clock={}
        self.last_mapping_check=-1e9
        self.analysis_interval=1.0
        self.clock_epoch=0
        self.clock_reset_reason='startup'

    def feed_rtp(self, packet, now=None):
        decoded = decode_rtp(packet)
        if decoded is None or np is None:
            return
        seq, stamp, ssrc, channels, raw = decoded
        now = time.monotonic() if now is None else now
        samples = np.frombuffer(raw, dtype='>i2').astype(np.float32).reshape(-1, channels) / 32768
        with self.lock:
            if self.stream != (ssrc, channels) or (self.reference and now-self.reference[-1][0] > 2):
                self.reference.clear(); self.capture.clear()
                self.stream = (ssrc, channels)
                self.high_seq = None; self.high_stamp = None
                self.seen.clear(); self.sequence_window.clear(); self.transit = None
                self.previous_delay = None; self.previous_delay_time = None; self.delay_history.clear()
                self.last_buffers = None
                self.channel_map = None; self.capture_origin = None; self.capture_frames = 0
                self.capture_clock=ClockModel(16000);self.reference_clock=ClockModel(44100)
                self.last_analyzed_capture=None;self.last_mapping_check=-1e9
                self.clock_epoch+=1;self.clock_reset_reason='rtp_stream_change'
            if self.high_seq is None:
                extended_seq = seq
                extended_stamp = stamp
            else:
                extended_seq = self.high_seq + ((seq - self.high_seq + 32768) % 65536 - 32768)
                extended_stamp = self.high_stamp + ((stamp - self.high_stamp + 2**31) % 2**32 - 2**31)
            if extended_seq in self.seen:
                self.stats['duplicates'] += 1
                return
            if len(self.sequence_window) == self.sequence_window.maxlen:
                self.seen.discard(self.sequence_window[0])
            self.sequence_window.append(extended_seq); self.seen.add(extended_seq)
            self.stats['packets'] += 1
            if self.high_seq is not None:
                if extended_seq > self.high_seq + 1:
                    self.stats['sequence_gaps'] += extended_seq-self.high_seq-1
                elif extended_seq < self.high_seq:
                    self.stats['out_of_order'] += 1
            if self.high_seq is None or extended_seq > self.high_seq:
                transit = now - extended_stamp / 44100
                if self.transit is not None:
                    delta = abs(transit-self.transit)*1000
                    self.stats['jitter_ms'] += (delta-self.stats['jitter_ms']) / 16
                self.transit = transit
                self.high_seq = extended_seq; self.high_stamp = extended_stamp
                self.reference_clock.observe(extended_stamp+len(samples),now)
            self.reference.append((now, extended_stamp, samples))
            while self.reference and self.reference[0][0] < now-self.HISTORY:
                self.reference.popleft()

    def feed_capture(self, raw, now=None):
        if np is None:
            return
        now = time.monotonic() if now is None else now
        samples = np.frombuffer(raw, dtype='<i2').astype(np.float32).reshape(-1, 2) / 32768
        with self.lock:
            previous=self.capture[-1][0] if self.capture else None
            if previous is not None and now-previous > 1:
                self.capture.clear(); self.capture_origin=None; self.capture_frames=0
                self.capture_clock=ClockModel(16000)
                self.clock_epoch+=1;self.clock_reset_reason='capture_delivery_gap'
                self.previous_delay=None; self.previous_delay_time=None; self.delay_history.clear()
            if self.capture_origin is None:
                self.capture_origin=now-len(samples)/16000
            self.capture_frames+=len(samples)
            self.capture_blocks+=1
            self.capture_clock.observe(self.capture_frames,now)
            sample_end=self.capture_clock.sample_time(self.capture_frames)
            clock=self.capture_clock.summary(self.capture_frames,now)
            self.capture_timing={
                'delivery_offset_ms': clock['raw_offset_ms'],
                'captured_frames':self.capture_frames,'captured_blocks':self.capture_blocks,
                'delivery_interval_error_ms': None if previous is None else round((now-previous-len(samples)/16000)*1000,2),
                'clock_basis': 'sample_count_with_robust_rate_fit'}
            self.capture.append((now, samples, sample_end, self.capture_frames))
            while self.capture and self.capture[0][0] < now-self.HISTORY:
                self.capture.popleft()

    def update_capture_health(self, health):
        with self.lock:
            if health.get('xrun_events',0)>self.capture_health.get('xrun_events',0):
                self.capture_clock=ClockModel(16000)
                self.clock_epoch+=1;self.clock_reset_reason='capture_xrun'
                self.previous_delay=None;self.previous_delay_time=None;self.delay_history.clear()
            self.capture_health=dict(health)

    def update_context(self, muted, reference, roc_error='', roc_warning=''):
        with self.lock:
            self.context = {'muted': muted, 'reference_meter': reference,
                            'roc_error': roc_error, 'roc_warning': roc_warning}
            self.last_context = time.monotonic()

    def snapshot(self):
        with self.lock:
            result = dict(self.result)
            result.update(capture_health=dict(self.capture_health), schema_version=2, workload=dict(self.workload), capture_timing=dict(self.capture_timing), rtp=dict(self.stats), events=list(self.events)[-1:], storage_error=self.storage_error)
        return result

    def buffers(self, now):
        with self.lock:
            packets = list(self.reference)
            captures = list(self.capture)
            stats = dict(self.stats)
            context = dict(self.context)
            context_age = now-self.last_context
            if packets and captures:
                capture_end=self.capture_clock.sample_time(captures[-1][3])
                if capture_end is None: capture_end=captures[-1][2]
                self.buffer_clock={'epoch':self.clock_epoch,'reset_reason':self.clock_reset_reason,
                                   'capture_rate':self.capture_clock.effective_rate,
                                   'reference_rate':self.reference_clock.effective_rate,
                                   'adc':self.capture_clock.summary(captures[-1][3],captures[-1][0])}
        if not packets or not captures or now-packets[-1][0] > 2 or now-captures[-1][0] > 1:
            return None
        # RTP timestamps define sample positions, not packet arrival intervals.
        end = max(stamp+len(data) for _, stamp, data in packets)
        begin = max(min(stamp for _, stamp, _ in packets), end-self.HISTORY*44100)
        reference = np.zeros((end-begin, packets[-1][2].shape[1]), dtype=np.float32)
        coverage = np.zeros(end-begin, dtype=bool)
        for _, stamp, data in packets:
            lo, hi = max(begin, stamp), min(end, stamp+len(data))
            if hi > lo:
                reference[lo-begin:hi-begin] = data[lo-stamp:hi-stamp]
                coverage[lo-begin:hi-begin] = True
        observed = np.concatenate([chunk[1] for chunk in captures])
        # End arrival time anchors an approximate delay; ADC/kernel buffering remains included.
        last_packet = max(packets, key=lambda p: p[1]+len(p[2]))
        with self.lock:
            reference_end_time=self.reference_clock.sample_time(end) if self.reference_clock.fit is not None else last_packet[0]
            self.buffer_clock['rtp']=self.reference_clock.summary(end,last_packet[0])
        return reference, observed, coverage, reference_end_time, capture_end, stats, context, context_age

    def analyze(self, now=None):
        now = time.monotonic() if now is None else now
        if np is None:
            with self.lock:
                self.result = {'status': 'unavailable', 'message': 'NumPy non disponibile: reinstallare il setup aggiornato'}
            return
        buffers_started=time.thread_time()
        buffers = self.buffers(now)
        buffers_cpu=(time.thread_time()-buffers_started)*1000
        if buffers is None:
            if self.pending and now >= self.pending['due']:
                self.pending['post_capture_unavailable'] = True
                self.save_event(self.trigger_buffers)
            with self.lock:
                reference_age = now-self.reference[-1][0] if self.reference else None
                capture_age = now-self.capture[-1][0] if self.capture else None
                context = dict(self.context)
                stats = dict(self.stats)
            status, message = 'unavailable', 'Riferimento RTP o ritorno analogico non recente'
            if self.last_buffers is not None:
                if reference_age is not None and reference_age > 2:
                    status, message = 'reference_timeout', 'Flusso RTP assente da oltre 2 secondi'
                elif capture_age is not None and capture_age > 1:
                    status, message = 'capture_interrupted', 'Ritorno ADC interrotto: verificare acquisizione Scarlett'
            fault = status in ('reference_timeout', 'capture_interrupted')
            with self.lock:
                self.result = {'status': status, 'message': message, 'confirmed': fault,
                               'reference_age_seconds': reference_age, 'capture_age_seconds': capture_age}
            if fault and self.pending is None and now-self.last_event >= 30:
                self.trigger_buffers = self.last_buffers
                self.pending = {'due': now+2, 'triggered_at': time.time(),
                                'analysis': dict(self.result), 'rtp_at_trigger': stats,
                                'context': context, 'post_capture_unavailable': True}
                self.last_event = now
            self.candidate = None; self.hits = 0
            return
        self.last_buffers = buffers
        reference, observed, coverage, ref_end, capture_end, stats, context, context_age = buffers
        # One analysis per second, with 250 ms overlap and only four seconds
        # filtered for DSP. Keep the full history for WAV evidence.
        fresh_capture=capture_end != self.last_analyzed_capture
        if not fresh_capture and context == self.last_analyzed_context: return
        self.last_analyzed_capture=capture_end
        self.last_analyzed_context=context
        capture_rate=self.buffer_clock['capture_rate'];reference_rate=self.buffer_clock['reference_rate']
        window=max(1.25,self.analysis_interval+.25)
        tail=observed[-int(window*capture_rate):]
        analysis_reference=reference[-int(max(4,window+1.5)*reference_rate):]
        mapping_due=self.channel_map is None or now-self.last_mapping_check>=30
        result=compare(analysis_reference,tail,reference_rate,capture_rate,self.channel_map,mapping_due)
        if mapping_due: self.last_mapping_check=now
        if 'channel_map' in result: self.channel_map=result['channel_map']
        result.setdefault('stage_cpu_ms',{})['buffers']=round(buffers_cpu,2)
        result['analysis_capture_start_monotonic']=capture_end-len(tail)/capture_rate
        result['analysis_reference_start_monotonic']=ref_end-len(analysis_reference)/reference_rate
        result['capture_timing']=dict(self.capture_timing)
        result['clock_diagnostics']=dict(self.buffer_clock)
        result['capture_health']=dict(self.capture_health)
        result['workload']=dict(self.workload)
        result['analysis_window_seconds']=round(len(tail)/capture_rate,3)
        result['updated_at'] = time.time()
        result['reference_coverage'] = round(float(coverage.mean()), 5)
        result['context_age_seconds'] = round(context_age, 1)
        result['delay_basis'] = 'software-fitted RTP/ADC sample timelines; includes delivery-buffer uncertainty'
        usable = [c for c in result.get('channels', []) if 'offset' in c]
        delays = []
        for channel in usable:
            delay = capture_end-len(tail)/capture_rate-(ref_end-len(analysis_reference)/reference_rate+channel['offset']/ANALYSIS_RATE)
            if result['status']=='matched' and abs(channel['correlation']) >= .85 and not channel['ambiguous'] and -0.1 <= delay <= 3:
                delays.append(delay*1000)
        if delays:
            delay = sum(delays)/len(delays)
            result['estimated_delay_ms'] = round(delay, 2)
            if self.previous_delay is not None:
                result['delay_change_ms'] = round(delay-self.previous_delay, 2)
            self.previous_delay = delay; self.previous_delay_time = now
            self.delay_history.append((now, delay))
            if len(self.delay_history) >= 20 and now-self.delay_history[0][0] >= 30:
                history = np.array(self.delay_history)
                x = history[:, 0]-history[0, 0]
                slope, intercept = np.polyfit(x, history[:, 1], 1)
                scatter = float(np.std(history[:, 1]-(slope*x+intercept)))
                if scatter < 2:
                    result['delay_trend_ms_per_minute'] = round(float(slope)*60, 3)
                    result['clock_drift_estimate_ppm'] = round(float(slope)*1000, 1)
                    result['drift_note'] = 'Trend includes network/capture buffering; not a direct hardware clock measurement'
        # Do not attribute analog defects where the reference itself has holes.
        if result.get('reference_coverage', 0) < .995:
            result.update(status='reference_gaps', message='Buchi nel riferimento RTP: confronto analogico non conclusivo')
        if context_age > 12:
            result.update(status='context_stale', message='Stato mute/volume non recente: diagnosi sospesa')
        elif context.get('muted') or not context.get('reference_meter', {}).get('available'):
            result.update(status='suspended', message='Confronto sospeso: mute o riferimento post-fader non disponibile')
        elif all(c.get('rms_dbfs', -96) < -55 for c in context['reference_meter'].get('channels', [])):
            result.update(status='suspended', message='Confronto sospeso: livello di uscita atteso insufficiente')
        if result['status'] == 'insufficient_signal' and not result.get('full_band_return_active') and context_age <= 12 and not context.get('muted'):
            levels = context.get('reference_meter', {})
            # A 5-second meter can remain active after a legitimate pause. Check
            # the actual aligned reference before calling a silent return faulty.
            if self.previous_delay is not None and self.previous_delay_time is not None and now-self.previous_delay_time < 10:
                start = int((capture_end-len(tail)/capture_rate-self.previous_delay/1000-
                             (ref_end-len(reference)/reference_rate))*reference_rate)
                expected = reference[max(0,start):max(0,start)+int(len(tail)/capture_rate*reference_rate)]
            else:
                expected = reference[-3*44100:]
            blocks = len(expected)//441
            consistently_active = False
            if blocks >= 50:
                power = np.mean(expected[:blocks*441].reshape(blocks,441,-1)**2, axis=1)
                consistently_active = bool(np.any(np.mean(power > 10**(-45/10), axis=0) > .9))
            if consistently_active and levels.get('available') and any(c.get('rms_dbfs', -96) > -45 for c in levels.get('channels', [])):
                result.update(status='missing_return', message='Ritorno silenzioso con riferimento di uscita attivo')
        if result['status'] == 'matched' and abs(result.get('delay_change_ms', 0)) > 20:
            result['timing_observation']='capture_delay_change'
            result['timing_message']='Variazione della stima RTP → ADC oltre 20 ms; non prova di un dropout audio'
        if abs(self.buffer_clock['adc'].get('residual_ms') or 0)>20:
            result['timing_observation']='capture_delivery_jitter'
            result['timing_message']='Consegna PCM irregolare rispetto al clock stimato; non prova di un difetto in uscita'
        adc_clock=self.buffer_clock['adc']
        if adc_clock['delivery_steps'] and now-(adc_clock.get('last_step_monotonic') or -1e9)<5:
            result['timing_observation']='capture_delivery_step'
            result['timing_message']='Salto persistente nella consegna ADC: nuova calibrazione, causa non attribuita alla riproduzione'
        capture_error_age=now-self.capture_health.get('last_xrun_monotonic',-1e9)
        if capture_error_age<5:
            result['observed_audio_status']=result['status']
            result.update(status='capture_unreliable',message='Overrun/xrun della cattura spia: confronto di uscita non conclusivo')
            result['timing_observation']='capture_xrun'
            result['timing_message']='Errore ADC acquisito nello stderr arecord; verificare carico e cattura'
        clocks=result['clock_diagnostics']
        adc=clocks['adc'];rtp_clock=clocks['rtp']
        result['timing_confidence']='calibrated_estimate' if adc['fit_valid'] and rtp_clock['fit_valid'] and abs(adc['residual_ms'] or 0)<20 and abs(rtp_clock['residual_ms'] or 0)<20 else 'uncalibrated'
        if not result.get('timing_observation') and adc['fit_valid'] and abs(adc.get('drift_ppm') or 0)>100:
            result['timing_observation']='clock_drift_compensated'
            result['timing_message']='Deriva del contatore ADC stimata e compensata; lo scarto cumulativo non è ritardo di uscita'
        result['confidence']='high' if result['status']=='matched' and usable and all(abs(c['correlation'])>=.85 and not c['ambiguous'] for c in usable) else 'limited'
        fault = result['status'] in ('dropout', 'mismatch', 'reference_gaps', 'missing_return', 'missing_channel', 'return_clipping')
        if fault and self.candidate == result['status']:
            self.hits += int(fresh_capture)
        else:
            self.candidate = result['status'] if fault else None
            self.hits = 1 if fault else 0
        result['confirmed'] = fault and (self.hits >= 2 or result['status'] == 'dropout')
        if result['confirmed'] and now-self.last_event >= 30 and self.pending is None:
            self.trigger_buffers = buffers
            self.pending = {'due': now+2, 'triggered_at': time.time(), 'analysis': dict(result),
                            'rtp_at_trigger': stats, 'context': context,
                            'trigger_reference_end_monotonic': ref_end,
                            'trigger_capture_end_monotonic': capture_end,
                            'trigger_reference_duration_seconds': len(reference)/44100,
                            'trigger_capture_duration_seconds': len(observed)/16000,
                            'stream': self.stream}
            if result['status'] == 'reference_gaps':
                self.pending['interpretation'] = 'Riferimento digitale incompleto: verificare trasporto e acquisizione pacchetti'
            elif context.get('roc_error') or context.get('roc_warning'):
                self.pending['interpretation'] = 'Anomalia analogica con messaggi Roc recenti: verificare le coincidenze nel journal'
            else:
                self.pending['interpretation'] = 'Anomalia nel ritorno con riferimento disponibile; causa digitale non ancora isolata'
            self.last_event = now
        with self.lock:
            self.result = result
        if self.pending and now >= self.pending['due']:
            if self.pending.get('stream', self.stream) != self.stream:
                self.pending['stream_changed_after_trigger'] = True
                self.save_event(self.trigger_buffers)
            else:
                self.save_event(buffers)

    def save_event(self, buffers):
        event = self.pending
        _, _, _, _, _, stats, context, _ = buffers
        if self.trigger_buffers is not None:
            buffers = self.trigger_buffers
            event['wav_snapshot'] = 'trigger'
        reference, observed, coverage, _, _, _, _, _ = buffers
        self.pending = None
        self.trigger_buffers = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            name = 'event-' + str(time.time_ns())
            folder = self.directory / name
            folder.mkdir(mode=0o700)
            for filename, data, rate in (('reference.wav', reference, 44100), ('return.wav', observed, 16000)):
                with wave.open(str(folder / filename), 'wb') as wav:
                    wav.setnchannels(data.shape[1]); wav.setsampwidth(2); wav.setframerate(rate)
                    wav.writeframes(np.clip(data*32768, -32768, 32767).astype('<i2').tobytes())
            event.pop('due', None)
            event.update(rtp_after=stats, context_after=context, reference_coverage=float(coverage.mean()),
                         reference_end_monotonic=buffers[3], capture_end_monotonic=buffers[4],
                         saved_at=time.time(),
                         reference_duration_seconds=len(reference)/44100,
                         capture_duration_seconds=len(observed)/16000,
                         note='Independent WAV timelines; channel offsets are relative to analysis_reference_start_monotonic '
                              '+ offset/analysis_rate, not the WAV start. RTP holes are zero-filled. Sequence gaps are provisional, not final packet loss.')
            try:
                journal = subprocess.run(['journalctl', '-u', 'roc-museum.service',
                                          '--since=-15sec', '-n', '200', '--no-pager', '-o', 'short-iso-precise'],
                                         capture_output=True, text=True, timeout=4, check=False)
                event['roc_journal'] = journal.stdout[-64000:]
                event['journal_error'] = journal.stderr[-2000:] if journal.returncode else ''
            except (OSError, subprocess.SubprocessError) as error:
                event['journal_error'] = str(error)
            (folder / 'event.json').write_text(json.dumps(event, ensure_ascii=False, indent=2))
            # Only directories produced by this module are eligible for retention.
            folders = sorted(p for p in self.directory.glob('event-*') if p.is_dir() and not p.is_symlink() and p.name[6:].isdigit())
            for old in folders[:-20]:
                for filename in ('reference.wav', 'return.wav', 'event.json'):
                    (old / filename).unlink(missing_ok=True)
                try:
                    old.rmdir()
                except OSError:
                    pass
            with self.lock:
                self.events.append({'path': str(folder), 'triggered_at': event['triggered_at'],
                                    'status': event['analysis']['status']})
                self.storage_error = ''
        except OSError as error:
            with self.lock:
                self.storage_error = str(error)

    def loop(self, stop_event=None):
        stop_event = stop_event or threading.Event()
        previous_start=None
        cpu_average=None
        while not stop_event.is_set():
            started=time.perf_counter()
            cpu_started=time.thread_time()
            try:
                self.analyze()
            except Exception as error:
                with self.lock:
                    self.result = {'status': 'error', 'message': 'Diagnostica: '+str(error)}
            elapsed=time.perf_counter()-started
            cpu=time.thread_time()-cpu_started
            period=1.0 if previous_start is None else max(.001,started-previous_start)
            cpu_average=cpu if cpu_average is None else .8*cpu_average+.2*cpu
            self.analysis_interval=max(1.0,min(2.5,cpu_average/.15))
            with self.lock:
                self.workload={'stage_cpu_ms':dict(self.result.get('stage_cpu_ms',{})),
                               'analysis_target_period_seconds':round(self.analysis_interval,3),
                               'analysis_gap_seconds':round(max(0,period-self.result.get('analysis_window_seconds',1.25)),3),
                               'analysis_wall_ms':round(elapsed*1000,2),
                               'analysis_cpu_ms':round(cpu*1000,2),
                               'analysis_core_percent':round(cpu/period*100,1),
                               'analysis_period_seconds':round(period,2),
                               'over_budget':cpu/period>.20 or elapsed/period>.5,
                               'sampled_at':time.time(),
                               'scope':'analysis worker only; excludes capture and RTP processing'}
            previous_start=started
            stop_event.wait(max(.05,self.analysis_interval-elapsed))
PY_RX_DIAGNOSTICS
    chmod 0644 /usr/local/lib/roc-museum/rx_diagnostics.py
    cat > /usr/local/lib/roc-museum/studio.py <<'PY_STUDIO'
#!/usr/bin/env python3
"""TX studio: one Roc sender, durable schedule, constrained USB explorer."""
import datetime as dt
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from zoneinfo import ZoneInfo

AUDIO_EXTENSIONS={'.wav','.mp3','.flac','.ogg','.m4a','.aac'}
MAX_FILE=512*1024*1024
RESERVE=256*1024*1024


def run(argv, timeout=20):
    return subprocess.run(argv,check=True,capture_output=True,text=True,timeout=timeout)


def audio_name(name):
    if not isinstance(name,str) or not name or name.startswith('.') or len(name.encode())>200 or any(c in name for c in '/\\\0') or any(ord(c)<32 for c in name) or Path(name).suffix.lower() not in AUDIO_EXTENSIONS:
        raise ValueError('Nome audio non valido')
    return name


def confined_open(root, relative='', directory=False):
    """Walk with dir_fd and O_NOFOLLOW: symlinks can never escape the mount."""
    if not isinstance(relative,str) or relative.startswith('/') or any(p in ('.','..','') for p in relative.split('/') if relative):
        raise ValueError('Percorso USB non valido')
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        parts=relative.split('/') if relative else []
        for index,part in enumerate(parts):
            flags=os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK
            if index<len(parts)-1 or directory: flags|=os.O_DIRECTORY
            child=os.open(part,flags,dir_fd=fd)
            os.close(fd);fd=child
        mode=os.fstat(fd).st_mode
        if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
            raise ValueError('Tipo di file non consentito')
        return fd
    except BaseException:
        os.close(fd);raise


class Studio:
    def __init__(self,config,media='/var/lib/roc-museum/media',state='/var/lib/roc-museum/studio',usb_root='/run/roc-museum-usb',copy_lock=None,audio_factory=None,bus_marker="/run/roc-museum-bus"):
        self.config=config
        self.media=Path(media);self.state=Path(state);self.usb_root=Path(usb_root)
        self.media.mkdir(parents=True,exist_ok=True,mode=0o750)
        self.state.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.lock=threading.RLock();self.copy_lock=copy_lock or threading.Lock()
        self.db=sqlite3.connect(self.state/'calendar.sqlite',check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS schedules(id TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS runs(event TEXT, occurrence TEXT, time REAL, state TEXT, message TEXT, PRIMARY KEY(event,occurrence));
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);''')
        self.db.commit()
        self.encoder=None;self.sender=None;self.error_log=None
        self.track=None;self.duration=0;self.position=0;self.started=0;self.status='live';self.loop=False
        self.origin='mixer';self.error='';self.queue=[];self.manual_hold=False
        self.shutdown=threading.Event();self.metadata={};self.thread=None
        self.bus=None;self.audio_factory=audio_factory;self.plan=None;self.bus_marker=Path(bus_marker)
        self.resume_saved=0.;self.restore_thread=None;self.playlist_active=False

    def start(self):
        try:
            self._ensure_audio()
        except Exception as error:
            self.error=str(error)
            try: self._live(clear_resume=False)
            except Exception as fallback:
                self.error=str(error)+' · fallback live: '+str(fallback)
        self.thread=threading.Thread(target=self._worker,daemon=True);self.thread.start()
        # Never block dashboard startup while probing/decoding the saved track.
        self.restore_thread=threading.Thread(target=self._restore_after_start,daemon=True)
        self.restore_thread.start()

    def _restore_after_start(self):
        try:
            with self.lock:
                if self.shutdown.is_set(): return
                self._restore_playback_resume()
        except Exception as error:
            with self.lock:
                self.error='Ripristino player non riuscito: '+str(error)

    def close(self):
        self.shutdown.set()
        if self.thread: self.thread.join(timeout=5)
        if self.restore_thread and self.restore_thread is not threading.current_thread():
            self.restore_thread.join(timeout=5)
        with self.lock:
            if self.status in ('playing','paused') and self.origin=='manual':
                self._save_playback_resume(force=True)
            self._terminate()
            if self.bus: self.bus.close();self.bus=None
            self.bus_marker.unlink(missing_ok=True)
            self.sender=None;self.db.close()

    def ducking(self):
        return self._setting('ducking','{"enabled":true,"threshold_db":-36,"reduction_db":-18}')

    def _ensure_audio(self):
        if self.bus and self.bus.snapshot()['active']: return
        if self.bus: self.bus.close();self.bus=None
        run(['systemctl','stop','roc-museum.service'])
        try:
            if self.audio_factory is None:
                spec=importlib.util.spec_from_file_location('museum_audio_bus',Path(__file__).with_name('audio_bus.py'))
                module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
                factory=module.AudioBus
            else: factory=self.audio_factory
            # The audio unit stays active as a coordinator; on monitor death it
            # automatically resumes the original ALSA microphone path.
            fd=os.open(self.bus_marker,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as marker: marker.write(str(os.getpid())+'\n')
            bus=factory(self.config);bus.configure(self.ducking());bus.set_volume(self._setting("music_volume","100"),self._setting("music_muted"));bus.start()
            self.bus=bus;self.sender=bus.sender
            run(['systemctl','start','roc-museum.service'])
        except Exception:
            if self.bus: self.bus.close();self.bus=None
            self.sender=None;self.bus_marker.unlink(missing_ok=True)
            run(['systemctl','start','roc-museum.service']);raise

    def _setting(self,key,default='false'):
        row=self.db.execute('SELECT value FROM settings WHERE key=?',(key,)).fetchone()
        return json.loads(row[0]) if row else json.loads(default)

    def _store_setting(self,key,value):
        self.db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(key,json.dumps(value)));self.db.commit()

    def _clear_playback_resume(self):
        self._store_setting('resume_playback',None)
        self.resume_saved=0.

    def _save_playback_resume(self,force=False):
        now=time.time()
        if not force and now-self.resume_saved<2:
            return
        if self.status not in ('playing','paused') or self.origin!='manual' or not self.track:
            return
        state={'status':self.status,'track':self.track,'position':round(self._position(),2),
               'playlist_active':self.playlist_active,'loop':bool(self.loop),'manual_hold':bool(self.manual_hold),'saved_at':now}
        self._store_setting('resume_playback',state)
        self.resume_saved=now

    def _restore_playback_resume(self):
        state=self._setting('resume_playback','null')
        if not isinstance(state,dict):
            return False
        try:
            status=state.get('status')
            track=audio_name(state.get('track'))
            position=state.get('position')
            loop=state.get('loop')
            if status not in ('playing','paused') or type(loop) is not bool:
                raise ValueError('Stato player salvato non valido')
            if type(position) not in (int,float) or isinstance(position,bool) or not math.isfinite(position) or position<0:
                raise ValueError('Posizione player salvata non valida')
            info=self.info(track)
            if position>=info['duration']:
                if loop:
                    position=0.
                else:
                    self._clear_playback_resume()
                    return False
            self.playlist_active=bool(state.get('playlist_active',False))
            self._play(track,position,origin='manual',loop=loop,persist=False)
            self.manual_hold=bool(state.get('manual_hold',True))
            if status=='paused':
                self.bus.pause(True);self.status='paused';self.position=position
            self._save_playback_resume(force=True)
            return True
        except (OSError,ValueError,subprocess.SubprocessError) as error:
            self.error='Ripristino player non riuscito: '+str(error)
            self._clear_playback_resume()
            return False

    def _terminate(self):
        if self.bus: self.bus.detach()
        if self.encoder:
            if self.encoder.poll() is None: self.encoder.terminate()
            try: self.encoder.wait(timeout=3)
            except subprocess.TimeoutExpired: self.encoder.kill();self.encoder.wait(timeout=3)
            if self.encoder.stdout: self.encoder.stdout.close()
        self.encoder=None
        if self.error_log: self.error_log.close();self.error_log=None

    def _live(self,clear_resume=True):
        self._terminate();self.plan=None;self.playlist_active=False
        if not self.bus or not self.bus.snapshot()['active']:
            if self.bus: self.bus.close();self.bus=None
            self.sender=None;self.bus_marker.unlink(missing_ok=True)
            run(['systemctl','start','roc-museum.service'])
        self.status='live';self.origin='mixer';self.position=0;self.track=None;self.duration=0
        if clear_resume: self._clear_playback_resume()

    def delete_media(self,name):
        name=audio_name(name)
        if not self.copy_lock.acquire(blocking=False): raise ValueError('Attendere il completamento della copia')
        try:
            with self.lock:
                if name==self.track or self.plan and name in self.plan['tracks']:
                    raise ValueError('Traccia in uso: fermare prima il player')
                for event in self.events():
                    if name in event.get('tracks',[event['track']]):
                        raise ValueError('Traccia utilizzata dall’evento: '+event['name']+'. Modificare o eliminare prima l’evento.')
                fd=confined_open(self.media,name);os.close(fd)
                (self.media/name).unlink()
                self.metadata={k:v for k,v in self.metadata.items() if k[0]!=name}
                return {'ok':True,'message':'Traccia eliminata','name':name}
        finally: self.copy_lock.release()

    def info(self,name):
        name=audio_name(name);path=self.media/name
        fd=confined_open(self.media,name)
        os.close(fd)
        key=(name,path.stat().st_size,path.stat().st_mtime_ns)
        if key not in self.metadata:
            data=json.loads(run(['ffprobe','-v','error','-protocol_whitelist','file,pipe','-format_whitelist','wav,mp3,flac,ogg,mov,aac','-select_streams','a:0','-show_entries','stream=codec_type:format=duration','-of','json',str(path)]).stdout)
            duration=float(data.get('format',{}).get('duration',0))
            if not data.get('streams') or not math.isfinite(duration) or duration<=0:
                raise ValueError('File senza traccia audio o durata valida')
            self.metadata[key]={'name':name,'duration':round(duration,3),'size':path.stat().st_size}
        return dict(self.metadata[key])

    def library(self):
        result=[]
        for p in sorted(self.media.iterdir()):
            if p.is_file() and not p.is_symlink() and p.suffix.lower() in AUDIO_EXTENSIONS and not p.name.startswith('.'):
                result.append({'name':p.name,'size':p.stat().st_size})
        return result

    def _play(self,name,position=0,origin='manual',loop=False,deadline=None,persist=True):
        info=self.info(name)
        if not isinstance(position,(int,float)) or isinstance(position,bool) or not math.isfinite(position) or not 0<=position<info['duration']:
            raise ValueError('Posizione fuori dalla durata del brano')
        self._ensure_audio();self._terminate()
        try:
            self.error_log=tempfile.TemporaryFile()
            self.encoder=subprocess.Popen(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-protocol_whitelist','file,pipe','-format_whitelist','wav,mp3,flac,ogg,mov,aac','-ss',str(position),'-i',str(self.media/name),'-map','0:a:0','-threads','1','-vn','-ac','2','-ar',self.config.get('SAMPLE_RATE','44100'),'-c:a','pcm_s16le','-f','s16le','pipe:1'],stdout=subprocess.PIPE,stderr=self.error_log,bufsize=0)
            self.bus.attach(self.encoder.stdout,position,deadline)
        except Exception:
            self._live();raise
        self.track=name;self.duration=info['duration'];self.position=position;self.started=time.monotonic()
        self.status='playing';self.origin=origin;self.loop=loop;self.error=''
        if persist and origin=='manual': self._save_playback_resume(force=True)

    def _position(self):
        if self.bus and self.status in ('playing','paused'): return min(self.duration,self.bus.snapshot()['position'])
        return self.position

    def _cancel_plan(self,state='interrupted'):
        if self.plan:
            self._record(self.plan['event'],self.plan['occurrence'],state)
            if self.bus: self.bus.set_deadline(None)
            self.plan=None

    def playlist(self):
        available=[f['name'] for f in self.library()]
        saved=self._setting('playlist_tracks','null')
        return available if saved is None else [name for name in available if name in saved]

    def _advance_playlist(self,step=1):
        names=[f['name'] for f in self.library()];selected=self.playlist()
        if not selected:
            self._live();return
        index=names.index(self.track) if self.track in names else (-1 if step>0 else len(names))
        candidates=[name for name in selected if (names.index(name)-index)*step>0]
        name=(candidates[0] if step>0 else candidates[-1]) if candidates else None
        if name is None and self._setting('playlist_loop'): name=selected[0] if step>0 else selected[-1]
        if name is None: self._live();return
        self._play(name,origin='manual');self._save_playback_resume(force=True)

    def command(self,data):
        with self.lock:
            command=data.get('command')
            if command=='playlist_select':
                names=data.get('tracks')
                available={f['name'] for f in self.library()}
                if not isinstance(names,list) or len(names)>len(available) or any(not isinstance(n,str) or n not in available for n in names) or len(set(names))!=len(names):
                    raise ValueError('Selezione scaletta non valida')
                self._store_setting('playlist_tracks',names)
            elif command=='playlist_loop':
                if type(data.get('enabled')) is not bool: raise ValueError('Loop scaletta non valido')
                self._store_setting('playlist_loop',data['enabled'])
                if data['enabled']:
                    self.loop=False;self._store_setting('track_loop',False)
                self._save_playback_resume(force=True)
            elif command=='playlist_start':
                names=self.playlist()
                if not names: raise ValueError('Selezionare almeno un brano nella scaletta')
                self.info(names[0]);self._cancel_plan('suspended')
                self.playlist_active=True;self.manual_hold=True;self._store_setting('track_loop',False)
                self._play(names[0],origin='manual')
            elif command in ('playlist_next','playlist_previous'):
                if not self.playlist_active: raise ValueError('Scaletta non attiva')
                self._advance_playlist(1 if command=='playlist_next' else -1)
            elif command=='music_volume':
                value=data.get('value')
                if type(value) is not int or not 0<=value<=100: raise ValueError('Volume musica: valore intero tra 0 e 100')
                self._store_setting('music_volume',value)
                if value>0: self._store_setting('music_muted',False)
                if self.bus: self.bus.set_volume(value,self._setting('music_muted'))
            elif command=='music_muted':
                enabled=data.get('enabled')
                if type(enabled) is not bool: raise ValueError('Mute musica non valido')
                self._store_setting('music_muted',enabled)
                if self.bus: self.bus.set_volume(self._setting('music_volume','100'),enabled)
            elif command=='ducking':
                settings={k:data.get(k,v) for k,v in self.ducking().items()}
                if type(settings['enabled']) is not bool: raise ValueError('Ducking non valido')
                for key,low,high in (('threshold_db',-60,-6),('reduction_db',-40,0)):
                    value=settings[key]
                    if type(value) not in (int,float) or not math.isfinite(value) or not low<=value<=high: raise ValueError('Parametro ducking non valido')
                self._store_setting('ducking',settings)
                if self.bus: self.bus.configure(settings)
            elif command=='automation':
                enabled=data.get('enabled')
                if type(enabled) is not bool: raise ValueError('Stato calendario non valido')
                if enabled and self.manual_hold: self._live()
                self._store_setting('enabled',enabled);self.manual_hold=False
                if not enabled:
                    self.queue=[]
                    if self.plan or self.origin.startswith('calendar:'):
                        self._cancel_plan('suspended');self._live()
            elif command=='play':
                # Validate before interrupting an existing programme.
                self.info(data.get('name'))
                self._cancel_plan('suspended')
                self.playlist_active=False
                loop=data.get('loop',self._setting('track_loop')) is True
                self._store_setting('track_loop',loop)
                if loop: self._store_setting('playlist_loop',False)
                self._play(data.get('name'),origin='manual',loop=loop);self.manual_hold=True
            elif command=='pause':
                if self.status!='playing': raise ValueError('Nessuna traccia in riproduzione')
                self.position=self._position();self.bus.pause(True);self.status='paused';self.manual_hold=True
                self._cancel_plan('suspended');self.origin='manual';self._save_playback_resume(force=True)
            elif command=='resume':
                if self.status!='paused': raise ValueError('Nessuna traccia in pausa')
                self.bus.pause(False);self.status='playing';self.origin='manual';self.manual_hold=True
                self._save_playback_resume(force=True)
            elif command=='seek':
                if self.status not in ('playing','paused'): raise ValueError('Nessuna traccia selezionata')
                value=data.get('position');was_paused=self.status=='paused'
                # _play validates position before changing the decoder.
                self._play(self.track,value,'manual',self.loop);self.manual_hold=True
                self._cancel_plan('suspended')
                if was_paused:
                    self.bus.pause(True);self.status='paused';self._save_playback_resume(force=True)
            elif command=='loop':
                if type(data.get('enabled')) is not bool: raise ValueError('Loop non valido')
                self.loop=data['enabled'];self._store_setting('track_loop',self.loop)
                if self.loop:
                    self.playlist_active=False;self._store_setting('playlist_loop',False)
                if self.status in ('playing','paused'):
                    self._cancel_plan('suspended');self.manual_hold=True;self.origin='manual'
                    self._save_playback_resume(force=True)
            elif command=='stop':
                self._cancel_plan('suspended');self._live();self.manual_hold=True
            else: raise ValueError('Comando player non valido')
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            rows=self.db.execute('SELECT event,occurrence,time,state,message FROM runs ORDER BY time DESC LIMIT 30').fetchall()
            return {'playlist_tracks':self.playlist(),'playlist_active':self.playlist_active,'playlist_loop':self._setting('playlist_loop'),'track_loop':self._setting('track_loop'),'status':self.status,'track':self.track,'position':round(self._position(),2),'duration':self.duration,'loop':self.loop,'origin':self.origin,'error':self.error,'automation_enabled':self._setting('enabled'),'manual_hold':self.manual_hold,'queue':[e['name'] for e in self.queue],'timezone':'Europe/Rome','events':self.events(),'next_events':self.next_events(),'sender_running':bool(self.sender and self.sender.poll() is None),'audio_bus':self.bus.snapshot() if self.bus else None,'ducking':self.ducking(),'music_volume':self._setting('music_volume','100'),'music_muted':self._setting('music_muted'),'system_time':dt.datetime.now(ZoneInfo('Europe/Rome')).isoformat(),'plan':{k:v for k,v in self.plan.items() if k!='event'} if self.plan else None,'history':[dict(zip(('event','occurrence','time','state','message'),r)) for r in rows]}

    def events(self):
        with self.lock:
            return [json.loads(row[0]) for row in self.db.execute('SELECT data FROM schedules ORDER BY id')]

    def next_events(self,now=None):
        now=now or dt.datetime.now(dt.timezone.utc)
        zone=ZoneInfo('Europe/Rome');today=now.astimezone(zone).date();result=[]
        for event in self.events():
            if not event['enabled']: continue
            start=dt.datetime.fromisoformat(event['start'])
            day=max(today,start.date())
            for offset in range(8):
                date=day+dt.timedelta(days=offset)
                if event['recurrence']=='once' and date!=start.date(): continue
                if event['recurrence']=='weekly' and date.weekday() not in event['weekdays']: continue
                candidate=dt.datetime.combine(date,start.time(),zone)
                # Nonexistent spring DST times are skipped; ambiguous fall times run once.
                if candidate.astimezone(dt.timezone.utc).astimezone(zone).replace(tzinfo=None)!=candidate.replace(tzinfo=None): continue
                key=candidate.strftime('%Y-%m-%dT%H:%M')
                claimed=self.db.execute('SELECT 1 FROM runs WHERE event=? AND occurrence=?',(event['id'],key)).fetchone()
                if candidate.astimezone(dt.timezone.utc)>=now and not claimed:
                    result.append({'id':event['id'],'name':event['name'],'at':candidate.isoformat()});break
        return sorted(result,key=lambda e:e['at'])[:5]

    def save_event(self,data):
        with self.lock:
            if not isinstance(data,dict): raise ValueError('Evento non valido')
            name=data.get('name','')
            if not isinstance(name,str) or not 1<=len(name.strip())<=100: raise ValueError('Titolo evento obbligatorio (max 100 caratteri)')
            tracks=data.get('tracks',[data.get('track')])
            if not isinstance(tracks,list) or not 1<=len(tracks)<=100: raise ValueError('Scegliere da 1 a 100 tracce nel gruppo')
            tracks=[audio_name(track) for track in tracks]
            for track in tracks: self.info(track)
            track=tracks[0]
            end_time=data.get('end_time','')
            if not isinstance(end_time,str): raise ValueError('Orario di fine non valido')
            if end_time:
                try:
                    end=dt.time.fromisoformat(end_time)
                    if end.tzinfo or end.second or end.microsecond or len(end_time)!=5: raise ValueError()
                except (ValueError,TypeError): raise ValueError('Orario di fine non valido')
            repetitions=data.get('repetitions',1);interval=data.get('interval_seconds',0)
            if type(repetitions) is not int or not 0<=repetitions<=10000: raise ValueError('Passaggi gruppo: da 0 a 10000')
            if repetitions==0 and not end_time: raise ValueError('La ripetizione continua richiede un orario di fine')
            if type(interval) is not int or not 0<=interval<=86400: raise ValueError('Intervallo non valido (0–86400 secondi)')
            try:
                start=dt.datetime.fromisoformat(data.get('start',''))
                if start.tzinfo or start.second or start.microsecond: raise ValueError()
            except (ValueError,TypeError): raise ValueError('Data e ora locali non valide: precisione al minuto')
            recurrence=data.get('recurrence','once');policy=data.get('policy','skip')
            if recurrence not in ('once','daily','weekly') or policy not in ('interrupt','wait','skip'): raise ValueError('Ricorrenza o priorità non valida')
            weekdays=data.get('weekdays',[start.weekday()])
            if not isinstance(weekdays,list) or not weekdays or any(type(day) is not int or not 0<=day<=6 for day in weekdays): raise ValueError('Giorni settimanali non validi')
            enabled=data.get('enabled',True)
            if type(enabled) is not bool: raise ValueError('Abilitazione non valida')
            event_id=data.get('id') or uuid.uuid4().hex
            if not isinstance(event_id,str) or not re_id(event_id): raise ValueError('Identificativo evento non valido')
            if data.get('id') and not self.db.execute('SELECT 1 FROM schedules WHERE id=?',(event_id,)).fetchone(): raise ValueError('Evento non trovato')
            if not data.get('id') and self.db.execute('SELECT count(*) FROM schedules').fetchone()[0]>=200: raise ValueError('Massimo 200 eventi')
            event={'id':event_id,'name':name.strip(),'track':track,'start':start.isoformat(timespec='minutes'),'recurrence':recurrence,'weekdays':sorted(set(weekdays)),'policy':policy,'enabled':enabled,'tracks':tracks,'end_time':end_time,'repetitions':repetitions,'interval_seconds':interval}
            self.db.execute('INSERT OR REPLACE INTO schedules VALUES(?,?)',(event_id,json.dumps(event)));self.db.commit()
            self.queue=[e for e in self.queue if e['id']!=event_id]
            if self.plan and self.plan['event']['id']==event_id:
                self._cancel_plan('interrupted');self._live()
            return event

    def delete_event(self,event_id):
        if not isinstance(event_id,str) or not re_id(event_id): raise ValueError('Identificativo evento non valido')
        with self.lock:
            if self.plan and self.plan['event']['id']==event_id:
                self._cancel_plan('cancelled');self._live()
            self.db.execute('DELETE FROM schedules WHERE id=?',(event_id,));self.db.commit()
            self.queue=[e for e in self.queue if e['id']!=event_id]

    @staticmethod
    def window(event,now):
        if not event.get('end_time'): return None
        zone=ZoneInfo('Europe/Rome');local=now.astimezone(zone);start=dt.datetime.fromisoformat(event['start'])
        for date in (local.date(),local.date()-dt.timedelta(days=1)):
            if date<start.date(): continue
            if event['recurrence']=='once' and date!=start.date(): continue
            if event['recurrence']=='weekly' and date.weekday() not in event['weekdays']: continue
            begin=dt.datetime.combine(date,start.time(),zone)
            if begin.astimezone(dt.timezone.utc).astimezone(zone).replace(tzinfo=None)!=begin.replace(tzinfo=None): continue
            end=dt.datetime.combine(date,dt.time.fromisoformat(event['end_time']),zone)
            if end<=begin: end+=dt.timedelta(days=1)
            if begin.timestamp()<=now.timestamp()<end.timestamp(): return begin,end
        return None

    @staticmethod
    def occurrence(event,now):
        if event.get('end_time'):
            window=Studio.window(event,now)
            return window[0].strftime('%Y-%m-%dT%H:%M') if window else None
        local=now.astimezone(ZoneInfo('Europe/Rome'));start=dt.datetime.fromisoformat(event['start'])
        if local.date()<start.date(): return None
        if event['recurrence']=='once' and local.date()!=start.date(): return None
        if event['recurrence']=='weekly' and local.weekday() not in event['weekdays']: return None
        if (local.hour,local.minute)!=(start.hour,start.minute): return None
        return local.strftime('%Y-%m-%dT%H:%M')

    def _record(self,event,occurrence,state,message=''):
        self.db.execute('INSERT OR REPLACE INTO runs VALUES(?,?,?,?,?)',(event['id'],occurrence,time.time(),state,message));self.db.commit()

    def _fire(self,event,occurrence,now=None):
        now=now or dt.datetime.now(dt.timezone.utc)
        window=self.window(event,now)
        if event.get('end_time') and not window:
            self._record(event,occurrence,'skipped','Fascia terminata');return
        self._cancel_plan()
        plan={'event':event,'event_id':event['id'],'occurrence':occurrence,'tracks':event.get('tracks',[event['track']]),'index':0,'cycle':1,'repetitions':event.get('repetitions',1),'interval_seconds':event.get('interval_seconds',0),'next_at':None,'end_at':window[1].timestamp() if window else None}
        try:
            self._play(plan['tracks'][0],origin='calendar:'+event['id'],deadline=plan['end_at'])
            self.plan=plan
            self.queue=[e for e in self.queue if e['id']!=event['id']]
            self._record(event,occurrence,'started')
        except Exception as error:
            self.error=str(error);self.plan=None;self._record(event,occurrence,'failed',str(error))

    def _next_track(self,now):
        plan=self.plan
        plan['index']+=1
        if plan['index']>=len(plan['tracks']):
            if plan['repetitions'] and plan['cycle']>=plan['repetitions']:
                self._record(plan['event'],plan['occurrence'],'completed');self._live();return
            plan['index']=0;plan['cycle']+=1
            if plan['interval_seconds']:
                self._terminate();self.status='live';self.track=None;self.duration=0;self.position=0
                plan['next_at']=now.timestamp()+plan['interval_seconds'];return
        self._play(plan['tracks'][plan['index']],origin='calendar:'+plan['event_id'],deadline=plan['end_at'])

    def tick(self,now=None):
        with self.lock:
            now=now or dt.datetime.now(dt.timezone.utc)
            if self.bus and not self.bus.snapshot()['active']:
                self.error=self.bus.snapshot()['error'] or 'Bus audio non disponibile'
                self._cancel_plan('failed');self._live()
            if self.plan and self.plan['end_at'] is not None and now.timestamp()>=self.plan['end_at']:
                self._record(self.plan['event'],self.plan['occurrence'],'completed','Fine fascia');self._live()
            if self.plan and self.plan['next_at'] is not None and now.timestamp()>=self.plan['next_at']:
                self.plan['next_at']=None
                try: self._play(self.plan['tracks'][self.plan['index']],origin='calendar:'+self.plan['event_id'],deadline=self.plan['end_at'])
                except (OSError,ValueError,subprocess.SubprocessError) as error:
                    self.error=str(error);self._cancel_plan('failed');self._live()
            if self.status=='playing' and self.bus and self.bus.snapshot()['music_eof'] and self.encoder and self.encoder.poll() is not None:
                if self.encoder.returncode!=0:
                    self.error='Decodifica audio fallita';self._cancel_plan('failed');self._live()
                elif self.plan:
                    try: self._next_track(now)
                    except (OSError,ValueError,subprocess.SubprocessError) as error:
                        self.error=str(error);self._cancel_plan('failed');self._live()
                elif self.playlist_active:
                    try: self._advance_playlist()
                    except (OSError,ValueError,subprocess.SubprocessError) as error:
                        self.error=str(error);self._live()
                elif self.loop: self._play(self.track,origin=self.origin,loop=True)
                else: self._live()
            self._save_playback_resume()
            if not self._setting('enabled'): return
            for event in sorted(self.events(),key=lambda e:(e['start'],e['id'])):
                if not event['enabled']: continue
                occurrence=self.occurrence(event,now)
                if occurrence is None: continue
                row=self.db.execute('SELECT state FROM runs WHERE event=? AND occurrence=?',(event['id'],occurrence)).fetchone()
                busy=self.status in ('playing','paused') or self.plan is not None
                if row:
                    # An active background window can restart after a monitor restart or manual override.
                    if event.get('end_time') and row[0] in ('started','interrupted','suspended') and not busy and not self.manual_hold:
                        self._fire(event,occurrence,now)
                    continue
                if self.manual_hold and event.get('end_time'): continue
                with self.db:
                    cursor=self.db.execute('INSERT OR IGNORE INTO runs VALUES(?,?,?,?,?)',(event['id'],occurrence,time.time(),'claimed',''))
                if not cursor.rowcount: continue
                if self.manual_hold:
                    self._record(event,occurrence,'skipped','Regia manuale attiva');continue
                if busy and event['policy']=='skip': self._record(event,occurrence,'skipped','Player occupato')
                elif busy and event['policy']=='wait':
                    self.queue.append(dict(event,occurrence=occurrence,queued_at=now.timestamp()));self._record(event,occurrence,'waiting')
                else: self._fire(event,occurrence,now)
            for event in list(self.queue):
                expired=now.timestamp()-event['queued_at']>900 or event.get('end_time') and not self.window(event,now)
                if expired:
                    self._record(event,event['occurrence'],'skipped','Attesa scaduta o fascia terminata');self.queue.remove(event)
            if not self.manual_hold and self.status=='live' and not self.plan and self.queue:
                event=self.queue.pop(0);self._fire(event,event['occurrence'],now)
            with self.db: self.db.execute('DELETE FROM runs WHERE time<?',(time.time()-90*86400,))

    def _worker(self):
        while not self.shutdown.is_set():
            try: self.tick()
            except Exception as error:
                with self.lock: self.error=str(error)
            self.shutdown.wait(.1)

    def devices(self):
        tree=json.loads(run(['lsblk','--json','--paths','--output','NAME,PATH,TYPE,TRAN,RM,FSTYPE,LABEL,MOUNTPOINTS']).stdout)
        result=[]
        def walk(node,usb=False):
            usb=usb or node.get('tran')=='usb'
            mounts=[m for m in (node.get('mountpoints') or []) if m]
            if usb and node.get('fstype') in ('vfat','exfat','ntfs','ntfs3','ext4','ext3','ext2','iso9660') and node.get('type') in ('part','disk'):
                path=node.get('path',node['name'])
                allowed=all(m.startswith(('/media/','/run/media/',str(self.usb_root)+'/')) for m in mounts)
                if allowed and path.startswith('/dev/') and Path(path).name.replace('-','').replace('_','').isalnum():
                    result.append({'id':Path(path).name,'device':path,'label':node.get('label') or Path(path).name,'filesystem':node['fstype'],'mount':mounts[0] if mounts else None})
            for child in node.get('children',[]): walk(child,usb)
        def system_disk(node):
            if any(m and not m.startswith(('/media/','/run/media/',str(self.usb_root)+'/')) for m in (node.get('mountpoints') or [])): return True
            return any(system_disk(child) for child in node.get('children',[]))
        for node in tree.get('blockdevices',[]):
            if not system_disk(node): walk(node)
        return result

    def _device(self,device_id):
        matches=[d for d in self.devices() if d['id']==device_id]
        if not matches: raise ValueError('Pennetta non presente o dispositivo non consentito')
        return matches[0]

    def mount(self,device_id):
        with self.lock:
            device=self._device(device_id)
            if device['mount']: return device['mount']
            self.usb_root.mkdir(parents=True,exist_ok=True,mode=0o700)
            target=self.usb_root/device['id'];target.mkdir(exist_ok=True,mode=0o700)
            if target.is_symlink(): raise ValueError('Punto di montaggio non valido')
            run(['mount','-o','ro,nosuid,nodev,noexec','--',device['device'],str(target)])
            return str(target)

    def browse(self,device_id,relative=''):
        with self.lock:
            root=self.mount(device_id);fd=confined_open(root,relative,directory=True)
            try:
                entries=[]
                with os.scandir(fd) as iterator:
                    for entry in iterator:
                        if entry.name.startswith('.') or entry.is_symlink(): continue
                        if len(entries)>=2000: raise ValueError('Cartella troppo grande: organizzare i file in sottocartelle')
                        if entry.is_dir(follow_symlinks=False): entries.append({'name':entry.name,'directory':True})
                        elif entry.is_file(follow_symlinks=False) and Path(entry.name).suffix.lower() in AUDIO_EXTENSIONS:
                            entries.append({'name':entry.name,'directory':False,'size':entry.stat(follow_symlinks=False).st_size})
                return {'device':device_id,'path':relative,'entries':sorted(entries,key=lambda e:(not e['directory'],e['name'].casefold()))}
            finally: os.close(fd)

    def import_usb(self,device_id,relative):
        if not self.copy_lock.acquire(blocking=False): raise ValueError('Un caricamento è già in corso')
        temporary=None;fd=None
        try:
            with self.lock:
                root=self.mount(device_id);fd=confined_open(root,relative)
            name=audio_name(Path(relative).name);size=os.fstat(fd).st_size
            if not 0<size<=MAX_FILE: raise ValueError('Massimo 512 MB per file')
            if shutil.disk_usage(self.media).free<size+RESERVE: raise ValueError('Spazio insufficiente sul TX')
            if (self.media/name).exists(): raise ValueError('Nome già presente in libreria')
            out,temporary=tempfile.mkstemp(prefix='.upload-',dir=self.media)
            with os.fdopen(out,'wb') as target:
                remaining=size
                while remaining:
                    chunk=os.read(fd,min(remaining,1024*1024))
                    if not chunk: raise ValueError('Pennetta rimossa o file incompleto')
                    target.write(chunk);remaining-=len(chunk)
                target.flush();os.fsync(target.fileno())
            os.link(temporary,self.media/name)
            return {'name':name,'size':size}
        finally:
            if fd is not None: os.close(fd)
            if temporary and os.path.exists(temporary): os.unlink(temporary)
            self.copy_lock.release()

    def eject(self,device_id):
        if not self.copy_lock.acquire(blocking=False): raise ValueError('Attendere il completamento del caricamento')
        try:
            with self.lock:
                device=self._device(device_id)
                if device['mount']:
                    if not device['mount'].startswith(str(self.usb_root)+'/'):
                        raise ValueError('Pennetta montata dal sistema: espellerla dal sistema operativo')
                    run(['umount','--',device['mount']])
        finally: self.copy_lock.release()


def re_id(value):
    return len(value)==32 and all(c in '0123456789abcdef' for c in value)
PY_STUDIO
    cat > /usr/local/lib/roc-museum/audio_bus.py <<'PY_AUDIO_BUS'
#!/usr/bin/env python3
"""Continuous stereo PCM bus: microphone always on, music-only ducking, one RTP sender."""
from array import array
from collections import deque
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time


def pcm_samples(data):
    samples=array('h');samples.frombytes(data)
    if sys.byteorder!='little': samples.byteswap()
    return samples


class Ducker:
    def __init__(self,rate=44100):
        self.rate=rate;self.gain=1.;self.limiter=1.;self.hold=0.
        self.enabled=True;self.threshold_db=-36.;self.reduction_db=-18.
        self.input_db=-96.;self.active=False;self.volume=1.;self.volume_target=1.

    def mix(self,music,microphone):
        mic=pcm_samples(microphone);song=pcm_samples(music)
        duration=len(mic)/(2*self.rate)
        rms=math.sqrt(sum(x*x for x in mic)/max(1,len(mic)))/32768
        self.input_db=max(-96.,20*math.log10(max(rms,1e-12)))
        if self.enabled and self.input_db>=self.threshold_db: self.hold=.5
        else: self.hold=max(0.,self.hold-duration)
        self.active=self.enabled and self.hold>0
        target=10**(self.reduction_db/20) if self.active else 1.
        old_volume=self.volume
        self.volume=self.volume_target+(self.volume-self.volume_target)*math.exp(-duration/.015)
        previous=self.gain
        tau=.03 if target<previous else .8
        self.gain=target+(previous-target)*math.exp(-duration/tau)
        # Gain ramp avoids discontinuities; the mic is never multiplied by the duck gain.
        raw=[int(m+(song[i] if i<len(song) else 0)*(previous+(self.gain-previous)*i/max(1,len(mic)-1))*(old_volume+(self.volume-old_volume)*i/max(1,len(mic)-1))) for i,m in enumerate(mic)]
        peak=max((abs(v) for v in raw),default=0)
        limit=min(1.,32760/max(1,peak))
        self.limiter=min(limit,self.limiter+(1-self.limiter)*duration/.2)
        out=array('h',(max(-32768,min(32767,int(v*self.limiter))) for v in raw))
        if sys.byteorder!='little': out.byteswap()
        return out.tobytes()


class AudioBus:
    def __init__(self,config,capture_enabled=True):
        self.config=config;self.rate=int(config.get('SAMPLE_RATE','44100'))
        self.frames=max(1,self.rate//100);self.block_bytes=self.frames*4
        self.lock=threading.RLock();self.stop=threading.Event();self.threads=[]
        self.sender=None;self.capture=None;self.log=None;self.error=''
        self.mic_error='Ingresso microfono in attesa';self.mic_online=False
        self.mic_queue=deque(maxlen=10);self.ducker=Ducker(self.rate)
        self.music=None;self.music_buffer=b'';self.music_eof=False;self.paused=False
        self.position=0.;self.deadline=None;self.deadline_hit=False
        self.capture_enabled=capture_enabled

    def configure(self,settings):
        with self.lock:
            self.ducker.enabled=settings['enabled'];self.ducker.threshold_db=settings['threshold_db'];self.ducker.reduction_db=settings['reduction_db']

    def set_volume(self,percent,muted=False):
        with self.lock: self.ducker.volume_target=0. if muted else percent/100.

    def start(self):
        self.log=tempfile.TemporaryFile()
        try:
            self.sender=subprocess.Popen(['roc-send','-i','file:-','--input-format','wav','-s','rtp://'+self.config.get('MULTICAST_ADDR','239.30.0.1')+':'+self.config.get('RTP_PORT','10001'),'--frame-len='+self.config.get('FRAME_LEN','4ms')],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=self.log,bufsize=0)
            # Unbounded streaming WAV, PCM S16LE stereo. Roc clocks the RTP output.
            self.sender.stdin.write(struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',0xffffffff,b'WAVE',b'fmt ',16,1,2,self.rate,self.rate*4,4,16,b'data',0xffffffff))
            os.set_blocking(self.sender.stdin.fileno(),False)
            self.threads=[threading.Thread(target=self._pump,daemon=True)]
            if self.capture_enabled: self.threads.append(threading.Thread(target=self._capture,daemon=True))
            for thread in self.threads: thread.start()
        except BaseException:
            self.close();raise

    @staticmethod
    def kill(process):
        if process is None: return
        if process.poll() is None: process.terminate()
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired: process.kill();process.wait(timeout=2)
        for pipe in (process.stdin,process.stdout):
            if pipe:
                try: pipe.close()
                except OSError: pass

    def close(self):
        self.stop.set()
        self.kill(self.capture);self.kill(self.sender)
        for thread in self.threads:
            if thread is not threading.current_thread(): thread.join(timeout=4)
        self.capture=None;self.sender=None
        if self.log: self.log.close();self.log=None

    def attach(self,stream,position=0,deadline=None):
        with self.lock:
            os.set_blocking(stream.fileno(),False)
            self.music=stream;self.music_buffer=b'';self.music_eof=False;self.paused=False
            self.position=position;self.deadline=deadline;self.deadline_hit=False

    def detach(self):
        with self.lock:
            self.music=None;self.music_buffer=b'';self.music_eof=False;self.paused=False;self.deadline=None;self.deadline_hit=False

    def set_deadline(self,value):
        with self.lock: self.deadline=value;self.deadline_hit=False

    def pause(self,value):
        with self.lock: self.paused=value

    def snapshot(self):
        with self.lock:
            return {'active':bool(self.sender and self.sender.poll() is None and not self.error),'microphone_online':self.mic_online,'microphone_error':self.mic_error,'microphone_dbfs':round(self.ducker.input_db,1),'ducking_active':self.ducker.active,'music_gain_db':round(20*math.log10(max(self.ducker.gain,1e-12)),1),'position':self.position,'music_eof':self.music_eof,'deadline_hit':self.deadline_hit,'error':self.error}

    def _music_block(self):
        if self.music is None or self.paused: return bytes(self.block_bytes)
        if self.deadline is not None and time.time()>=self.deadline:
            self.deadline_hit=True;return bytes(self.block_bytes)
        while len(self.music_buffer)<self.block_bytes and not self.music_eof:
            try: data=os.read(self.music.fileno(),self.block_bytes-len(self.music_buffer))
            except BlockingIOError: break
            if not data: self.music_eof=True;break
            self.music_buffer+=data
        size=min(len(self.music_buffer),self.block_bytes)//4*4
        data=self.music_buffer[:size];self.music_buffer=self.music_buffer[size:]
        self.position+=size/(4*self.rate)
        return data+bytes(self.block_bytes-size)

    def _pump(self):
        pending=b'';blocked_since=None;next_block=time.monotonic()
        try:
            while not self.stop.is_set():
                if self.sender.poll() is not None: raise OSError('Il trasmettitore Roc si è fermato')
                if not pending:
                    with self.lock:
                        mic=self.mic_queue.popleft() if self.mic_queue else bytes(self.block_bytes)
                        pending=self.ducker.mix(self._music_block(),mic)
                try:
                    count=os.write(self.sender.stdin.fileno(),pending)
                    pending=pending[count:];blocked_since=None
                except BlockingIOError:
                    blocked_since=blocked_since or time.monotonic()
                    if time.monotonic()-blocked_since>1: raise OSError('Trasmissione audio bloccata')
                    self.stop.wait(.002);continue
                if pending: continue
                next_block+=self.frames/self.rate
                if next_block<time.monotonic()-.1: next_block=time.monotonic()
                self.stop.wait(max(0,next_block-time.monotonic()))
        except (OSError,ValueError) as error:
            if not self.stop.is_set(): self.error=str(error)

    def _capture(self):
        while not self.stop.is_set():
            process=None
            try:
                listing=subprocess.run(['arecord','-l'],check=True,capture_output=True,text=True,timeout=4,env={**os.environ,'LC_ALL':'C'}).stdout
                card=next((re.search(r'card (\d+):\s*([^\s\[]+)',line) for line in listing.splitlines() if re.search('scarlett|focusrite',line,re.I)),None)
                if not card: raise OSError('Scarlett non rilevata; riconnessione automatica')
                device='plughw:CARD='+card.group(2)+',DEV=0'
                with tempfile.TemporaryFile() as log:
                    process=subprocess.Popen(['arecord','-q','-D',device,'-t','raw','-f','S16_LE','-r',str(self.rate),'-c','2','--period-time=10000','--buffer-time=80000'],stdout=subprocess.PIPE,stderr=log,bufsize=0)
                    self.capture=process;buffer=b''
                    while not self.stop.is_set():
                        data=process.stdout.read(self.block_bytes-len(buffer))
                        if not data: raise OSError('Ingresso microfono interrotto; riconnessione automatica')
                        buffer+=data
                        if len(buffer)==self.block_bytes:
                            with self.lock:
                                self.mic_queue.append(buffer);self.mic_online=True;self.mic_error=''
                            buffer=b''
            except (OSError,subprocess.SubprocessError) as error:
                with self.lock:
                    self.mic_online=False;self.mic_error=str(error);self.mic_queue.clear()
            finally:
                self.kill(process)
                if self.capture is process: self.capture=None
            self.stop.wait(2)
PY_AUDIO_BUS
    cat > /usr/local/share/roc-museum/studio.html <<'HTML_STUDIO'
<section id="studioTools" class="box" hidden style="margin:18px 0">
<style>
.box button,.box input,.box select{font:inherit;color:#e5e7eb;background:#111827;border:1px solid #6b7280;border-radius:6px;padding:8px;margin:4px;max-width:100%;box-sizing:border-box}.box button{cursor:pointer}.box button:hover{border-color:#60a5fa}.box button:disabled{opacity:.5;cursor:wait}
#studioTools h3{margin-top:28px}#studioTools fieldset{border:1px solid #4b5563;margin:12px 0}#studioTools label{display:inline-block}#studioTools table{width:100%;border-collapse:collapse}#studioTools td,#studioTools th{padding:8px;text-align:left;border-bottom:1px solid #374151}#studioTools .scroll{overflow-x:auto}#studioTools ul,#studioTools ol{padding-left:24px}#studioTools .hint{color:#9ca3af}#studioTools [role=status]{color:#93c5fd;white-space:pre-wrap}.danger{border-color:#f87171!important}.playlist-row{margin:6px 0}

#playerPanel{border:1px solid #56606f;border-radius:10px;margin:18px 0;background:#11151c;overflow:hidden}
#playerPanel>summary{display:flex;align-items:center;gap:12px;cursor:pointer;list-style:none;padding:13px 16px;background:#282e38;user-select:none}
#playerPanel>summary::-webkit-details-marker{display:none}#playerPanel>summary:after{content:'Espandi ▾';margin-left:auto;font-size:12px;color:#b8c1ce;white-space:nowrap}#playerPanel[open]>summary:after{content:'Riduci ▴'}
.vlc-summary-copy{min-width:0;display:flex;flex-direction:column;gap:3px}.vlc-summary-copy small{font-size:12px;color:#aeb7c6;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:60vw}.vlc-mark{color:#ff9a32;font-size:24px}
.vlc-screen{min-height:185px;background:radial-gradient(ellipse at center,#242a32 0,#101318 70%);display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:24px 16px;gap:10px}
.vlc-cone{width:64px;height:76px;filter:drop-shadow(0 7px 8px #0008)}#nowPlaying{font-size:20px;font-weight:650;overflow-wrap:anywhere;margin:0;max-width:100%}#playerState{color:#aeb7c6!important;font-size:13px;margin:0}
.vlc-bottom{background:#252b34;border-top:1px solid #454e5b;padding:10px 14px}.vlc-timeline{display:flex;align-items:center;gap:12px;font-variant-numeric:tabular-nums}.vlc-time{font-family:ui-monospace,monospace;font-size:12px;min-width:47px;text-align:center}
#studioTools input[type=range].vlc-range{padding:0;margin:8px 0;accent-color:#ff9638;border:0;background:transparent;min-width:0;cursor:pointer}#playerSeek{width:100%;flex:1;height:20px}
.vlc-toolbar{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-top:5px}.vlc-transport,.vlc-options,.vlc-volume{display:flex;align-items:center;gap:3px}
#studioTools .vlc-button{margin:2px;padding:0;display:inline-flex;align-items:center;justify-content:center;width:36px;height:36px;border:1px solid #647082;background:linear-gradient(#3e4755,#29313d);color:#f5f7fb;font-size:17px;border-radius:5px;flex-shrink:0}
#studioTools .vlc-button:hover{background:#465568;border-color:#ffad63}#studioTools .vlc-button[aria-pressed=true]{color:#ffb36e;border-color:#ff9638;background:#57391f}#studioTools .vlc-play{width:48px;height:44px;font-size:22px;color:#191b20;background:linear-gradient(#ffb969,#f18a2e);border-color:#ffb46d}
.vlc-volume{margin-left:auto}.vlc-volume input{width:105px}.vlc-volume output{font-size:12px;font-variant-numeric:tabular-nums;min-width:38px}.vlc-statusbar{display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px;padding-top:9px;margin-top:8px;border-top:1px solid #414957;font-size:12px;color:#b8c1ce}
#groupState{margin:0}.vlc-library{border-top:1px solid #454e5b;background:#191f28;padding:12px 14px}.vlc-library[hidden]{display:none}.vlc-library-heading{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap}.vlc-library-heading h4{margin:4px 0}.vlc-library-heading input{width:230px;margin:0!important}
#studioTools #library{list-style:none;padding:0;margin:10px 0;max-height:270px;overflow:auto;border:1px solid #3f4b5b;border-radius:5px}#library li{display:flex;align-items:center;gap:9px;padding:4px 8px;border-bottom:1px solid #303b49}#library li:last-child{border:0}#library li.selected{background:#354454;box-shadow:inset 3px 0 #ff9638}#library li.playing .vlc-track:before{content:'▶ ';color:#ffb36e}#library li[hidden]{display:none}
#studioTools .vlc-track{flex:1;text-align:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;border:0;background:transparent;margin:0;padding:8px 2px;min-width:0}#library .vlc-file-size{font-size:12px;color:#aeb7c6;white-space:nowrap}#studioTools .vlc-delete{background:transparent;border:0;color:#bac3d1;margin:0;padding:5px;font-size:18px}#studioTools .vlc-delete:hover{color:#fca5a5}
.vlc-precise{font-size:12px;color:#b8c1ce;margin-top:10px}.vlc-precise summary{cursor:pointer}.vlc-notice{font-size:12px;color:#94a3b8;margin:10px 0 0}#playerMessage{color:#fbbf24;min-height:18px;margin:7px 0 0;font-size:13px}
@media(max-width:540px){.vlc-screen{min-height:150px}.vlc-toolbar{gap:8px}.vlc-transport{gap:0}.vlc-volume{width:100%;justify-content:flex-end}.vlc-library-heading input{width:100%}.vlc-summary-copy small{max-width:48vw}.vlc-file-size{display:none}.vlc-statusbar{font-size:11px}}
#studioTools h3{margin-top:28px}#studioTools .studioPanel{border:1px solid #374151;border-radius:10px;padding:16px;margin:18px 0;background:#18212f}#studioTools .studioPanel>h3{margin-top:0}#studioTools .scheduledPanel{border:1px solid #4b5563;border-radius:10px;margin:18px 0;background:#18212f}#studioTools .scheduledPanel>summary{cursor:pointer;list-style:none;padding:16px;font-size:1.12rem;font-weight:700;display:flex;justify-content:space-between;align-items:center;gap:12px}#studioTools .scheduledPanel>summary::-webkit-details-marker{display:none}#studioTools .scheduledPanel>summary:after{content:'▾';color:#93c5fd;transition:transform .15s ease}#studioTools .scheduledPanel[open]>summary:after{transform:rotate(180deg)}#studioTools .scheduledBody{border-top:1px solid #374151;padding:0 16px 16px}#studioTools .scheduledMeta{font-size:.85rem;font-weight:400;color:#9ca3af;margin-left:auto}#studioTools fieldset{border:1px solid #4b5563;margin:12px 0}#studioTools label{display:inline-block}#studioTools table{width:100%;border-collapse:collapse}#studioTools td,#studioTools th{padding:8px;text-align:left;border-bottom:1px solid #374151}#studioTools .scroll{overflow-x:auto}#studioTools ul,#studioTools ol{padding-left:24px}#studioTools .hint{color:#9ca3af}#studioTools [role=status]{color:#93c5fd;white-space:pre-wrap}.danger{border-color:#f87171!important}.playlist-row{margin:6px 0}

.vlc-options{flex-wrap:wrap}.vlc-options #repeatToggle,.vlc-options #playlistLoop{width:auto;padding:8px 12px;font-weight:700}.playlist-check{width:20px;height:20px;flex-shrink:0;accent-color:#ff9e36}

/* Navigazione principale della regia: separa uso quotidiano, calendario e manutenzione. */
.regia-tabs{display:flex;gap:8px;flex-wrap:wrap;margin:18px 0;border-bottom:1px solid #4b5563;padding-bottom:8px}
#studioTools .regia-tab{margin:0;padding:10px 18px;border-radius:8px 8px 0 0;background:#111827;border:1px solid #4b5563;font-weight:750}
#studioTools .regia-tab[aria-selected=true]{background:#1d4ed8;border-color:#60a5fa;color:#eff6ff}
.regia-tab-panel{min-width:0}.regia-tab-panel[hidden]{display:none!important}
.regia-section-title{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
#rxAudioHost{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px;margin-top:12px}
#systemDashboardHost{margin-top:16px}
@media(max-width:600px){.regia-tabs{display:grid;grid-template-columns:repeat(3,1fr)}#studioTools .regia-tab{padding:9px 6px;font-size:13px}}
</style>
<h2>Regia audio TX</h2>
<p class="hint">Un solo programma per tutti gli RX. Il microfono degli annunci rimane sempre udibile, anche durante musica, pausa e intervalli.</p>
<nav class="regia-tabs" role="tablist" aria-label="Sezioni regia">
<button type="button" class="regia-tab" id="tabPlayer" role="tab" aria-selected="true" aria-controls="regiaPlayer" data-regia-tab="player">Player</button>
<button type="button" class="regia-tab" id="tabEvents" role="tab" aria-selected="false" aria-controls="regiaEvents" data-regia-tab="events">Eventi</button>
<button type="button" class="regia-tab" id="tabSystem" role="tab" aria-selected="false" aria-controls="regiaSystem" data-regia-tab="system">Sistema</button>
</nav>
<section id="regiaPlayer" class="regia-tab-panel" role="tabpanel" aria-labelledby="tabPlayer">
<details id="playerPanel" open>
<summary><span class="vlc-mark" aria-hidden="true">▲</span><span class="vlc-summary-copy"><strong>Lettore multimediale</strong><small id="playerSummary">Nessuna traccia in riproduzione</small></span></summary>
<div id="vlcPlayer" tabindex="0" aria-label="Lettore audio TX">
<div class="vlc-screen">
<svg class="vlc-cone" viewBox="0 0 80 100" aria-hidden="true"><path fill="#ef8c28" d="M35 5h10l22 76H13z"/><path fill="#f8f5e8" d="M31 20h18l4 14H27zm-9 30h36l5 16H17z"/><path fill="#e67c1c" d="M12 81h56l9 11H3z"/><path fill="#ffac48" d="M13 81h54l5 5H8z"/></svg>
<p id="nowPlaying">Nessuna traccia in riproduzione</p><p id="playerState" aria-live="polite">Collegamento al TX…</p>
</div>
<div class="vlc-bottom">
<div class="vlc-timeline"><span id="elapsedTime" class="vlc-time">00:00</span><input id="playerSeek" class="vlc-range" type="range" min="0" max="1" step="0.1" value="0" disabled aria-label="Posizione riproduzione"><span id="totalTime" class="vlc-time">00:00</span></div>
<div class="vlc-toolbar">
<div class="vlc-transport">
<button type="button" id="playerToggle" class="vlc-button vlc-play" aria-label="Riproduci" title="Riproduci / pausa (Spazio)">▶</button>
<button type="button" data-player="stop" class="vlc-button" aria-label="Ferma musica" title="Ferma la musica; il microfono rimane attivo">■</button>
<button type="button" id="playerPrevious" class="vlc-button" aria-label="Traccia precedente" title="Traccia precedente / ricomincia">⏮</button>
<button type="button" id="playerBack" class="vlc-button" aria-label="Indietro 10 secondi" title="Indietro 10 secondi">↶</button>
<button type="button" id="playerForward" class="vlc-button" aria-label="Avanti 10 secondi" title="Avanti 10 secondi">↷</button>
<button type="button" id="playerNext" class="vlc-button" aria-label="Traccia successiva" title="Riproduci traccia successiva">⏭</button>
</div>
<div class="vlc-options"><button type="button" id="playlistToggle" class="vlc-button" aria-label="Mostra o nascondi playlist" aria-pressed="true" title="Playlist">☷</button><button type="button" id="repeatToggle" class="vlc-button" aria-label="Ripeti traccia" aria-pressed="false" title="Ripeti la traccia corrente">↻ Loop brano: OFF</button><button type="button" id="playlistLoop" class="vlc-button" aria-pressed="false">↻ Loop scaletta: OFF</button><input type="checkbox" id="playerLoop" hidden></div>
<div class="vlc-volume"><button type="button" id="musicMute" class="vlc-button" aria-label="Silenzia musica" aria-pressed="false" title="Silenzia solo la musica">◖))</button><input id="musicVolume" class="vlc-range" type="range" min="0" max="100" step="1" value="100" aria-label="Volume musica"><output id="musicVolumeLabel" for="musicVolume">100%</output></div>
</div>
<div class="vlc-statusbar"><span id="playerSource">TX · solo microfono</span><span id="groupState"></span><span id="playlistCount">0 tracce</span></div>
<p id="playerMessage" role="status"></p>
<details class="vlc-precise"><summary>Vai a un tempo preciso</summary><form id="seekForm"><label>Posizione (secondi) <input id="seekPosition" type="number" min="0" step="0.1" required></label><button>Vai</button><span id="positionText"></span></form></details>
</div>
<div id="playerPlaylist" class="vlc-library"><div class="vlc-library-heading"><h4>Playlist · libreria TX</h4><input id="playlistSearch" type="search" placeholder="Cerca una traccia…" aria-label="Cerca nella playlist"></div><select id="trackSelect" hidden aria-label="Traccia selezionata"></select><button type="button" id="playlistStart">▶ Avvia scaletta</button><p id="playlistStatus" role="status"></p><div id="playlistImport"></div><div id="playlistHost"></div><p class="vlc-notice">Spunta i brani da includere nella scaletta, in ordine di libreria. Un doppio clic avvia un brano singolo e interrompe la scaletta; per ripartire usa Avvia scaletta. Volume e mute agiscono solo sulla musica; gli annunci rimangono udibili.</p></div>
</div></details>
<h3>Annunci dal microfono · ducking</h3>
<p id="microphoneState" role="status"></p>
<form id="duckingForm"><label><input name="enabled" type="checkbox" checked> Abbassa automaticamente la musica durante gli annunci</label>
<label>Soglia voce (dBFS) <input name="threshold_db" type="number" min="-60" max="-6" step="1" value="-36" required></label>
<label>Attenuazione musica (dB) <input name="reduction_db" type="number" min="-40" max="0" step="1" value="-18" required></label><button>Applica ducking</button></form>
<p class="hint">Il microfono non viene attenuato dal ducking. Se il rumore di fondo fa abbassare la musica, alza la soglia (per esempio da −36 a −30 dBFS). Il volume della musica torna gradualmente normale dopo l’annuncio.</p>
<section class="studioPanel" aria-labelledby="audioMonitorTitle">
<div class="regia-section-title"><h3 id="audioMonitorTitle">Monitor audio TX e RX</h3><span class="hint">Meter in tempo reale · volume e mute RX</span></div>
<div id="rxAudioHost"><p class="hint">Caricamento stato audio…</p></div>
</section>
</section>
<section id="regiaEvents" class="regia-tab-panel" role="tabpanel" aria-labelledby="tabEvents" hidden>
<details id="scheduledEventsPanel" class="scheduledPanel" open>
<summary><span>Eventi programmati</span><span id="scheduledEventsMeta" class="scheduledMeta">caricamento…</span></summary>
<div class="scheduledBody">
<h3>Calendario · Europe/Rome</h3><p id="automationState"></p>
<button id="enableAuto">Abilita / riprendi programma</button><button id="disableAuto">Disabilita programma</button>
<p class="hint">I comandi manuali sospendono il calendario fino a “Riprendi programma”. Una fascia ancora attiva riparte dall’inizio del gruppo. Il microfono resta sempre disponibile.</p>
<p id="nextEvents"></p>
<form id="eventForm"><input type="hidden" name="id"><fieldset><legend id="eventLegend">Nuovo evento</legend>
<label>Titolo <input name="name" required maxlength="100"></label>
<div><label>Traccia <select name="track" id="eventTrack" required></select></label><button type="button" id="addEventTrack">Aggiungi al gruppo</button></div>
<p class="hint">Per un solo brano basta selezionarlo. Per un gruppo, aggiungi le tracce e scegli l’ordine qui sotto.</p>
<ol id="eventPlaylist"></ol>
<label>Data e ora iniziale <input name="start" type="datetime-local" required step="60"></label>
<label>Ora fine fascia (facoltativa) <input name="end_time" type="time" step="60"></label>
<p class="hint">Se la fine è uguale o precedente all’inizio, la fascia termina il giorno successivo. Alla fine della fascia la musica si ferma, anche a metà brano.</p>
<label>Passaggi del gruppo <input name="repetitions" type="number" min="0" max="10000" step="1" value="1" required></label>
<label>Intervallo tra passaggi (secondi) <input name="interval_seconds" type="number" min="0" max="86400" step="1" value="0" required></label>
<p class="hint">1 = una volta; 2 = due passaggi completi; 0 = ripeti fino a fine fascia (richiede l’ora di fine). L’intervallo si applica dopo tutto il gruppo.</p>
<label>Ricorrenza <select name="recurrence"><option value="once">Una volta</option><option value="daily">Ogni giorno</option><option value="weekly">Ogni settimana</option></select></label>
<div id="weekdays">Giorni settimanali:
<label><input type="checkbox" value="0">Lun</label><label><input type="checkbox" value="1">Mar</label><label><input type="checkbox" value="2">Mer</label><label><input type="checkbox" value="3">Gio</label><label><input type="checkbox" value="4">Ven</label><label><input type="checkbox" value="5">Sab</label><label><input type="checkbox" value="6">Dom</label></div>
<label>Se il player è occupato <select name="policy"><option value="skip">Salta</option><option value="wait">Attendi fine programma (max 15 minuti)</option><option value="interrupt">Interrompi e riproduci</option></select></label>
<label><input name="enabled" type="checkbox" checked> Evento abilitato</label><button>Salva evento</button><button type="button" id="cancelEvent">Annulla modifica</button></fieldset></form>
<div class="scroll"><table><thead><tr><th>Evento</th><th>Fascia / ricorrenza</th><th>Tracce / ripetizioni</th><th>Azioni</th></tr></thead><tbody id="eventRows"></tbody></table></div>
<details><summary>Registro eventi (ultimi 30)</summary><ul id="eventHistory"></ul></details>
</div>
</details>
</section>
<section id="regiaSystem" class="regia-tab-panel" role="tabpanel" aria-labelledby="tabSystem" hidden>
<div id="systemDashboardHost">
<h3>Stato sistema</h3>
<p class="hint">Stato TX/RX, rete, servizi, autodiagnosi e manutenzione.</p>
</div>
<details id="latencyPanel" class="box" style="margin-top:18px">
<summary>Latenza comune degli RX</summary>
<p>Un solo target per tutti i ricevitori. Il TX salva il valore e lo invia anche agli RX che tornano online.</p>
<form id="fleetLatencyForm">
<label>Target latenza (ms) <input id="fleetLatencyTarget" type="number" min="20" max="2000" step="1" required aria-label="Target latenza comune in millisecondi"></label>
<button id="fleetLatencyApply" type="submit">Applica a tutti gli RX</button>
</form>
<p>Il cambio riavvia il servizio audio sui ricevitori interessati e causa una breve interruzione. Lo stesso target non garantisce uscite perfettamente sincronizzate.</p>
<p id="fleetLatencyMessage" role="status" aria-live="polite"></p>
<ul id="fleetLatencyNodes"></ul>
</details>
<details id="debugPanel" class="box" style="margin-top:18px">
<summary>Debug avanzato · log ed evidenze audio</summary>
<p>Consultazione su richiesta, senza SSH. Nessuna modifica alla riproduzione. Richiede TX e RX aggiornati alla versione 4.29 o successiva.</p>
<label>Nodo <select id="debugNode" aria-label="Nodo debug"></select></label>
<button type="button" id="debugDiscover">Rileva nodi</button>
<label>Servizio <select id="debugUnit"><option value="roc-museum">Roc / audio</option><option value="roc-museum-monitor">Monitor e cattura diagnostica</option></select></label>
<label>Intervallo <select id="debugWindow"><option value="15m">Ultimi 15 minuti</option><option value="1h">Ultima ora</option><option value="24h">Ultime 24 ore</option></select></label>
<button type="button" id="debugJournal">Leggi log</button>
<button type="button" id="debugEvents">Elenca evidenze salvate</button>
<p id="debugMessage" role="status" aria-live="polite"></p>
<p>Il journal mostra tutte le righe disponibili nell’intervallo scelto, fino a 5000 righe / 512 KiB; un taglio viene segnalato. Non viene aggiornato automaticamente.</p>
<pre id="debugLog" style="max-height:420px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere"></pre>
<div id="debugEvidence"></div>
<p>I WAV possono contenere audio ambientale o annunci. Premi Ascolta per caricarli. I due file hanno tempi di partenza indipendenti: confrontarli usando gli offset dell’analisi. “Confermato” è l’esito del rilevatore, non una diagnosi della causa.</p>
<div id="debugFiles"></div>
</details>

<h3>Explorer USB</h3><button id="scanUSB">Rileva pennette</button><label>Dispositivo <select id="usbDevice"></select></label><button id="openUSB">Apri</button><button id="ejectUSB">Espelli</button>
<p id="usbPath">Nessuna pennetta aperta</p><button id="usbParent">Cartella superiore</button><ul id="usbEntries"></ul>
<p class="hint">Le nuove pennette sono montate in sola lettura. Importa i brani nella libreria prima di scollegarle.</p>
<p id="studioMessage" role="status" aria-live="polite"></p>
<details id="updatePanel" style="margin:24px 0;border:1px solid #4b5563;border-radius:8px;padding:14px">
<summary style="cursor:pointer"><strong>Aggiornamento dispositivi · TX e RX</strong></summary>
<p>Controlla la versione su GitHub oppure avvia l’aggiornamento: prima il TX, poi gli RX in sequenza. L’audio si interrompe brevemente durante l’installazione di ciascun dispositivo.</p>
<p id="updateVersions">Versione installata: in attesa…</p>
<button type="button" id="checkUpdates">Controlla versione GitHub</button>
<button type="button" id="deployUpdates">Aggiorna TX e propaga agli RX</button>
<p id="updateMessage" role="status" aria-live="polite"></p>
<ul id="updateNodes"></ul>
<p>Gli RX vengono rilevati automaticamente dal TX. All’avvio scegli i ricevitori e inserisci una sola coppia di credenziali SSH, comune a tutti i selezionati oppure diversa per ogni modulo.</p>
<dialog id="updateCredentials" style="background:#1f2937;color:#e5e7eb;max-width:650px;width:90%;max-height:85vh;overflow:auto;border:1px solid #6b7280;border-radius:10px">
<form id="updateCredentialsForm">
<h3>Aggiornamento TX e ricevitori rilevati</h3>
<p>Il TX si aggiorna per primo, poi gli RX selezionati. L’audio subirà brevi interruzioni.</p>
<div id="discoveredReceivers"></div>
<label>Credenziali <select id="credentialScope"><option value="all">Uguali per tutti gli RX selezionati</option><option value="individual">Specifiche per ciascun RX</option></select></label>
<div id="credentialFields"></div>
<p class="hint">Per accedere direttamente come root, usa root come nome utente. Con un altro utente, la stessa password SSH viene usata anche per sudo. Le credenziali valgono solo per questo aggiornamento.</p>
<p id="credentialMessage" role="status" aria-live="polite"></p>
<button type="submit" id="startCredentialUpdate">Avvia aggiornamento</button>
<button type="button" id="cancelCredentialUpdate">Annulla</button>
</form></dialog>
<p class="hint">Puoi chiudere il browser: l’operazione prosegue sul TX. Il riavvio della regia richiede un nuovo login; rientra qui per vedere l’esito.</p>
</details>
</section>
</section>
<script>
(function(){
'use strict';
var currentEvents=[],eventTracks=[],usbPath='',usbOpened='',inFlight=false,duckInitialized=false;
var mediaFiles=[],playerSnapshot=null,playerSampleTime=0,scrubbing=false,volumeEditing=false,playerBusy=false,selectionDirty=false,playerRevision=0;
function el(id){return document.getElementById(id);}

/* Le schede cambiano solo presentazione: i servizi continuano a girare sempre. */
function activateRegiaTab(name,persist){
  var valid=['player','events','system'];
  if(!valid.includes(name)){name='player';}
  document.querySelectorAll('[data-regia-tab]').forEach(function(button){
    var active=button.dataset.regiaTab===name;
    button.setAttribute('aria-selected',String(active));
  });
  valid.forEach(function(tabName){
    var panel=el('regia'+tabName.charAt(0).toUpperCase()+tabName.slice(1));
    if(panel){panel.hidden=tabName!==name;}
  });
  if(persist){
    try{localStorage.setItem('museum.regia.tab',name);}catch(error){}
  }
  if(typeof placeDashboard==='function'){placeDashboard();}
  if(name==='player'&&typeof refreshAudioMonitor==='function'){refreshAudioMonitor();}
}

function message(text){el('studioMessage').textContent=text;el('playerMessage').textContent=text;}

/* Vista operativa: usa i dati del monitor centrale ma mostra soltanto audio e comandi RX. */
async function refreshAudioMonitor(){
  var host=el('rxAudioHost');
  if(!host||!authorized){return;}
  try{
    var response=await fetch('/api/status',{cache:'no-store'});
    if(!response.ok){throw new Error('stato sistema non disponibile');}
    var data=await response.json();
    var html='';
    (data.nodes||[]).forEach(function(node){
      var title=esc(node.name)+' · '+esc((node.role||'').toUpperCase());
      html+='<article class="card'+(isProbe(node)?' probeCard':'')+'">'+probeBadge(node)+'<div class="head"><strong>'+title+'</strong><span class="badge '+esc(node.state||'OK')+'">'+esc(node.state||'')+'</span></div>';
      html+=meterBlock(node);
      if(node.role==='rx'){
        html+=volumeBlock(node);
      }
      html+='</article>';
    });
    if(!html){html='<p class="hint">Nessun nodo audio rilevato.</p>';}
    host.innerHTML=html;
    if(typeof bindVolumeControls==='function'){bindVolumeControls();}
  }catch(error){
    host.innerHTML='<p class="hint">Monitor audio non disponibile: '+esc(error.message)+'</p>';
  }
}

/* La dashboard tecnica completa vive in Sistema durante la sessione di regia.
   Al logout viene riportata nella sua posizione pubblica originale. */
function placeDashboard(){
  if(!authorized&&document.getElementById("debugPanel")){clearDebug();el("debugNode").replaceChildren();el("debugPanel").open=false;}
  var systemHost=el('systemDashboardHost');
  var publicHome=document.getElementById('publicDashboardHome');
  var summary=document.getElementById('summary');
  var nodes=document.getElementById('nodes');
  var footer=document.getElementById('footer');
  var history=document.getElementById('diagnosticHistory');
  if(!systemHost||!publicHome||!summary||!nodes||!footer){return;}

  if(authorized){
    if(summary.parentNode!==systemHost){
      systemHost.appendChild(summary);
      systemHost.appendChild(nodes);
      if(history)systemHost.appendChild(history);
      systemHost.appendChild(footer);
    }
  }else if(summary.parentNode!==publicHome){
    publicHome.appendChild(summary);
    publicHome.appendChild(nodes);
    if(history)publicHome.appendChild(history);
    publicHome.appendChild(footer);
  }
}
async function api(path,data){
  var options={cache:'no-store'};
  if(data!==undefined){options.method='POST';options.headers={'Content-Type':'application/json','X-CSRF-Token':csrf};options.body=JSON.stringify(data);}
  var r=await fetch(path,options),d=await r.json();
  if(!r.ok){if(r.status===401){clearDebug();authorized=false;el('studioTools').hidden=true;await session();}throw new Error(d.message||'Operazione fallita');}
  return d;
}
async function perform(action){try{await action();}catch(error){message(error.message);}}
function option(select,value,label){var o=document.createElement('option');o.value=value;o.textContent=label;select.appendChild(o);}
function button(label,action){var b=document.createElement('button');b.type='button';b.textContent=label;b.onclick=action;return b;}
library=async function(){
  var data=await api('/api/media'),old=el('trackSelect').value,eventOld=el('eventTrack').value;
  mediaFiles=data.files;el('library').replaceChildren();el('trackSelect').replaceChildren();el('eventTrack').replaceChildren();
  data.files.forEach(function(f){
    var li=document.createElement('li');li.dataset.name=f.name;
    var title=button(f.name,function(){selectTrack(f.name);});title.className='vlc-track';title.title=f.name+' · doppio clic per riprodurre';title.setAttribute('aria-label','Seleziona '+f.name);
    title.ondblclick=function(){playSelected();};title.onkeydown=function(e){if(e.key==='Enter'){e.preventDefault();selectTrack(f.name);playSelected();}};
    var size=document.createElement('span');size.className='vlc-file-size';size.textContent=(f.size/1048576).toFixed(1)+' MB';
    var remove=button('×',function(){
      if(!confirm('Eliminare definitivamente '+f.name+' dalla libreria del TX?'))return;
      perform(async function(){remove.disabled=true;try{var d=await api('/api/media/delete',{name:f.name});await library();message(d.message);}finally{remove.disabled=false;}});
    });remove.className='vlc-delete';remove.title='Elimina traccia';remove.setAttribute('aria-label','Elimina '+f.name);
    var include=document.createElement('input');include.type='checkbox';include.className='playlist-check';include.dataset.name=f.name;include.setAttribute('aria-label','Includi nella scaletta '+f.name);include.checked=!!playerSnapshot&&playerSnapshot.playlist_tracks.includes(f.name);include.disabled=!playerSnapshot;include.onchange=function(){var tracks=Array.from(document.querySelectorAll('.playlist-check:checked')).map(function(c){return c.dataset.name;});perform(function(){return playerCommand({command:'playlist_select',tracks:tracks});});};li.append(include,title,size,remove);el('library').appendChild(li);option(el('trackSelect'),f.name,f.name);option(el('eventTrack'),f.name,f.name);
  });
  if(data.files.some(function(f){return f.name===old;}))el('trackSelect').value=old;
  if(data.files.some(function(f){return f.name===eventOld;}))el('eventTrack').value=eventOld;
  markTracks();filterTracks();renderPlayer();
};
function selectTrack(name){selectionDirty=true;el('trackSelect').value=name;markTracks();renderPlayer();}
function markTracks(){document.querySelectorAll('#library li').forEach(function(row){row.classList.toggle('selected',row.dataset.name===el('trackSelect').value);row.classList.toggle('playing',!!playerSnapshot&&row.dataset.name===playerSnapshot.track);});}
function filterTracks(){var query=el('playlistSearch').value.toLocaleLowerCase('it-IT');document.querySelectorAll('#library li').forEach(function(row){row.hidden=!row.dataset.name.toLocaleLowerCase('it-IT').includes(query);});el('playlistCount').textContent=mediaFiles.length+' tracce';}
function timeLabel(seconds){seconds=Math.max(0,Math.floor(Number(seconds)||0));var h=Math.floor(seconds/3600),m=Math.floor(seconds%3600/60),s=seconds%60;return (h?h+':':'')+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0');}
function playerPosition(){var s=playerSnapshot;if(!s)return 0;var elapsed=s.status==='playing'?Math.min(3,(performance.now()-playerSampleTime)/1000):0;return Math.min(s.duration,s.position+elapsed);}
function renderTimeline(){var s=playerSnapshot;if(!s||scrubbing)return;var pos=playerPosition();el('playerSeek').value=pos;el('elapsedTime').textContent=timeLabel(pos);}
function renderPlayer(){
  var s=playerSnapshot,active=!!s&&['playing','paused'].includes(s.status),selection=el('trackSelect').value;
  var different=active&&selection!==s.track;
  el('playerToggle').disabled=playerBusy||!selection;el('musicMute').disabled=el('musicVolume').disabled=!s||playerBusy;
  var pausing=active&&s.status==='playing'&&!different;
  el('playerToggle').textContent=pausing?'❚❚':'▶';el('playerToggle').setAttribute('aria-label',pausing?'Pausa musica':active&&s.status==='paused'&&!different?'Riprendi traccia':'Riproduci selezione');
  el('nowPlaying').textContent=active?s.track:selection||'Nessuna traccia in riproduzione';
  el('playerSummary').textContent=(active?(s.status==='playing'?'In riproduzione':'In pausa'):'Pronto')+' · '+(active?s.track:selection||'nessuna traccia');
  el('playerSource').textContent=active?(s.origin.startsWith('calendar:')?'Calendario · tutti gli RX':'Regia manuale · tutti gli RX'):'TX · solo microfono';
  el('playerSeek').disabled=!active||playerBusy;el('playerSeek').max=active?Math.max(0,s.duration-.01):1;
  el('playerBack').disabled=el('playerForward').disabled=!active||playerBusy;
  var index=mediaFiles.findIndex(function(f){return f.name===selection;});el('playerPrevious').disabled=playerBusy||(!active&&index<=0);el('playerNext').disabled=playerBusy||index<0||index>=mediaFiles.length-1;
  el('totalTime').textContent=timeLabel(s?s.duration:0);
  if(!volumeEditing&&s){el('musicVolume').value=s.music_volume;el('musicVolumeLabel').textContent=s.music_volume+'%';}
  if(s){el('musicMute').setAttribute('aria-pressed',s.music_muted?'true':'false');el('musicMute').textContent=s.music_muted?'◖×':'◖))';el('musicMute').setAttribute('aria-label',s.music_muted?'Riattiva musica':'Silenzia musica');}
  var trackLoop=!!s&&s.track_loop,playlistLoop=!!s&&s.playlist_loop;
  el('playerLoop').checked=trackLoop;
  el('repeatToggle').setAttribute('aria-pressed',String(trackLoop));el('repeatToggle').textContent='↻ Loop brano: '+(trackLoop?'ON':'OFF');el('repeatToggle').setAttribute('aria-label','Loop brano: '+(trackLoop?'ON':'OFF'));
  el('playlistLoop').setAttribute('aria-pressed',String(playlistLoop));el('playlistLoop').textContent='↻ Loop scaletta: '+(playlistLoop?'ON':'OFF');
  el('repeatToggle').disabled=el('playlistLoop').disabled=playerBusy||!s;
  document.querySelectorAll('.playlist-check').forEach(function(c){c.checked=!!s&&s.playlist_tracks.includes(c.dataset.name);c.disabled=playerBusy||!s;});
  el('playlistStart').disabled=playerBusy||!s||!s.playlist_tracks.length;
  el('playlistStatus').textContent=s?(s.playlist_active?'Scaletta in esecuzione':'Scaletta ferma')+' · '+s.playlist_tracks.length+' brani selezionati'+(s.playlist_loop?' · ripetizione continua':' · un passaggio'):'';
  if(s&&s.playlist_active){el('playerSource').textContent='Scaletta · tutti gli RX';el('playerNext').disabled=el('playerPrevious').disabled=playerBusy;}
  renderTimeline();markTracks();
}
async function playerCommand(data){if(playerBusy)return;playerBusy=true;playerRevision++;renderPlayer();try{var result=await api('/api/player',data);playerSnapshot=result;playerSampleTime=performance.now();message('');await update();}finally{playerBusy=false;renderPlayer();}}
function playSelected(){perform(async function(){await playerCommand({command:'play',name:el('trackSelect').value,loop:el('playerLoop').checked});selectionDirty=false;});}
function togglePlayback(){var s=playerSnapshot,name=el('trackSelect').value;if(!name)return;if(s&&s.track===name&&s.status==='playing')perform(function(){return playerCommand({command:'pause'});});else if(s&&s.track===name&&s.status==='paused')perform(function(){return playerCommand({command:'resume'});});else playSelected();}
function seekPlayer(position){var s=playerSnapshot;if(!s||!['playing','paused'].includes(s.status))return;perform(function(){return playerCommand({command:'seek',position:Math.max(0,Math.min(position,s.duration-.01))});});}
function renderPlaylist(){
  el('eventPlaylist').replaceChildren();
  eventTracks.forEach(function(name,index){
    var li=document.createElement('li');li.className='playlist-row';li.textContent=name+' ';
    var up=button('↑',function(){[eventTracks[index-1],eventTracks[index]]=[eventTracks[index],eventTracks[index-1]];renderPlaylist();});up.disabled=index===0;up.setAttribute('aria-label','Sposta su '+name);
    var down=button('↓',function(){[eventTracks[index+1],eventTracks[index]]=[eventTracks[index],eventTracks[index+1]];renderPlaylist();});down.disabled=index===eventTracks.length-1;down.setAttribute('aria-label','Sposta giù '+name);
    li.append(up,down,button('Rimuovi dal gruppo',function(){eventTracks.splice(index,1);renderPlaylist();}));el('eventPlaylist').appendChild(li);
  });
}
async function update(){
  el('studioTools').hidden=!authorized;if(!authorized||inFlight)return;inFlight=true;
  try{
    var revision=playerRevision,s=await api('/api/studio'),bus=s.audio_bus;if(revision!==playerRevision)return;
    if(!selectionDirty&&s.track&&mediaFiles.some(function(f){return f.name===s.track;}))el('trackSelect').value=s.track;playerSnapshot=s;playerSampleTime=performance.now();
    el('playerState').textContent=({live:'Solo microfono / ingresso mixer',playing:'In riproduzione',paused:'Musica in pausa'}[s.status]||s.status)+(s.track?' · '+s.track:'')+' · origine: '+(s.origin==='manual'?'regia':s.origin.startsWith('calendar:')?'calendario':'ingresso')+(s.error?' · Errore: '+s.error:'');
    el('positionText').textContent=s.position.toFixed(1)+' / '+s.duration.toFixed(1)+' s';el('seekPosition').max=Math.max(0,s.duration-0.01);
    if(s.status!=='live')el('playerLoop').checked=s.loop;renderPlayer();
    el('groupState').textContent=s.plan?'Gruppo: traccia '+(s.plan.index+1)+'/'+s.plan.tracks.length+' · passaggio '+s.plan.cycle+'/'+(s.plan.repetitions||'fino a fine fascia')+(s.plan.next_at?' · prossimo passaggio '+new Date(s.plan.next_at*1000).toLocaleTimeString('it-IT',{timeZone:'Europe/Rome'}):''):'';
    el('microphoneState').textContent=bus?(bus.microphone_online?'Microfono collegato':'ATTENZIONE: '+bus.microphone_error)+' · ingresso '+bus.microphone_dbfs+' dBFS · musica '+bus.music_gain_db+' dB'+(bus.ducking_active?' · DUCKING ATTIVO':''):'Ingresso diretto: il bus annunci si avvia con la regia.';
    if(!duckInitialized){var duck=el('duckingForm');duck.elements.namedItem('enabled').checked=s.ducking.enabled;duck.elements.namedItem('threshold_db').value=s.ducking.threshold_db;duck.elements.namedItem('reduction_db').value=s.ducking.reduction_db;duckInitialized=true;}
    el('automationState').textContent=(s.automation_enabled?'Calendario abilitato':'Calendario disabilitato')+(s.manual_hold?' · sospeso dalla regia manuale':'')+(s.queue.length?' · in attesa: '+s.queue.join(', '):'');
    el('nextEvents').textContent='Prossimi eventi: '+(s.next_events||[]).map(function(e){return e.name+' · '+new Date(e.at).toLocaleString('it-IT',{timeZone:'Europe/Rome'});}).join(' | ');
    currentEvents=s.events;renderEvents();el('eventHistory').replaceChildren();
    el('scheduledEventsMeta').textContent=currentEvents.length+' '+(currentEvents.length===1?'evento':'eventi')+' · '+(s.automation_enabled?'programma attivo':'programma disabilitato');
    var states={started:'avviato',completed:'completato',skipped:'saltato',waiting:'in attesa',interrupted:'interrotto',suspended:'sospeso',failed:'errore',cancelled:'annullato'};
    s.history.forEach(function(e){var li=document.createElement('li'),event=s.events.find(function(v){return v.id===e.event;});li.textContent=(event?event.name:e.event)+' · '+e.occurrence+' · '+(states[e.state]||e.state)+(e.message?' · '+e.message:'');el('eventHistory').appendChild(li);});
  }catch(error){message(error.message);}finally{inFlight=false;}
}
function renderEvents(){
  el('eventRows').replaceChildren();
  currentEvents.forEach(function(e){
    var tr=document.createElement('tr'),tracks=e.tracks||[e.track],repetitions=e.repetitions===undefined?1:e.repetitions;
    var recurrence={once:'una volta',daily:'ogni giorno',weekly:'settimanale: '+e.weekdays.map(function(d){return ['Lun','Mar','Mer','Gio','Ven','Sab','Dom'][d];}).join(', ')}[e.recurrence];
    [e.name+(e.enabled?'':' (disabilitato)'),e.start+(e.end_time?' → '+e.end_time:'')+' · '+recurrence,tracks.join(' → ')+' · '+(repetitions?repetitions+' passaggi':'fino a fine fascia')+' · intervallo '+(e.interval_seconds||0)+' s · '+({skip:'salta',wait:'attendi',interrupt:'interrompi'}[e.policy])].forEach(function(text){var td=document.createElement('td');td.textContent=text;tr.appendChild(td);});
    var actions=document.createElement('td');
    actions.appendChild(button('Modifica',function(){
      var form=el('eventForm');['id','name','start','recurrence','policy'].forEach(function(k){form.elements.namedItem(k).value=e[k];});
      form.elements.namedItem('track').value=tracks[0];form.elements.namedItem('end_time').value=e.end_time||'';form.elements.namedItem('repetitions').value=repetitions;form.elements.namedItem('interval_seconds').value=e.interval_seconds||0;
      form.elements.namedItem('enabled').checked=e.enabled;eventTracks=tracks.slice();renderPlaylist();
      document.querySelectorAll('#weekdays input').forEach(function(c){c.checked=e.weekdays.includes(Number(c.value));});el('eventLegend').textContent='Modifica evento';activateRegiaTab('events',true);el('scheduledEventsPanel').open=true;form.scrollIntoView({behavior:'smooth'});
    }));
    actions.appendChild(button('Elimina evento',function(){if(confirm('Eliminare l’evento '+e.name+'?'))perform(async function(){await api('/api/calendar/delete',{id:e.id});await update();});}));
    tr.appendChild(actions);el('eventRows').appendChild(tr);
  });
}
document.querySelectorAll('[data-player]').forEach(function(b){b.onclick=function(){perform(function(){return playerCommand({command:b.dataset.player});});};});
el('playerToggle').onclick=togglePlayback;
el('playlistStart').onclick=function(){selectionDirty=false;perform(function(){return playerCommand({command:'playlist_start'});});};
el('playlistLoop').onclick=function(){perform(function(){return playerCommand({command:'playlist_loop',enabled:!playerSnapshot.playlist_loop});});};
el('playerNext').onclick=function(){if(playerSnapshot&&playerSnapshot.playlist_active){perform(function(){return playerCommand({command:'playlist_next'});});return;}var index=mediaFiles.findIndex(function(f){return f.name===el('trackSelect').value;});if(index<mediaFiles.length-1){selectTrack(mediaFiles[index+1].name);playSelected();}};
el('playerPrevious').onclick=function(){if(playerSnapshot&&playerSnapshot.playlist_active){perform(function(){return playerCommand({command:'playlist_previous'});});return;}if(playerSnapshot&&playerPosition()>3&&playerSnapshot.track===el('trackSelect').value){seekPlayer(0);return;}var index=mediaFiles.findIndex(function(f){return f.name===el('trackSelect').value;});if(index>0){selectTrack(mediaFiles[index-1].name);playSelected();}else if(playerSnapshot&&playerSnapshot.track)seekPlayer(0);};
el('playerBack').onclick=function(){seekPlayer(playerPosition()-10);};el('playerForward').onclick=function(){seekPlayer(playerPosition()+10);};
el('playerSeek').oninput=function(){scrubbing=true;el('elapsedTime').textContent=timeLabel(this.value);};
el('playerSeek').onchange=function(){var target=Number(this.value);scrubbing=false;seekPlayer(target);};
el('playerSeek').addEventListener('pointercancel',function(){scrubbing=false;renderTimeline();});
el('repeatToggle').onclick=function(){el('playerLoop').checked=!el('playerLoop').checked;renderPlayer();perform(function(){return playerCommand({command:'loop',enabled:el('playerLoop').checked});});};
el('playlistToggle').onclick=function(){var hidden=!el('playerPlaylist').hidden;el('playerPlaylist').hidden=hidden;this.setAttribute('aria-pressed',hidden?'false':'true');};
el('playlistSearch').oninput=filterTracks;
el('musicVolume').oninput=function(){volumeEditing=true;el('musicVolumeLabel').textContent=this.value+'%';};
el('musicVolume').onchange=function(){var value=Number(this.value);perform(async function(){try{await playerCommand({command:'music_volume',value:value});}finally{volumeEditing=false;renderPlayer();}});};
el('musicMute').onclick=function(){perform(function(){return playerCommand({command:'music_muted',enabled:!playerSnapshot.music_muted});});};
el('seekForm').onsubmit=function(e){e.preventDefault();seekPlayer(Number(el('seekPosition').value));};
el('playerPanel').addEventListener('toggle',function(){try{localStorage.setItem('museum.player.open',this.open?'yes':'no');}catch(error){}});
el('vlcPlayer').addEventListener('keydown',function(e){if(/INPUT|SELECT|TEXTAREA|BUTTON|SUMMARY/.test(e.target.tagName))return;if(e.code==='Space'){e.preventDefault();togglePlayback();}else if(e.key==='ArrowLeft'){e.preventDefault();seekPlayer(playerPosition()-10);}else if(e.key==='ArrowRight'){e.preventDefault();seekPlayer(playerPosition()+10);}});
el('duckingForm').onsubmit=function(e){e.preventDefault();var f=e.target;perform(async function(){await api('/api/player',{command:'ducking',enabled:f.elements.namedItem('enabled').checked,threshold_db:Number(f.elements.namedItem('threshold_db').value),reduction_db:Number(f.elements.namedItem('reduction_db').value)});message('Impostazioni ducking salvate');await update();});};
el('enableAuto').onclick=function(){perform(async function(){await api('/api/player',{command:'automation',enabled:true});await update();});};
el('disableAuto').onclick=function(){perform(async function(){await api('/api/player',{command:'automation',enabled:false});await update();});};
el('addEventTrack').onclick=function(){var name=el('eventTrack').value;if(!name)return;if(eventTracks.length>=100){message('Massimo 100 tracce per gruppo');return;}eventTracks.push(name);renderPlaylist();};
el('cancelEvent').onclick=function(){el('eventForm').reset();el('eventForm').elements.namedItem('id').value='';eventTracks=[];renderPlaylist();el('eventLegend').textContent='Nuovo evento';};
el('eventForm').onsubmit=function(e){
  e.preventDefault();var form=e.target,data=Object.fromEntries(new FormData(form));
  data.enabled=form.elements.namedItem('enabled').checked;data.tracks=eventTracks.length?eventTracks.slice():[el('eventTrack').value];data.repetitions=Number(data.repetitions);data.interval_seconds=Number(data.interval_seconds);
  if(data.repetitions===0&&!data.end_time){message('Indicare l’ora di fine per ripetere fino a fine fascia');return;}
  data.weekdays=Array.from(document.querySelectorAll('#weekdays input:checked')).map(function(c){return Number(c.value);});
  if(!data.weekdays.length){if(data.recurrence==='weekly'){message('Selezionare almeno un giorno della settimana');return;}delete data.weekdays;}
  if(!data.id)delete data.id;
  perform(async function(){await api('/api/calendar/save',data);el('cancelEvent').click();message('Evento salvato. Abilitare il programma per eseguirlo.');await update();});
};
async function scan(){var d=await api('/api/usb');el('usbDevice').replaceChildren();d.devices.forEach(function(device){option(el('usbDevice'),device.id,device.label+' · '+device.filesystem);});message(d.devices.length?'Pennette rilevate':'Nessuna pennetta USB disponibile');}
async function browse(path){
  var device=el('usbDevice').value;if(!device)throw new Error('Selezionare una pennetta');
  var data=await api('/api/usb/browse',{device:device,path:path});usbPath=data.path;usbOpened=device;el('usbPath').textContent=device+': /'+usbPath;el('usbEntries').replaceChildren();
  data.entries.forEach(function(entry){var li=document.createElement('li'),b=button((entry.directory?'📁 ':'Importa: ')+entry.name,function(){perform(async function(){
    if(el('usbDevice').value!==usbOpened)throw new Error('Aprire la pennetta selezionata');
    var relative=(usbPath?usbPath+'/':'')+entry.name;
    if(entry.directory)await browse(relative);else{b.disabled=true;message('Importazione in corso…');try{await api('/api/usb/import',{device:device,path:relative});await library();message('File importato: '+entry.name);}finally{b.disabled=false;}}
  });});li.appendChild(b);el('usbEntries').appendChild(li);});
}
el('scanUSB').onclick=function(){perform(scan);};el('openUSB').onclick=function(){perform(function(){return browse('');});};
el('usbParent').onclick=function(){perform(function(){return browse(usbPath.split('/').slice(0,-1).join('/'));});};
el('ejectUSB').onclick=function(){perform(async function(){await api('/api/usb/eject',{device:el('usbDevice').value});usbPath='';usbOpened='';el('usbEntries').replaceChildren();el('usbPath').textContent='Pennetta espulsa';message('È possibile scollegare la pennetta');await scan();});};
var updatePolling=false;
async function refreshUpdates(){
  if(!authorized||updatePolling||!el('updatePanel').open)return;
  updatePolling=true;
  try{
    var s=await api('/api/updates'),busy=['queued','running'].includes(s.state);
    el('updateVersions').textContent='TX installato: '+s.installed+(s.latest?' · GitHub: '+s.latest:'')+(s.commit?' · commit '+s.commit.slice(0,12):'');
    el('updateMessage').textContent=s.message;
    ['checkUpdates','deployUpdates'].forEach(function(id){el(id).disabled=busy;});
    el('updateNodes').replaceChildren();(s.nodes||[]).forEach(function(n){var li=document.createElement('li');li.textContent=n.host+' · '+n.message;el('updateNodes').appendChild(li);});
  }catch(error){el('updateMessage').textContent='Regia non disponibile: attendi il riavvio e accedi nuovamente per leggere l’esito. '+error.message;}
  finally{updatePolling=false;}
}
async function requestUpdate(action){
  el('checkUpdates').disabled=true;el('deployUpdates').disabled=true;
  try{await api('/api/updates',{action:action});await refreshUpdates();}
  catch(error){el('updateMessage').textContent=error.message;el('checkUpdates').disabled=false;el('deployUpdates').disabled=false;}
}
el('checkUpdates').onclick=function(){requestUpdate('check');};
var updateReceivers=[],credentialGroups=[];
function renderCredentialFields(){
  el('credentialFields').replaceChildren();credentialGroups=[];
  var groups=el('credentialScope').value==='all'?[{ip:'all',name:'Tutti gli RX selezionati'}]:updateReceivers.filter(function(n){return n.online;});
  groups.forEach(function(n){
    var field=document.createElement('fieldset'),legend=document.createElement('legend');legend.textContent=n.name+(n.ip==='all'?'':' · '+n.ip);field.appendChild(legend);
    var inputs={};[['username','Utente SSH','text'],['password','Password SSH / sudo','password']].forEach(function(info){
      var label=document.createElement('label'),input=document.createElement('input');label.textContent=info[1]+' ';input.type=info[2];input.autocomplete='off';input.maxLength=info[0]==='username'?64:1024;input.required=true;if(info[0]==='username')input.value='root';label.appendChild(input);field.appendChild(label);field.appendChild(document.createElement('br'));inputs[info[0]]=input;
    });
    var hint=document.createElement('small');hint.className='hint';hint.textContent='Usa una sola coppia di credenziali. Se l’utente non è root deve poter usare sudo con la stessa password.';field.appendChild(hint);
    el('credentialFields').appendChild(field);credentialGroups.push({ip:n.ip,inputs:inputs,field:field});
  });
  syncCredentialSelection();
}
function selectedReceivers(){return Array.from(el('discoveredReceivers').querySelectorAll('input:checked')).map(function(input){return input.value;});}
function syncCredentialSelection(){
  var selected=selectedReceivers();credentialGroups.forEach(function(g){g.field.disabled=g.ip!=='all'&&!selected.includes(g.ip);g.field.hidden=g.field.disabled;});
  el('startCredentialUpdate').disabled=!selected.length;
}
function clearUpdateCredentials(){el('credentialFields').replaceChildren();credentialGroups=[];}
el('credentialScope').onchange=renderCredentialFields;
el('updateCredentials').addEventListener('close',clearUpdateCredentials);
el('cancelCredentialUpdate').onclick=function(){el('updateCredentials').close();};
el('deployUpdates').onclick=function(){perform(async function(){
  var state=await api('/api/updates');if(['queued','running'].includes(state.state))throw new Error('Aggiornamento già in corso');
  updateReceivers=state.receivers||[];el('discoveredReceivers').replaceChildren();el('credentialMessage').textContent='';
  updateReceivers.forEach(function(n){var label=document.createElement('label'),input=document.createElement('input');input.type='checkbox';input.value=n.ip;input.checked=n.online;input.disabled=!n.online;input.onchange=syncCredentialSelection;label.appendChild(input);label.appendChild(document.createTextNode(n.name+' · '+n.ip+(n.online?'':' · offline')));el('discoveredReceivers').appendChild(label);el('discoveredReceivers').appendChild(document.createElement('br'));});
  if(!updateReceivers.some(function(n){return n.online;}))el('credentialMessage').textContent='Nessun RX online rilevato. Attendi che i ricevitori si colleghino al TX.';
  renderCredentialFields();el('updateCredentials').showModal();
});};
el('updateCredentialsForm').onsubmit=async function(event){
  event.preventDefault();var credentials={},scope=el('credentialScope').value;
  credentialGroups.forEach(function(g){if(g.field.disabled)return;var value={};Object.keys(g.inputs).forEach(function(k){value[k]=g.inputs[k].value;});if(scope==='all')credentials=value;else credentials[g.ip]=value;});
  el('startCredentialUpdate').disabled=true;el('cancelCredentialUpdate').disabled=true;
  try{
    await api('/api/updates',{action:'update',scope:scope,receivers:selectedReceivers(),credentials:credentials});
    el('updateCredentials').close();await refreshUpdates();
  }catch(error){el('credentialMessage').textContent=error.message;syncCredentialSelection();}
  finally{credentials=null;el('cancelCredentialUpdate').disabled=false;}
};
el('updatePanel').addEventListener('toggle',refreshUpdates);
setInterval(refreshUpdates,3000);

window.addEventListener('DOMContentLoaded',function(){
  el('playlistHost').appendChild(el('library'));el('playlistImport').appendChild(el('upload'));
  var oldTitle=el('studio').querySelector('h3');if(oldTitle)oldTitle.remove();

  document.querySelectorAll('[data-regia-tab]').forEach(function(button){
    button.addEventListener('click',function(){activateRegiaTab(button.dataset.regiaTab,true);});
  });

  var initialTab='player';
  try{
    el('playerPanel').open=localStorage.getItem('museum.player.open')!=='no';
    initialTab=localStorage.getItem('museum.regia.tab')||'player';
  }catch(error){}
  activateRegiaTab(initialTab,false);
  placeDashboard();
  refreshAudioMonitor();

  update();
  setInterval(update,2000);
  setInterval(refreshAudioMonitor,2000);
  setInterval(renderTimeline,250);
});

var latencyPolling=false,latencySaving=false;
async function refreshFleetLatency(){
  if(!authorized||!el('latencyPanel').open||latencyPolling)return;
  latencyPolling=true;
  try{
    var data=await api('/api/latency');
    if(!authorized)return;
    var field=el('fleetLatencyTarget');
    if(!field.value&&data.desired)field.value=data.desired.target_ms;
    var labels={confermato:'Confermato',offline:'Offline: applicazione al rientro',aggiornamento_richiesto:'Aggiornare RX alla 4.30',errore:'Errore',in_attesa:'In attesa di conferma',non_impostata:'Target comune non impostato'};
    el('fleetLatencyNodes').replaceChildren();
    data.nodes.forEach(function(n){
      var li=document.createElement('li');
      li.textContent=n.name+' · '+labels[n.state]+' · valore riportato: '+(n.current||'n/d')+(n.error?' · '+n.error:'');
      el('fleetLatencyNodes').appendChild(li);
    });
    if(!latencySaving)el('fleetLatencyMessage').textContent=data.desired?'Target comune salvato: '+data.desired.target_ms+' ms. Conferma verificata dai heartbeat di ciascun RX.':'Nessun target comune salvato. Seleziona un valore per iniziare la prova.';
  }catch(error){el('fleetLatencyMessage').textContent=error.message;}
  finally{latencyPolling=false;}
}
el('latencyPanel').addEventListener('toggle',refreshFleetLatency);
el('fleetLatencyForm').onsubmit=async function(event){
  event.preventDefault();
  if(latencySaving||!authorized||!event.target.reportValidity())return;
  var target=Number(el('fleetLatencyTarget').value);
  if(!confirm('Applicare '+target+' ms a tutti gli RX? Il cambio causa una breve interruzione audio sui ricevitori.'))return;
  latencySaving=true;el('fleetLatencyApply').disabled=true;
  try{
    await api('/api/latency',{target_ms:target});
    el('fleetLatencyMessage').textContent='Target salvato: '+target+' ms. Applicazione agli RX in corso…';
  }catch(error){el('fleetLatencyMessage').textContent=error.message;}
  finally{latencySaving=false;el('fleetLatencyApply').disabled=false;}
};
setInterval(refreshFleetLatency,5000);

var debugBusy=false,debugGeneration=0;
function clearDebugFiles(){
  el('debugFiles').querySelectorAll('audio').forEach(function(audio){audio.pause();audio.removeAttribute('src');audio.load();});
  el('debugFiles').replaceChildren();
}
function clearDebug(){debugGeneration++;el('debugLog').textContent='';el('debugEvidence').replaceChildren();clearDebugFiles();el('debugMessage').textContent='';}
function debugURL(action,extra){var q=new URLSearchParams(Object.assign({node:el('debugNode').value,action:action},extra||{}));return '/api/diagnostics/debug?'+q.toString();}
async function debugRead(action,extra){var r=await fetch(debugURL(action,extra),{cache:'no-store'});var d=await r.json();if(!r.ok)throw new Error(d.message||'Diagnostica non disponibile');return d;}
async function debugRun(task){if(debugBusy||!authorized)return;debugBusy=true;var generation=debugGeneration;el('debugMessage').textContent='Lettura in corso…';try{await task(generation);}catch(error){if(generation===debugGeneration)el('debugMessage').textContent=error.message;}finally{debugBusy=false;}}
async function debugDiscover(){await debugRun(async function(g){var d=await api('/api/status');if(g!==debugGeneration||!authorized)return;var old=el('debugNode').value;el('debugNode').replaceChildren();d.nodes.forEach(function(n){option(el('debugNode'),n.name,n.name+(n.online?'':' · offline'));});if(d.nodes.some(function(n){return n.name===old;}))el('debugNode').value=old;el('debugMessage').textContent=d.nodes.length?'Seleziona un nodo e una lettura.':'Nessun nodo disponibile.';});}
el('debugPanel').addEventListener('toggle',function(){if(this.open&&authorized&&!el('debugNode').options.length)debugDiscover();});
el('logout').addEventListener('click',clearDebug);
el('debugDiscover').onclick=debugDiscover;
el('debugNode').onchange=clearDebug;
el('debugJournal').onclick=function(){debugRun(async function(g){var d=await debugRead('journal',{unit:el('debugUnit').value,window:el('debugWindow').value});if(g!==debugGeneration||!authorized)return;el('debugLog').textContent=d.text||'Nessuna riga disponibile nel journal.';el('debugMessage').textContent=(d.truncated?'LOG TAGLIATO: raggiunto il limite di righe o byte. Riduci l’intervallo. ':'')+'Lettura '+historyTime(d.generated_at);});};
el('debugEvents').onclick=function(){debugRun(async function(g){var d=await debugRead('events');if(g!==debugGeneration||!authorized)return;el('debugEvidence').replaceChildren();clearDebugFiles();d.events.forEach(function(e){var row=document.createElement('p');row.textContent=historyTime(e.triggered_at||e.saved_at)+' · '+e.status+' ';row.appendChild(button('Apri '+e.id,function(){debugOpenEvent(e.id);}));el('debugEvidence').appendChild(row);});el('debugMessage').textContent=d.events.length+' evidenze disponibili sul nodo (massimo 20; le più vecchie vengono eliminate).';});};
function debugOpenEvent(id){debugRun(async function(g){var d=await debugRead('file',{event:id,file:'event.json'});if(g!==debugGeneration||!authorized)return;var box=el('debugFiles');clearDebugFiles();var title=document.createElement('h4');title.textContent=id;box.appendChild(title);var pre=document.createElement('pre');pre.style.cssText='max-height:420px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere';pre.textContent=JSON.stringify(d,null,2);box.appendChild(pre);['event.json','reference.wav','return.wav'].forEach(function(file){var url=debugURL('file',{event:id,file:file}),row=document.createElement('p'),link=document.createElement('a');link.href=url;link.download=id+'-'+file;link.textContent='Scarica '+file;row.appendChild(link);if(file.endsWith('.wav')){var audio=document.createElement('audio');audio.controls=true;audio.preload='none';var play=button('Ascolta '+(file==='reference.wav'?'riferimento RTP':'ritorno analogico'),function(){audio.src=url;audio.play().catch(function(){el('debugMessage').textContent='Audio non disponibile: evidenza rimossa, nodo offline o sessione scaduta.';});});audio.onerror=function(){el('debugMessage').textContent='Impossibile leggere il WAV: verificare nodo e sessione.';};row.appendChild(play);row.appendChild(audio);}box.appendChild(row);});el('debugMessage').textContent='Evidenza caricata. Journal dell’evento e dettagli nel JSON.';});}

})();
</script>
HTML_STUDIO
    chmod 0644 /usr/local/lib/roc-museum/studio.py /usr/local/lib/roc-museum/audio_bus.py /usr/local/share/roc-museum/studio.html
}

write_remote_access() {
    cat > /usr/local/sbin/roc-museum-remote <<'SH_REMOTE'
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
SH_REMOTE
    chmod 0755 /usr/local/sbin/roc-museum-remote
    mkdir -p /usr/local/lib/roc-museum/funnel-watchdog/{scripts,deploy}
    cat > /usr/local/lib/roc-museum/funnel-watchdog/README.md <<'WATCHDOG_0'
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
WATCHDOG_0
    cat > /usr/local/lib/roc-museum/funnel-watchdog/UPSTREAM <<'WATCHDOG_1'
https://github.com/rivros0/tailscale-funnel-watchdog
Commit: eb6beb4717bdd21461b5c5fb5e5084f82fc47a5e
WATCHDOG_1
    cat > /usr/local/lib/roc-museum/funnel-watchdog/deploy/check-tailscale-funnel.sh <<'WATCHDOG_3'
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
WATCHDOG_3
    cat > /usr/local/lib/roc-museum/funnel-watchdog/deploy/tailscale-funnel-watchdog.service <<'WATCHDOG_4'
[Unit]
Description=Watchdog Tailscale Funnel per servizi HTTP locali
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
EnvironmentFile=/etc/tailscale-funnel-watchdog.conf
ExecStart=/usr/local/sbin/check-tailscale-funnel.sh
TimeoutStartSec=360
LogsDirectory=tailscale-funnel
Environment=LOG_FILE=/var/log/tailscale-funnel/watchdog.log
SyslogIdentifier=tailscale-funnel-watchdog
WATCHDOG_4
    cat > /usr/local/lib/roc-museum/funnel-watchdog/deploy/tailscale-funnel-watchdog.timer <<'WATCHDOG_5'
[Unit]
Description=Controllo periodico Tailscale Funnel

[Timer]
OnBootSec=2min
OnUnitInactiveSec=5min
Unit=tailscale-funnel-watchdog.service

[Install]
WantedBy=timers.target
WATCHDOG_5
    cat > /usr/local/lib/roc-museum/funnel-watchdog/deploy/tailscale-funnel.logrotate <<'WATCHDOG_6'
/var/log/tailscale-funnel/watchdog.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
WATCHDOG_6
    cat > /usr/local/lib/roc-museum/funnel-watchdog/scripts/install.sh <<'WATCHDOG_8'
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
WATCHDOG_8
}

write_updater() {
    cat > /usr/local/lib/roc-museum/updater.py <<'PY_UPDATER'
#!/usr/bin/env python3
"""Durable TX-first fleet updates, executed outside the monitor's systemd unit."""
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

ROOT=Path('/var/lib/roc-museum/updates')
CONFIG=Path('/etc/roc-museum.conf')
SERVICE='roc-museum-update.service'
REPOSITORY='https://github.com/rivros0/RETE-MUSEO-AudioOverNetwork.git'
BRANCH='main'
BUSY={'queued','running'}
SECRETS=Path('/run/roc-museum-update-job.json')


def version(value):
    if not isinstance(value,str) or not re.fullmatch(r'\d+(?:\.\d+)*',value):
        raise ValueError('Versione numerica non valida')
    parts=[int(v) for v in value.split('.')]
    while len(parts)>1 and parts[-1]==0: parts.pop()
    return tuple(parts)


def read_config(path=CONFIG):
    result={}
    for line in Path(path).read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key,value=line.split('=',1)
            tokens=shlex.split(value,comments=True)
            if len(tokens)==1: result[key]=tokens[0]
    return result


def atomic(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,name=tempfile.mkstemp(dir=path.parent,prefix='.state-')
    try:
        with os.fdopen(fd,'w') as stream:
            json.dump(data,stream,ensure_ascii=False);stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name): os.unlink(name)


def read_json(path,default):
    try: return json.loads(Path(path).read_text())
    except FileNotFoundError: return default


@contextlib.contextmanager
def lock(root,blocking=False):
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (root/'lock').open('a') as stream:
        try: fcntl.flock(stream,fcntl.LOCK_EX|(0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError: raise ValueError('Operazione di aggiornamento già in corso') from None
        yield


def targets(text):
    if not isinstance(text,str) or len(text)>8192: raise ValueError('Elenco RX non valido')
    result=[]
    for item in text.splitlines():
        item=item.strip()
        if not item: continue
        if not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]*@[0-9.]+',item):
            raise ValueError('Inserire un RX per riga nel formato utente@IPv4')
        ipaddress.IPv4Address(item.split('@')[1])
        if item in result: raise ValueError('RX duplicato')
        result.append(item)
    if len(result)>32: raise ValueError('Massimo 32 RX')
    return result


def command(argv,timeout=60,input=None):
    result=subprocess.run(argv,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if result.returncode:
        print(result.stderr.decode('utf-8',errors='replace'),file=sys.stderr,flush=True)
        raise RuntimeError('Comando fallito: '+Path(argv[0]).name+' (consultare il log aggiornamenti)')
    return result.stdout.decode('utf-8',errors='replace')


def ssh(host,script,input=None,timeout=60):
    return command(['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
                    '-o','ConnectTimeout=12','-o','ServerAliveInterval=15',
                    '-o','ServerAliveCountMax=3',host,script],timeout=timeout,input=input)


class PasswordSSH:
    """One in-memory SSH connection; passwords never appear in commands or logs."""
    def __init__(self, address, credentials):
        import paramiko
        self.client=paramiko.SSHClient()
        self.client.load_system_host_keys()
        # Unknown LAN hosts are trusted for this connection only. Known changed keys fail.
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.credentials=credentials
        try:
            self.client.connect(address, username=credentials['username'], password=credentials['password'],
                                look_for_keys=False, allow_agent=False, timeout=12, auth_timeout=15, banner_timeout=15)
        except Exception:
            self.client.close()
            raise RuntimeError('Connessione SSH fallita: verificare credenziali e chiave host') from None
    def close(self): self.client.close()
    def __call__(self, host, script, input=None, timeout=60):
        stdin,stdout,stderr=self.client.exec_command(script,timeout=timeout)
        if input: stdin.write(input);stdin.flush()
        stdin.channel.shutdown_write()
        # Drain both streams concurrently to avoid SSH window deadlocks.
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            out=pool.submit(stdout.read);err=pool.submit(stderr.read)
            result=out.result();err.result()
        if stdout.channel.recv_exit_status():
            raise RuntimeError('Comando remoto fallito (consultare il log sul ricevitore)')
        return result.decode('utf-8',errors='replace')
    def _sudo_with_password(self, script, timeout):
        # Use the same password used for SSH authentication. The password is
        # written only to the sudo terminal and never appears in argv or logs.
        command='sudo -S -p '+shlex.quote('Password: ')+' -- sh -c '+shlex.quote(script)
        stdin,stdout,stderr=self.client.exec_command(command,get_pty=True,timeout=timeout)
        import select
        channel=stdout.channel
        output=b''
        sent=False
        deadline=time.monotonic()+timeout

        while True:
            if time.monotonic()>deadline:
                channel.close()
                raise RuntimeError('Timeout comando amministrativo RX')

            if channel.recv_ready():
                output+=channel.recv(4096)
                lowered=output.lower()
                if not sent and (b'password:' in lowered or b'[sudo]' in lowered):
                    channel.sendall((self.credentials['password']+'\n').encode())
                    sent=True
                output=output[-2048:]
            elif channel.exit_status_ready():
                break
            else:
                select.select([channel],[],[],0.1)

        result=channel.recv_exit_status()
        if result:
            raise RuntimeError(
                'Comando amministrativo RX fallito: verificare che l’utente SSH sia root '
                'oppure sia abilitato a sudo con la stessa password'
            )

    def privileged(self, host, script, timeout=60):
        if self.credentials['username']=='root':
            return self(host,script,timeout=timeout)

        # First support accounts configured for passwordless sudo. This avoids
        # sending anything to stdin when sudo does not need authentication.
        stdin,stdout,stderr=self.client.exec_command(
            'sudo -n -- sh -c '+shlex.quote(script),
            timeout=timeout
        )
        stdout.read()
        stderr.read()
        if stdout.channel.recv_exit_status()==0:
            return

        return self._sudo_with_password(script,timeout)


def credential(value):
    if not isinstance(value,dict):
        raise ValueError('Credenziali RX mancanti')

    user=value.get('username','')
    password=value.get('password','')

    if not isinstance(user,str) or not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]*',user):
        raise ValueError('Nome utente SSH non valido')

    if not isinstance(password,str) or not password or len(password)>1024 or any(c in password for c in ('\n','\r','\0')):
        raise ValueError('Password RX mancante o non valida')

    return {'username':user,'password':password}


REMOTE_CONFIG="""import json,shlex
from pathlib import Path
result={}
for line in Path('/etc/roc-museum.conf').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key,value=line.split('=',1); tokens=shlex.split(value,comments=True)
        if len(tokens)==1: result[key]=tokens[0]
print(json.dumps(result))
"""


def remote_config(host, connection=None):
    return json.loads((connection or ssh)(host,'python3 -c '+shlex.quote(REMOTE_CONFIG)))


def fetch_candidate(directory):
    repo=Path(directory)/'repo'
    command(['git','-c','core.hooksPath=/dev/null','clone','--depth','1','--branch',BRANCH,'--',REPOSITORY,str(repo)],timeout=180)
    commit=command(['git','-C',str(repo),'rev-parse','HEAD']).strip()
    if not re.fullmatch('[0-9a-f]{40}',commit): raise ValueError('Commit GitHub non valido')
    artifact=repo/'setup_roc_museum.sh'
    if artifact.is_symlink() or not artifact.is_file() or artifact.stat().st_size>4*1024*1024:
        raise ValueError('Installer GitHub non valido')
    content=artifact.read_bytes()
    match=re.search(rb'(?m)^VERSION="(\d+(?:\.\d+)*)"$',content)
    if not match: raise ValueError('Versione GitHub non disponibile')
    latest=match[1].decode();version(latest)
    command(['bash','-n',str(artifact)])
    return artifact,latest,commit,hashlib.sha256(content).hexdigest()


def local_install(artifact,config,log):
    with log.open('ab') as stream:
        result=subprocess.run(['bash',str(artifact),'--role','tx','--name',config['NODE_NAME']],stdout=stream,stderr=subprocess.STDOUT,timeout=3600)
    if result.returncode: raise RuntimeError('Aggiornamento TX fallito: consultare il log')


def verify_local(latest):
    if version(read_config().get('SOFTWARE_VERSION',''))!=version(latest):
        raise ValueError('Versione TX dopo installazione diversa da quella attesa')
    for service in ('roc-museum.service','roc-museum-monitor.service'):
        command(['systemctl','is-active','--quiet',service])
    # Readiness includes the HTTP monitor, not only systemd's process state.
    import urllib.request
    for attempt in range(15):
        try:
            with urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=3) as response:
                if response.status==200 and response.read(16)==b'ok\n': return
        except OSError: pass
        time.sleep(2)
    raise RuntimeError('TX aggiornato ma regia non disponibile; propagazione RX fermata')


def install_rx(host,artifact,latest,digest,connection=None):
    run=connection or ssh
    config=remote_config(host,connection) if connection else remote_config(host)
    if config.get('ROLE')!='rx': raise ValueError('Il dispositivo non è un RX')
    current=config.get('SOFTWARE_VERSION','');version(current)
    if version(current)>=version(latest): return 'Già aggiornato ('+current+')'
    directory=run(host,'mktemp -d /tmp/roc-museum-update.XXXXXXXX').strip()
    if not re.fullmatch(r'/tmp/roc-museum-update\.[a-zA-Z0-9]+',directory): raise ValueError('Directory remota non valida')
    remote=directory+'/setup.sh'
    try:
        run(host,'cat > '+shlex.quote(remote),input=artifact.read_bytes(),timeout=120)
        actual=run(host,'sha256sum -- '+shlex.quote(remote)).split()[0]
        if actual!=digest: raise ValueError('Integrità installer RX non valida')
        ipaddress.IPv4Address(config['TX_IP'])
        invocation=['bash',remote,'--role','rx','--tx-ip',config['TX_IP'],'--name',config['NODE_NAME']]
        script=shlex.join(invocation)+' > '+shlex.quote(directory+'/install.log')+' 2>&1'
        if connection: connection.privileged(host,script,timeout=3600)
        else: run(host,'sudo -n '+script,timeout=3600)
        after=remote_config(host,connection) if connection else remote_config(host)
        if after.get('ROLE')!='rx' or version(after.get('SOFTWARE_VERSION',''))!=version(latest):
            raise ValueError('Verifica versione RX fallita')
        run(host,'systemctl is-active --quiet roc-museum.service && systemctl is-active --quiet roc-museum-monitor.service')
        run(host,'rm -rf -- '+shlex.quote(directory))
        return 'Aggiornato a '+latest
    except Exception:
        # Preserve logs and installer when outcome needs manual inspection.
        raise RuntimeError('Aggiornamento RX fallito; log su RX: '+directory+'/install.log') from None


class Manager:
    def __init__(self,root=ROOT,discover=None,secrets=SECRETS):
        self.root=Path(root);self.discover=discover or (lambda: []);self.secrets=Path(secrets)
    def receivers(self):
        result=[];seen=set()
        for node in self.discover():
            if node.get('role')!='rx': continue
            try: address=str(ipaddress.IPv4Address(node.get('source_ip','')))
            except (ValueError,TypeError): continue
            if address in seen: continue
            seen.add(address)
            result.append({'ip':address,'name':str(node.get('name',address))[:100],
                           'online':time.time()-node.get('received_at',0)<=15})
        return result[:32]
    def state(self): return read_json(self.root/'status.json',{'state':'idle','message':'Nessun controllo eseguito','nodes':[]})
    def snapshot(self):
        if read_config().get('ROLE')!='tx': raise ValueError('Aggiornamenti disponibili soltanto sul TX')
        state=self.state()
        if state['state'] in BUSY and time.time()-state.get('updated_at',0)>20:
            active=command(['systemctl','show',SERVICE,'--property=ActiveState','--value']).strip()
            if active not in ('active','activating','reloading'):
                try:
                    with lock(self.root):
                        state=self.state()
                        if state['state'] in BUSY:
                            state.update(state='failed',message='Operazione interrotta: controllare log e versioni prima di riprovare',updated_at=time.time())
                            atomic(self.root/'status.json',state)
                            self.secrets.unlink(missing_ok=True)
                except ValueError: pass
        return {**state,'installed':read_config().get('SOFTWARE_VERSION',''),
                'receivers':self.receivers()}
    def request(self,action,data):
        if read_config().get('ROLE')!='tx': raise ValueError('Aggiornamenti disponibili soltanto sul TX')
        if action not in ('check','update'): raise ValueError('Azione aggiornamento non valida')
        with lock(self.root):
            if self.state()['state'] in BUSY: raise ValueError('Operazione già in corso')
            active=command(['systemctl','show',SERVICE,'--property=ActiveState','--value']).strip()
            if active in ('active','activating','reloading'): raise ValueError('Servizio di aggiornamento già in corso')
            if action=='update':
                known={n['ip'] for n in self.receivers() if n['online']}
                selected=data.get('receivers')
                if not isinstance(selected,list) or not selected or len(selected)>32:
                    raise ValueError('Selezionare almeno un RX online')
                if any(not isinstance(ip,str) or ip not in known for ip in selected) or len(set(selected))!=len(selected):
                    raise ValueError('Elenco RX cambiato: riaprire la finestra di aggiornamento')
                scope=data.get('scope')
                if scope not in ('all','individual'): raise ValueError('Modalità credenziali non valida')
                values=data.get('credentials')
                if not isinstance(values,dict): raise ValueError('Credenziali RX mancanti')
                job=[{'ip':ip,'credentials':credential(values if scope=='all' else values.get(ip))} for ip in selected]
                self.secrets.parent.mkdir(parents=True,exist_ok=True)
                atomic(self.secrets,job)
            atomic(self.root/'status.json',{'state':'queued','action':action,'message':'Operazione in avvio',
                                          'updated_at':time.time(),'nodes':[]})
            try: command(['systemctl','start','--no-block',SERVICE])
            except Exception:
                self.secrets.unlink(missing_ok=True)
                atomic(self.root/'status.json',{'state':'failed','message':'Avvio aggiornamento fallito','nodes':[]})
                raise
        return {'ok':True}
    def worker(self):
        with lock(self.root,blocking=True):
            state=self.state()
            if state.get('state')!='queued': raise ValueError('Nessuna operazione in attesa')
            def progress(message,**extra):
                state.update(message=message,updated_at=time.time(),**extra)
                atomic(self.root/'status.json',state)
            connections={}
            try:
                job=read_json(self.secrets,None) if state['action']=='update' else None
                if state['action']=='update' and job is None: raise ValueError('Credenziali scadute: avviare nuovamente l’aggiornamento')
                for item in job or []:
                    host=item['ip'];progress('Verifica accesso SSH e sudo '+host,state='running')
                    conn=PasswordSSH(host,item['credentials']);connections[host]=conn
                    if remote_config(host,conn).get('ROLE')!='rx': raise ValueError('Il dispositivo non è un RX: '+host)
                    conn.privileged(host,'true')
                progress('Controllo versione su GitHub',state='running')
                config=read_config()
                if config.get('ROLE')!='tx': raise ValueError('Il dispositivo non è un TX')
                with tempfile.TemporaryDirectory(prefix='release-',dir=self.root) as temp:
                    artifact,latest,commit,digest=fetch_candidate(temp)
                    receivers=[item['ip'] for item in job] if job is not None else []
                    nodes=[{'host':host,'state':'pending','message':'In attesa'} for host in receivers]
                    progress('Versione GitHub '+latest,latest=latest,commit=commit,sha256=digest,nodes=nodes)
                    if state['action']=='check':
                        progress('Controllo completato',state='checked');return
                    current=config.get('SOFTWARE_VERSION','');version(current)
                    if version(current)>version(latest):
                        raise ValueError('TX più recente di GitHub: aggiornamento fermato per evitare versioni miste')
                    if version(current)<version(latest):
                        progress('Aggiornamento TX in corso; la regia si riconnetterà dopo il riavvio')
                        # Backup of configuration only; live SQLite databases are preserved by setup.
                        (self.root/'tx-config.backup').write_text(CONFIG.read_text())
                        local_install(artifact,config,self.root/'tx-install.log')
                    progress('Verifica TX prima della propagazione')
                    verify_local(latest)
                    failures=False
                    for node in nodes:
                        progress('Aggiornamento '+node['host'])
                        node.update(state='running',message='Connessione SSH')
                        progress(state['message'])
                        try:
                            node.update(message=install_rx(node['host'],artifact,latest,digest,connections[node['host']]),state='completed')
                        except Exception as error:
                            node.update(state='failed',message=str(error));failures=True
                        progress('Esito '+node['host'])
                    progress('Aggiornamento completato con errori RX' if failures else 'TX e RX aggiornati',
                             state='partial' if failures else 'completed')
            except Exception as error:
                progress(str(error),state='failed')
                raise
            finally:
                for conn in connections.values(): conn.close()
                self.secrets.unlink(missing_ok=True)


if __name__=='__main__':
    if sys.argv[1:]!=['worker']: raise SystemExit('Uso interno: updater.py worker')
    Manager().worker()
PY_UPDATER
    chmod 0644 /usr/local/lib/roc-museum/updater.py
    cat > /etc/systemd/system/roc-museum-update.service <<'UNIT_UPDATE'
[Unit]
Description=RETE MUSEO aggiornamento TX e propagazione RX
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/roc-museum/updater.py worker
TimeoutStartSec=infinity
UMask=0077
UNIT_UPDATE
}

write_systemd_services() {
    cat > "$AUDIO_SERVICE" <<'EOF_AUDIO'
[Unit]
Description=RETE MUSEO Roc Audio node
After=network-online.target sound.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/roc-museum-run
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF_AUDIO
    cat > "$MONITOR_SERVICE" <<'EOF_MONITOR'
[Unit]
Description=RETE MUSEO Audio monitor agent
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/roc-museum-monitor
ExecStopPost=/usr/local/sbin/roc-museum-monitor --restore-live
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF_MONITOR
}

get_service_state() {
    local service="$1"
    local state=""
    state="$(systemctl is-active "$service" 2>/dev/null || true)"
    if [ -z "$state" ]; then state="unknown"; fi
    echo "$state"
}

start_service() {
    local service="$1"
    systemctl enable "$service" >/dev/null
    if ! systemctl restart "$service"; then warn "Avvio immediato non riuscito: $service"; fi
}

enable_services() {
    systemctl daemon-reload
    start_service roc-museum.service
    start_service roc-museum-monitor.service
    sleep 2
    if [ "$(get_service_state roc-museum-monitor.service)" = "active" ]; then ok "Monitor attivo e abilitato al boot."; else warn "Monitor non attivo."; fi
    if [ "$(get_service_state roc-museum.service)" = "active" ]; then
        ok "Audio Roc attivo e abilitato al boot."
    else
        warn "Audio Roc non ancora attivo; systemd continuerà a ritentare."
        echo
        echo "Ultime righe del log Roc:"
        journalctl -u roc-museum.service -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true
    fi
}

print_diagnostics() {
    local local_ip=""
    local_ip="$(get_ipv4 "$NETWORK_IFACE")"
    echo
    echo -e "${C_BOLD}================ INSTALLAZIONE COMPLETATA ================${C_RESET}"
    echo "Versione           : $VERSION"
    echo "Nodo / ruolo       : $NODE_NAME / ${ROLE^^}"
    echo "Ethernet           : $NETWORK_IFACE"
    echo "IPv4               : ${local_ip:-n/d}"
    echo "Audio multicast    : ${MULTICAST_ADDR}:${RTP_PORT}"
    echo "Servizio audio     : $(get_service_state roc-museum.service)"
    echo "Servizio monitor   : $(get_service_state roc-museum-monitor.service)"
    if [ "$ROLE" = "tx" ]; then
        echo "Dashboard           : http://${local_ip:-IP-TX}:${MONITOR_HTTP_PORT}/"
        echo "API                 : http://${local_ip:-IP-TX}:${MONITOR_HTTP_PORT}/api/status"
        echo "Versione monitor     : http://${local_ip:-IP-TX}:${MONITOR_HTTP_PORT}/api/version"
    else
        echo "Monitor TX          : ${TX_IP}:${MONITOR_PORT}/UDP"
    fi
    echo "==========================================================="
    echo
    echo "Comandi di manutenzione:"
    echo "  systemctl status roc-museum --no-pager"
    echo "  systemctl status roc-museum-monitor --no-pager"
    echo "  journalctl -u roc-museum -f"
    echo
    if [ "$ROLE" = "tx" ]; then echo "IMPORTANTE: mantenere stabile l'IP del TX."; echo; fi
}

ask_reboot() {
    local answer=""
    if [ "$REBOOT_REQUIRED" != "yes" ]; then return; fi
    echo -e "${C_YELLOW}È necessario un riavvio per completare l'audio analogico.${C_RESET}"
    if [ "$INTERACTIVE_MODE" != "yes" ]; then echo "Eseguire: sudo reboot"; return; fi
    read -r -p "Riavviare ora? [S/n]: " answer
    if [ -z "$answer" ] || [ "$answer" = "s" ] || [ "$answer" = "S" ]; then
        echo "Riavvio in corso; la sessione SSH verrà chiusa."
        sleep 2
        systemctl reboot
    fi
}

main() {
    require_root
    print_title
    parse_arguments "$@"
    step "Rilevamento rete e configurazione precedente"
    detect_network_interface
    load_existing_configuration
    ok "Ethernet: $NETWORK_IFACE - IPv4: $(get_ipv4 "$NETWORK_IFACE")"
    step "Configurazione guidata"
    choose_role
    validate_role
    generate_node_name
    ask_tx_ip
    show_configuration
    ok "Configurazione definita."
    step "Installazione software"
    install_packages
    step "Preparazione hardware audio"
    stop_existing_services
    enable_pi_analog_audio
    check_hardware
    check_tx_reachability
    step "Scrittura configurazione"
    write_config
    ok "Configurazione salvata in $CONFIG_FILE."
    step "Installazione motore Roc"
    write_runner
    ok "Motore audio installato."
    step "Installazione monitor e dashboard"
    write_monitor
    ok "Monitor installato."
    step "Configurazione servizi automatici"
    write_remote_access
    write_updater
    write_systemd_services
    enable_services
    step "Verifica finale"
    print_diagnostics
    ask_reboot
}

main "$@"
