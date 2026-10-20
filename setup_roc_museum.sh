#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RETE MUSEO - AudioOverNetwork
# Setup unico e guidato per Raspberry Pi TX/RX - v4.4
#
# Uso normale:
#   sudo ./setup_roc_museum.sh
#
# Gli argomenti restano disponibili solo per automazione avanzata:
#   --role tx|rx   --tx-ip A.B.C.D   --name NOME
# =============================================================================

VERSION="4.4"
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
    apt-get install -y roc-toolkit-tools alsa-utils iproute2 python3 ethtool
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
    systemctl stop roc-museum.service >/dev/null 2>&1 || true
    systemctl stop roc-museum-monitor.service >/dev/null 2>&1 || true
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
REGISTRY={}
REGISTRY_LOCK=threading.Lock()

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

def last_roc_error():
    code,output=run(["journalctl","-u","roc-museum.service","-n","20","--no-pager","-o","cat"])
    if not output:
        return ""
    lines=[line.strip() for line in output.splitlines() if line.strip()]
    preferred=[]
    for line in lines:
        low=line.lower()
        if "[err]" in low or "error" in low or "failed" in low or "can't " in low or "cannot " in low or "unbound variable" in low or "non rilevata" in low:
            preferred.append(line)
    source=preferred if preferred else lines
    if not source:
        return ""
    return source[-1][-240:]

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

def get_volume_percent():
    code,output=run(["amixer","-c","0","get","PCM"])
    if code!=0:
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
    code,output=run(["amixer","-c","0","sset","PCM",str(value)+"%"])
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
    snapshot={"name":config.get("NODE_NAME",socket.gethostname()),"hostname":socket.gethostname(),"role":role,"software_version":config.get("SOFTWARE_VERSION",""),"timestamp":time.time(),"roc_service":service.get("active","unknown"),"roc_service_sub":service.get("sub","unknown"),"roc_result":service.get("result",""),"roc_restarts":service.get("restarts",0),"roc_process":roc_process,"roc_last_error":last_roc_error(),"audio_device":audio_device_state(role),"volume_percent":get_volume_percent() if role=="rx" else None,"network":network_state(interface),"multicast":{"group":config.get("MULTICAST_ADDR",""),"state":multicast_state(role,interface,config.get("MULTICAST_ADDR",""),roc_process)},"temperature_c":temperature(),"throttled":throttled()}
    try: snapshot["load_1m"]=round(os.getloadavg()[0],2)
    except OSError: snapshot["load_1m"]=None
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
        snapshot["source_ip"]=source[0]
        snapshot["received_at"]=time.time()
        name=snapshot.get("name",source[0])
        with REGISTRY_LOCK: REGISTRY[name]=snapshot

def command_listener_loop(config):
    port=int(config.get("CONTROL_PORT","19091"))
    tx_ip=config.get("TX_IP","")
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    sock.bind(("0.0.0.0",port))
    while True:
        payload,source=sock.recvfrom(4096)
        if tx_ip and source[0]!=tx_ip:
            continue
        try:
            message=json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError,json.JSONDecodeError):
            continue
        if message.get("command")=="set_volume":
            set_volume_percent(message.get("value"),persist=True)

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
    message={"command":command}
    if value is not None:
        message["value"]=value
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    try:
        sock.sendto(json.dumps(message,separators=(",",":")).encode("utf-8"),(source_ip,port))
    except OSError as exc:
        return False,str(exc)
    finally:
        sock.close()
    return True,"comando inviato"

def system_status(config):
    now=time.time()
    with REGISTRY_LOCK: nodes=[dict(item) for item in REGISTRY.values()]
    for node in nodes:
        received_at=node.get("received_at",node.get("timestamp",0))
        age=max(0,now-received_at)
        online=age<=OFFLINE_AFTER
        problems=[]
        if not online: problems.append("offline")
        if node.get("roc_service")!="active": problems.append("roc_service")
        if not node.get("roc_process"): problems.append("roc_process")
        if not node.get("audio_device"): problems.append("audio_device")
        if not node.get("network",{}).get("carrier"): problems.append("ethernet")
        state="OK"
        if problems: state="ATTENZIONE"
        if "offline" in problems: state="OFFLINE"
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

PAGE=r'''<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>RETE MUSEO - AudioOverNetwork</title><style>body{font-family:system-ui,sans-serif;background:#111827;color:#e5e7eb;margin:0;padding:24px}main{max-width:1150px;margin:auto}h1{margin:0 0 6px}.sub{color:#9ca3af;margin-bottom:22px}.summary,.grid{display:grid;gap:14px}.summary{grid-template-columns:repeat(auto-fit,minmax(150px,1fr));margin-bottom:18px}.grid{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.box,.card{background:#1f2937;border:1px solid #374151;border-radius:12px;padding:16px}.num{font-size:28px;font-weight:700}.head{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}.badge{font-size:12px;font-weight:700;padding:5px 9px;border-radius:999px}.OK{background:#064e3b;color:#a7f3d0}.ATTENZIONE{background:#78350f;color:#fde68a}.OFFLINE{background:#7f1d1d;color:#fecaca}.row{display:flex;justify-content:space-between;gap:12px;border-top:1px solid #374151;padding:8px 0;font-size:14px}.label{color:#9ca3af}.value{text-align:right}footer{color:#6b7280;margin-top:22px;font-size:13px}code{color:#93c5fd}.volume{border-top:1px solid #374151;padding:12px 0}.volumeHead{display:flex;justify-content:space-between;gap:12px;margin-bottom:8px}.volume input[type=range]{width:100%}.volumeMsg{min-height:18px;color:#9ca3af;font-size:12px;margin-top:4px}</style></head><body><main><h1>RETE MUSEO - AudioOverNetwork</h1><div class="sub">Monitor centrale TX · monitoraggio e controllo RX</div><div id="summary" class="summary"></div><div id="nodes" class="grid"></div><footer id="footer"></footer><script>function esc(value){var text='';if(value!=null){text=String(value);}return text.replace(/[&<>"']/g,function(c){var map={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'};return map[c];});}function boolLabel(value,okText,koText){return value?okText:koText;}function multicastLabel(state){var map={sending:'trasmissione attiva',joined:'gruppo agganciato',stopped:'trasmissione ferma',not_joined:'gruppo non agganciato'};return map[state]||state||'n/d';}function volumeBlock(n){if(n.role!=='rx'){return '';}var value=(n.volume_percent==null)?0:Math.max(0,Math.min(100,Number(n.volume_percent)));return '<div class="volume"><div class="volumeHead"><span class="label">Volume uscita</span><strong id="vol-label-'+esc(n.name)+'">'+esc(value)+' %</strong></div><input class="volumeRange" type="range" min="0" max="100" step="1" value="'+esc(value)+'" data-node="'+esc(n.name)+'" aria-label="Volume '+esc(n.name)+'"><div class="volumeMsg" id="vol-msg-'+esc(n.name)+'"></div></div>';}function nodeCard(n){var net=n.network||{};var multi=n.multicast||{};var speed='';if(net.speed_mbps){speed=' · '+esc(net.speed_mbps)+' Mb/s';}var temp='n/d';if(n.temperature_c!=null){temp=esc(n.temperature_c)+' °C';}var service=esc(n.roc_service||'n/d');if(n.roc_service_sub){service+=' / '+esc(n.roc_service_sub);}var err='';if(n.roc_last_error){err='<div class="row"><span class="label">Ultimo errore Roc</span><span class="value">'+esc(n.roc_last_error)+'</span></div>';}return '<article class="card"><div class="head"><strong>'+esc(n.name)+' · '+esc((n.role||'').toUpperCase())+'</strong><span class="badge '+esc(n.state)+'">'+esc(n.state)+'</span></div><div class="row"><span class="label">IPv4</span><span class="value">'+esc(net.ipv4||'n/d')+'</span></div><div class="row"><span class="label">Ethernet</span><span class="value">'+boolLabel(net.carrier,'collegata','non collegata')+speed+'</span></div><div class="row"><span class="label">Servizio Roc</span><span class="value">'+service+'</span></div><div class="row"><span class="label">Processo Roc</span><span class="value">'+boolLabel(n.roc_process,'in esecuzione','non in esecuzione')+'</span></div><div class="row"><span class="label">Riavvii Roc</span><span class="value">'+esc(n.roc_restarts||0)+'</span></div><div class="row"><span class="label">Dispositivo audio</span><span class="value">'+boolLabel(n.audio_device,'rilevato','non rilevato')+'</span></div><div class="row"><span class="label">Multicast</span><span class="value"><code>'+esc(multi.group)+'</code> · '+esc(multicastLabel(multi.state))+'</span></div>'+volumeBlock(n)+err+'<div class="row"><span class="label">Temperatura</span><span class="value">'+temp+'</span></div><div class="row"><span class="label">Load 1m</span><span class="value">'+esc(n.load_1m)+'</span></div><div class="row"><span class="label">Heartbeat</span><span class="value">'+esc(n.age_seconds)+' s fa</span></div></article>';}async function refresh(){try{var response=await fetch('/api/status',{cache:'no-store'});var data=await response.json();var okCount=0;var offCount=0;for(var i=0;i<data.nodes.length;i++){if(data.nodes[i].state==='OK'){okCount++;}if(data.nodes[i].state==='OFFLINE'){offCount++;}}document.getElementById('summary').innerHTML='<div class="box"><div class="label">Nodi</div><div class="num">'+data.nodes.length+'</div></div><div class="box"><div class="label">OK</div><div class="num">'+okCount+'</div></div><div class="box"><div class="label">Offline</div><div class="num">'+offCount+'</div></div><div class="box"><div class="label">RX previsti</div><div class="num">'+data.expected_rx+'</div></div>';var html='';for(var j=0;j<data.nodes.length;j++){html+=nodeCard(data.nodes[j]);}if(!html){html='<div class="box">Nessun nodo rilevato.</div>';}document.getElementById('nodes').innerHTML=html;bindVolumeControls();document.getElementById('footer').textContent='Aggiornato '+new Date().toLocaleTimeString()+' · refresh 2 s · offline dopo 15 s';}catch(error){document.getElementById('footer').textContent='Errore dashboard: '+error;}}async function sendVolume(node,value){var msg=document.getElementById('vol-msg-'+node);if(msg){msg.textContent='Invio '+value+' %...';}try{var response=await fetch('/api/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({node:node,command:'set_volume',value:Number(value)})});var result=await response.json();if(!response.ok||!result.ok){throw new Error(result.message||'comando non riuscito');}if(msg){msg.textContent='Comando inviato';}}catch(error){if(msg){msg.textContent='Errore: '+error.message;}}}function bindVolumeControls(){var controls=document.querySelectorAll('.volumeRange');for(var i=0;i<controls.length;i++){(function(control){var node=control.getAttribute('data-node');control.addEventListener('input',function(){var label=document.getElementById('vol-label-'+node);if(label){label.textContent=control.value+' %';}});control.addEventListener('change',function(){sendVolume(node,control.value);});})(controls[i]);}}refresh();setInterval(refresh,2000);</script></main></body></html>'''

class Handler(BaseHTTPRequestHandler):
    config={}
    def log_message(self,fmt,*args): return
    def reply(self,code,content_type,payload):
        self.send_response(code);self.send_header("Content-Type",content_type);self.send_header("Cache-Control","no-store");self.send_header("Content-Length",str(len(payload)));self.end_headers();self.wfile.write(payload)
    def do_GET(self):
        if self.path=="/" or self.path=="/index.html": self.reply(200,"text/html; charset=utf-8",PAGE.encode("utf-8"));return
        if self.path=="/api/status": self.reply(200,"application/json; charset=utf-8",json.dumps(system_status(self.config),indent=2).encode("utf-8"));return
        if self.path=="/healthz": self.reply(200,"text/plain; charset=utf-8",b"ok\n");return
        self.reply(404,"text/plain; charset=utf-8",b"Not found\n")
    def do_POST(self):
        if self.path!="/api/control":
            self.reply(404,"application/json; charset=utf-8",b'{"ok":false,"message":"Not found"}');return
        try:
            length=min(int(self.headers.get("Content-Length","0")),4096)
            data=json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError,UnicodeDecodeError,json.JSONDecodeError):
            self.reply(400,"application/json; charset=utf-8",b'{"ok":false,"message":"Richiesta non valida"}');return
        node=str(data.get("node",""))
        command=str(data.get("command",""))
        if command!="set_volume":
            self.reply(400,"application/json; charset=utf-8",b'{"ok":false,"message":"Comando non supportato"}');return
        try:
            value=max(0,min(100,int(data.get("value"))))
        except (TypeError,ValueError):
            self.reply(400,"application/json; charset=utf-8",b'{"ok":false,"message":"Volume non valido"}');return
        ok,message=send_control(self.config,node,command,value)
        payload=json.dumps({"ok":ok,"message":message,"node":node,"value":value}).encode("utf-8")
        self.reply(200 if ok else 409,"application/json; charset=utf-8",payload)

def main():
    config=read_config();role=config.get("ROLE","")
    if role=="rx":
        restore_saved_volume()
    heartbeat=threading.Thread(target=heartbeat_loop,args=(config,),daemon=True);heartbeat.start()
    if role=="tx":
        listener=threading.Thread(target=listener_loop,args=(config,),daemon=True);listener.start()
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
    start_service roc-museum-monitor.service
    start_service roc-museum.service
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
