#!/bin/bash
# Nach install-vps.sh + Backup-Restore: Produktiv-Konfiguration Netcup + Fritzbox-Gateway.
set -euo pipefail

BACKUP_FILE="${1:-}"
NETCUP_ENDPOINT="${NETCUP_ENDPOINT:-}"
OLD_ENDPOINT="${OLD_ENDPOINT:-}"
LAN_SUBNET="${LAN_SUBNET:-192.168.2.0/24}"
# Keys nur per Umgebung — nie Defaults mit echten Werten ins Git!
FB_PUBKEY="${FB_PUBKEY:-}"
PI_PUBKEY="${PI_PUBKEY:-}"
FRITZBOX_PRIVATE_KEY="${FRITZBOX_PRIVATE_KEY:-}"
WG_CONF="/etc/wireguard/wg0.conf"
W2H_CONF="/etc/wireguard2home.conf"
CLIENT_DIR="/root/wg-clients"
RESTORE_TMP="/tmp/gate2home-migrate-restore"

log() { printf '[migrate] %s\n' "$*"; }

require_root() { [ "$(id -u)" -eq 0 ] || { echo "root noetig"; exit 1; }; }

restore_from_backup() {
  [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] || { echo "Backup fehlt: $BACKUP_FILE"; exit 1; }
  log "Extrahiere $BACKUP_FILE ..."
  rm -rf "$RESTORE_TMP"
  mkdir -p "$RESTORE_TMP"
  tar -xzf "$BACKUP_FILE" -C "$RESTORE_TMP"

  log "Kopiere WireGuard, Clients, Docker-Stacks ..."
  cp -a "$RESTORE_TMP/etc/wireguard/." /etc/wireguard/
  cp -a "$RESTORE_TMP/root/wg-clients/." "$CLIENT_DIR/"
  for stack in npm uptime-kuma watchtower crowdsec; do
    [ -d "$RESTORE_TMP/opt/$stack" ] && cp -a "$RESTORE_TMP/opt/$stack" /opt/
  done
  [ -d "$RESTORE_TMP/etc/crowdsec" ] && cp -a "$RESTORE_TMP/etc/crowdsec" /etc/
  [ -f "$RESTORE_TMP/etc/wireguard2home.conf" ] && cp -a "$RESTORE_TMP/etc/wireguard2home.conf" "$W2H_CONF"
  chmod 600 "$WG_CONF" "$W2H_CONF" 2>/dev/null || true
  find "$CLIENT_DIR" -name '*.conf' -exec chmod 600 {} \;
}

configure_fritzbox_gateway() {
  if [ -z "$FB_PUBKEY" ]; then
    echo "FB_PUBKEY fehlt (Fritzbox WireGuard Public Key)." >&2
    exit 1
  fi
  log "Passe wg0.conf fuer Fritzbox-Gateway an ..."
  local tmp
  tmp="$(mktemp)"

  awk -v pi="$PI_PUBKEY" -v fb="$FB_PUBKEY" -v lan="$LAN_SUBNET" '
    BEGIN { in_peer=0; skip=0; mtu_done=0 }
    /^\[Interface\]/ { print; if (!mtu_done) { print "MTU = 1280"; mtu_done=1 }; next }
    /^MTU =/ { next }
    /^\[Peer\]/ {
      in_peer=1
      peer_block=$0 "\n"
      next
    }
    in_peer {
      peer_block = peer_block $0 "\n"
      if ($0 ~ /^$/ || ($0 !~ /^[[:space:]]/ && $0 !~ /^#/ && $0 !~ /^(PublicKey|AllowedIPs|Endpoint|PersistentKeepalive)/)) {
        # end of peer block at next section - handled below
      }
      if (NR && $0 ~ /^$/ ) { }
      next
    }
    !in_peer { print }
  ' "$WG_CONF" > /dev/null 2>&1 || true

  # Einfacher: neu aus Interface + Client-Peers + Fritzbox bauen
  python3 - "$WG_CONF" "$tmp" "$PI_PUBKEY" "$FB_PUBKEY" "$LAN_SUBNET" <<'PY'
import sys, re
src, dst, pi_pk, fb_pk, lan = sys.argv[1:6]
text = open(src).read()
iface_m = re.search(r'\[Interface\](.*?)(?=\n\[Peer\]|\Z)', text, re.S)
if not iface_m:
    sys.exit('kein Interface-Block')
iface = iface_m.group(0)
iface = re.sub(r'\nMTU = \d+', '', iface)
if 'MTU =' not in iface:
    iface = iface.rstrip() + '\nMTU = 1280\n'
peers = re.findall(r'\[Peer\][^\[]*', text, re.S)
keep = []
for p in peers:
    pk = re.search(r'^PublicKey = (.+)$', p, re.M)
    if not pk:
        continue
    key = pk.group(1).strip()
    if key == pi_pk:
        continue
    if key == fb_pk:
        p = re.sub(r'AllowedIPs = .*', f'AllowedIPs = 10.100.0.2/32, {lan}', p)
        keep.append(p.strip() + '\n')
        continue
    keep.append(p.strip() + '\n')
if not any(fb_pk in k for k in keep):
    keep.append(f"""[Peer]
PublicKey = {fb_pk}
AllowedIPs = 10.100.0.2/32, {lan}
PersistentKeepalive = 25
""")
open(dst, 'w').write(iface.strip() + '\n\n' + '\n'.join(keep))
PY

  install -m 600 "$tmp" "$WG_CONF"
  rm -f "$tmp"
}

update_runtime_config() {
  log "Aktualisiere wireguard2home.conf ..."
  if [ -f "$W2H_CONF" ]; then
    sed -i "s|^WIREGUARD2HOME_ENDPOINT=.*|WIREGUARD2HOME_ENDPOINT=${NETCUP_ENDPOINT}|" "$W2H_CONF"
    sed -i "s|^WIREGUARD2HOME_SPEEDTEST_HOST=.*|WIREGUARD2HOME_SPEEDTEST_HOST=192.168.2.35|" "$W2H_CONF" || true
    grep -q '^WIREGUARD2HOME_LAN_SUBNET=' "$W2H_CONF" \
      || echo "WIREGUARD2HOME_LAN_SUBNET=${LAN_SUBNET}" >> "$W2H_CONF"
  fi
}

update_client_endpoints() {
  log "Client-Configs: Endpoint $OLD_ENDPOINT -> $NETCUP_ENDPOINT"
  local host port
  host="${NETCUP_ENDPOINT%%:*}"
  port="${NETCUP_ENDPOINT##*:}"
  for f in "$CLIENT_DIR"/*.conf; do
    [ -f "$f" ] || continue
    sed -i "s|^Endpoint = ${OLD_ENDPOINT}|Endpoint = ${NETCUP_ENDPOINT}|g" "$f"
    sed -i "s|^Endpoint = 31.70.75.7:51820|Endpoint = ${NETCUP_ENDPOINT}|g" "$f"
  done
}

write_fritzbox_production_conf() {
  local server_pub fb_priv out="/root/fritzbox-netcup-production.conf"
  server_pub="$(awk -F' = ' '/^PrivateKey =/ {print $2; exit}' "$WG_CONF" | wg pubkey 2>/dev/null || wg show wg0 public-key 2>/dev/null)"
  fb_priv="$FRITZBOX_PRIVATE_KEY"
  [ -z "$fb_priv" ] && fb_priv="$(awk -F' = ' '/^PrivateKey =/ {print $2; exit}' /root/fritzbox-netcup-import-lan24.conf 2>/dev/null || true)"
  [ -z "$fb_priv" ] && fb_priv="$(awk -F' = ' '/^PrivateKey =/ {print $2; exit}' /root/fritzbox-netcup-import.conf 2>/dev/null || true)"
  if [ -z "$fb_priv" ]; then
    log "Fritzbox PrivateKey fehlt. Setze FRITZBOX_PRIVATE_KEY oder lege Import-Config auf dem VPS ab."
    return 0
  fi
  cat > "$out" <<EOF
[Interface]
PrivateKey = ${fb_priv}
Address = 192.168.2.1/24

[Peer]
PublicKey = ${server_pub}
Endpoint = ${NETCUP_ENDPOINT}
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25
EOF
  chmod 600 "$out"
  log "Fritzbox-Produktivconfig: $out"
}

ensure_vps_wg_postup() {
  log "VPS PostUp: MASQUERADE (Full Tunnel) + DOCKER-USER (NPM -> Heimnetz) ..."
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/vps-wg-postup.sh
  source "${script_dir}/vps-wg-postup.sh"
  VPS_LAN_SUBNET="$LAN_SUBNET"
  vps_apply_wg_postup_to_conf "$WG_CONF"
  vps_ensure_wg_boot_after_docker
}

start_services() {
  log "Starte WireGuard + Docker-Stacks ..."
  ensure_vps_wg_postup
  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
  if command -v docker >/dev/null 2>&1; then
    docker network inspect gate2home_proxy >/dev/null 2>&1 || docker network create gate2home_proxy
    for stack in /opt/npm /opt/uptime-kuma /opt/watchtower /opt/crowdsec; do
      [ -f "${stack}/docker-compose.yml" ] && (cd "$stack" && docker compose up -d) || true
    done
  fi
}

main() {
  require_root
  restore_from_backup
  configure_fritzbox_gateway
  update_runtime_config
  update_client_endpoints
  write_fritzbox_production_conf
  start_services
  echo ""
  wg show wg0
  echo ""
  log "Migration abgeschlossen. Fritzbox-Config importieren: /root/fritzbox-netcup-production.conf"
  log "DNS A-Records auf 188.68.38.18 zeigen lassen."
}

main "$@"
