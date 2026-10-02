#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Rete Museo - Roc Museum Audio
# Installer unico per nodi TX e RX - v3.2
#
# TX: Focusrite Scarlett 2i4 + roc-send + dashboard Web centrale.
# RX: uscita analogica Raspberry Pi + roc-recv + heartbeat verso TX.
#
# Uso interattivo:
#   sudo ./setup_roc_museum.sh
#
# Uso non interattivo:
#   sudo ./setup_roc_museum.sh --role tx --name TX
#   sudo ./setup_roc_museum.sh --role rx --name RX1 --tx-ip 192.168.1.50
# =============================================================================

VERSION="3.2"
MULTICAST_ADDR="239.30.0.1"
RTP_PORT="10001"
SAMPLE_RATE="44100"
TARGET_LATENCY="100ms"
IO_LATENCY="20ms"
FRAME_LEN="4ms"
MONITOR_PORT="19090"
HTTP_PORT="8080"
EXPECTED_RX_COUNT="3"

CONFIG_FILE="/etc/roc-museum.conf"
RUNNER="/usr/local/sbin/roc-museum-run"
MONITOR="/usr/local/sbin/roc-museum-monitor"
AUDIO_UNIT="/etc/systemd/system/roc-museum.service"
MONITOR_UNIT="/etc/systemd/system/roc-museum-monitor.service"

ROLE=""
NODE_NAME=""
TX_IP=""
NETWORK_IFACE=""
REBOOT_REQUIRED="no"

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'ATTENZIONE: %s\n' "$*" >&2; }
fail() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "Eseguire lo script con sudo."
}

validate_ipv4() {
    local ip="$1" part
    local IFS='.'
    local -a octets
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for part in "${octets[@]}"; do
        [[ "$part" =~ ^[0-9]+$ ]] || return 1
        [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --role) [ "$#" -ge 2 ] || fail "Manca --role"; ROLE="$2"; shift 2 ;;
            --name) [ "$#" -ge 2 ] || fail "Manca --name"; NODE_NAME="$2"; shift 2 ;;
            --tx-ip) [ "$#" -ge 2 ] || fail "Manca --tx-ip"; TX_IP="$2"; shift 2 ;;
            -h|--help)
                cat <<'HELP'
Uso:
  sudo ./setup_roc_museum.sh
  sudo ./setup_roc_museum.sh --role tx --name TX
  sudo ./setup_roc_museum.sh --role rx --name RX1 --tx-ip 192.168.1.50
HELP
                exit 0
                ;;
            *) fail "Argomento non riconosciuto: $1" ;;
        esac
    done
}

choose_role() {
    if [ -z "$ROLE" ]; then
        echo "1) TX - Scarlett 2i4, trasmissione Roc, dashboard"
        echo "2) RX - ricezione Roc, minijack Raspberry Pi"
        while true; do
            read -r -p "Scelta [1/2]: " answer
            if [ "$answer" = "1" ]; then ROLE="tx"; break; fi
            if [ "$answer" = "2" ]; then ROLE="rx"; break; fi
        done
    fi
    [ "$ROLE" = "tx" ] || [ "$ROLE" = "rx" ] || fail "Ruolo non valido: $ROLE"
}

ask_values() {
    local answer default_name
    if [ -z "$NODE_NAME" ]; then
        if [ "$ROLE" = "tx" ]; then default_name="TX"; else default_name="RX1"; fi
        read -r -p "Nome nodo [${default_name}]: " answer
        if [ -n "$answer" ]; then NODE_NAME="$answer"; else NODE_NAME="$default_name"; fi
    fi

    if [ "$ROLE" = "rx" ]; then
        while ! validate_ipv4 "$TX_IP" 2>/dev/null; do
            read -r -p "Indirizzo IPv4 del TX: " TX_IP
        done
    fi
}

detect_network() {
    if ip link show eth0 >/dev/null 2>&1; then
        NETWORK_IFACE="eth0"
    else
        NETWORK_IFACE="$(ip -o link show | awk -F': ' '$2 != "lo" {n=$2; sub(/@.*/,"",n); if (n ~ /^e/) {print n; exit}}')"
    fi
    [ -n "$NETWORK_IFACE" ] || fail "Nessuna interfaccia Ethernet rilevata."
}

get_ipv4() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'
}

install_packages() {
    info "Installazione dipendenze"
    apt-get update
    apt-cache show roc-toolkit-tools >/dev/null 2>&1 || fail "roc-toolkit-tools non disponibile. Usare Raspberry Pi OS recente basato su Debian Trixie."
    apt-get install -y roc-toolkit-tools alsa-utils python3 iproute2 ethtool
}

enable_analog_audio() {
    [ "$ROLE" = "rx" ] || return 0
    local cfg=""
    if [ -f /boot/firmware/config.txt ]; then cfg="/boot/firmware/config.txt"; fi
    if [ -z "$cfg" ] && [ -f /boot/config.txt ]; then cfg="/boot/config.txt"; fi
    if [ -n "$cfg" ] && ! grep -Eq '^[[:space:]]*dtparam=audio=on([[:space:]]|$)' "$cfg"; then
        printf '\n# Roc Museum Audio\ndtparam=audio=on\n' >> "$cfg"
        REBOOT_REQUIRED="yes"
    fi
}

hardware_report() {
    if [ "$ROLE" = "tx" ]; then
        if arecord -l 2>/dev/null | grep -Eqi 'Scarlett|Focusrite'; then
            info "Scarlett rilevata da ALSA"
        else
            warn "Scarlett non rilevata. Il servizio audio continuerà a ritentare tramite systemd."
        fi
    else
        if aplay -l 2>/dev/null | grep -Eqi 'Headphones|bcm2835'; then
            info "Uscita analogica Raspberry Pi rilevata"
        else
            warn "Uscita analogica non ancora rilevata; potrebbe essere necessario un riavvio."
            REBOOT_REQUIRED="yes"
        fi
    fi
}

write_config() {
    local local_ip
    local_ip="$(get_ipv4 "$NETWORK_IFACE")"
    if [ "$ROLE" = "tx" ]; then TX_IP="$local_ip"; fi

    cat > "$CONFIG_FILE" <<EOF_CONFIG
ROLE="$ROLE"
NODE_NAME="$NODE_NAME"
NETWORK_IFACE="$NETWORK_IFACE"
TX_IP="$TX_IP"
MULTICAST_ADDR="$MULTICAST_ADDR"
RTP_PORT="$RTP_PORT"
SAMPLE_RATE="$SAMPLE_RATE"
TARGET_LATENCY="$TARGET_LATENCY"
IO_LATENCY="$IO_LATENCY"
FRAME_LEN="$FRAME_LEN"
MONITOR_PORT="$MONITOR_PORT"
MONITOR_HTTP_PORT="$HTTP_PORT"
EXPECTED_RX_COUNT="$EXPECTED_RX_COUNT"
SOFTWARE_VERSION="$VERSION"
EOF_CONFIG
    chmod 0644 "$CONFIG_FILE"
}

write_runner() {
    cat > "$RUNNER" <<'EOF_RUNNER'
#!/usr/bin/env bash
set -euo pipefail
. /etc/roc-museum.conf

get_ipv4() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'
}

find_card() {
    local mode="$1" pattern="$2" line card
    if [ "$mode" = "capture" ]; then
        line="$(LC_ALL=C arecord -l 2>/dev/null | grep -Ei "$pattern" | head -n1 || true)"
    else
        line="$(LC_ALL=C aplay -l 2>/dev/null | grep -Ei "$pattern" | head -n1 || true)"
    fi
    card="$(printf '%s\n' "$line" | sed -n 's/.*card \([0-9][0-9]*\).*/\1/p')"
    [ -n "$card" ] || return 1
    printf 'plughw:%s,0\n' "$card"
}

ip route replace 239.0.0.0/8 dev "$NETWORK_IFACE"

if [ "$ROLE" = "tx" ]; then
    INPUT_DEVICE="$(find_card capture 'Scarlett|Focusrite')" || { echo "Scarlett non rilevata" >&2; exit 1; }
    exec roc-send -vv \
        -i "alsa://${INPUT_DEVICE}" \
        -s "rtp://${MULTICAST_ADDR}:${RTP_PORT}" \
        --rate="$SAMPLE_RATE" \
        --io-latency="$IO_LATENCY" \
        --frame-len="$FRAME_LEN"
fi

if [ "$ROLE" = "rx" ]; then
    LOCAL_IP="$(get_ipv4 "$NETWORK_IFACE")"
    [ -n "$LOCAL_IP" ] || { echo "IPv4 non disponibile su $NETWORK_IFACE" >&2; exit 1; }
    OUTPUT_DEVICE="$(find_card playback 'Headphones|bcm2835')" || { echo "Uscita analogica non rilevata" >&2; exit 1; }
    exec roc-recv -vv \
        -s "rtp://${MULTICAST_ADDR}:${RTP_PORT}" \
        --miface="$LOCAL_IP" \
        -o "alsa://${OUTPUT_DEVICE}" \
        --rate="$SAMPLE_RATE" \
        --target-latency="$TARGET_LATENCY" \
        --io-latency="$IO_LATENCY" \
        --frame-len="$FRAME_LEN"
fi

exit 1
EOF_RUNNER
    chmod 0755 "$RUNNER"
}

write_monitor() {
    cat > "$MONITOR" <<'PY_MONITOR'
#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG = "/etc/roc-museum.conf"
NODES = {}
LOCK = threading.Lock()
OFFLINE_AFTER = 15


def read_config():
    data = {}
    with open(CONFIG, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key] = value.strip().strip('"')
    return data


def run(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=2, check=False)
        return result.stdout.strip()
    except Exception:
        return ""


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except Exception:
        return ""


def local_ipv4(iface):
    output = run(["ip", "-4", "-o", "addr", "show", "dev", iface, "scope", "global"])
    for line in output.splitlines():
        fields = line.split()
        if len(fields) > 3:
            return fields[3].split("/")[0]
    return ""


def service_state():
    value = run(["systemctl", "is-active", "roc-museum.service"])
    if value:
        return value
    return "unknown"


def process_state(role):
    process = "roc-send" if role == "tx" else "roc-recv"
    return bool(run(["pgrep", "-x", process]))


def audio_state(role):
    if role == "tx":
        text = run(["arecord", "-l"]).lower()
        return "scarlett" in text or "focusrite" in text
    text = run(["aplay", "-l"]).lower()
    return "headphones" in text or "bcm2835" in text


def temperature():
    raw = read_text("/sys/class/thermal/thermal_zone0/temp")
    try:
        return round(float(raw) / 1000.0, 1)
    except Exception:
        return None


def throttled():
    output = run(["vcgencmd", "get_throttled"])
    if not output:
        return None
    return output.split("=", 1)[-1] if "=" in output else output


def multicast_member(iface, group):
    output = run(["ip", "maddr", "show", "dev", iface])
    return group in output


def node_status(cfg):
    iface = cfg.get("NETWORK_IFACE", "eth0")
    role = cfg.get("ROLE", "")
    carrier = read_text("/sys/class/net/" + iface + "/carrier") == "1"
    speed = read_text("/sys/class/net/" + iface + "/speed")
    try:
        speed_value = int(speed)
    except Exception:
        speed_value = None

    try:
        load_1m = round(os.getloadavg()[0], 2)
    except Exception:
        load_1m = None

    data = {
        "name": cfg.get("NODE_NAME", socket.gethostname()),
        "hostname": socket.gethostname(),
        "role": role,
        "software_version": cfg.get("SOFTWARE_VERSION", ""),
        "timestamp": time.time(),
        "roc_service": service_state(),
        "roc_process": process_state(role),
        "audio_device": audio_state(role),
        "network": {
            "interface": iface,
            "ipv4": local_ipv4(iface),
            "carrier": carrier,
            "speed_mbps": speed_value,
        },
        "multicast": {
            "group": cfg.get("MULTICAST_ADDR", ""),
            "member": multicast_member(iface, cfg.get("MULTICAST_ADDR", "")),
        },
        "temperature_c": temperature(),
        "throttled": throttled(),
        "load_1m": load_1m,
    }
    return data


def send_heartbeats(cfg):
    role = cfg.get("ROLE", "")
    tx_ip = cfg.get("TX_IP", "")
    port = int(cfg.get("MONITOR_PORT", "19090"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    while True:
        status = node_status(cfg)
        if role == "tx":
            with LOCK:
                NODES[status["name"]] = status
        elif tx_ip:
            payload = json.dumps(status, separators=(",", ":")).encode("utf-8")
            try:
                sock.sendto(payload, (tx_ip, port))
            except OSError:
                pass
        time.sleep(5)


def listen_heartbeats(cfg):
    port = int(cfg.get("MONITOR_PORT", "19090"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    while True:
        payload, address = sock.recvfrom(65535)
        try:
            data = json.loads(payload.decode("utf-8"))
            data["source_ip"] = address[0]
            data["timestamp_received"] = time.time()
            name = data.get("name", address[0])
            with LOCK:
                NODES[name] = data
        except Exception:
            continue


def api_payload(cfg):
    now = time.time()
    with LOCK:
        snapshot = [dict(value) for value in NODES.values()]
    for node in snapshot:
        stamp = node.get("timestamp_received", node.get("timestamp", 0))
        age = max(0, now - stamp)
        node["age_seconds"] = round(age, 1)
        node["online"] = age <= OFFLINE_AFTER
        problems = []
        if not node["online"]:
            problems.append("offline")
        if node.get("roc_service") != "active":
            problems.append("roc_service")
        if not node.get("roc_process"):
            problems.append("roc_process")
        if not node.get("audio_device"):
            problems.append("audio_device")
        if not node.get("network", {}).get("carrier"):
            problems.append("ethernet")
        node["problems"] = problems
        node["state"] = "OK" if not problems else ("OFFLINE" if "offline" in problems else "ATTENZIONE")
    snapshot.sort(key=lambda item: (0 if item.get("role") == "tx" else 1, item.get("name", "")))
    return {
        "system": "Roc Museum Audio",
        "generated_at": now,
        "expected_rx": int(cfg.get("EXPECTED_RX_COUNT", "3")),
        "nodes": snapshot,
    }


PAGE = r'''<!doctype html>
<html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Roc Museum Audio</title>
<style>
body{font-family:system-ui,sans-serif;background:#111827;color:#e5e7eb;margin:0;padding:24px}main{max-width:1150px;margin:auto}h1{margin:0 0 6px}.sub{color:#9ca3af;margin-bottom:22px}.summary,.grid{display:grid;gap:14px}.summary{grid-template-columns:repeat(auto-fit,minmax(150px,1fr));margin-bottom:18px}.grid{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.box,.card{background:#1f2937;border:1px solid #374151;border-radius:12px;padding:16px}.num{font-size:28px;font-weight:700}.head{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}.badge{font-size:12px;font-weight:700;padding:5px 9px;border-radius:999px}.OK{background:#064e3b;color:#a7f3d0}.ATTENZIONE{background:#78350f;color:#fde68a}.OFFLINE{background:#7f1d1d;color:#fecaca}.row{display:flex;justify-content:space-between;gap:12px;border-top:1px solid #374151;padding:8px 0;font-size:14px}.label{color:#9ca3af}.value{text-align:right}footer{color:#6b7280;margin-top:22px;font-size:13px}code{color:#93c5fd}</style></head>
<body><main><h1>Roc Museum Audio</h1><div class="sub">Monitor centrale TX · dashboard read-only</div>
<div id="summary" class="summary"></div><div id="nodes" class="grid"></div><footer id="footer"></footer>
<script>
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function card(n){let net=n.network||{};return `<article class="card"><div class="head"><strong>${esc(n.name)} · ${esc((n.role||'').toUpperCase())}</strong><span class="badge ${esc(n.state)}">${esc(n.state)}</span></div><div class="row"><span class="label">IPv4</span><span class="value">${esc(net.ipv4||'n/d')}</span></div><div class="row"><span class="label">Ethernet</span><span class="value">${net.carrier?'OK':'KO'}${net.speed_mbps?' · '+esc(net.speed_mbps)+' Mb/s':''}</span></div><div class="row"><span class="label">Roc</span><span class="value">${esc(n.roc_service)} · processo ${n.roc_process?'OK':'KO'}</span></div><div class="row"><span class="label">Audio device</span><span class="value">${n.audio_device?'OK':'KO'}</span></div><div class="row"><span class="label">Multicast</span><span class="value"><code>${esc((n.multicast||{}).group)}</code> ${((n.multicast||{}).member)?'JOIN':'-'}</span></div><div class="row"><span class="label">Temperatura</span><span class="value">${n.temperature_c==null?'n/d':esc(n.temperature_c)+' °C'}</span></div><div class="row"><span class="label">Load 1m</span><span class="value">${esc(n.load_1m??'n/d')}</span></div><div class="row"><span class="label">Ultimo heartbeat</span><span class="value">${esc(n.age_seconds)} s</span></div></article>`}
async function refresh(){try{let r=await fetch('/api/status',{cache:'no-store'}),d=await r.json(),ok=d.nodes.filter(n=>n.state==='OK').length,off=d.nodes.filter(n=>n.state==='OFFLINE').length;document.getElementById('summary').innerHTML=`<div class="box"><div class="label">Nodi rilevati</div><div class="num">${d.nodes.length}</div></div><div class="box"><div class="label">Nodi OK</div><div class="num">${ok}</div></div><div class="box"><div class="label">Offline</div><div class="num">${off}</div></div><div class="box"><div class="label">RX previsti</div><div class="num">${d.expected_rx}</div></div>`;document.getElementById('nodes').innerHTML=d.nodes.map(card).join('')||'<div class="box">Nessun nodo rilevato.</div>';document.getElementById('footer').textContent='Aggiornato '+new Date().toLocaleTimeString()+' · refresh 2 s · offline dopo 15 s';}catch(e){document.getElementById('footer').textContent='Errore dashboard: '+e}}
refresh();setInterval(refresh,2000);
</script></main></body></html>'''


class Handler(BaseHTTPRequestHandler):
    cfg = {}
    def log_message(self, fmt, *args):
        return
    def reply(self, code, content_type, payload):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.reply(200, "text/html; charset=utf-8", PAGE.encode("utf-8"))
            return
        if self.path == "/api/status":
            payload = json.dumps(api_payload(self.cfg), indent=2).encode("utf-8")
            self.reply(200, "application/json; charset=utf-8", payload)
            return
        if self.path == "/healthz":
            self.reply(200, "text/plain; charset=utf-8", b"ok\n")
            return
        self.reply(404, "text/plain; charset=utf-8", b"Not found\n")


def main():
    cfg = read_config()
    threading.Thread(target=send_heartbeats, args=(cfg,), daemon=True).start()
    if cfg.get("ROLE") == "tx":
        threading.Thread(target=listen_heartbeats, args=(cfg,), daemon=True).start()
        Handler.cfg = cfg
        server = ThreadingHTTPServer(("0.0.0.0", int(cfg.get("MONITOR_HTTP_PORT", "8080"))), Handler)
        server.serve_forever()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
PY_MONITOR
    chmod 0755 "$MONITOR"
}

write_units() {
    cat > "$AUDIO_UNIT" <<'EOF_AUDIO_UNIT'
[Unit]
Description=Roc Museum Audio node
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/roc-museum-run
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_AUDIO_UNIT

    cat > "$MONITOR_UNIT" <<'EOF_MONITOR_UNIT'
[Unit]
Description=Roc Museum Audio monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/roc-museum-monitor
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_MONITOR_UNIT
}

start_services() {
    info "Abilitazione e avvio automatico servizi"
    systemctl daemon-reload
    systemctl enable roc-museum-monitor.service roc-museum.service >/dev/null
    systemctl restart roc-museum-monitor.service || warn "Monitor non avviato correttamente."
    systemctl restart roc-museum.service || warn "Audio non avviato correttamente."
    sleep 2
}

report() {
    local ip audio_state monitor_state
    ip="$(get_ipv4 "$NETWORK_IFACE")"
    audio_state="$(systemctl is-active roc-museum.service 2>/dev/null || true)"
    monitor_state="$(systemctl is-active roc-museum-monitor.service 2>/dev/null || true)"
    echo
    echo "================ ROC MUSEUM AUDIO ================="
    echo "Versione            : $VERSION"
    echo "Nodo / ruolo        : $NODE_NAME / $ROLE"
    echo "IPv4                : ${ip:-n/d}"
    echo "Audio multicast     : $MULTICAST_ADDR:$RTP_PORT"
    echo "roc-museum          : ${audio_state:-unknown}"
    echo "roc-museum-monitor  : ${monitor_state:-unknown}"
    if [ "$ROLE" = "tx" ]; then
        echo "Dashboard            : http://${ip:-IP-TX}:$HTTP_PORT/"
        echo "API                  : http://${ip:-IP-TX}:$HTTP_PORT/api/status"
    else
        echo "Monitor TX           : $TX_IP:$MONITOR_PORT UDP"
    fi
    echo "===================================================="
    echo "Log audio:   journalctl -u roc-museum -f"
    echo "Log monitor: journalctl -u roc-museum-monitor -f"
    if [ "$REBOOT_REQUIRED" = "yes" ]; then
        echo
        warn "Riavvio consigliato/necessario per completare l'abilitazione dell'audio analogico."
        echo "Dopo il reboot i servizi partiranno automaticamente."
    fi
}

main() {
    require_root
    parse_args "$@"
    choose_role
    ask_values
    detect_network
    install_packages
    enable_analog_audio
    hardware_report
    systemctl stop roc-museum.service roc-museum-monitor.service >/dev/null 2>&1 || true
    write_config
    write_runner
    write_monitor
    write_units
    start_services
    report
}

main "$@"
