#!/bin/bash
# Gemeinsame WireGuard PostUp/PostDown-Logik fuer den VPS (Fritzbox-Gateway + NPM/Docker).
#
# Zwei Aufgaben:
# 1. MASQUERADE 10.100.0.0/24 -> WAN: Full-Tunnel-Clients erreichen das Internet
#    ueber den VPS (Speedtest, Surfen unterwegs). Ohne NAT schlagen nur interne Dienste zu.
# 2. DOCKER-USER fuer 192.168.x.0/24: NPM erreicht Heimnetz-Backends via wg0.
#    Chain existiert erst nach Docker-Start — daher Boot-Reihenfolge + Hilfsdienst.
#
# Nutzung: source scripts/vps-wg-postup.sh

VPS_WG_NET_CIDR="${VPS_WG_NET_CIDR:-10.100.0.0/24}"
VPS_LAN_SUBNET="${VPS_LAN_SUBNET:-192.168.2.0/24}"
VPS_WG_IFACE="${VPS_WG_IFACE:-wg0}"

vps_detect_wan_interface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# PostUp-Zeile fuer wg0.conf (eine Zeile, wg-quick-kompatibel)
vps_wg_postup_line() {
  local wan="${1:-$(vps_detect_wan_interface)}"
  wan="${wan:-eth0}"
  local wg="$VPS_WG_IFACE"
  local net="$VPS_WG_NET_CIDR"
  local lan="$VPS_LAN_SUBNET"
  printf '%s' "PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i ${wg} -j ACCEPT; iptables -A FORWARD -o ${wg} -j ACCEPT; iptables -t nat -C POSTROUTING -s ${net} -o ${wan} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${net} -o ${wan} -j MASQUERADE; if iptables -nL DOCKER-USER >/dev/null 2>&1; then iptables -C DOCKER-USER -d ${lan} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -d ${lan} -j ACCEPT; iptables -C DOCKER-USER -s ${lan} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -s ${lan} -j ACCEPT; fi"
}

vps_wg_postdown_line() {
  local wan="${1:-$(vps_detect_wan_interface)}"
  wan="${wan:-eth0}"
  local wg="$VPS_WG_IFACE"
  local net="$VPS_WG_NET_CIDR"
  printf '%s' "PostDown = iptables -D FORWARD -i ${wg} -j ACCEPT; iptables -D FORWARD -o ${wg} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${net} -o ${wan} -j MASQUERADE 2>/dev/null || true"
}

# PostUp/PostDown in bestehender wg0.conf ersetzen oder einfuegen
vps_apply_wg_postup_to_conf() {
  local conf="${1:-/etc/wireguard/wg0.conf}"
  local wan="${2:-$(vps_detect_wan_interface)}"
  wan="${wan:-eth0}"

  python3 - "$conf" "$(vps_wg_postup_line "$wan")" "$(vps_wg_postdown_line "$wan")" <<'PY'
import re, sys
path, postup, postdown = sys.argv[1:4]
lines = open(path).read().splitlines()
out, in_iface, done = [], False, False
for line in lines:
    if re.match(r'^\[Interface\]', line):
        in_iface, done = True, False
        out.append(line)
        continue
    if in_iface and re.match(r'^\[', line):
        if not done:
            out.append(postup)
            out.append(postdown)
            done = True
        in_iface = False
        if re.match(r'^PostUp = ', line) or re.match(r'^PostDown = ', line):
            continue
        out.append(line)
        continue
    if in_iface and (re.match(r'^PostUp = ', line) or re.match(r'^PostDown = ', line)):
        continue
    out.append(line)
if in_iface and not done:
    out.append(postup)
    out.append(postdown)
open(path, 'w').write('\n'.join(out).rstrip() + '\n')
PY
  chmod 600 "$conf"
}

# wg-quick startet nach Docker; DOCKER-USER-Regeln werden nachgezogen
vps_ensure_wg_boot_after_docker() {
  local lan="$VPS_LAN_SUBNET"
  mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
  cat > /etc/systemd/system/wg-quick@wg0.service.d/after-docker.conf <<'EOF'
[Unit]
After=docker.service
Wants=docker.service
EOF

  cat > /etc/systemd/system/gate2home-docker-wg-routes.service <<EOF
[Unit]
Description=Gate2home DOCKER-USER rules for WireGuard home LAN
After=docker.service wg-quick@wg0.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if ip link show wg0 >/dev/null 2>&1 && iptables -nL DOCKER-USER >/dev/null 2>&1; then iptables -C DOCKER-USER -d ${lan} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -d ${lan} -j ACCEPT; iptables -C DOCKER-USER -s ${lan} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -s ${lan} -j ACCEPT; fi'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable gate2home-docker-wg-routes.service >/dev/null 2>&1 || true
}
