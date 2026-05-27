#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -euo pipefail

APP_NAME="Wireguard2Home"
PKG_MANAGER=""
HAS_SYSTEMCTL=0

resolve_user_home() {
  local user_name="$1"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2"
    return
  fi

  local passwd_home=""
  passwd_home="$(getent passwd "$user_name" 2>/dev/null | awk -F: '{print $6}')"
  if [ -n "$passwd_home" ]; then
    printf '%s\n' "$passwd_home"
    return
  fi

  printf '/root\n'
}

SERVICE_USER="${WIREGUARD2HOME_SERVICE_USER:-root}"
SERVICE_HOME="$(resolve_user_home "$SERVICE_USER" "${WIREGUARD2HOME_SERVICE_HOME:-}")"
BACKUP_RECEIVE_USER="${WIREGUARD2HOME_BACKUP_RECEIVE_USER:-$SERVICE_USER}"
BACKUP_RECEIVE_HOME="$(resolve_user_home "$BACKUP_RECEIVE_USER" "${WIREGUARD2HOME_BACKUP_RECEIVE_HOME:-}")"
BACKUP_AUTH_USER="${WIREGUARD2HOME_BACKUP_AUTH_USER:-$SERVICE_USER}"
BACKUP_AUTH_HOME="$(resolve_user_home "$BACKUP_AUTH_USER" "${WIREGUARD2HOME_BACKUP_AUTH_HOME:-}")"

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_PI_IP_CIDR="10.100.0.2/24"
WG_NETWORK_CIDR="10.100.0.0/24"
LAN_SUBNET="192.168.50.0/24"
SERVER_ENDPOINT="vpn.example.com:51820"
SERVER_PUBLIC_KEY=""

BACKUP_RECEIVE_DIR="${WIREGUARD2HOME_BACKUP_RECEIVE_DIR:-${BACKUP_RECEIVE_HOME}/backups/from-vps}"
BACKUP_AUTH_KEYS_PATH="${WIREGUARD2HOME_BACKUP_AUTHORIZED_KEYS_PATH:-${BACKUP_AUTH_HOME}/.ssh/authorized_keys}"
VPS_BACKUP_PUBLIC_KEY=""
ENABLE_MASQUERADE=0
MASQUERADE_INTERFACE=""

usage() {
  cat <<EOF
${APP_NAME} Gateway Host Installer

Nutzung:
  $0 [optionen]

Optionen:
  --gateway-address CIDR        WireGuard Adresse des Gateway-Hosts (Standard: ${WG_PI_IP_CIDR})
  --raspberry-address CIDR      Veralteter Alias fuer --gateway-address
  --wg-network CIDR             WireGuard Netz (Standard: ${WG_NETWORK_CIDR})
  --lan-subnet CIDR             Heimnetz hinter dem Raspberry (Standard: ${LAN_SUBNET})
  --service-user USER           Besitzer fuer lokale App-Daten auf dem Raspberry
  --service-home PFAD           Home-Pfad des lokalen Service-Users
  --backup-receive-user USER    Ziel-User fuer empfangene Backups
  --backup-receive-home PFAD    Home-Pfad des Backup-Ziel-Users
  --backup-auth-user USER       User, dessen authorized_keys den VPS-Backup-Key erhaelt
  --backup-auth-home PFAD       Home-Pfad des Auth-Users fuer Backup-SSH
  --authorized-keys-path PFAD   Direkter Pfad zur authorized_keys fuer Backup-SSH
  --server-endpoint HOST:PORT   VPS Endpoint (Standard: ${SERVER_ENDPOINT})
  --server-public-key KEY       Public Key des VPS
  --vps-backup-public-key KEY   Public Key fuer VPS-Backupzugriff
  --enable-masquerade           NAT/Masquerade Regeln in wg0.conf Template eintragen
  --masquerade-interface IFACE  Interface fuer Masquerade, z. B. eth0
  --help                        Diese Hilfe anzeigen
EOF
}

log() {
  printf '[%s] %s\n' "${APP_NAME}" "$1" >&2
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte als root ausfuehren."
    exit 1
  fi
}

detect_platform() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    echo "Fehler: Kein unterstuetzter Paketmanager gefunden (apt, dnf, yum, pacman, zypper)."
    exit 1
  fi

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAS_SYSTEMCTL=1
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --gateway-address|--raspberry-address)
        WG_PI_IP_CIDR="$2"
        shift 2
        ;;
      --wg-network)
        WG_NETWORK_CIDR="$2"
        shift 2
        ;;
      --lan-subnet)
        LAN_SUBNET="$2"
        shift 2
        ;;
      --service-user)
        SERVICE_USER="$2"
        SERVICE_HOME="$(resolve_user_home "$SERVICE_USER" "${WIREGUARD2HOME_SERVICE_HOME:-}")"
        BACKUP_RECEIVE_USER="$SERVICE_USER"
        BACKUP_RECEIVE_HOME="$SERVICE_HOME"
        BACKUP_RECEIVE_DIR="${BACKUP_RECEIVE_HOME}/backups/from-vps"
        BACKUP_AUTH_USER="$SERVICE_USER"
        BACKUP_AUTH_HOME="$SERVICE_HOME"
        BACKUP_AUTH_KEYS_PATH="${BACKUP_AUTH_HOME}/.ssh/authorized_keys"
        shift 2
        ;;
      --service-home)
        SERVICE_HOME="$2"
        BACKUP_RECEIVE_HOME="$SERVICE_HOME"
        BACKUP_RECEIVE_DIR="${BACKUP_RECEIVE_HOME}/backups/from-vps"
        BACKUP_AUTH_HOME="$SERVICE_HOME"
        BACKUP_AUTH_KEYS_PATH="${BACKUP_AUTH_HOME}/.ssh/authorized_keys"
        shift 2
        ;;
      --backup-receive-user)
        BACKUP_RECEIVE_USER="$2"
        BACKUP_RECEIVE_HOME="$(resolve_user_home "$BACKUP_RECEIVE_USER" "${WIREGUARD2HOME_BACKUP_RECEIVE_HOME:-}")"
        BACKUP_RECEIVE_DIR="${BACKUP_RECEIVE_HOME}/backups/from-vps"
        shift 2
        ;;
      --backup-receive-home)
        BACKUP_RECEIVE_HOME="$2"
        BACKUP_RECEIVE_DIR="${BACKUP_RECEIVE_HOME}/backups/from-vps"
        shift 2
        ;;
      --backup-auth-user)
        BACKUP_AUTH_USER="$2"
        BACKUP_AUTH_HOME="$(resolve_user_home "$BACKUP_AUTH_USER" "${WIREGUARD2HOME_BACKUP_AUTH_HOME:-}")"
        BACKUP_AUTH_KEYS_PATH="${BACKUP_AUTH_HOME}/.ssh/authorized_keys"
        shift 2
        ;;
      --backup-auth-home)
        BACKUP_AUTH_HOME="$2"
        BACKUP_AUTH_KEYS_PATH="${BACKUP_AUTH_HOME}/.ssh/authorized_keys"
        shift 2
        ;;
      --authorized-keys-path)
        BACKUP_AUTH_KEYS_PATH="$2"
        shift 2
        ;;
      --server-endpoint)
        SERVER_ENDPOINT="$2"
        shift 2
        ;;
      --server-public-key)
        SERVER_PUBLIC_KEY="$2"
        shift 2
        ;;
      --vps-backup-public-key)
        VPS_BACKUP_PUBLIC_KEY="$2"
        shift 2
        ;;
      --enable-masquerade)
        ENABLE_MASQUERADE=1
        shift
        ;;
      --masquerade-interface)
        MASQUERADE_INTERFACE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Fehler: Unbekannte Option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

install_packages() {
  log "Erkannter Paketmanager: ${PKG_MANAGER}"

  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      log "Paketlisten werden aktualisiert..."
      apt-get update
      log "Installiere Kern-Abhaengigkeiten..."
      apt-get install -y \
        wireguard \
        rsync \
        iperf3 \
        openssh-server \
        tar \
        gawk \
        iproute2 \
        ca-certificates \
        iptables
      ;;
    dnf)
      log "Installiere Kern-Abhaengigkeiten..."
      dnf install -y \
        wireguard-tools \
        rsync \
        iperf3 \
        openssh-server \
        tar \
        gawk \
        iproute \
        ca-certificates \
        iptables
      ;;
    yum)
      log "Installiere Kern-Abhaengigkeiten..."
      yum install -y \
        wireguard-tools \
        rsync \
        iperf3 \
        openssh-server \
        tar \
        gawk \
        iproute \
        ca-certificates \
        iptables
      ;;
    pacman)
      log "Synchronisiere Paketdatenbank..."
      pacman -Sy --noconfirm
      log "Installiere Kern-Abhaengigkeiten..."
      pacman -S --noconfirm \
        wireguard-tools \
        rsync \
        iperf3 \
        openssh \
        tar \
        gawk \
        iproute2 \
        ca-certificates \
        iptables
      ;;
    zypper)
      log "Installiere Kern-Abhaengigkeiten..."
      zypper --non-interactive install \
        wireguard-tools \
        rsync \
        iperf3 \
        openssh \
        tar \
        gawk \
        iproute2 \
        ca-certificates \
        iptables
      ;;
  esac

  require_commands wg rsync ssh tar awk ip iperf3
}

require_commands() {
  local missing=()
  local cmd=""
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Fehler: Folgende Befehle fehlen nach der Installation: ${missing[*]}"
    exit 1
  fi
}

ensure_dir() {
  mkdir -p "$1"
  chmod "$2" "$1"
}

ensure_pi_keypair() {
  local private_key="${WG_DIR}/raspberry_private.key"
  local public_key="${WG_DIR}/raspberry_public.key"
  local conf_private_key=""

  if [ -f "$WG_CONF" ]; then
    conf_private_key="$(awk -F' = ' '/^PrivateKey =/ {print $2; exit}' "$WG_CONF" 2>/dev/null || true)"
    if [ -n "$conf_private_key" ]; then
      log "Bestehende wg0.conf erkannt. Uebernehme aktiven Public Key aus der vorhandenen Konfiguration..."
      printf '%s\n' "$conf_private_key" | wg pubkey > "$public_key"
      chmod 644 "$public_key"
      return
    fi
  fi

  if [ ! -f "$private_key" ]; then
      log "Erzeuge WireGuard Gateway-Host-Keypair..."
    umask 077
    wg genkey | tee "$private_key" | wg pubkey > "$public_key"
  fi

  chmod 600 "$private_key"
  chmod 644 "$public_key"
}

configure_ip_forwarding() {
  cat > /etc/sysctl.d/99-wireguard2home.conf <<EOF
net.ipv4.ip_forward=1
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
EOF
  sysctl --system >/dev/null
}

install_vps_backup_key() {
  if [ -z "$VPS_BACKUP_PUBLIC_KEY" ]; then
    log "Hinweis: Kein VPS-Backup-Public-Key uebergeben. Backup-SSH-Zugriff muss spaeter manuell freigeschaltet werden."
    return
  fi

  mkdir -p "$(dirname "$BACKUP_AUTH_KEYS_PATH")"
  chmod 700 "$(dirname "$BACKUP_AUTH_KEYS_PATH")"
  touch "$BACKUP_AUTH_KEYS_PATH"
  chmod 600 "$BACKUP_AUTH_KEYS_PATH"

  if ! grep -Fqx "$VPS_BACKUP_PUBLIC_KEY" "$BACKUP_AUTH_KEYS_PATH"; then
    printf '%s\n' "$VPS_BACKUP_PUBLIC_KEY" >> "$BACKUP_AUTH_KEYS_PATH"
  fi
}

write_nat_lines() {
  if [ "$ENABLE_MASQUERADE" -eq 1 ] && [ -n "$MASQUERADE_INTERFACE" ]; then
    if ! command -v iptables >/dev/null 2>&1; then
      log "Hinweis: iptables ist auf diesem System nicht verfuegbar. NAT-Zeilen werden nicht automatisch eingetragen."
      return
    fi
    cat <<EOF
PostUp = iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NETWORK_CIDR} -o ${MASQUERADE_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NETWORK_CIDR} -o ${MASQUERADE_INTERFACE} -j MASQUERADE
EOF
  fi
}

write_raspberry_template_if_missing() {
  local private_key="${WG_DIR}/raspberry_private.key"
  local nat_lines=""

  nat_lines="$(write_nat_lines || true)"

  if [ -f "$WG_CONF" ]; then
    chmod 600 "$WG_CONF"
    log "${WG_CONF} existiert bereits. Bestehende Konfiguration bleibt erhalten."
    return
  fi

  {
    echo "[Interface]"
    echo "Address = ${WG_PI_IP_CIDR}"
    echo "PrivateKey = $(cat "$private_key")"
    if [ -n "$nat_lines" ]; then
      echo "$nat_lines"
    else
      echo "# Optionales NAT-Beispiel:"
      echo "# PostUp = iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NETWORK_CIDR} -o eth0 -j MASQUERADE"
      echo "# PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NETWORK_CIDR} -o eth0 -j MASQUERADE"
    fi

    if [ -n "$SERVER_PUBLIC_KEY" ]; then
      echo ""
      echo "[Peer]"
      echo "PublicKey = ${SERVER_PUBLIC_KEY}"
      echo "Endpoint = ${SERVER_ENDPOINT}"
      echo "AllowedIPs = ${WG_NETWORK_CIDR}"
      echo "PersistentKeepalive = 25"
    else
      echo ""
      echo "# Peer fuer den VPS spaeter ergaenzen:"
      echo "# [Peer]"
      echo "# PublicKey = CHANGE_ME_SERVER_PUBLIC_KEY"
      echo "# Endpoint = ${SERVER_ENDPOINT}"
      echo "# AllowedIPs = ${WG_NETWORK_CIDR}"
      echo "# PersistentKeepalive = 25"
    fi
  } > "$WG_CONF"

  chmod 600 "$WG_CONF"
  log "Template fuer ${WG_CONF} wurde angelegt."
}

enable_services() {
  if [ "$HAS_SYSTEMCTL" -ne 1 ]; then
    log "Hinweis: Kein laufendes systemd erkannt. Dienste bitte manuell aktivieren."
    return
  fi

  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl start ssh >/dev/null 2>&1 || systemctl start sshd >/dev/null 2>&1 || true
  systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
}

print_summary() {
  local gateway_public_key
  gateway_public_key="$(cat "${WG_DIR}/raspberry_public.key")"

  echo ""
  echo "========================================"
  echo "${APP_NAME} Raspberry Installation abgeschlossen"
  echo "========================================"
  echo ""
  echo "Wichtige Pfade:"
  echo "  WireGuard Config: ${WG_CONF}"
  echo "  Backup Ziel:      ${BACKUP_RECEIVE_DIR}"
  echo "  Backup SSH Auth:  ${BACKUP_AUTH_KEYS_PATH}"
  echo ""
  echo "Gateway-Host Public Key:"
  echo "  ${gateway_public_key}"
  echo ""
  echo "Peer-Block fuer den VPS:"
  echo ""
  echo "[Peer]"
  echo "PublicKey = ${gateway_public_key}"
  echo "AllowedIPs = 10.100.0.2/32, ${LAN_SUBNET}"
  echo "PersistentKeepalive = 25"
  echo ""
  echo "Naechste Schritte:"
  echo "1. Obigen Peer-Block in ${WG_IFACE}.conf auf dem VPS eintragen."
  echo "2. Auf dem Gateway-Host den korrekten VPS Public Key in ${WG_CONF} pruefen."
  echo "3. Backup-SSH vom VPS zum Gateway-Host testen."
  if [ "$HAS_SYSTEMCTL" -eq 1 ]; then
    echo "4. WireGuard mit systemctl restart wg-quick@${WG_IFACE} pruefen."
  else
    echo "4. SSH-Dienst und WireGuard auf diesem Host manuell starten, da kein systemd erkannt wurde."
  fi
  echo ""
}

main() {
  parse_args "$@"
  require_root
  detect_platform

  if [ "$ENABLE_MASQUERADE" -eq 1 ] && [ -z "$MASQUERADE_INTERFACE" ]; then
    echo "Fehler: --enable-masquerade benoetigt --masquerade-interface."
    exit 1
  fi

  install_packages
  ensure_dir "$WG_DIR" 700
  ensure_dir "$BACKUP_RECEIVE_DIR" 700
  ensure_pi_keypair
  configure_ip_forwarding
  install_vps_backup_key
  write_raspberry_template_if_missing
  enable_services
  print_summary
}

main "$@"
