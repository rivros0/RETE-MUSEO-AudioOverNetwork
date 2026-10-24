#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RETE MUSEO - AudioOverNetwork
# Setup unico e guidato per Raspberry Pi TX/RX - v4.9
#
# Uso normale:
#   sudo ./setup_roc_museum.sh
#
# Gli argomenti restano disponibili solo per automazione avanzata:
#   --role tx|rx   --tx-ip A.B.C.D   --name NOME
# =============================================================================

VERSION="4.9"
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
    apt-get install -y roc-toolkit-tools alsa-utils iproute2 python3 ethtool ffmpeg util-linux mount exfatprogs ntfs-3g tzdata
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
from urllib.parse import unquote
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
VOLUME_STATE_FILE="/var/lib/roc-museum/volume"
HEARTBEAT_INTERVAL=5
OFFLINE_AFTER=15
CONTROL_RESULTS={}
MUTED=False
RESUME_VOLUME=None
REGISTRY={}
STUDIO=None
REGISTRY_LOCK=threading.Lock()

# Passive packet capture: never opens ALSA or binds Roc's UDP port.
# Requires CAP_NET_RAW (the existing systemd monitor runs as root).
class AudioMeter:
    def __init__(self):
        self.lock=threading.Lock()
        self.frames=deque()
        self.last_clip=None
        self.error="In attesa di RTP L16"

    def feed(self, packet, now=None):
        now=time.monotonic() if now is None else now
        if len(packet)<12 or packet[0]>>6!=2:
            return
        pt=packet[1]&127
        if pt not in (10,11):
            with self.lock: self.error="Formato RTP non supportato (PT %d)"%pt
            return
        channels=2 if pt==10 else 1
        offset=12+4*(packet[0]&15)
        if len(packet)<offset: return
        if packet[0]&16:
            if len(packet)<offset+4: return
            offset+=4+4*struct.unpack_from("!H",packet,offset+2)[0]
        end=len(packet)
        if packet[0]&32:
            padding=packet[-1]
            if not padding or padding>end-offset: return
            end-=padding
        if end<=offset or (end-offset)%(2*channels): return
        samples=struct.unpack("!%dh"%((end-offset)//2),packet[offset:end])
        stats=[]
        for channel in range(channels):
            values=samples[channel::channels]
            stats.append((max(abs(v) for v in values),sum(v*v for v in values),len(values),sum(v in (-32768,32767) for v in values)))
        with self.lock:
            self.error=""
            if any(v[3] for v in stats): self.last_clip=now
            self.frames.append((now,stats))
            self.prune(now)

    def prune(self, now):
        while self.frames and self.frames[0][0]<now-5: self.frames.popleft()
        # Bound memory even in case of excessive traffic.
        while len(self.frames)>10000: self.frames.popleft()

    def snapshot(self):
        now=time.monotonic()
        with self.lock:
            self.prune(now)
            frames=list(self.frames)
            error=self.error
            clip_age=None if self.last_clip is None else round(now-self.last_clip,1)
        fresh=bool(frames and now-frames[-1][0]<2)
        result={"available":fresh,"error":error if error else ("" if fresh else "Nessun pacchetto audio recente"),"window_seconds":5,"clip_age_seconds":clip_age,"channels":[]}
        if not fresh: return result
        channels=len(frames[-1][1])
        def db(value): return round(max(-96,20*math.log10(value/32768)),1) if value else -96.0
        for ch in range(channels):
            values=[f[1][ch] for f in frames if len(f[1])==channels]
            peak=max(v[0] for v in values)
            rms=math.sqrt(sum(v[1] for v in values)/sum(v[2] for v in values))
            result["channels"].append({"peak_dbfs":db(peak),"rms_dbfs":db(rms),"full_scale_samples":sum(v[3] for v in values)})
        return result

METER=AudioMeter()

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
                    METER.feed(packet[ihl+8:ihl+length])
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
    result={"interface":interface,"ipv4":local_ipv4(interface),"carrier":False,"speed_mbps":None}
    if not os.path.isdir(path): return result
    if read_text(os.path.join(path,"carrier"))=="1": result["carrier"]=True
    speed=read_text(os.path.join(path,"speed"))
    try: result["speed_mbps"]=int(speed)
    except ValueError: result["speed_mbps"]=None
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
    if code!=0: return None
    match=re.search(r"0x[0-9a-fA-F]+",output)
    if match is None: return None
    return match.group(0)

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
    return snapshot

def heartbeat_loop(config):
    role=config.get("ROLE","")
    tx_ip=config.get("TX_IP","")
    port=int(config.get("MONITOR_PORT","19090"))
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    while True:
        snapshot=build_snapshot(config)
        if role=="tx":
            snapshot["received_at"]=time.time()
            with REGISTRY_LOCK: REGISTRY[snapshot["name"]]=snapshot
        else:
            payload=json.dumps(snapshot,separators=(",",":")).encode("utf-8")
            try: sock.sendto(payload,(tx_ip,port))
            except OSError: pass
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

def apply_control(command,value):
    global MUTED,RESUME_VOLUME
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
        ok=apply_control(message.get("command"),message.get("value"))
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
    def sort_key(node):
        priority=1
        if node.get("role")=="tx": priority=0
        return priority,node.get("name","")
    nodes.sort(key=sort_key)
    return {"system":"RETE MUSEO - AudioOverNetwork","generated_at":now,"expected_rx":int(config.get("EXPECTED_RX_COUNT","3")),"nodes":nodes}

PAGE=r'''<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>RETE MUSEO - AudioOverNetwork</title><style>body{font-family:system-ui,sans-serif;background:#111827;color:#e5e7eb;margin:0;padding:24px}main{max-width:1150px;margin:auto}h1{margin:0 0 6px}.sub{color:#9ca3af;margin-bottom:22px}.summary,.grid{display:grid;gap:14px}.summary{grid-template-columns:repeat(auto-fit,minmax(150px,1fr));margin-bottom:18px}.grid{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.box,.card{background:#1f2937;border:1px solid #374151;border-radius:12px;padding:16px}.num{font-size:28px;font-weight:700}.head{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}.badge{font-size:12px;font-weight:700;padding:5px 9px;border-radius:999px}.OK{background:#064e3b;color:#a7f3d0}.ATTENZIONE{background:#78350f;color:#fde68a}.OFFLINE{background:#7f1d1d;color:#fecaca}.row{display:flex;justify-content:space-between;gap:12px;border-top:1px solid #374151;padding:8px 0;font-size:14px}.label{color:#9ca3af}.value{text-align:right}footer{color:#6b7280;margin-top:22px;font-size:13px}code{color:#93c5fd}.volume{border-top:1px solid #374151;padding:12px 0}.volumeHead{display:flex;justify-content:space-between;gap:12px;margin-bottom:8px}.volumeNumber{width:75px;padding:7px;background:#111827;color:#fff;border:1px solid #6b7280;border-radius:5px}.volume button{padding:7px;margin-top:8px;cursor:pointer}.muteButton[aria-pressed=true]{background:#b91c1c;color:white}.volumeMsg{min-height:18px;color:#9ca3af;font-size:12px;margin-top:4px}.diag{border-top:1px solid #374151;padding-top:10px;margin-top:4px}.diag summary{cursor:pointer;color:#9ca3af;font-size:13px}.diagBody{padding-top:8px}.latency{border-top:1px solid #374151;padding:8px 0;font-size:14px}.meter{border-top:1px solid #374151;padding:12px 0}.meter progress{width:100%;height:14px;accent-color:#34d399}.meter.hot progress{accent-color:#fbbf24}.meter.clip progress{accent-color:#f87171}.meter small{display:block;color:#9ca3af;margin-top:6px}</style></head><body><main><h1>RETE MUSEO - AudioOverNetwork</h1><div class="sub">Monitor centrale TX · monitoraggio e controllo RX</div><div id="summary" class="summary"></div><div id="nodes" class="grid"></div><footer id="footer"></footer><script>function esc(value){var text='';if(value!=null){text=String(value);}return text.replace(/[&<>"']/g,function(c){var map={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'};return map[c];});}function boolLabel(value,okText,koText){return value?okText:koText;}function multicastLabel(state){var map={sending:'trasmissione attiva',joined:'gruppo agganciato',stopped:'trasmissione ferma',not_joined:'gruppo non agganciato'};return map[state]||state||'n/d';}var drafts={},feedback={},pending={},knownMute={},confirmed={};
function volumeBlock(n){if(n.role!=='rx')return '';if(confirmed[n.name]&&Date.now()<confirmed[n.name].until){n=Object.assign({},n,confirmed[n.name]);}var value=Object.prototype.hasOwnProperty.call(drafts,n.name)?drafts[n.name]:(n.volume_percent==null?'':n.volume_percent);knownMute[n.name]=!!n.muted;
return '<div class="volume"><form class="volumeForm" data-node="'+esc(n.name)+'"><label>Volume uscita (%) <input class="volumeNumber" type="number" min="0" max="100" step="1" required value="'+esc(value)+'" aria-label="Volume '+esc(n.name)+'" '+(!n.online?'disabled':'')+'></label> <button '+(!n.online||pending[n.name]?'disabled':'')+'>Applica</button> <button type="button" class="muteButton" aria-pressed="'+!!n.muted+'" '+(!n.online||pending[n.name]?'disabled':'')+'>'+(n.muted?'Riattiva audio':'Mute')+'</button></form><div role="status" aria-live="polite" class="volumeMsg" id="vol-msg-'+esc(n.name)+'">'+(feedback[n.name]||'')+'</div></div>';}
function latencyBlock(n){if(n.role!=='rx'){return '';}var target=n.target_latency||'n/d';var rtt=(n.network_rtt_ms==null)?'n/d':esc(n.network_rtt_ms)+' ms';return '<div class="latency"><div class="row"><span class="label">Latenza Roc target</span><span class="value">'+esc(target)+'</span></div><div class="row"><span class="label">RTT rete verso TX</span><span class="value">'+rtt+'</span></div></div>';}function diagnosticsBlock(n){var body='';if(n.roc_last_error){body+='<div class="row"><span class="label">Ultimo errore Roc</span><span class="value">'+esc(n.roc_last_error)+'</span></div>';}if(n.roc_last_warning){body+='<div class="row"><span class="label">Ultimo avviso Roc</span><span class="value">'+esc(n.roc_last_warning)+'</span></div>';}if(!body){body='<div class="row"><span class="label">Roc</span><span class="value">nessun errore recente</span></div>';}return '<details class="diag"><summary>Diagnostica Roc</summary><div class="diagBody">'+body+'</div></details>';}function meterBlock(n){
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
function nodeCard(n){var net=n.network||{};var multi=n.multicast||{};var speed='';if(net.speed_mbps){speed=' · '+esc(net.speed_mbps)+' Mb/s';}var temp='n/d';if(n.temperature_c!=null){temp=esc(n.temperature_c)+' °C';}var service=esc(n.roc_service||'n/d');if(n.roc_service_sub){service+=' / '+esc(n.roc_service_sub);}return '<article class="card"><div class="head"><strong>'+esc(n.name)+' · '+esc((n.role||'').toUpperCase())+'</strong><span class="badge '+esc(n.state)+'">'+esc(n.state)+'</span></div><div class="row"><span class="label">IPv4</span><span class="value">'+esc(net.ipv4||'n/d')+'</span></div><div class="row"><span class="label">Ethernet</span><span class="value">'+boolLabel(net.carrier,'collegata','non collegata')+speed+'</span></div><div class="row"><span class="label">Servizio Roc</span><span class="value">'+service+'</span></div><div class="row"><span class="label">Processo Roc</span><span class="value">'+boolLabel(n.roc_process,'in esecuzione','non in esecuzione')+'</span></div><div class="row"><span class="label">Riavvii Roc</span><span class="value">'+esc(n.roc_restarts||0)+'</span></div><div class="row"><span class="label">Dispositivo audio</span><span class="value">'+boolLabel(n.audio_device,'rilevato','non rilevato')+'</span></div><div class="row"><span class="label">Multicast</span><span class="value"><code>'+esc(multi.group)+'</code> · '+esc(multicastLabel(multi.state))+'</span></div>'+(n.role==='tx'?'<div class="row"><span class="label">Sorgente</span><span>'+esc(({playing:'Player',paused:'Player in pausa',live:'Ingresso mixer'}[n.studio_source])||'Ingresso mixer')+'</span></div>':'')+meterBlock(n)+latencyBlock(n)+volumeBlock(n)+'<div class="row"><span class="label">Temperatura</span><span class="value">'+temp+'</span></div><div class="row"><span class="label">Load 1m</span><span class="value">'+esc(n.load_1m)+'</span></div><div class="row"><span class="label">Heartbeat</span><span class="value">'+esc(n.age_seconds)+' s fa</span></div>'+diagnosticsBlock(n)+'</article>';}async function refresh(){try{var response=await fetch('/api/status',{cache:'no-store'});var data=await response.json();var okCount=0;var offCount=0;for(var i=0;i<data.nodes.length;i++){if(data.nodes[i].state==='OK'){okCount++;}if(data.nodes[i].state==='OFFLINE'){offCount++;}}document.getElementById('summary').innerHTML='<div class="box"><div class="label">Nodi</div><div class="num">'+data.nodes.length+'</div></div><div class="box"><div class="label">OK</div><div class="num">'+okCount+'</div></div><div class="box"><div class="label">Offline</div><div class="num">'+offCount+'</div></div><div class="box"><div class="label">RX previsti</div><div class="num">'+data.expected_rx+'</div></div>';var html='';for(var j=0;j<data.nodes.length;j++){html+=nodeCard(data.nodes[j]);}if(!html){html='<div class="box">Nessun nodo rilevato.</div>';}var active=document.activeElement;var focusedNode=active&&active.classList.contains('volumeNumber')?active.closest('form').dataset.node:null;document.getElementById('nodes').innerHTML=html;bindVolumeControls();if(focusedNode){document.querySelectorAll('.volumeForm').forEach(function(f){if(f.dataset.node===focusedNode)f.querySelector('input').focus();});}document.getElementById('footer').textContent='Aggiornato '+new Date().toLocaleTimeString()+' · refresh 2 s · offline dopo 15 s';}catch(error){document.getElementById('footer').textContent='Errore dashboard: '+error;}}function showFeedback(node,text){feedback[node]=text;var el=document.getElementById('vol-msg-'+node);if(el)el.innerHTML=text;}
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
async function session(){var r=await fetch('/api/session');var d=await r.json();authorized=d.authenticated;csrf=d.csrf||'';document.getElementById('login').hidden=authorized;document.getElementById('studio').hidden=!authorized;if(authorized)await library();refresh();}
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
PAGE=PAGE.replace("var data=await response.json();var okCount", "var data=await response.json();syncTxClock(data.generated_at);var okCount",1)

class Handler(BaseHTTPRequestHandler):
    config={}
    studio=None
    page=None
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
    def do_GET(self):
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
        if self.path=="/" or self.path=="/index.html": self.reply(200,"text/html; charset=utf-8",(self.page or PAGE).encode("utf-8"));return
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
    global STUDIO
    if sys.argv[1:]==["--set-password"]:
        set_password();return
    config=read_config();role=config.get("ROLE","")
    if sys.argv[1:]==["--restore-live"]:
        if role=="tx": subprocess.run(["systemctl","--no-block","start","roc-museum.service"],check=False,timeout=15)
        return
    if role=="rx":
        restore_saved_volume()
    threading.Thread(target=meter_loop,args=(config,),daemon=True).start()
    heartbeat=threading.Thread(target=heartbeat_loop,args=(config,),daemon=True);heartbeat.start()
    if role=="tx":
        listener=threading.Thread(target=listener_loop,args=(config,),daemon=True);listener.start()
        try:
            import importlib.util
            spec=importlib.util.spec_from_file_location("roc_studio","/usr/local/lib/roc-museum/studio.py")
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            engine=module.Studio(config,media=MEDIA_DIR,copy_lock=UPLOAD_LOCK)
            engine.start();STUDIO=engine;Handler.studio=engine
            snippet=Path("/usr/local/share/roc-museum/studio.html").read_text()
            Handler.page=PAGE.replace('<div id="summary"',snippet+'<div id="summary"')
        except Exception as error:
            print("Regia non disponibile: "+str(error),flush=True)
        Handler.config=config
        port=int(config.get("MONITOR_HTTP_PORT","8080"))
        server=ThreadingHTTPServer(("0.0.0.0",port),Handler)
        print("Dashboard in ascolto sulla porta "+str(port),flush=True)
        server.serve_forever();return
    commands=threading.Thread(target=command_listener_loop,args=(config,),daemon=True);commands.start()
    while True: time.sleep(3600)
if __name__=="__main__": main()
PY_MONITOR
    chmod 0755 "$MONITOR_TARGET"
    install -d -m 0755 /usr/local/lib/roc-museum /usr/local/share/roc-museum
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

    def start(self):
        try: self._ensure_audio()
        except Exception as error:
            self.error=str(error);self._live()
        self.thread=threading.Thread(target=self._worker,daemon=True);self.thread.start()

    def close(self):
        self.shutdown.set()
        if self.thread: self.thread.join(timeout=5)
        with self.lock:
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
            bus=factory(self.config);bus.configure(self.ducking());bus.start()
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

    def _terminate(self):
        if self.bus: self.bus.detach()
        if self.encoder:
            if self.encoder.poll() is None: self.encoder.terminate()
            try: self.encoder.wait(timeout=3)
            except subprocess.TimeoutExpired: self.encoder.kill();self.encoder.wait(timeout=3)
            if self.encoder.stdout: self.encoder.stdout.close()
        self.encoder=None
        if self.error_log: self.error_log.close();self.error_log=None

    def _live(self):
        self._terminate();self.plan=None
        if not self.bus or not self.bus.snapshot()['active']:
            if self.bus: self.bus.close();self.bus=None
            self.sender=None;self.bus_marker.unlink(missing_ok=True)
            run(['systemctl','start','roc-museum.service'])
        self.status='live';self.origin='mixer';self.position=0;self.track=None;self.duration=0

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

    def _play(self,name,position=0,origin='manual',loop=False,deadline=None):
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

    def _position(self):
        if self.bus and self.status in ('playing','paused'): return min(self.duration,self.bus.snapshot()['position'])
        return self.position

    def _cancel_plan(self,state='interrupted'):
        if self.plan:
            self._record(self.plan['event'],self.plan['occurrence'],state)
            if self.bus: self.bus.set_deadline(None)
            self.plan=None

    def command(self,data):
        with self.lock:
            command=data.get('command')
            if command=='ducking':
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
                self._play(data.get('name'),origin='manual',loop=data.get('loop') is True);self.manual_hold=True
            elif command=='pause':
                if self.status!='playing': raise ValueError('Nessuna traccia in riproduzione')
                self.position=self._position();self.bus.pause(True);self.status='paused';self.manual_hold=True
                self._cancel_plan('suspended');self.origin='manual'
            elif command=='resume':
                if self.status!='paused': raise ValueError('Nessuna traccia in pausa')
                self.bus.pause(False);self.status='playing';self.origin='manual';self.manual_hold=True
            elif command=='seek':
                if self.status not in ('playing','paused'): raise ValueError('Nessuna traccia selezionata')
                value=data.get('position');was_paused=self.status=='paused'
                # _play validates position before changing the decoder.
                self._play(self.track,value,'manual',self.loop);self.manual_hold=True
                self._cancel_plan('suspended')
                if was_paused: self.bus.pause(True);self.status='paused'
            elif command=='loop':
                if type(data.get('enabled')) is not bool: raise ValueError('Loop non valido')
                self.loop=data['enabled']
                if self.status in ('playing','paused'):
                    self._cancel_plan('suspended');self.manual_hold=True;self.origin='manual'
            elif command=='stop':
                self._cancel_plan('suspended');self._live();self.manual_hold=True
            else: raise ValueError('Comando player non valido')
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            rows=self.db.execute('SELECT event,occurrence,time,state,message FROM runs ORDER BY time DESC LIMIT 30').fetchall()
            return {'status':self.status,'track':self.track,'position':round(self._position(),2),'duration':self.duration,'loop':self.loop,'origin':self.origin,'error':self.error,'automation_enabled':self._setting('enabled'),'manual_hold':self.manual_hold,'queue':[e['name'] for e in self.queue],'timezone':'Europe/Rome','events':self.events(),'next_events':self.next_events(),'sender_running':bool(self.sender and self.sender.poll() is None),'audio_bus':self.bus.snapshot() if self.bus else None,'ducking':self.ducking(),'system_time':dt.datetime.now(ZoneInfo('Europe/Rome')).isoformat(),'plan':{k:v for k,v in self.plan.items() if k!='event'} if self.plan else None,'history':[dict(zip(('event','occurrence','time','state','message'),r)) for r in rows]}

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
                elif self.loop: self._play(self.track,origin=self.origin,loop=True)
                else: self._live()
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
        self.input_db=-96.;self.active=False

    def mix(self,music,microphone):
        mic=pcm_samples(microphone);song=pcm_samples(music)
        duration=len(mic)/(2*self.rate)
        rms=math.sqrt(sum(x*x for x in mic)/max(1,len(mic)))/32768
        self.input_db=max(-96.,20*math.log10(max(rms,1e-12)))
        if self.enabled and self.input_db>=self.threshold_db: self.hold=.5
        else: self.hold=max(0.,self.hold-duration)
        self.active=self.enabled and self.hold>0
        target=10**(self.reduction_db/20) if self.active else 1.
        previous=self.gain
        tau=.03 if target<previous else .8
        self.gain=target+(previous-target)*math.exp(-duration/tau)
        # Gain ramp avoids discontinuities; the mic is never multiplied by the duck gain.
        raw=[int(m+(song[i] if i<len(song) else 0)*(previous+(self.gain-previous)*i/max(1,len(mic)-1))) for i,m in enumerate(mic)]
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
</style>
<h2>Regia audio TX</h2>
<p class="hint">Un solo programma per tutti gli RX. Il microfono degli annunci rimane sempre udibile, anche durante musica, pausa e intervalli.</p>
<h3>Player</h3><p id="playerState" aria-live="polite">Caricamento…</p>
<label>Traccia <select id="trackSelect" aria-label="Traccia dalla libreria"></select></label>
<button data-player="play">▶ Riproduci selezione</button><button data-player="pause">Pausa musica</button><button data-player="resume">Riprendi traccia</button><button data-player="stop">Stop musica / solo microfono</button>
<label><input type="checkbox" id="playerLoop"> Ripeti traccia</label>
<progress id="playerProgress" max="1" value="0" style="width:100%" aria-label="Avanzamento traccia"></progress>
<form id="seekForm"><label>Posizione (secondi) <input id="seekPosition" type="number" min="0" step="0.1" required></label><button>Vai</button><span id="positionText"></span></form>
<p id="groupState"></p>
<h3>Annunci dal microfono · ducking</h3>
<p id="microphoneState" role="status"></p>
<form id="duckingForm"><label><input name="enabled" type="checkbox" checked> Abbassa automaticamente la musica durante gli annunci</label>
<label>Soglia voce (dBFS) <input name="threshold_db" type="number" min="-60" max="-6" step="1" value="-36" required></label>
<label>Attenuazione musica (dB) <input name="reduction_db" type="number" min="-40" max="0" step="1" value="-18" required></label><button>Applica ducking</button></form>
<p class="hint">Il microfono non viene attenuato dal ducking. Se il rumore di fondo fa abbassare la musica, alza la soglia (per esempio da −36 a −30 dBFS). Il volume della musica torna gradualmente normale dopo l’annuncio.</p>
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
<h3>Explorer USB</h3><button id="scanUSB">Rileva pennette</button><label>Dispositivo <select id="usbDevice"></select></label><button id="openUSB">Apri</button><button id="ejectUSB">Espelli</button>
<p id="usbPath">Nessuna pennetta aperta</p><button id="usbParent">Cartella superiore</button><ul id="usbEntries"></ul>
<p class="hint">Le nuove pennette sono montate in sola lettura. Importa i brani nella libreria prima di scollegarle.</p>
<p id="studioMessage" role="status" aria-live="polite"></p>
</section>
<script>
(function(){
'use strict';
var currentEvents=[],eventTracks=[],usbPath='',usbOpened='',inFlight=false,duckInitialized=false;
function el(id){return document.getElementById(id);}
function message(text){el('studioMessage').textContent=text;}
async function api(path,data){
  var options={cache:'no-store'};
  if(data!==undefined){options.method='POST';options.headers={'Content-Type':'application/json','X-CSRF-Token':csrf};options.body=JSON.stringify(data);}
  var r=await fetch(path,options),d=await r.json();
  if(!r.ok){if(r.status===401){authorized=false;el('studioTools').hidden=true;await session();}throw new Error(d.message||'Operazione fallita');}
  return d;
}
async function perform(action){try{await action();}catch(error){message(error.message);}}
function option(select,value,label){var o=document.createElement('option');o.value=value;o.textContent=label;select.appendChild(o);}
function button(label,action){var b=document.createElement('button');b.type='button';b.textContent=label;b.onclick=action;return b;}
library=async function(){
  var data=await api('/api/media'),old=el('trackSelect').value,eventOld=el('eventTrack').value;
  el('library').replaceChildren();el('trackSelect').replaceChildren();el('eventTrack').replaceChildren();
  data.files.forEach(function(f){
    var li=document.createElement('li');li.textContent=f.name+' ('+(f.size/1048576).toFixed(1)+' MB) ';
    li.appendChild(button('Seleziona',function(){el('trackSelect').value=f.name;}));
    var remove=button('Elimina traccia',function(){
      if(!confirm('Eliminare definitivamente '+f.name+' dalla libreria del TX?'))return;
      perform(async function(){remove.disabled=true;try{var d=await api('/api/media/delete',{name:f.name});await library();message(d.message);}finally{remove.disabled=false;}});
    });remove.className='danger';li.appendChild(remove);el('library').appendChild(li);
    option(el('trackSelect'),f.name,f.name);option(el('eventTrack'),f.name,f.name);
  });
  if(data.files.some(function(f){return f.name===old;}))el('trackSelect').value=old;
  if(data.files.some(function(f){return f.name===eventOld;}))el('eventTrack').value=eventOld;
};
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
    var s=await api('/api/studio'),bus=s.audio_bus;
    el('playerState').textContent=({live:'Solo microfono / ingresso mixer',playing:'In riproduzione',paused:'Musica in pausa'}[s.status]||s.status)+(s.track?' · '+s.track:'')+' · origine: '+(s.origin==='manual'?'regia':s.origin.startsWith('calendar:')?'calendario':'ingresso')+(s.error?' · Errore: '+s.error:'');
    el('positionText').textContent=s.position.toFixed(1)+' / '+s.duration.toFixed(1)+' s';el('seekPosition').max=Math.max(0,s.duration-0.01);el('playerProgress').max=s.duration||1;el('playerProgress').value=s.position;
    if(s.status!=='live')el('playerLoop').checked=s.loop;
    el('groupState').textContent=s.plan?'Gruppo: traccia '+(s.plan.index+1)+'/'+s.plan.tracks.length+' · passaggio '+s.plan.cycle+'/'+(s.plan.repetitions||'fino a fine fascia')+(s.plan.next_at?' · prossimo passaggio '+new Date(s.plan.next_at*1000).toLocaleTimeString('it-IT',{timeZone:'Europe/Rome'}):''):'';
    el('microphoneState').textContent=bus?(bus.microphone_online?'Microfono collegato':'ATTENZIONE: '+bus.microphone_error)+' · ingresso '+bus.microphone_dbfs+' dBFS · musica '+bus.music_gain_db+' dB'+(bus.ducking_active?' · DUCKING ATTIVO':''):'Ingresso diretto: il bus annunci si avvia con la regia.';
    if(!duckInitialized){var duck=el('duckingForm');duck.elements.namedItem('enabled').checked=s.ducking.enabled;duck.elements.namedItem('threshold_db').value=s.ducking.threshold_db;duck.elements.namedItem('reduction_db').value=s.ducking.reduction_db;duckInitialized=true;}
    el('automationState').textContent=(s.automation_enabled?'Calendario abilitato':'Calendario disabilitato')+(s.manual_hold?' · sospeso dalla regia manuale':'')+(s.queue.length?' · in attesa: '+s.queue.join(', '):'');
    el('nextEvents').textContent='Prossimi eventi: '+(s.next_events||[]).map(function(e){return e.name+' · '+new Date(e.at).toLocaleString('it-IT',{timeZone:'Europe/Rome'});}).join(' | ');
    currentEvents=s.events;renderEvents();el('eventHistory').replaceChildren();
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
      document.querySelectorAll('#weekdays input').forEach(function(c){c.checked=e.weekdays.includes(Number(c.value));});el('eventLegend').textContent='Modifica evento';form.scrollIntoView({behavior:'smooth'});
    }));
    actions.appendChild(button('Elimina evento',function(){if(confirm('Eliminare l’evento '+e.name+'?'))perform(async function(){await api('/api/calendar/delete',{id:e.id});await update();});}));
    tr.appendChild(actions);el('eventRows').appendChild(tr);
  });
}
document.querySelectorAll('[data-player]').forEach(function(b){b.onclick=function(){perform(async function(){var data={command:b.dataset.player};if(data.command==='play'){data.name=el('trackSelect').value;data.loop=el('playerLoop').checked;}await api('/api/player',data);await update();});};});
el('playerLoop').onchange=function(){perform(async function(){await api('/api/player',{command:'loop',enabled:el('playerLoop').checked});await update();});};
el('seekForm').onsubmit=function(e){e.preventDefault();perform(async function(){await api('/api/player',{command:'seek',position:Number(el('seekPosition').value)});await update();});};
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
window.addEventListener('DOMContentLoaded',function(){update();setInterval(update,2000);});
})();
</script>
HTML_STUDIO
    chmod 0644 /usr/local/lib/roc-museum/studio.py /usr/local/lib/roc-museum/audio_bus.py /usr/local/share/roc-museum/studio.html
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
    write_systemd_services
    enable_services
    step "Verifica finale"
    print_diagnostics
    ask_reboot
}

main "$@"
