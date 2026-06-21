#!/bin/bash
# Minimal WireGuard-Hub auf einem frischen VPS — nur fuer Netcup ↔ Fritzbox-Test.
# Kein NPM, kein Pi-Peer. Produktiv-IONOS bleibt unangetastet.
#
# Auf dem Netcup-VPS als root:
#   curl -fsSL ... | bash
#   oder: scp + bash scripts/netcup-fritzbox-minimal.sh root@NETCUP:/root/ && ssh root@NETCUP bash /root/netcup-fritzbox-minimal.sh
#
# Optional per Umgebung:
#   FRITZBOX_PUBLIC_KEY=... LAN_SUBNET=192.168.2.0/24 FB_TUNNEL_IP=10.100.0.12 ./netcup-fritzbox-minimal.sh

set -euo pipefail

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_SERVER_IP="10.100.0.1/24"
LAN_SUBNET="${LAN_SUBNET:-192.168.2.0/24}"
FB_TUNNEL_IP="${FB_TUNNEL_IP:-10.100.0.12}"
FB_TUNNEL_CIDR="${FB_TUNNEL_IP}/32"
IMPORT_FILE="/root/fritzbox-netcup-import.conf"

log() { printf '[netcup-fb] %s\n' "$*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausfuehren." >&2
    exit 1
  fi
}

detect_public_ip() {
  curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null \
    || curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard wireguard-tools iperf3 curl iproute2 iptables
}

ensure_server_keys() {
  mkdir -p "$WG_DIR"
  chmod 700 "$WG_DIR"
  if [ ! -f "${WG_DIR}/server_private.key" ]; then
    umask 077
    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
  fi
  chmod 600 "${WG_DIR}/server_private.key"
  chmod 644 "${WG_DIR}/server_public.key"
}

prompt_fritzbox_pubkey() {
  if [ -n "${FRITZBOX_PUBLIC_KEY:-}" ]; then
    return
  fi
  echo ""
  echo "Fritzbox Public Key (aus FRITZ!OS Export oder: echo PRIVATE | wg pubkey):"
  read -r FRITZBOX_PUBLIC_KEY
  if [ -z "$FRITZBOX_PUBLIC_KEY" ]; then
    echo "FRITZBOX_PUBLIC_KEY fehlt — Abbruch." >&2
    exit 1
  fi
}

write_wg_config() {
  local wan postup postdown script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/vps-wg-postup.sh
  source "${script_dir}/vps-wg-postup.sh"
  VPS_LAN_SUBNET="$LAN_SUBNET"
  wan="$(vps_detect_wan_interface)"
  postup="$(vps_wg_postup_line "${wan:-eth0}")"
  postdown="$(vps_wg_postdown_line "${wan:-eth0}")"

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = $(cat "${WG_DIR}/server_private.key")
SaveConfig = false
${postup}
${postdown}

# Fritzbox-Test (kein Pi-Peer)
[Peer]
PublicKey = ${FRITZBOX_PUBLIC_KEY}
AllowedIPs = ${FB_TUNNEL_CIDR}, ${LAN_SUBNET}
PersistentKeepalive = 25
EOF
  chmod 600 "$WG_CONF"
}

open_firewall_udp() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${WG_LISTEN_PORT}/udp" comment "WireGuard Fritzbox-Test" || true
    return
  fi
  iptables -C INPUT -p udp --dport "$WG_LISTEN_PORT" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p udp --dport "$WG_LISTEN_PORT" -j ACCEPT
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.d/99-gate2home.conf 2>/dev/null \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-gate2home.conf
}

start_wireguard() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/vps-wg-postup.sh
  source "${script_dir}/vps-wg-postup.sh"
  VPS_LAN_SUBNET="$LAN_SUBNET"
  vps_ensure_wg_boot_after_docker
  systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IFACE}"
}

write_fritzbox_import() {
  local endpoint pub
  pub="$(cat "${WG_DIR}/server_public.key")"
  endpoint="$(detect_public_ip)"

  cat > "$IMPORT_FILE" <<EOF
[Interface]
# Bestehenden Fritzbox PrivateKey eintragen (oder neuen Key in FRITZ!OS erzeugen lassen)
PrivateKey = FRITZBOX_PRIVATE_KEY_HIER_EINTRAGEN
Address = ${FB_TUNNEL_CIDR}

[Peer]
PublicKey = ${pub}
Endpoint = ${endpoint}:${WG_LISTEN_PORT}
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25
EOF
  chmod 600 "$IMPORT_FILE"
}

print_summary() {
  local pub endpoint
  pub="$(cat "${WG_DIR}/server_public.key")"
  endpoint="$(detect_public_ip)"

  echo ""
  echo "=============================================="
  echo " Netcup VPS — WireGuard fuer Fritzbox-Test"
  echo "=============================================="
  echo ""
  echo "VPS Public Key:  ${pub}"
  echo "VPS Endpoint:    ${endpoint}:${WG_LISTEN_PORT}"
  echo "Fritzbox-Import: ${IMPORT_FILE}"
  echo ""
  echo "--- Fritzbox (FRITZ!OS 7.50+) ---"
  echo "1. Alte IONOS-Verbindung deaktivieren ODER Endpoint/PublicKey aktualisieren"
  echo "2. Internet → Freigaben → VPN → WireGuard → Verbindung hinzufuegen"
  echo "3. „Netzwerke verbinden“, Config aus ${IMPORT_FILE} hochladen"
  echo "4. PrivateKey in der Datei eintragen (gleicher Key wie beim IONOS-Test moeglich)"
  echo "5. NICHT: „Gesamten IPv4-Verkehr ueber VPN“"
  echo ""
  echo "--- Nach Handshake auf dem VPS pruefen ---"
  echo "  wg show"
  echo "  ping -c 3 ${FB_TUNNEL_IP}"
  echo "  ping -c 3 192.168.2.1"
  echo "  ping -c 3 192.168.2.35"
  echo ""
  echo "--- Durchsatz (Plex-Host, iperf3 -s auf 192.168.2.35) ---"
  echo "  iperf3 -c 192.168.2.35 -t 20 -P 4 -f m"
  echo ""
  echo "Falls Ping zu 192.168.2.1 ok, aber andere LAN-Hosts nein:"
  echo "  Export anpassen: Address = 192.168.2.1/24 (siehe docs/GATEWAY-OPTIONEN.md)"
  echo "  oder LAN-LAN-Assistent in der Fritzbox testen."
  echo ""
}

main() {
  require_root
  install_packages
  ensure_server_keys
  prompt_fritzbox_pubkey
  write_wg_config
  enable_forwarding
  open_firewall_udp
  start_wireguard
  write_fritzbox_import
  print_summary
  wg show "$WG_IFACE" 2>/dev/null || true
}

main "$@"
