#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -euo pipefail

APP_NAME="Wireguard2Home"
W2H_VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
BACKUP_SSH_USER="${WIREGUARD2HOME_BACKUP_SSH_USER:-$SERVICE_USER}"
BACKUP_SSH_HOME="$(resolve_user_home "$BACKUP_SSH_USER" "${WIREGUARD2HOME_BACKUP_SSH_HOME:-}")"
BACKUP_REMOTE_USER="${WIREGUARD2HOME_BACKUP_REMOTE_USER:-root}"
BACKUP_REMOTE_HOME="$(resolve_user_home "$BACKUP_REMOTE_USER" "${WIREGUARD2HOME_BACKUP_REMOTE_HOME:-}")"
CONFIG_FILE="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"

if [ -f "$CONFIG_FILE" ]; then
  # Reuse the active runtime configuration on reruns so an installer
  # update does not silently reset LAN or DNS values back to examples.
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

TARGET_SCRIPT="${WIREGUARD2HOME_TARGET_SCRIPT:-${SERVICE_HOME}/Wireguard2Home.sh}"
SCRIPT_SOURCE="${SCRIPT_DIR}/Wireguard2Home.sh"

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_SERVER_IP_CIDR="10.100.0.1/24"
WG_NET_CIDR="10.100.0.0/24"
WG_LISTEN_PORT="51820"
WG_ENDPOINT="${WIREGUARD2HOME_ENDPOINT:-}"
LAN_SUBNET="192.168.50.0/24"
LAN_SUBNET_EXPLICIT=0

CLIENT_DIR="${WIREGUARD2HOME_CLIENT_DIR:-${SERVICE_HOME}/wg-clients}"
if [ -n "${WIREGUARD2HOME_STATE_DIR:-}" ]; then
  STATE_DIR="$WIREGUARD2HOME_STATE_DIR"
elif [ "$SERVICE_USER" = "root" ]; then
  STATE_DIR="/var/lib/gate2home/wg-dashboard"
else
  STATE_DIR="${SERVICE_HOME}/.local/state/gate2home/wg-dashboard"
fi
BACKUP_DIR="${WIREGUARD2HOME_BACKUP_BASE:-${SERVICE_HOME}/backups/gate2home}"
PRE_RESTORE_DIR="${WIREGUARD2HOME_PRE_RESTORE_ROOT:-${SERVICE_HOME}/pre-restore-backups}"
NPM_DIR="/opt/npm"
WATCHTOWER_DIR="/opt/watchtower"
UPTIME_DIR="/opt/uptime-kuma"
CROWDSEC_DIR="/opt/crowdsec"
PROXY_NETWORK="gate2home_proxy"

BACKUP_SSH_KEY="${WIREGUARD2HOME_BACKUP_SSH_KEY:-${BACKUP_SSH_HOME}/.ssh/gate2home_backup}"
BACKUP_SSH_COMMENT="wireguard2home-backup@$(hostname -s 2>/dev/null || hostname)"
RPI_TARGET="${WIREGUARD2HOME_BACKUP_REMOTE_TARGET:-${BACKUP_REMOTE_HOME}/backups/from-vps}"
DNS_HOME_LABEL="${WIREGUARD2HOME_DNS_HOME_LABEL:-Home DNS}"
DNS_HOME_VALUE="${WIREGUARD2HOME_DNS_HOME_VALUE:-192.168.50.53}"
DNS_ROUTER_LABEL="${WIREGUARD2HOME_DNS_ROUTER_LABEL:-Router DNS}"
DNS_ROUTER_VALUE="${WIREGUARD2HOME_DNS_ROUTER_VALUE:-192.168.50.1}"
SPEEDTEST_USER="${WIREGUARD2HOME_SPEEDTEST_USER:-$BACKUP_REMOTE_USER}"
SPEEDTEST_HOST="${WIREGUARD2HOME_SPEEDTEST_HOST:-10.100.0.2}"
SPEEDTEST_SSH_KEY="${WIREGUARD2HOME_SPEEDTEST_SSH_KEY:-$BACKUP_SSH_KEY}"
SPEEDTEST_SIZE_MB="${WIREGUARD2HOME_SPEEDTEST_SIZE_MB:-64}"
ENABLE_UFW_FAIL2BAN=0
ENABLE_DOCKER=0
ENABLE_MONITORING=0
ENABLE_REVERSE_PROXY=0
ENABLE_CROWDSEC_BOUNCER=0
ENABLE_SWAP=0
SWAP_SIZE_MB="${WIREGUARD2HOME_SWAP_SIZE_MB:-1024}"
SWAP_FILE="${WIREGUARD2HOME_SWAP_FILE:-/swapfile}"
MIN_MONITORING_RAM_MB=900
PUSHOVER_TOKEN="${WIREGUARD2HOME_PUSHOVER_TOKEN:-}"
PUSHOVER_USER="${WIREGUARD2HOME_PUSHOVER_USER:-}"

usage() {
  cat <<EOF
${APP_NAME} v${W2H_VERSION} — VPS Installer

Nutzung:
  $0 [optionen]

Optionen:
  --script-source PFAD         Quelle fuer Wireguard2Home.sh
  --config-file PFAD           Ziel fuer die Wireguard2Home-Konfiguration
  --service-user USER          Besitzer der App-Daten und des Einstiegsscripts
  --service-home PFAD          Home-Pfad fuer den Service-User
  --backup-ssh-user USER       User, unter dessen .ssh der Backup-Key liegt
  --backup-ssh-home PFAD       Home-Pfad fuer den Backup-SSH-User
  --backup-remote-user USER    Ziel-User auf dem Raspberry fuer Backups
  --backup-remote-home PFAD    Home-Pfad des Ziel-Users auf dem Raspberry
  --target-script PFAD         Zielpfad auf dem VPS (Standard: ${TARGET_SCRIPT})
  --server-address CIDR        WireGuard Interface-Adresse (Standard: ${WG_SERVER_IP_CIDR})
  --wg-network CIDR            WireGuard Netz (Standard: ${WG_NET_CIDR})
  --listen-port PORT           WireGuard ListenPort (Standard: ${WG_LISTEN_PORT})
  --endpoint HOST:PORT         Oeffentlicher Endpunkt des VPS, z. B. myvps.example.com:51820
  --lan-subnet CIDR            Heimnetz fuer Hinweise/Template (Standard: ${LAN_SUBNET})
  --dns-home-label TEXT        Anzeigename fuer lokales DNS-Preset 1
  --dns-home-value IPS         Wert fuer lokales DNS-Preset 1
  --dns-router-label TEXT      Anzeigename fuer lokales DNS-Preset 2
  --dns-router-value IPS       Wert fuer lokales DNS-Preset 2
  --speedtest-user USER        SSH-User fuer den Tunnel-Speedtest
  --speedtest-host HOST        Zielhost fuer den Tunnel-Speedtest
  --speedtest-ssh-key PFAD     SSH-Key fuer den Tunnel-Speedtest
  --speedtest-size-mb N        Datenmenge pro Speedtest-Richtung
  --with-ufw-fail2ban          Installiert zusaetzlich ufw und fail2ban (Host)
  --with-docker                Installiert zusaetzlich docker.io und docker-compose-plugin
  --with-reverse-proxy         Reverse-Proxy-Stack: Nginx Proxy Manager (impliziert --with-docker)
  --with-monitoring            Monitoring-Stack: Uptime Kuma, Watchtower, CrowdSec (impliziert --with-docker)
  --with-crowdsec-bouncer      Aktiviert zusaetzlich den CrowdSec Firewall-Bouncer
                               (standardmaessig AUS, um SSH-Aussperren zu vermeiden)
  --pushover-token TOKEN       Pushover API-Token fuer Benachrichtigungen (optional)
  --pushover-user KEY          Pushover User-Key fuer Benachrichtigungen (optional)
  --with-swap                  Richtet eine Swap-Datei ein (Default: ${SWAP_SIZE_MB} MB unter ${SWAP_FILE})
                               Empfohlen bei wenig RAM (z. B. 0.5 GB) zusammen mit --with-monitoring
  --swap-size-mb N             Groesse der Swap-Datei in MB (Default: ${SWAP_SIZE_MB})
  --swap-file PFAD             Pfad der Swap-Datei (Default: ${SWAP_FILE})
  --help                       Diese Hilfe anzeigen
EOF
}

log() {
  printf '[%s] %s\n' "${APP_NAME}" "$1"
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte als root ausfuehren."
    exit 1
  fi
}

require_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Fehler: Dieses Install-Script erwartet ein apt-basiertes System."
    exit 1
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --script-source)
        SCRIPT_SOURCE="$2"
        shift 2
        ;;
      --config-file)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --service-user)
        SERVICE_USER="$2"
        SERVICE_HOME="$(resolve_user_home "$SERVICE_USER" "${WIREGUARD2HOME_SERVICE_HOME:-}")"
        BACKUP_SSH_USER="$SERVICE_USER"
        BACKUP_SSH_HOME="$SERVICE_HOME"
        BACKUP_SSH_KEY="${BACKUP_SSH_HOME}/.ssh/gate2home_backup"
        TARGET_SCRIPT="${SERVICE_HOME}/Wireguard2Home.sh"
        CLIENT_DIR="${SERVICE_HOME}/wg-clients"
        BACKUP_DIR="${SERVICE_HOME}/backups/gate2home"
        PRE_RESTORE_DIR="${SERVICE_HOME}/pre-restore-backups"
        if [ "$SERVICE_USER" = "root" ]; then
          STATE_DIR="/var/lib/gate2home/wg-dashboard"
        else
          STATE_DIR="${SERVICE_HOME}/.local/state/gate2home/wg-dashboard"
        fi
        shift 2
        ;;
      --service-home)
        SERVICE_HOME="$2"
        BACKUP_SSH_HOME="$SERVICE_HOME"
        BACKUP_SSH_KEY="${BACKUP_SSH_HOME}/.ssh/gate2home_backup"
        TARGET_SCRIPT="${SERVICE_HOME}/Wireguard2Home.sh"
        CLIENT_DIR="${SERVICE_HOME}/wg-clients"
        BACKUP_DIR="${SERVICE_HOME}/backups/gate2home"
        PRE_RESTORE_DIR="${SERVICE_HOME}/pre-restore-backups"
        if [ "$SERVICE_USER" != "root" ]; then
          STATE_DIR="${SERVICE_HOME}/.local/state/gate2home/wg-dashboard"
        fi
        shift 2
        ;;
      --backup-ssh-user)
        BACKUP_SSH_USER="$2"
        BACKUP_SSH_HOME="$(resolve_user_home "$BACKUP_SSH_USER" "${WIREGUARD2HOME_BACKUP_SSH_HOME:-}")"
        BACKUP_SSH_KEY="${BACKUP_SSH_HOME}/.ssh/gate2home_backup"
        shift 2
        ;;
      --backup-ssh-home)
        BACKUP_SSH_HOME="$2"
        BACKUP_SSH_KEY="${BACKUP_SSH_HOME}/.ssh/gate2home_backup"
        shift 2
        ;;
      --backup-remote-user)
        BACKUP_REMOTE_USER="$2"
        BACKUP_REMOTE_HOME="$(resolve_user_home "$BACKUP_REMOTE_USER" "${WIREGUARD2HOME_BACKUP_REMOTE_HOME:-}")"
        RPI_TARGET="${BACKUP_REMOTE_HOME}/backups/from-vps"
        shift 2
        ;;
      --backup-remote-home)
        BACKUP_REMOTE_HOME="$2"
        RPI_TARGET="${BACKUP_REMOTE_HOME}/backups/from-vps"
        shift 2
        ;;
      --target-script)
        TARGET_SCRIPT="$2"
        shift 2
        ;;
      --server-address)
        WG_SERVER_IP_CIDR="$2"
        shift 2
        ;;
      --wg-network)
        WG_NET_CIDR="$2"
        shift 2
        ;;
      --listen-port)
        WG_LISTEN_PORT="$2"
        shift 2
        ;;
      --endpoint)
        WG_ENDPOINT="$2"
        shift 2
        ;;
      --lan-subnet)
        LAN_SUBNET="$2"
        LAN_SUBNET_EXPLICIT=1
        shift 2
        ;;
      --dns-home-label)
        DNS_HOME_LABEL="$2"
        shift 2
        ;;
      --dns-home-value)
        DNS_HOME_VALUE="$2"
        shift 2
        ;;
      --dns-router-label)
        DNS_ROUTER_LABEL="$2"
        shift 2
        ;;
      --dns-router-value)
        DNS_ROUTER_VALUE="$2"
        shift 2
        ;;
      --speedtest-user)
        SPEEDTEST_USER="$2"
        shift 2
        ;;
      --speedtest-host)
        SPEEDTEST_HOST="$2"
        shift 2
        ;;
      --speedtest-ssh-key)
        SPEEDTEST_SSH_KEY="$2"
        shift 2
        ;;
      --speedtest-size-mb)
        SPEEDTEST_SIZE_MB="$2"
        shift 2
        ;;
      --with-ufw-fail2ban)
        ENABLE_UFW_FAIL2BAN=1
        shift
        ;;
      --with-reverse-proxy)
        ENABLE_REVERSE_PROXY=1
        ENABLE_DOCKER=1
        shift
        ;;
      --with-monitoring)
        ENABLE_MONITORING=1
        ENABLE_DOCKER=1
        shift
        ;;
      --with-crowdsec-bouncer)
        ENABLE_CROWDSEC_BOUNCER=1
        shift
        ;;
      --pushover-token)
        PUSHOVER_TOKEN="$2"
        shift 2
        ;;
      --pushover-user)
        PUSHOVER_USER="$2"
        shift 2
        ;;
      --with-swap)
        ENABLE_SWAP=1
        shift
        ;;
      --swap-size-mb)
        SWAP_SIZE_MB="$2"
        ENABLE_SWAP=1
        shift 2
        ;;
      --swap-file)
        SWAP_FILE="$2"
        shift 2
        ;;
      --with-docker)
        ENABLE_DOCKER=1
        shift
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

prompt_runtime_defaults() {
  if [ ! -t 0 ]; then
    return
  fi

  echo ""

  # Endpoint: oeffentliche IP/Hostname des VPS fuer Client-Configs.
  # IPv4 wird bevorzugt; nur wenn keine IPv4 erreichbar ist, wird IPv6 genutzt.
  if [ -z "$WG_ENDPOINT" ]; then
    local _detected_ip=""
    if command -v curl >/dev/null 2>&1; then
      _detected_ip="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
      if [ -z "$_detected_ip" ]; then
        _detected_ip="$(curl -6 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
      fi
    elif command -v wget >/dev/null 2>&1; then
      _detected_ip="$(wget -4 -qO- --timeout=5 https://ifconfig.me 2>/dev/null || true)"
      if [ -z "$_detected_ip" ]; then
        _detected_ip="$(wget -6 -qO- --timeout=5 https://ifconfig.me 2>/dev/null || true)"
      fi
    fi
    local _default_endpoint="${_detected_ip:-vpn.example.com}:${WG_LISTEN_PORT}"
    echo "Oeffentlicher WireGuard-Endpunkt (wird in Client-Configs als 'Endpoint' eingetragen)."
    read -r -p "VPS-Endpunkt HOST:PORT [${_default_endpoint}]: " _endpoint_input
    WG_ENDPOINT="${_endpoint_input:-${_default_endpoint}}"
  fi

  if [ "$LAN_SUBNET_EXPLICIT" -eq 0 ]; then
    read -r -p "Heimnetz hinter dem Gateway-Host [${LAN_SUBNET}]: " LAN_SUBNET_INPUT
    if [ -n "${LAN_SUBNET_INPUT:-}" ]; then
      LAN_SUBNET="$LAN_SUBNET_INPUT"
    fi
  fi

  read -r -p "Label fuer Heim-DNS-Preset [${DNS_HOME_LABEL}]: " DNS_HOME_LABEL_INPUT
  if [ -n "${DNS_HOME_LABEL_INPUT:-}" ]; then
    DNS_HOME_LABEL="$DNS_HOME_LABEL_INPUT"
  fi

  read -r -p "Wert fuer Heim-DNS-Preset [${DNS_HOME_VALUE}]: " DNS_HOME_VALUE_INPUT
  if [ -n "${DNS_HOME_VALUE_INPUT:-}" ]; then
    DNS_HOME_VALUE="$DNS_HOME_VALUE_INPUT"
  fi

  read -r -p "Label fuer Router-DNS-Preset [${DNS_ROUTER_LABEL}]: " DNS_ROUTER_LABEL_INPUT
  if [ -n "${DNS_ROUTER_LABEL_INPUT:-}" ]; then
    DNS_ROUTER_LABEL="$DNS_ROUTER_LABEL_INPUT"
  fi

  read -r -p "Wert fuer Router-DNS-Preset [${DNS_ROUTER_VALUE}]: " DNS_ROUTER_VALUE_INPUT
  if [ -n "${DNS_ROUTER_VALUE_INPUT:-}" ]; then
    DNS_ROUTER_VALUE="$DNS_ROUTER_VALUE_INPUT"
  fi

  if [ "$ENABLE_MONITORING" -eq 1 ] && [ -t 0 ]; then
    echo ""
    echo "Pushover-Benachrichtigungen (optional, leer lassen zum Ueberspringen)."
    if [ -z "$PUSHOVER_TOKEN" ]; then
      read -r -p "Pushover API-Token: " PUSHOVER_TOKEN_INPUT
      if [ -n "${PUSHOVER_TOKEN_INPUT:-}" ]; then
        PUSHOVER_TOKEN="$PUSHOVER_TOKEN_INPUT"
      fi
    fi
    if [ -z "$PUSHOVER_USER" ]; then
      read -r -p "Pushover User-Key: " PUSHOVER_USER_INPUT
      if [ -n "${PUSHOVER_USER_INPUT:-}" ]; then
        PUSHOVER_USER="$PUSHOVER_USER_INPUT"
      fi
    fi
  fi
}

detect_total_ram_mb() {
  # Gesamter physischer RAM in MB (ohne Swap)
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  echo $(( kb / 1024 ))
}

detect_total_swap_mb() {
  local kb
  kb="$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  echo $(( kb / 1024 ))
}

setup_swap() {
  local size_mb="$SWAP_SIZE_MB"
  local file="$SWAP_FILE"

  local existing_swap
  existing_swap="$(detect_total_swap_mb)"
  if [ "$existing_swap" -gt 0 ]; then
    log "Swap bereits aktiv (${existing_swap} MB). Ueberspringe Swap-Einrichtung."
    return 0
  fi

  if [ -e "$file" ] && swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$file"; then
    log "Swap-Datei ${file} ist bereits eingebunden."
    return 0
  fi

  log "Richte Swap-Datei ein: ${file} (${size_mb} MB) ..."

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${size_mb}M" "$file" 2>/dev/null \
      || dd if=/dev/zero of="$file" bs=1M count="$size_mb" status=none
  else
    dd if=/dev/zero of="$file" bs=1M count="$size_mb" status=none
  fi

  chmod 600 "$file"
  mkswap "$file" >/dev/null 2>&1 || { log "Fehler: mkswap auf ${file} fehlgeschlagen."; rm -f "$file"; return 1; }
  swapon "$file" || { log "Fehler: swapon auf ${file} fehlgeschlagen."; return 1; }

  # Literal-Suche (fgrep) vermeidet Regex-Metachar-Probleme mit dem Pfad
  if ! grep -qF "$file" /etc/fstab 2>/dev/null; then
    printf '%s none swap sw 0 0\n' "$file" >> /etc/fstab
    log "Swap dauerhaft in /etc/fstab eingetragen."
  else
    log "Swap-Eintrag fuer ${file} bereits in /etc/fstab vorhanden."
  fi

  # Etwas konservativere Swap-Nutzung bei wenig RAM
  if [ ! -f /etc/sysctl.d/99-wireguard2home-swap.conf ]; then
    printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-wireguard2home-swap.conf
    sysctl -p /etc/sysctl.d/99-wireguard2home-swap.conf >/dev/null 2>&1 || true
  fi

  log "Swap aktiv: $(detect_total_swap_mb) MB."
}

check_monitoring_resources() {
  # Warnt, wenn fuer den Monitoring-Stack zu wenig RAM vorhanden ist.
  if [ "$ENABLE_MONITORING" -ne 1 ]; then
    return 0
  fi

  local ram_mb swap_mb
  ram_mb="$(detect_total_ram_mb)"
  swap_mb="$(detect_total_swap_mb)"

  if [ "$ram_mb" -ge "$MIN_MONITORING_RAM_MB" ]; then
    return 0
  fi

  echo ""
  echo "============================================================"
  echo "WARNUNG: Wenig Arbeitsspeicher fuer den Monitoring-Stack"
  echo "============================================================"
  echo "Erkannt:    ${ram_mb} MB RAM, ${swap_mb} MB Swap"
  echo "Empfohlen:  mindestens ${MIN_MONITORING_RAM_MB} MB RAM fuer"
  echo "            Tunnel + Reverse-Proxy + Monitoring."
  echo ""
  echo "Der Monitoring-Stack (Uptime Kuma, Watchtower, CrowdSec) belegt"
  echo "zusammen mit Docker und Nginx Proxy Manager grob 600-700 MB."
  echo "Ohne genuegend RAM/Swap koennen Container vom OOM-Killer beendet"
  echo "werden."
  echo ""
  if [ "$ENABLE_SWAP" -eq 1 ]; then
    echo "Hinweis: --with-swap ist aktiv – es wird eine Swap-Datei eingerichtet,"
    echo "die das RAM-Limit abfedert (aber langsamer als echter RAM ist)."
    echo "============================================================"
    echo ""
    return 0
  fi

  echo "Empfehlung: Mit --with-swap erneut starten (richtet ${SWAP_SIZE_MB} MB"
  echo "Swap ein) oder den VPS auf >= 1 GB RAM upgraden."
  echo "============================================================"
  echo ""

  if [ -t 0 ]; then
    read -r -p "Trotzdem ohne zusaetzlichen Swap fortfahren? [j/N]: " _ram_ans
    case "${_ram_ans:-N}" in
      [jJyY]) : ;;
      *) echo "Abgebrochen. Tipp: erneut mit --with-swap ausfuehren."; exit 1 ;;
    esac
  else
    log "Nicht-interaktiv: fahre trotz wenig RAM fort (erwaege --with-swap)."
  fi
}

install_compose_plugin() {
  # Compose V2 heisst je nach Distribution unterschiedlich:
  #  - Ubuntu/Debian Universe:     docker-compose-v2
  #  - Docker-eigenes APT-Repo:    docker-compose-plugin
  #  - Aelteres Standalone (V1):   docker-compose
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  local candidate
  for candidate in docker-compose-v2 docker-compose-plugin; do
    if apt-get install -y "$candidate" >/dev/null 2>&1; then
      log "Compose-Plugin installiert: ${candidate}"
      if docker compose version >/dev/null 2>&1; then
        return 0
      fi
    fi
  done

  # Fallback: Standalone docker-compose (V1)
  if apt-get install -y docker-compose >/dev/null 2>&1; then
    log "Standalone docker-compose (V1) als Fallback installiert."
    if command -v docker-compose >/dev/null 2>&1; then
      return 0
    fi
  fi

  log "Warnung: Konnte kein Docker-Compose-Plugin finden."
  log "Bitte manuell installieren (z. B. 'apt-get install docker-compose-v2')."
  return 1
}

ensure_docker() {
  export DEBIAN_FRONTEND=noninteractive

  if ! command -v docker >/dev/null 2>&1; then
    log "Installiere Docker-Engine (docker.io)..."
    apt-get install -y docker.io
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true

  install_compose_plugin || true
}

compose_up() {
  # $1 = Verzeichnis mit docker-compose.yml
  local dir="$1"
  if docker compose version >/dev/null 2>&1; then
    ( cd "$dir" && docker compose up -d )
  elif command -v docker-compose >/dev/null 2>&1; then
    ( cd "$dir" && docker-compose up -d )
  else
    log "Fehler: Docker Compose nicht verfuegbar – ueberspringe ${dir}."
    return 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Paketlisten werden aktualisiert..."
  apt-get update

  CORE_PACKAGES=(
    wireguard
    qrencode
    rsync
    iperf3
    openssh-client
    openssh-server
    tar
    gawk
    grep
    findutils
    coreutils
    procps
    iproute2
    curl
    ca-certificates
  )

  log "Installiere Kern-Abhaengigkeiten..."
  apt-get install -y "${CORE_PACKAGES[@]}"

  if [ "$ENABLE_UFW_FAIL2BAN" -eq 1 ]; then
    log "Installiere empfohlene Security-Pakete..."
    apt-get install -y ufw fail2ban
  fi

  if [ "$ENABLE_DOCKER" -eq 1 ]; then
    log "Installiere Docker-Pakete..."
    ensure_docker
  fi
}

configure_kernel_network() {
  cat > /etc/sysctl.d/99-wireguard2home-network.conf <<EOF
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

ensure_dir() {
  mkdir -p "$1"
  chmod "$2" "$1"
}

ensure_owner_access() {
  local path="$1"
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    chown "$SERVICE_USER":"$(id -gn "$SERVICE_USER")" "$path" >/dev/null 2>&1 || true
  fi
}

write_runtime_config() {
  cat > "$CONFIG_FILE" <<EOF
WIREGUARD2HOME_SERVICE_USER=$(printf '%q' "$SERVICE_USER")
WIREGUARD2HOME_SERVICE_HOME=$(printf '%q' "$SERVICE_HOME")
WIREGUARD2HOME_CLIENT_DIR=$(printf '%q' "$CLIENT_DIR")
WIREGUARD2HOME_STATE_DIR=$(printf '%q' "$STATE_DIR")
WIREGUARD2HOME_BACKUP_BASE=$(printf '%q' "$BACKUP_DIR")
WIREGUARD2HOME_PRE_RESTORE_ROOT=$(printf '%q' "$PRE_RESTORE_DIR")
WIREGUARD2HOME_TARGET_SCRIPT=$(printf '%q' "$TARGET_SCRIPT")
WIREGUARD2HOME_BACKUP_SSH_USER=$(printf '%q' "$BACKUP_SSH_USER")
WIREGUARD2HOME_BACKUP_SSH_HOME=$(printf '%q' "$BACKUP_SSH_HOME")
WIREGUARD2HOME_BACKUP_SSH_KEY=$(printf '%q' "$BACKUP_SSH_KEY")
WIREGUARD2HOME_BACKUP_REMOTE_USER=$(printf '%q' "$BACKUP_REMOTE_USER")
WIREGUARD2HOME_BACKUP_REMOTE_HOME=$(printf '%q' "$BACKUP_REMOTE_HOME")
WIREGUARD2HOME_BACKUP_REMOTE_TARGET=$(printf '%q' "$RPI_TARGET")
WIREGUARD2HOME_DNS_HOME_LABEL=$(printf '%q' "$DNS_HOME_LABEL")
WIREGUARD2HOME_DNS_HOME_VALUE=$(printf '%q' "$DNS_HOME_VALUE")
WIREGUARD2HOME_DNS_ROUTER_LABEL=$(printf '%q' "$DNS_ROUTER_LABEL")
WIREGUARD2HOME_DNS_ROUTER_VALUE=$(printf '%q' "$DNS_ROUTER_VALUE")
WIREGUARD2HOME_LAN_SUBNET=$(printf '%q' "$LAN_SUBNET")
WIREGUARD2HOME_ENDPOINT=$(printf '%q' "${WG_ENDPOINT:-vpn.example.com:51820}")
WIREGUARD2HOME_SPEEDTEST_USER=$(printf '%q' "$SPEEDTEST_USER")
WIREGUARD2HOME_SPEEDTEST_HOST=$(printf '%q' "$SPEEDTEST_HOST")
WIREGUARD2HOME_SPEEDTEST_SSH_KEY=$(printf '%q' "$SPEEDTEST_SSH_KEY")
WIREGUARD2HOME_SPEEDTEST_SIZE_MB=$(printf '%q' "$SPEEDTEST_SIZE_MB")
EOF
  chmod 600 "$CONFIG_FILE"
}

deploy_main_script() {
  if [ ! -f "$SCRIPT_SOURCE" ]; then
    log "Hinweis: ${SCRIPT_SOURCE} nicht gefunden. Deployment von ${TARGET_SCRIPT} wird uebersprungen."
    return
  fi

  if [ "$(readlink -f "$SCRIPT_SOURCE")" = "$(readlink -f "$TARGET_SCRIPT")" ]; then
    chmod 700 "$TARGET_SCRIPT"
    log "Hauptscript liegt bereits am Zielpfad ${TARGET_SCRIPT}. Deployment wird uebersprungen."
    return
  fi

  install -m 700 "$SCRIPT_SOURCE" "$TARGET_SCRIPT"
  log "Hauptscript deployed nach ${TARGET_SCRIPT}"
}

ensure_backup_ssh_key() {
  mkdir -p "${BACKUP_SSH_HOME}/.ssh"
  chmod 700 "${BACKUP_SSH_HOME}/.ssh"

  if [ ! -f "$BACKUP_SSH_KEY" ]; then
    log "Erzeuge Backup-SSH-Key fuer VPS -> Raspberry..."
    ssh-keygen -t ed25519 -f "$BACKUP_SSH_KEY" -N "" -C "$BACKUP_SSH_COMMENT" >/dev/null
  fi

  chmod 600 "$BACKUP_SSH_KEY"
  chmod 644 "${BACKUP_SSH_KEY}.pub"
}

ensure_server_keypair() {
  local private_key="${WG_DIR}/server_private.key"
  local public_key="${WG_DIR}/server_public.key"
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
    log "Erzeuge WireGuard Server-Keypair..."
    umask 077
    wg genkey | tee "$private_key" | wg pubkey > "$public_key"
  fi

  chmod 600 "$private_key"
  chmod 644 "$public_key"
}

write_wg_template_if_missing() {
  local private_key="${WG_DIR}/server_private.key"

  if [ -f "$WG_CONF" ]; then
    chmod 600 "$WG_CONF"
    log "${WG_CONF} existiert bereits. Bestehende Konfiguration bleibt erhalten."
    return
  fi

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_SERVER_IP_CIDR}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = $(cat "$private_key")
SaveConfig = false

# Optionales NAT-Beispiel fuer Internet-Ausleitung:
# PostUp = iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET_CIDR} -o eth0 -j MASQUERADE
# PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET_CIDR} -o eth0 -j MASQUERADE

# Raspberry-Peer hier ergaenzen, z. B.:
# [Peer]
# PublicKey = CHANGE_ME_RASPBERRY_PUBLIC_KEY
# AllowedIPs = 10.100.0.2/32, ${LAN_SUBNET}
# PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CONF"
  log "Template fuer ${WG_CONF} wurde angelegt."
}

enable_services() {
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl start ssh >/dev/null 2>&1 || systemctl start sshd >/dev/null 2>&1 || true
  systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
}

print_summary() {
  local server_public_key
  server_public_key="$(cat "${WG_DIR}/server_public.key")"

  echo ""
  echo "========================================"
  echo "${APP_NAME} VPS Installation abgeschlossen"
  echo "========================================"
  echo ""
  echo "Installierter Einstieg:"
  echo "  ${TARGET_SCRIPT}"
  echo ""
  echo "Wichtige Pfade:"
  echo "  WireGuard Config:     ${WG_CONF}"
  echo "  Client Configs:       ${CLIENT_DIR}"
  echo "  Dashboard State:      ${STATE_DIR}"
  echo "  Backup Ziel lokal:    ${BACKUP_DIR}"
  echo "  Pre-Restore Backups:  ${PRE_RESTORE_DIR}"
  echo "  Raspberry Backup-Key: ${BACKUP_SSH_KEY}"
  echo ""
  echo "Server Public Key:"
  echo "  ${server_public_key}"
  echo ""
  echo "Backup Public Key fuer den Gateway-Host:"
  echo "  $(cat "${BACKUP_SSH_KEY}.pub")"
  echo ""
  echo "Naechste Schritte:"
  echo "1. Gateway-Host mit install-gateway-host.sh vorbereiten."
  echo "2. Raspberry Public Key als Peer in ${WG_CONF} eintragen."
  echo "3. WireGuard mit systemctl restart wg-quick@${WG_IFACE} pruefen."
  echo "4. ${TARGET_SCRIPT} starten."
  echo ""

  if [ "$ENABLE_REVERSE_PROXY" -eq 1 ] || [ "$ENABLE_MONITORING" -eq 1 ]; then
    local host_ip="${WG_ENDPOINT%%:*}"
    [ -z "$host_ip" ] && host_ip="<VPS-IP>"
    echo "Zusatz-Stack (Docker):"
    if [ "$ENABLE_REVERSE_PROXY" -eq 1 ]; then
      echo "  Nginx Proxy Manager: http://${host_ip}:81"
      echo "    Erst-Login: admin@example.com / changeme (sofort aendern!)"
      echo "    Daten:      ${NPM_DIR}"
    fi
    if [ "$ENABLE_MONITORING" -eq 1 ]; then
      echo "  Uptime Kuma:         http://${host_ip}:3001 (Admin beim ersten Aufruf anlegen)"
      echo "    Daten:             ${UPTIME_DIR}"
      echo "  Watchtower:          aktiv (${WATCHTOWER_DIR})"
      echo "  CrowdSec:            aktiv (${CROWDSEC_DIR})"
      if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
        echo "  Pushover:            konfiguriert (Watchtower-Notifications)"
      else
        echo "  Pushover:            nicht gesetzt – in ${WATCHTOWER_DIR}/.env nachtragen"
      fi
    fi
    echo ""
    echo "Ressourcen: $(detect_total_ram_mb) MB RAM, $(detect_total_swap_mb) MB Swap"
    echo "WICHTIG: Firewall/Ports 80, 443, 81, 3001 am VPS ggf. freigeben."
    echo ""
  fi
}

write_pushover_env() {
  # Schreibt eine root-only .env mit optionalen Pushover-Notifications.
  # $1 = Zielpfad der .env
  local env_path="$1"
  {
    echo "# Wireguard2Home Monitoring – automatisch erzeugt"
    echo "# Pushover-Benachrichtigungen (optional). Leer = deaktiviert."
    if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
      echo "WATCHTOWER_NOTIFICATIONS=shoutrrr"
      echo "WATCHTOWER_NOTIFICATION_URL=pushover://shoutrrr:${PUSHOVER_TOKEN}@${PUSHOVER_USER}"
      echo "PUSHOVER_TOKEN=${PUSHOVER_TOKEN}"
      echo "PUSHOVER_USER=${PUSHOVER_USER}"
    else
      echo "# PUSHOVER_TOKEN=CHANGE_ME"
      echo "# PUSHOVER_USER=CHANGE_ME"
      echo "# Danach in /opt/watchtower/.env eintragen:"
      echo "# WATCHTOWER_NOTIFICATIONS=shoutrrr"
      echo "# WATCHTOWER_NOTIFICATION_URL=pushover://shoutrrr:CHANGE_ME_TOKEN@CHANGE_ME_USER"
    fi
  } > "$env_path"
  chmod 600 "$env_path"
}

ensure_proxy_network() {
  if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
    log "Erstelle gemeinsames Docker-Netzwerk ${PROXY_NETWORK} ..."
    docker network create "$PROXY_NETWORK"
  fi
}

deploy_reverse_proxy() {
  log "Richte Reverse Proxy (Nginx Proxy Manager) ein..."
  ensure_docker
  ensure_proxy_network
  ensure_dir "$NPM_DIR" 700
  ensure_dir "${NPM_DIR}/data" 700
  ensure_dir "${NPM_DIR}/letsencrypt" 700

  cat > "${NPM_DIR}/docker-compose.yml" <<'____NPM_COMPOSE____'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy_net

networks:
  proxy_net:
    external: true
    name: gate2home_proxy
____NPM_COMPOSE____
  chmod 600 "${NPM_DIR}/docker-compose.yml"

  compose_up "$NPM_DIR" || log "Hinweis: NPM-Stack konnte nicht gestartet werden."
}

deploy_uptime_kuma() {
  log "Richte Uptime Kuma ein..."
  ensure_dir "$UPTIME_DIR" 700
  ensure_dir "${UPTIME_DIR}/data" 700
  cat > "${UPTIME_DIR}/docker-compose.yml" <<'____UPTIME_COMPOSE____'
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    expose:
      - "3001"
    volumes:
      - ./data:/app/data
    networks:
      - proxy_net

networks:
  proxy_net:
    external: true
    name: gate2home_proxy
____UPTIME_COMPOSE____
  chmod 600 "${UPTIME_DIR}/docker-compose.yml"
  compose_up "$UPTIME_DIR" || log "Hinweis: Uptime-Kuma-Stack konnte nicht gestartet werden."
}

deploy_monitoring() {
  log "Richte Monitoring-Stack ein (Uptime Kuma, Watchtower, CrowdSec)..."
  ensure_docker
  ensure_proxy_network

  # --- Uptime Kuma ---
  deploy_uptime_kuma

  # --- Watchtower (mit optionalen Pushover-Notifications) ---
  ensure_dir "$WATCHTOWER_DIR" 700
  write_pushover_env "${WATCHTOWER_DIR}/.env"
  cat > "${WATCHTOWER_DIR}/docker-compose.yml" <<'____WATCHTOWER_COMPOSE____'
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
____WATCHTOWER_COMPOSE____
  chmod 600 "${WATCHTOWER_DIR}/docker-compose.yml"
  compose_up "$WATCHTOWER_DIR" || log "Hinweis: Watchtower-Stack konnte nicht gestartet werden."

  # --- CrowdSec (Detection; Firewall-Bouncer nur auf Wunsch) ---
  ensure_dir "$CROWDSEC_DIR" 700
  ensure_dir "${CROWDSEC_DIR}/config" 700
  ensure_dir "${CROWDSEC_DIR}/data" 700
  cat > "${CROWDSEC_DIR}/config/acquis.yaml" <<'____CROWDSEC_ACQUIS____'
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
---
filenames:
  - /opt/npm/data/logs/*.log
labels:
  type: nginx
____CROWDSEC_ACQUIS____
  chmod 600 "${CROWDSEC_DIR}/config/acquis.yaml"

  cat > "${CROWDSEC_DIR}/docker-compose.yml" <<'____CROWDSEC_COMPOSE____'
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager
    volumes:
      - ./config:/etc/crowdsec
      - ./data:/var/lib/crowdsec/data
      - /var/log:/var/log:ro
      - /opt/npm/data/logs:/opt/npm/data/logs:ro
____CROWDSEC_COMPOSE____
  chmod 600 "${CROWDSEC_DIR}/docker-compose.yml"
  compose_up "$CROWDSEC_DIR" || log "Hinweis: CrowdSec-Stack konnte nicht gestartet werden."

  if [ "$ENABLE_CROWDSEC_BOUNCER" -eq 1 ]; then
    log "Installiere CrowdSec Firewall-Bouncer auf dem Host..."
    apt-get install -y crowdsec-firewall-bouncer-iptables 2>/dev/null \
      || log "Hinweis: Firewall-Bouncer-Paket nicht verfuegbar – bitte manuell einrichten."
  else
    log "CrowdSec Firewall-Bouncer NICHT aktiviert (Schutz vor SSH-Aussperren)."
    log "Aktivierung optional mit --with-crowdsec-bouncer."
  fi
}

main() {
  parse_args "$@"
  require_root
  require_apt
  prompt_runtime_defaults

  # Ressourcen-Pruefung + optionaler Swap, bevor der schwere Stack startet
  check_monitoring_resources
  if [ "$ENABLE_SWAP" -eq 1 ]; then
    setup_swap || log "Hinweis: Swap-Einrichtung fehlgeschlagen – fahre fort."
  fi

  install_packages

  ensure_dir "$WG_DIR" 700
  ensure_dir "$CLIENT_DIR" 700
  ensure_dir "$STATE_DIR" 700
  ensure_dir "$BACKUP_DIR" 700
  ensure_dir "$PRE_RESTORE_DIR" 700
  ensure_dir "$NPM_DIR" 700
  ensure_dir "$WATCHTOWER_DIR" 700
  ensure_dir "$UPTIME_DIR" 700
  ensure_dir "$CROWDSEC_DIR" 700
  ensure_dir "$(dirname "$TARGET_SCRIPT")" 700

  write_runtime_config
  deploy_main_script
  ensure_backup_ssh_key
  ensure_server_keypair
  write_wg_template_if_missing
  configure_kernel_network
  enable_services
  ensure_owner_access "$CLIENT_DIR"
  ensure_owner_access "$STATE_DIR"
  ensure_owner_access "$BACKUP_DIR"
  ensure_owner_access "$PRE_RESTORE_DIR"
  ensure_owner_access "$CONFIG_FILE"
  ensure_owner_access "$TARGET_SCRIPT"

  if [ "$ENABLE_REVERSE_PROXY" -eq 1 ]; then
    deploy_reverse_proxy
  fi
  if [ "$ENABLE_MONITORING" -eq 1 ]; then
    deploy_monitoring
  fi

  print_summary
}

main "$@"
