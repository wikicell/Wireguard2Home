#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
# Self-contained bootstrap — all sub-scripts are embedded as heredocs.
# Embedded content: keep in sync with standalone files in the repository.
set -euo pipefail

APP_NAME="Wireguard2Home"
RAW_BASE_URL="https://raw.githubusercontent.com/wikicell/Wireguard2Home/main"
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

ROLE="auto"
VPS_HOST=""
VPS_SSH_KEY=""
SERVICE_USER="${WIREGUARD2HOME_SERVICE_USER:-root}"
SERVICE_HOME="$(resolve_user_home "$SERVICE_USER" "${WIREGUARD2HOME_SERVICE_HOME:-}")"
REMOTE_SERVICE_USER="${WIREGUARD2HOME_REMOTE_SERVICE_USER:-$SERVICE_USER}"
REMOTE_SERVICE_HOME="$(resolve_user_home "$REMOTE_SERVICE_USER" "${WIREGUARD2HOME_REMOTE_SERVICE_HOME:-}")"
REMOTE_INSTALL_DIR="${WIREGUARD2HOME_REMOTE_INSTALL_DIR:-$REMOTE_SERVICE_HOME}"
SERVER_PUBLIC_KEY=""
VPS_BACKUP_PUBLIC_KEY=""
RASPBERRY_INSTALL_ARGS=()
VPS_ENDPOINT_HOST=""
WG_LISTEN_PORT="51820"
LAN_SUBNET="192.168.50.0/24"
DNS_HOME_LABEL="Home DNS"
DNS_HOME_VALUE="192.168.50.53"
DNS_ROUTER_LABEL="Router DNS"
DNS_ROUTER_VALUE="192.168.50.1"
UPDATE_MODE=0

usage() {
  cat <<EOF
${APP_NAME} Bootstrap Installer

Nutzung:
  $0 [optionen]

Rollen:
  --role auto|vps|gateway
    auto       Erkennt Gateway-Host bevorzugt automatisch, sonst VPS
    vps        Installiert nur den VPS-Teil lokal
    gateway    Installiert lokal den Gateway-Host-Teil und optional den VPS-Teil remote per SSH

Wichtige Optionen:
  --vps-host USER@HOST          SSH-Ziel fuer den VPS, z. B. root@YOUR_VPS_HOST
  --vps-ssh-key PFAD            SSH-Key fuer den VPS-Zugriff
  --service-user USER           Lokaler Service-User fuer Dateien und Runtime-Daten
  --service-home PFAD           Lokales Home des Service-Users
  --remote-service-user USER    Service-User auf dem VPS
  --remote-service-home PFAD    Home des Service-Users auf dem VPS
  --remote-install-dir PFAD     Zielverzeichnis auf dem VPS (Standard: Home des Remote-Service-Users)
  --server-public-key KEY       VPS WireGuard Public Key fuer Gateway-Install
  --vps-backup-public-key KEY   VPS Backup SSH Public Key fuer Gateway-Install

Infrastruktur-Konfiguration (interaktiv abgefragt, wenn nicht angegeben):
  --server-endpoint HOST[:PORT] Oeffentlicher Hostname/IP des VPS fuer WireGuard-Endpoint
  --wg-port PORT                WireGuard ListenPort (Standard: 51820)
  --lan-subnet CIDR             Heimnetz hinter dem Gateway-Host (Standard: 192.168.50.0/24)
  --dns-home-label TEXT         Anzeigename fuer Heim-DNS-Preset
  --dns-home-value IPS          IP fuer Heim-DNS-Preset (z. B. AdGuard Home oder Pi-hole)
  --dns-router-label TEXT       Anzeigename fuer Router-DNS-Preset
  --dns-router-value IPS        IP fuer Router-DNS-Preset (z. B. FRITZ!Box)

  --help                        Diese Hilfe anzeigen

Aktualisierung bereits installierter Hosts:
  --update                      Aktualisiert nur die Runtime-Skripte
                                (Wireguard2Home.sh etc.), ohne WireGuard-
                                Konfiguration oder Schluessel zu veraendern.
                                Mit --role gateway --vps-host USER@HOST wird
                                zusaetzlich der VPS per SSH aktualisiert.

Beispiele:
  $0 --role vps
  $0 --role gateway --vps-host root@YOUR_VPS_HOST --vps-ssh-key /root/.ssh/id_rsa
  $0 --update
  $0 --update --role gateway --vps-host root@YOUR_VPS_HOST
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehler: Benoetigtes Kommando nicht gefunden: $1"
    exit 1
  fi
}

# Stellt den SSH-Client (ssh/scp) sicher. openssh-server liefert nur den
# Daemon (sshd); der Client kommt je nach Distribution aus einem eigenen Paket.
ensure_ssh_client() {
  if command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1; then
    return
  fi

  log "SSH-Client (ssh/scp) nicht gefunden – Installation wird versucht ..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openssh-client
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-clients
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-clients
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm openssh
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install openssh-clients
  else
    echo "Fehler: Konnte SSH-Client nicht automatisch installieren."
    echo "Bitte 'openssh-client' (bzw. 'openssh-clients') manuell installieren."
    exit 1
  fi

  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    echo "Fehler: SSH-Client (ssh/scp) ist weiterhin nicht verfuegbar."
    exit 1
  fi
}

shell_escape() {
  printf '%q' "$1"
}

detect_role() {
  if [ -f /proc/device-tree/model ] && grep -qi 'raspberry\|deskpi' /proc/device-tree/model 2>/dev/null; then
    echo "gateway"
    return
  fi
  echo "vps"
}

ask_role_if_needed() {
  if [ "$ROLE" != "auto" ]; then
    return
  fi

  DETECTED_ROLE="$(detect_role)"

  if [ -t 0 ]; then
    echo ""
    echo "Installationsziel auswaehlen:"
    echo "1) VPS lokal vorbereiten"
    echo "2) Gateway-Host lokal vorbereiten und VPS remote per SSH anstossen"
    echo ""
    read -r -p "Auswahl [${DETECTED_ROLE}]: " ROLE_CHOICE

    case "$ROLE_CHOICE" in
      "" )  ROLE="$DETECTED_ROLE" ;;
      1)    ROLE="vps" ;;
      2)    ROLE="gateway" ;;
      *)    echo "Fehler: Ungueltige Auswahl."; exit 1 ;;
    esac
  else
    ROLE="$DETECTED_ROLE"
  fi
}

ask_gateway_connection_if_needed() {
  if [ "$ROLE" != "gateway" ] || [ -n "$VPS_HOST" ]; then
    return
  fi

  if [ ! -t 0 ]; then
    echo "Fehler: Fuer den Gateway-Modus ist --vps-host USER@HOST erforderlich."
    exit 1
  fi

  echo ""
  echo "VPS-Verbindung fuer den Gateway-Host:"
  echo "Beispiel: root@203.0.113.10 oder admin@vpn.example.com"
  read -r -p "VPS SSH-Ziel USER@HOST: " VPS_HOST

  if [ -z "$VPS_HOST" ]; then
    echo "Fehler: Fuer den Gateway-Modus ist ein VPS SSH-Ziel erforderlich."
    exit 1
  fi

  echo ""
  echo "Optional: Pfad zu einer SSH-Key-Datei fuer den VPS-Zugriff,"
  echo "z. B. /root/.ssh/id_rsa oder ~/.ssh/id_ed25519."
  echo "Einfach leer lassen und Enter druecken, wenn der VPS nur per"
  echo "Passwort erreichbar ist oder ein SSH-Agent/Standard-Key genutzt wird"
  echo "(dann wird nach dem Passwort gefragt)."
  read -r -p "Pfad zur SSH-Key-Datei (leer = Passwort/Agent): " VPS_SSH_KEY_INPUT
  if [ -n "${VPS_SSH_KEY_INPUT:-}" ]; then
    # Tilde-Expansion fuer Eingaben wie ~/.ssh/id_rsa
    case "$VPS_SSH_KEY_INPUT" in
      "~/"*) VPS_SSH_KEY_INPUT="${HOME}/${VPS_SSH_KEY_INPUT#"~/"}" ;;
      "~")   VPS_SSH_KEY_INPUT="${HOME}" ;;
    esac
    if [ ! -f "$VPS_SSH_KEY_INPUT" ]; then
      echo "Warnung: '${VPS_SSH_KEY_INPUT}' ist keine vorhandene Datei."
      echo "Es wird stattdessen Passwort-/Agent-Authentifizierung versucht."
    else
      VPS_SSH_KEY="$VPS_SSH_KEY_INPUT"
    fi
  fi
}

ask_infra_config_if_needed() {
  if [ ! -t 0 ]; then
    return
  fi

  echo ""
  echo "Infrastruktur-Konfiguration:"

  if [ -z "$VPS_ENDPOINT_HOST" ]; then
    if [ "$ROLE" = "gateway" ] && [ -n "$VPS_HOST" ]; then
      VPS_ENDPOINT_HOST="${VPS_HOST##*@}"
    else
      local _detected_ip=""
      if command -v curl >/dev/null 2>&1; then
        _detected_ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
      fi
      echo ""
      read -r -p "Oeffentlicher Hostname oder IP des VPS fuer WireGuard-Endpoint [${_detected_ip:-vpn.example.com}]: " _input
      VPS_ENDPOINT_HOST="${_input:-${_detected_ip:-vpn.example.com}}"
    fi
  fi

  echo ""
  read -r -p "WireGuard ListenPort [${WG_LISTEN_PORT}]: " _input
  WG_LISTEN_PORT="${_input:-${WG_LISTEN_PORT}}"

  echo ""
  read -r -p "Heimnetz hinter dem Gateway-Host [${LAN_SUBNET}]: " _input
  LAN_SUBNET="${_input:-${LAN_SUBNET}}"

  echo ""
  read -r -p "Heim-DNS IP, z. B. AdGuard Home oder Pi-hole [${DNS_HOME_VALUE}]: " _input
  DNS_HOME_VALUE="${_input:-${DNS_HOME_VALUE}}"

  echo ""
  read -r -p "Label fuer Heim-DNS-Preset [${DNS_HOME_LABEL}]: " _input
  DNS_HOME_LABEL="${_input:-${DNS_HOME_LABEL}}"

  echo ""
  read -r -p "Router-DNS IP, z. B. FRITZ!Box [${DNS_ROUTER_VALUE}]: " _input
  DNS_ROUTER_VALUE="${_input:-${DNS_ROUTER_VALUE}}"

  echo ""
  read -r -p "Label fuer Router-DNS-Preset [${DNS_ROUTER_LABEL}]: " _input
  DNS_ROUTER_LABEL="${_input:-${DNS_ROUTER_LABEL}}"

  echo ""
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)
        ROLE="$2"
        if [ "$ROLE" = "raspberry" ]; then ROLE="gateway"; fi
        shift 2
        ;;
      --vps-host)
        VPS_HOST="$2"; shift 2 ;;
      --vps-ssh-key)
        VPS_SSH_KEY="$2"; shift 2 ;;
      --service-user)
        SERVICE_USER="$2"
        SERVICE_HOME="$(resolve_user_home "$SERVICE_USER" "${WIREGUARD2HOME_SERVICE_HOME:-}")"
        shift 2
        ;;
      --service-home)
        SERVICE_HOME="$2"; shift 2 ;;
      --remote-service-user)
        REMOTE_SERVICE_USER="$2"
        REMOTE_SERVICE_HOME="$(resolve_user_home "$REMOTE_SERVICE_USER" "${WIREGUARD2HOME_REMOTE_SERVICE_HOME:-}")"
        REMOTE_INSTALL_DIR="$REMOTE_SERVICE_HOME"
        shift 2
        ;;
      --remote-service-home)
        REMOTE_SERVICE_HOME="$2"
        REMOTE_INSTALL_DIR="$REMOTE_SERVICE_HOME"
        shift 2
        ;;
      --remote-install-dir)
        REMOTE_INSTALL_DIR="$2"; shift 2 ;;
      --server-public-key)
        SERVER_PUBLIC_KEY="$2"; shift 2 ;;
      --vps-backup-public-key)
        VPS_BACKUP_PUBLIC_KEY="$2"; shift 2 ;;
      --raw-base-url)
        RAW_BASE_URL="$2"; shift 2 ;;
      --server-endpoint)
        VPS_ENDPOINT_HOST="${2%%:*}"
        if [[ "$2" == *:* ]]; then WG_LISTEN_PORT="${2##*:}"; fi
        shift 2
        ;;
      --wg-port)
        WG_LISTEN_PORT="$2"; shift 2 ;;
      --lan-subnet)
        LAN_SUBNET="$2"; shift 2 ;;
      --dns-home-label)
        DNS_HOME_LABEL="$2"; shift 2 ;;
      --dns-home-value)
        DNS_HOME_VALUE="$2"; shift 2 ;;
      --dns-router-label)
        DNS_ROUTER_LABEL="$2"; shift 2 ;;
      --dns-router-value)
        DNS_ROUTER_VALUE="$2"; shift 2 ;;
      --update)
        UPDATE_MODE=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        log "Option '$1' wird an den jeweiligen Installer (VPS/Gateway) weitergereicht."
        RASPBERRY_INSTALL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Embedded scripts — keep in sync with standalone files in the repository
# ──────────────────────────────────────────────────────────────────────────────

write_runtime_paths_sh() {
  cat > "$1" <<'____W2H_RUNTIME_PATHS____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.

WIREGUARD2HOME_CONFIG_FILE="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"

if [ -f "$WIREGUARD2HOME_CONFIG_FILE" ]; then
  # Shared runtime overrides for service-user and path configuration.
  # shellcheck disable=SC1090
  . "$WIREGUARD2HOME_CONFIG_FILE"
fi

wireguard2home_resolve_user_home() {
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

WIREGUARD2HOME_SERVICE_USER="${WIREGUARD2HOME_SERVICE_USER:-root}"
WIREGUARD2HOME_SERVICE_HOME="$(wireguard2home_resolve_user_home "$WIREGUARD2HOME_SERVICE_USER" "${WIREGUARD2HOME_SERVICE_HOME:-}")"
WIREGUARD2HOME_BACKUP_SSH_USER="${WIREGUARD2HOME_BACKUP_SSH_USER:-$WIREGUARD2HOME_SERVICE_USER}"
WIREGUARD2HOME_BACKUP_SSH_HOME="$(wireguard2home_resolve_user_home "$WIREGUARD2HOME_BACKUP_SSH_USER" "${WIREGUARD2HOME_BACKUP_SSH_HOME:-}")"
WIREGUARD2HOME_BACKUP_REMOTE_USER="${WIREGUARD2HOME_BACKUP_REMOTE_USER:-root}"
WIREGUARD2HOME_BACKUP_REMOTE_HOME="$(wireguard2home_resolve_user_home "$WIREGUARD2HOME_BACKUP_REMOTE_USER" "${WIREGUARD2HOME_BACKUP_REMOTE_HOME:-}")"

WIREGUARD2HOME_CLIENT_DIR="${WIREGUARD2HOME_CLIENT_DIR:-${WIREGUARD2HOME_SERVICE_HOME}/wg-clients}"
WIREGUARD2HOME_CLIENT_ARCHIVE_PATH="${WIREGUARD2HOME_CLIENT_DIR#/}"

if [ -z "${WIREGUARD2HOME_STATE_DIR:-}" ]; then
  if [ "$WIREGUARD2HOME_SERVICE_USER" = "root" ]; then
    WIREGUARD2HOME_STATE_DIR="/var/lib/gate2home/wg-dashboard"
  else
    WIREGUARD2HOME_STATE_DIR="${WIREGUARD2HOME_SERVICE_HOME}/.local/state/gate2home/wg-dashboard"
  fi
fi

WIREGUARD2HOME_BACKUP_BASE="${WIREGUARD2HOME_BACKUP_BASE:-${WIREGUARD2HOME_SERVICE_HOME}/backups/gate2home}"
WIREGUARD2HOME_PRE_RESTORE_ROOT="${WIREGUARD2HOME_PRE_RESTORE_ROOT:-${WIREGUARD2HOME_SERVICE_HOME}/pre-restore-backups}"
WIREGUARD2HOME_TARGET_SCRIPT="${WIREGUARD2HOME_TARGET_SCRIPT:-${WIREGUARD2HOME_SERVICE_HOME}/Wireguard2Home.sh}"
WIREGUARD2HOME_BACKUP_SSH_KEY="${WIREGUARD2HOME_BACKUP_SSH_KEY:-${WIREGUARD2HOME_BACKUP_SSH_HOME}/.ssh/gate2home_backup}"
WIREGUARD2HOME_BACKUP_REMOTE_HOST="${WIREGUARD2HOME_BACKUP_REMOTE_HOST:-10.100.0.2}"
WIREGUARD2HOME_BACKUP_REMOTE_TARGET="${WIREGUARD2HOME_BACKUP_REMOTE_TARGET:-${WIREGUARD2HOME_BACKUP_REMOTE_HOME}/backups/from-vps}"
WIREGUARD2HOME_DASHBOARD_SCRIPT="${WIREGUARD2HOME_DASHBOARD_SCRIPT:-${WIREGUARD2HOME_SERVICE_HOME}/wireguard-dashboard.sh}"
WIREGUARD2HOME_DNS_HOME_LABEL="${WIREGUARD2HOME_DNS_HOME_LABEL:-Home DNS}"
WIREGUARD2HOME_DNS_HOME_VALUE="${WIREGUARD2HOME_DNS_HOME_VALUE:-192.168.50.53}"
WIREGUARD2HOME_DNS_ROUTER_LABEL="${WIREGUARD2HOME_DNS_ROUTER_LABEL:-Router DNS}"
WIREGUARD2HOME_DNS_ROUTER_VALUE="${WIREGUARD2HOME_DNS_ROUTER_VALUE:-192.168.50.1}"
WIREGUARD2HOME_LAN_SUBNET="${WIREGUARD2HOME_LAN_SUBNET:-192.168.50.0/24}"
WIREGUARD2HOME_ENDPOINT="${WIREGUARD2HOME_ENDPOINT:-vpn.example.com:51820}"
WIREGUARD2HOME_SPEEDTEST_USER="${WIREGUARD2HOME_SPEEDTEST_USER:-$WIREGUARD2HOME_BACKUP_REMOTE_USER}"
WIREGUARD2HOME_SPEEDTEST_HOST="${WIREGUARD2HOME_SPEEDTEST_HOST:-10.100.0.2}"
WIREGUARD2HOME_SPEEDTEST_SSH_KEY="${WIREGUARD2HOME_SPEEDTEST_SSH_KEY:-$WIREGUARD2HOME_BACKUP_SSH_KEY}"
WIREGUARD2HOME_SPEEDTEST_SIZE_MB="${WIREGUARD2HOME_SPEEDTEST_SIZE_MB:-64}"
____W2H_RUNTIME_PATHS____
  chmod 700 "$1"
}
write_install_vps_sh() {
  cat > "$1" <<'____W2H_INSTALL_VPS____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -euo pipefail

APP_NAME="Wireguard2Home"
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
PUSHOVER_TOKEN="${WIREGUARD2HOME_PUSHOVER_TOKEN:-}"
PUSHOVER_USER="${WIREGUARD2HOME_PUSHOVER_USER:-}"

usage() {
  cat <<EOF
${APP_NAME} VPS Installer

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
      echo "  Watchtower:          aktiv (${WATCHTOWER_DIR})"
      echo "  CrowdSec:            aktiv (${CROWDSEC_DIR})"
      if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
        echo "  Pushover:            konfiguriert (Watchtower-Notifications)"
      else
        echo "  Pushover:            nicht gesetzt – in ${WATCHTOWER_DIR}/.env nachtragen"
      fi
    fi
    echo ""
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

deploy_reverse_proxy() {
  log "Richte Reverse Proxy (Nginx Proxy Manager) ein..."
  ensure_docker
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
      - "81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
____NPM_COMPOSE____
  chmod 600 "${NPM_DIR}/docker-compose.yml"

  compose_up "$NPM_DIR" || log "Hinweis: NPM-Stack konnte nicht gestartet werden."
}

deploy_monitoring() {
  log "Richte Monitoring-Stack ein (Uptime Kuma, Watchtower, CrowdSec)..."
  ensure_docker

  # --- Uptime Kuma ---
  ensure_dir "$UPTIME_DIR" 700
  ensure_dir "${UPTIME_DIR}/data" 700
  cat > "${UPTIME_DIR}/docker-compose.yml" <<'____UPTIME_COMPOSE____'
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - ./data:/app/data
____UPTIME_COMPOSE____
  chmod 600 "${UPTIME_DIR}/docker-compose.yml"
  compose_up "$UPTIME_DIR" || log "Hinweis: Uptime-Kuma-Stack konnte nicht gestartet werden."

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
____W2H_INSTALL_VPS____
  chmod 700 "$1"
}
write_install_gateway_sh() {
  cat > "$1" <<'____W2H_INSTALL_GATEWAY____'
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
VPS_PEER_FILE="${WG_DIR}/vps-peer.conf"
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
        openssh-client \
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
        openssh-clients \
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
        openssh-clients \
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

update_server_peer_in_conf() {
  # Aktualisiert den VPS-[Peer]-Block in einer bereits vorhandenen wg0.conf
  # idempotent. Wichtig nach VPS-Neuaufsetzung: dort wird ein neuer Server-Key
  # erzeugt, und eine alte Gateway-Config wuerde sonst auf den falschen Key
  # zeigen (Handshake schlaegt fehl, Tunnel kommt nicht zustande).
  if [ -z "$SERVER_PUBLIC_KEY" ]; then
    log "Kein Server-Public-Key uebergeben – VPS-Peer wird nicht angepasst."
    return 0
  fi

  local tmp_conf
  tmp_conf="$(mktemp)"

  # Alle bestehenden [Peer]-Bloecke entfernen (Gateway hat genau einen Peer: den VPS)
  awk '
    BEGIN { RS=""; FS="\n" }
    {
      if ($0 ~ /\[Peer\]/) { next }
      printf "%s%s", (printed++ ? "\n\n" : ""), $0
    }
    END { if (printed) print "" }
  ' "$WG_CONF" > "$tmp_conf"

  # Frischen VPS-Peer anhaengen
  {
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${SERVER_PUBLIC_KEY}"
    echo "Endpoint = ${SERVER_ENDPOINT}"
    echo "AllowedIPs = ${WG_NETWORK_CIDR}"
    echo "PersistentKeepalive = 25"
  } >> "$tmp_conf"

  install -m 600 "$tmp_conf" "$WG_CONF"
  rm -f "$tmp_conf"
  log "VPS-Peer in ${WG_CONF} aktualisiert (PublicKey/Endpoint)."

  if [ "$HAS_SYSTEMCTL" -eq 1 ]; then
    systemctl restart "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
  fi
}

write_raspberry_template_if_missing() {
  local private_key="${WG_DIR}/raspberry_private.key"
  local nat_lines=""

  nat_lines="$(write_nat_lines || true)"

  if [ -f "$WG_CONF" ]; then
    chmod 600 "$WG_CONF"
    log "${WG_CONF} existiert bereits. Aktualisiere ggf. den VPS-Peer (Key/Endpoint)."
    update_server_peer_in_conf
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

write_vps_peer_file() {
  local gateway_public_key
  gateway_public_key="$(cat "${WG_DIR}/raspberry_public.key")"

  {
    echo "[Peer]"
    echo "PublicKey = ${gateway_public_key}"
    echo "AllowedIPs = 10.100.0.2/32, ${LAN_SUBNET}"
    echo "PersistentKeepalive = 25"
  } > "$VPS_PEER_FILE"

  chmod 600 "$VPS_PEER_FILE"
  log "Peer-Block fuer den VPS abgelegt unter ${VPS_PEER_FILE}."
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
  echo "Peer-Block fuer den VPS (auch gespeichert unter ${VPS_PEER_FILE}):"
  echo ""
  echo "[Peer]"
  echo "PublicKey = ${gateway_public_key}"
  echo "AllowedIPs = 10.100.0.2/32, ${LAN_SUBNET}"
  echo "PersistentKeepalive = 25"
  echo ""
  echo "Naechste Schritte:"
  echo "1. Obigen Peer-Block in ${WG_IFACE}.conf auf dem VPS eintragen"
  echo "   (beim Gateway-Setup ueber den Bootstrap-Installer geschieht das automatisch)."
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
  write_vps_peer_file
  enable_services
  print_summary
}

main "$@"
____W2H_INSTALL_GATEWAY____
  chmod 700 "$1"
}
write_wireguard2home_sh() {
  cat > "$1" <<'____W2H_MAIN_SCRIPT____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -e

APP_NAME="Wireguard2Home"
CONFIG_FILE="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"

if [ -f "$CONFIG_FILE" ]; then
  # Allow installers to persist service-user and path overrides centrally.
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

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

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IFACE}.conf"
ENDPOINT="${WIREGUARD2HOME_ENDPOINT:-vpn.example.com:51820}"
WG_NET_PREFIX="10.100.0"
START_IP=3
END_IP=254
CLIENT_DIR="${WIREGUARD2HOME_CLIENT_DIR:-${SERVICE_HOME}/wg-clients}"
CLIENT_ARCHIVE_PATH="${CLIENT_DIR#/}"
DNS_HOME_LABEL="${WIREGUARD2HOME_DNS_HOME_LABEL:-Home DNS}"
DNS_HOME_VALUE="${WIREGUARD2HOME_DNS_HOME_VALUE:-192.168.50.53}"
DNS_ROUTER_LABEL="${WIREGUARD2HOME_DNS_ROUTER_LABEL:-Router DNS}"
DNS_ROUTER_VALUE="${WIREGUARD2HOME_DNS_ROUTER_VALUE:-192.168.50.1}"
LAN_SUBNET="${WIREGUARD2HOME_LAN_SUBNET:-192.168.50.0/24}"
SPEEDTEST_USER="${WIREGUARD2HOME_SPEEDTEST_USER:-$BACKUP_REMOTE_USER}"
SPEEDTEST_HOST="${WIREGUARD2HOME_SPEEDTEST_HOST:-10.100.0.2}"
SPEEDTEST_SSH_KEY="${WIREGUARD2HOME_SPEEDTEST_SSH_KEY:-${BACKUP_SSH_HOME}/.ssh/gate2home_backup}"
SPEEDTEST_SIZE_MB="${WIREGUARD2HOME_SPEEDTEST_SIZE_MB:-64}"

if [ -n "${WIREGUARD2HOME_STATE_DIR:-}" ]; then
  STATE_DIR="$WIREGUARD2HOME_STATE_DIR"
elif [ "$SERVICE_USER" = "root" ]; then
  STATE_DIR="/var/lib/gate2home/wg-dashboard"
else
  STATE_DIR="${SERVICE_HOME}/.local/state/gate2home/wg-dashboard"
fi
ONLINE_THRESHOLD=180
DASHBOARD_VIEW_MODE="radar"
DASHBOARD_LAST_RENDER_TS=0
declare -A DASHBOARD_SCREEN_PREV_RX=()
declare -A DASHBOARD_SCREEN_PREV_TX=()
declare -A DASHBOARD_CLIENT_NAMES=()
declare -A DASHBOARD_CLIENT_WG_IPS=()

BACKUP_BASE="${WIREGUARD2HOME_BACKUP_BASE:-${SERVICE_HOME}/backups/gate2home}"
BACKUP_WORKDIR=""
BACKUP_FILE=""
RPI_USER="$BACKUP_REMOTE_USER"
RPI_HOST="${WIREGUARD2HOME_BACKUP_REMOTE_HOST:-10.100.0.2}"
RPI_TARGET="${WIREGUARD2HOME_BACKUP_REMOTE_TARGET:-$(resolve_user_home "$BACKUP_REMOTE_USER" "${WIREGUARD2HOME_BACKUP_REMOTE_HOME:-}")/backups/from-vps}"
SSH_KEY="${WIREGUARD2HOME_BACKUP_SSH_KEY:-${BACKUP_SSH_HOME}/.ssh/gate2home_backup}"
LOCAL_KEEP_DAYS=14
LOCAL_KEEP_COUNT=30
RPI_KEEP_DAYS=30
RPI_KEEP_COUNT=60

RESTORE_ROOT="/tmp/gate2home-restore"
RESTORE_TS=""
RESTORE_WORKDIR=""
PRE_RESTORE_BASE=""
PRE_RESTORE_ROOT="${WIREGUARD2HOME_PRE_RESTORE_ROOT:-${SERVICE_HOME}/pre-restore-backups}"
RESTORE_BACKUP_FILE=""
RESTORE_MODE="interactive"
RESTORE_DRY_RUN=0

common_require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehler: Benoetigtes Kommando nicht gefunden: $1"
    exit 1
  fi
}

common_require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte mit sudo oder als root ausfuehren."
    exit 1
  fi
}

common_pause_return() {
  echo ""
  read -p "Enter fuer Zurueck..." _ || true
}

common_use_colors() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

common_use_clear() {
  [ -t 1 ] && [ -n "${TERM:-}" ]
}

common_colorize() {
  COLOR="$1"
  TEXT="$2"

  if ! common_use_colors; then
    printf "%s" "$TEXT"
    return
  fi

  case "$COLOR" in
    green) printf '\033[32m%s\033[0m' "$TEXT" ;;
    yellow) printf '\033[33m%s\033[0m' "$TEXT" ;;
    red) printf '\033[31m%s\033[0m' "$TEXT" ;;
    cyan) printf '\033[36m%s\033[0m' "$TEXT" ;;
    blue) printf '\033[34m%s\033[0m' "$TEXT" ;;
    magenta) printf '\033[35m%s\033[0m' "$TEXT" ;;
    dim) printf '\033[2m%s\033[0m' "$TEXT" ;;
    bold) printf '\033[1m%s\033[0m' "$TEXT" ;;
    *) printf "%s" "$TEXT" ;;
  esac
}

common_repeat_char() {
  CHAR="$1"
  COUNT="$2"
  printf "%${COUNT}s" "" | tr " " "$CHAR"
}

common_human_bytes() {
  BYTES="$1"

  awk -v bytes="$BYTES" '
    function human(value) {
      split("B KiB MiB GiB TiB", units, " ")
      idx = 1
      while (value >= 1024 && idx < 5) {
        value /= 1024
        idx++
      }
      if (idx == 1) {
        return sprintf("%d %s", value, units[idx])
      }
      return sprintf("%.1f %s", value, units[idx])
    }
    BEGIN { print human(bytes) }
  '
}

common_truncate_field() {
  VALUE="$1"
  WIDTH="$2"

  awk -v value="$VALUE" -v width="$WIDTH" '
    BEGIN {
      if (length(value) <= width) {
        print value
      } else if (width <= 3) {
        print substr(value, 1, width)
      } else {
        print substr(value, 1, width - 3) "..."
      }
    }
  '
}

app_banner() {
  echo ""
  echo "========================================"
  echo "$APP_NAME"
  echo "========================================"
  echo ""
}

app_check_base_files() {
  if [ ! -f "$WG_CONF" ]; then
    echo "Fehler: $WG_CONF nicht gefunden."
    exit 1
  fi
}

app_require_wg_running() {
  SERVER_PUBLIC_KEY=$(wg show "$WG_IFACE" public-key 2>/dev/null || true)

  if [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Fehler: WireGuard Interface $WG_IFACE laeuft nicht."
    echo "Starte zuerst:"
    echo "systemctl restart wg-quick@$WG_IFACE"
    exit 1
  fi
}

app_show_help() {
  echo ""
  echo "========================================"
  echo "HILFE"
  echo "========================================"
  echo ""
  echo "1) Client Manager"
  echo "   Neue WireGuard-Clients anlegen, anzeigen und entfernen."
  echo ""
  echo "2) Status Dashboard (Snapshot)"
  echo "   Snapshot-Ansicht mit Radar/Inspector-Umschaltung."
  echo ""
  echo "3) Status Dashboard (Live)"
  echo "   Echtzeitansicht mit Traffic-Historie und Tastatursteuerung."
  echo ""
  echo "4) Backup erstellen"
  echo "   Erstellt ein Gate2Home-Backup und repliziert es zum Raspberry."
  echo ""
  echo "5) Restore starten"
  echo "   Stellt Clients, WireGuard oder das volle Setup wieder her."
  echo ""
  echo "6) Speedtests"
  echo "   Misst den Tunnel zum Raspberry und optional die"
  echo "   Internet-Downloadgeschwindigkeit des VPS."
  echo ""
  echo "Integrierte Module in dieser einen Datei:"
  echo "  Client-Verwaltung"
  echo "  Dashboard"
  echo "  Backup"
  echo "  Restore"
  echo ""
  echo "Wichtige Pfade:"
  echo "  WireGuard: $WG_CONF"
  echo "  Clients:   $CLIENT_DIR"
  echo "  State:     $STATE_DIR"
  echo "  Backups:   $BACKUP_BASE"
  echo ""
}

wireguard_backup_conf() {
  CONF_BACKUP_FILE="${WG_CONF}.bak-$(date +"%Y-%m-%d_%H-%M-%S")"
  cp "$WG_CONF" "$CONF_BACKUP_FILE"
  echo "$CONF_BACKUP_FILE"
}

wireguard_restore_conf() {
  CONF_BACKUP_FILE="$1"

  if [ -f "$CONF_BACKUP_FILE" ]; then
    cp "$CONF_BACKUP_FILE" "$WG_CONF"
    chmod 600 "$WG_CONF"
  fi
}

wireguard_restart_with_rollback() {
  CONF_BACKUP_FILE="$1"
  CLIENT_CONF_TO_DELETE="${2:-}"
  CLIENT_QR_TO_DELETE="${3:-}"

  if systemctl restart "wg-quick@$WG_IFACE"; then
    return 0
  fi

  echo ""
  echo "Fehler: Neustart von wg-quick@$WG_IFACE fehlgeschlagen."
  echo "Stelle letzte Sicherung wieder her: $CONF_BACKUP_FILE"

  wireguard_restore_conf "$CONF_BACKUP_FILE"

  if [ -n "$CLIENT_CONF_TO_DELETE" ]; then
    rm -f "$CLIENT_CONF_TO_DELETE"
  fi

  if [ -n "$CLIENT_QR_TO_DELETE" ]; then
    rm -f "$CLIENT_QR_TO_DELETE"
  fi

  systemctl restart "wg-quick@$WG_IFACE" || true
  return 1
}

wireguard_sanitize_name() {
  echo "$1" | tr -cd '[:alnum:]_-'
}

wireguard_get_used_ips() {
  shopt -s nullglob
  CLIENT_FILES=("$CLIENT_DIR"/*.conf)

  {
    awk -F'[ =/,\t]+' -v prefix="$WG_NET_PREFIX." '
      $1 == "AllowedIPs" {
        for (i = 2; i <= NF; i++) {
          if ($i ~ ("^" prefix "[0-9]+$") && $(i + 1) == "32") {
            print $i
          }
        }
      }
    ' "$WG_CONF" 2>/dev/null || true

    if [ ${#CLIENT_FILES[@]} -gt 0 ]; then
      awk -F'[ =/,\t]+' -v prefix="$WG_NET_PREFIX." '
        $1 == "Address" {
          for (i = 2; i <= NF; i++) {
            if ($i ~ ("^" prefix "[0-9]+$")) {
              print $i
            }
          }
        }
      ' "${CLIENT_FILES[@]}" 2>/dev/null || true
    fi
  } | sort -u
}

wireguard_get_next_ip() {
  USED_IPS=$(wireguard_get_used_ips)
  NEXT_IP=""

  for i in $(seq "$START_IP" "$END_IP"); do
    CANDIDATE="${WG_NET_PREFIX}.${i}"
    if ! echo "$USED_IPS" | grep -qx "$CANDIDATE"; then
      NEXT_IP="$CANDIDATE"
      break
    fi
  done

  echo "$NEXT_IP"
}

wireguard_validate_client_conf() {
  CONF_FILE="$1"

  if [ ! -f "$CONF_FILE" ]; then
    return 1
  fi

  grep -q "^\[Interface\]" "$CONF_FILE" && \
  grep -q "^PrivateKey =" "$CONF_FILE" && \
  grep -q "^Address =" "$CONF_FILE" && \
  grep -q "^\[Peer\]" "$CONF_FILE" && \
  grep -q "^PublicKey =" "$CONF_FILE" && \
  grep -q "^Endpoint =" "$CONF_FILE" && \
  grep -q "^AllowedIPs =" "$CONF_FILE"
}

wireguard_remove_peer_by_public_key() {
  TARGET_PUBLIC_KEY="$1"
  TMP_FILE="$2"

  awk -v target_key="$TARGET_PUBLIC_KEY" '
    function flush_peer_block() {
      if (!in_peer) {
        return
      }

      if (peer_public_key == target_key) {
        if (pending_comment != "") {
          pending_comment = ""
        }
      } else {
        printf "%s", pending_comment
        printf "%s", peer_block
      }

      pending_comment = ""
      peer_block = ""
      peer_public_key = ""
      in_peer = 0
    }

    BEGIN {
      in_peer = 0
      pending_comment = ""
      peer_block = ""
      peer_public_key = ""
    }

    /^\[Peer\]/ {
      flush_peer_block()
      in_peer = 1
      peer_block = $0 ORS
      next
    }

    in_peer && /^# END_CLIENT / {
      flush_peer_block()
      next
    }

    in_peer && /^# / {
      flush_peer_block()
      pending_comment = pending_comment $0 ORS
      next
    }

    in_peer {
      peer_block = peer_block $0 ORS

      if ($1 == "PublicKey" && $2 == "=") {
        peer_public_key = $3
      }
      next
    }

    /^# END_CLIENT / {
      next
    }

    /^# / {
      pending_comment = pending_comment $0 ORS
      next
    }

    pending_comment != "" {
      if ($0 ~ /^[[:space:]]*$/) {
        pending_comment = pending_comment $0 ORS
        next
      }

      printf "%s", pending_comment
      pending_comment = ""
    }

    { print }

    END {
      flush_peer_block()

      if (pending_comment != "") {
        printf "%s", pending_comment
      }
    }
  ' "$WG_CONF" > "$TMP_FILE"
}

wireguard_select_dns() {
  echo ""
  echo "DNS-Server fuer diesen Client auswaehlen:"
  echo ""
  echo "--- Heimnetz-DNS (Anfragen gehen durch den Tunnel in dein Heimnetz) ---"
  echo ""
  printf "  1) %-20s %s\n" "$DNS_HOME_LABEL" "$DNS_HOME_VALUE"
  echo "     Waehle diese Option wenn du Pi-hole, AdGuard Home oder einen"
  echo "     eigenen DNS-Server im Heimnetz betreibst."
  echo "     Vorteil: Werbeblocker, eigene DNS-Regeln, lokale Hostnamen."
  echo ""
  printf "  2) %-20s %s\n" "$DNS_ROUTER_LABEL" "$DNS_ROUTER_VALUE"
  echo "     Waehle diese Option wenn kein dedizierter DNS-Server vorhanden"
  echo "     ist und du nur den Router als DNS nutzt."
  echo "     Vorteil: Lokale DHCP-Hostnamen erreichbar (z. B. nas.fritz.box)."
  echo ""
  echo "  Entweder 1 oder 2 – je nachdem was in deinem Heimnetz laeuft."
  echo ""
  echo "--- Oeffentliche DNS (Anfragen gehen direkt ins Internet) -------------"
  echo ""
  echo "  3) Cloudflare        1.1.1.1, 1.0.0.1"
  echo "  4) Google            8.8.8.8, 8.8.4.4"
  echo "  5) OpenDNS           208.67.222.222, 208.67.220.220"
  echo ""
  echo "--- Sonstiges ---------------------------------------------------------"
  echo ""
  echo "  6) Kein DNS          (Geraet nutzt eigene DNS-Einstellungen)"
  echo "  7) Custom DNS        (eigene Adresse manuell eingeben)"
  echo ""

  read -p "Auswahl [1]: " DNS_CHOICE

  case "$DNS_CHOICE" in
    ""|1) DNS_SERVER="$DNS_HOME_VALUE"; DNS_SELECTION_KIND="home" ;;
    2) DNS_SERVER="$DNS_ROUTER_VALUE"; DNS_SELECTION_KIND="router" ;;
    3) DNS_SERVER="1.1.1.1, 1.0.0.1"; DNS_SELECTION_KIND="cloudflare" ;;
    4) DNS_SERVER="8.8.8.8, 8.8.4.4"; DNS_SELECTION_KIND="google" ;;
    5) DNS_SERVER="208.67.222.222, 208.67.220.220"; DNS_SELECTION_KIND="opendns" ;;
    6) DNS_SERVER=""; DNS_SELECTION_KIND="none" ;;
    7)
      read -p "Custom DNS: " DNS_SERVER
      if [ -z "$DNS_SERVER" ]; then
        echo "Fehler: DNS darf nicht leer sein."
        exit 1
      fi
      DNS_SELECTION_KIND="custom"
      ;;
    *)
      echo "Ungueltige Auswahl."
      exit 1
      ;;
  esac
}

wireguard_private_dns_routes() {
  printf '%s\n' "$1" | awk -F',' '
    function is_private(ip, octets) {
      split(ip, octets, ".")
      if (octets[1] == 10) return 1
      if (octets[1] == 192 && octets[2] == 168) return 1
      if (octets[1] == 172 && octets[2] >= 16 && octets[2] <= 31) return 1
      return 0
    }
    BEGIN { first = 1 }
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        if ($i != "" && is_private($i)) {
          if (!first) {
            printf ", "
          }
          printf "%s/32", $i
          first = 0
        }
      }
    }
  '
}

wireguard_apply_home_dns_split_mode() {
  EFFECTIVE_DNS_SERVER="$DNS_SERVER"
  if [ -z "$EFFECTIVE_DNS_SERVER" ] || [ "${DNS_SELECTION_KIND:-home}" = "none" ]; then
    EFFECTIVE_DNS_SERVER="$DNS_HOME_VALUE"
  fi

  HOME_DNS_ROUTES="$(wireguard_private_dns_routes "$EFFECTIVE_DNS_SERVER")"

  CLIENT_ALLOWED_IPS="${LAN_SUBNET}, 10.100.0.0/24"
  if [ -n "$HOME_DNS_ROUTES" ]; then
    CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS}, ${HOME_DNS_ROUTES}"
  fi

  DNS_SERVER="$EFFECTIVE_DNS_SERVER"
}

wireguard_apply_split_dns_routes_if_needed() {
  PRIVATE_DNS_ROUTES="$(wireguard_private_dns_routes "$DNS_SERVER")"
  if [ -n "$PRIVATE_DNS_ROUTES" ]; then
    CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS}, ${PRIVATE_DNS_ROUTES}"
  fi
}

wireguard_select_allowed_ips() {
  echo ""
  echo "Tunnel-Modus auswaehlen:"
  echo ""
  echo "1) Full-Tunnel"
  echo "   Leitet den kompletten Traffic des Clients durch den VPS."
  echo "   Gut fuer Reisen, fremde WLANs und wenn alles durch dein VPN soll."
  echo "   Beispiel-Ziel: Internet ueber VPN, z. B. Webseiten oder Apps"
  echo "   wie 1.1.1.1, 8.8.8.8 oder beliebige externe Dienste."
  echo "2) Split-Tunnel Heimnetz"
  echo "   Leitet nur Heimnetz und WireGuard-Netz durch den Tunnel."
  echo "   Das normale Internet des Clients bleibt lokal."
  echo "   Beispiel-Ziele: NAS ${LAN_SUBNET%0/24}10, Drucker ${LAN_SUBNET%0/24}20,"
  echo "   Router ${LAN_SUBNET%0/24}1 sowie VPS/andere WG-Clients unter 10.100.0.x."
  echo "3) Split-Tunnel einzelne IPs/Netze"
  echo "   Fuer gezielte Hosts, Dienste oder Teilnetze."
  echo "   Ideal, wenn nur einzelne Ziele ueber WireGuard erreichbar sein sollen."
  echo "   Beispiel-Ziele: NAS ${LAN_SUBNET%0/24}10/32, Proxmox ${LAN_SUBNET%0/24}20/32,"
  echo "   WG-Netz 10.100.0.0/24."
  echo "4) Split-Tunnel + Heim-DNS-Filter"
  echo "   Noob-freundlich fuer Handy und Laptop unterwegs."
  echo "   Internet bleibt direkt ueber Mobilfunk oder lokales WLAN."
  echo "   Heimnetz geht durch den Tunnel und DNS wird fest auf ${DNS_HOME_LABEL}"
  echo "   (${DNS_HOME_VALUE}) gesetzt."
  echo "   Vorteil: weniger Werbung, mehr Privatsphaere und interne Ziele bleiben"
  echo "   erreichbar, ohne dass dein kompletter Internet-Traffic durchs VPN muss."
  echo "   Beispiel-Ziele: NAS ${LAN_SUBNET%0/24}10, Router ${LAN_SUBNET%0/24}1,"
  echo "   Home Assistant ${LAN_SUBNET%0/24}30 plus DNS ueber ${DNS_HOME_VALUE}."
  echo ""

  read -p "Auswahl [1]: " TUNNEL_CHOICE

  case "$TUNNEL_CHOICE" in
    ""|1) CLIENT_ALLOWED_IPS="0.0.0.0/0" ;;
    2)
      CLIENT_ALLOWED_IPS="${LAN_SUBNET}, 10.100.0.0/24"
      if [ -n "$DNS_SERVER" ]; then
        wireguard_apply_split_dns_routes_if_needed
      fi
      ;;
    3)
      echo ""
      echo "Bitte einzelne IPs oder Netze eintragen."
      echo "Beispiel: ${LAN_SUBNET%0/24}10/32, 10.100.0.0/24"
      read -p "AllowedIPs: " CLIENT_ALLOWED_IPS
      if [ -z "$CLIENT_ALLOWED_IPS" ]; then
        echo "Fehler: AllowedIPs darf nicht leer sein."
        exit 1
      fi
      if [ -n "$DNS_SERVER" ]; then
        wireguard_apply_split_dns_routes_if_needed
      fi
      ;;
    4)
      wireguard_apply_home_dns_split_mode
      ;;
    *)
      echo "Ungueltige Auswahl."
      exit 1
      ;;
  esac
}

wireguard_list_clients() {
  echo ""
  echo "=============================="
  echo "Vorhandene WireGuard Clients"
  echo "=============================="
  echo ""

  mapfile -t FILES < <(wireguard_get_client_files_ordered)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "Keine Client-Configs gefunden in:"
    echo "$CLIENT_DIR"
    return
  fi

  printf "%-4s %-28s %-18s %-25s %-10s\n" "Nr." "Name" "IP" "DNS" "Status"
  printf "%-4s %-28s %-18s %-25s %-10s\n" "---" "----------------------------" "------------------" "-------------------------" "----------"

  INDEX=1
  for FILE in "${FILES[@]}"; do
    NAME=$(basename "$FILE" .conf)
    IP=$(grep "^Address =" "$FILE" | awk '{print $3}' | cut -d'/' -f1)
    DNS=$(grep "^DNS =" "$FILE" | cut -d'=' -f2- | xargs)

    if wireguard_validate_client_conf "$FILE"; then
      STATUS="gueltig"
    else
      STATUS="fehlerhaft"
    fi

    printf "%-4s %-28s %-18s %-25s %-10s\n" "$INDEX" "$NAME" "$IP" "$DNS" "$STATUS"
    INDEX=$((INDEX+1))
  done

  echo ""
}

wireguard_get_client_files_ordered() {
  shopt -s nullglob
  FILES=("$CLIENT_DIR"/*.conf)

  if [ ${#FILES[@]} -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${FILES[@]}" | while IFS= read -r FILE; do
    IP="$(grep "^Address =" "$FILE" | awk '{print $3}' | cut -d'/' -f1)"
    if [ -n "$IP" ]; then
      awk -v ip="$IP" -v file="$FILE" '
        BEGIN {
          split(ip, parts, ".")
          printf "%03d.%03d.%03d.%03d\t%s\n", parts[1], parts[2], parts[3], parts[4], file
        }
      '
    else
      printf "999.999.999.999\t%s\n" "$FILE"
    fi
  done | sort | cut -f2-
}

speedtest_start_remote_iperf_server() {
  ssh -i "$SPEEDTEST_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SPEEDTEST_USER}@${SPEEDTEST_HOST}" \
    "nohup iperf3 -s -1 >/tmp/wireguard2home-iperf3.log 2>&1 &"
}

speedtest_measure_direction() {
  DIRECTION="$1"
  CLIENT_ARGS=()

  if [ "$DIRECTION" = "download" ]; then
    CLIENT_ARGS+=("-R")
  fi

  speedtest_start_remote_iperf_server
  sleep 1

  IPERF_OUTPUT="$(iperf3 -c "$SPEEDTEST_HOST" -t 10 -f m "${CLIENT_ARGS[@]}")"
  SPEEDTEST_RATE="$(printf '%s\n' "$IPERF_OUTPUT" | awk '/receiver$/ {rate=$(NF-2); unit=$(NF-1)} END {if (rate != "") printf "%s %s", rate, unit}')"

  if [ -z "$SPEEDTEST_RATE" ]; then
    return 1
  fi

  printf '%s\n' "$SPEEDTEST_RATE"
}

run_tunnel_speedtest() {
  common_require_command ssh
  common_require_command iperf3
  common_require_command awk

  if [ ! -f "$SPEEDTEST_SSH_KEY" ]; then
    echo "Fehler: Speedtest-SSH-Key nicht gefunden: $SPEEDTEST_SSH_KEY"
    return
  fi

  echo ""
  echo "=============================="
  echo "Tunnel Speedtest"
  echo "=============================="
  echo ""
  echo "Ziel:   ${SPEEDTEST_USER}@${SPEEDTEST_HOST}"
  echo "Methode: iperf3 ueber den WireGuard-Tunnel"
  echo "Hinweis: SSH dient nur zum Starten des Remote-iperf3-Servers."
  echo ""

  SSH_PROBE_OUTPUT="$(ssh -i "$SPEEDTEST_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SPEEDTEST_USER}@${SPEEDTEST_HOST}" "command -v iperf3 >/dev/null 2>&1 && echo IPERF_OK || echo IPERF_MISSING" 2>&1)"
  SSH_PROBE_STATUS=$?

  if [ "$SSH_PROBE_STATUS" -ne 0 ]; then
    echo "Fehler: SSH-Verbindung zum Gateway-Host (${SPEEDTEST_USER}@${SPEEDTEST_HOST}) fehlgeschlagen."
    echo "Moegliche Ursachen:"
    echo "  - WireGuard-Tunnel ist nicht aktiv (pruefe: wg show)."
    echo "  - Der Gateway-Host hat den Speedtest-Key noch nicht autorisiert."
    echo "  - SSH-Key fehlt oder ist falsch: ${SPEEDTEST_SSH_KEY}"
    echo ""
    echo "SSH-Meldung:"
    printf '  %s\n' "$SSH_PROBE_OUTPUT"
    return
  fi

  if ! printf '%s\n' "$SSH_PROBE_OUTPUT" | grep -q 'IPERF_OK'; then
    echo "Fehler: iperf3 ist auf dem Gateway-Host (${SPEEDTEST_HOST}) nicht installiert."
    echo "Installiere es dort, z. B.: sudo apt-get install -y iperf3"
    return
  fi

  echo "Teste VPS -> Gateway-Host ueber den Tunnel..."
  if ! UPLOAD_RESULT="$(speedtest_measure_direction upload)"; then
    echo "Fehler: Upload-Test mit iperf3 konnte nicht ausgewertet werden."
    return
  fi

  echo "Teste Gateway-Host -> VPS ueber den Tunnel..."
  if ! DOWNLOAD_RESULT="$(speedtest_measure_direction download)"; then
    echo "Fehler: Download-Test mit iperf3 konnte nicht ausgewertet werden."
    return
  fi

  echo ""
  printf "VPS -> Gateway-Host: %s\n" "$UPLOAD_RESULT"
  printf "Gateway-Host -> VPS: %s\n" "$DOWNLOAD_RESULT"
}

run_vps_external_speedtest() {
  common_require_command curl
  common_require_command awk

  echo ""
  echo "=============================="
  echo "VPS Aussen-Speedtest"
  echo "=============================="
  echo ""
  echo "Hinweis: Dieser Test misst einen HTTP-Download vom VPS ins Internet."
  echo ""

  DOWNLOAD_BYTES_PER_SEC="$(curl -L -o /dev/null -sS --max-time 60 -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=$((SPEEDTEST_SIZE_MB * 1024 * 1024))")"

  if [ -z "$DOWNLOAD_BYTES_PER_SEC" ] || [ "$DOWNLOAD_BYTES_PER_SEC" = "0" ]; then
    echo "Fehler: Externer Downloadtest konnte nicht ausgewertet werden."
    return
  fi

  DOWNLOAD_MBIT="$(awk -v bps="$DOWNLOAD_BYTES_PER_SEC" 'BEGIN { printf "%.2f", (bps * 8) / 1000000 }')"
  printf "Download nach aussen: %6.2f Mbit/s\n" "$DOWNLOAD_MBIT"
}

speedtest_menu() {
  echo ""
  echo "Speedtests:"
  echo ""
  echo "1) Tunnel Speedtest"
  echo "2) VPS Aussen-Speedtest"
  echo "3) Beide Tests"
  echo "4) Zurueck"
  echo ""

  read -p "Auswahl [1]: " SPEEDTEST_CHOICE
  case "$SPEEDTEST_CHOICE" in
    ""|1) run_tunnel_speedtest ;;
    2) run_vps_external_speedtest ;;
    3)
      run_tunnel_speedtest
      echo ""
      run_vps_external_speedtest
      ;;
    4) return ;;
    *) echo "Ungueltige Auswahl." ;;
  esac
}

wireguard_show_created_client() {
  CONF_FILE="$1"
  CLIENT_QR="$2"

  echo ""
  echo "=============================="
  echo "VALIDIERUNG"
  echo "=============================="
  echo ""

  if wireguard_validate_client_conf "$CONF_FILE"; then
    echo "OK - gueltige WireGuard-Konfiguration erkannt."
  else
    echo "FEHLER - wichtige Felder fehlen."
    exit 1
  fi

  echo ""
  echo "=============================="
  echo "WIREGUARD CLIENT CONFIG"
  echo "=============================="
  echo ""
  cat "$CONF_FILE"

  echo ""
  echo "=============================="
  echo "QR-CODE"
  echo "=============================="
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CONF_FILE"
    qrencode -o "$CLIENT_QR" -t png < "$CONF_FILE"
    echo ""
    echo "PNG gespeichert unter:"
    echo "$CLIENT_QR"
  else
    echo "qrencode nicht installiert."
    echo "Installieren mit: apt install qrencode -y"
  fi
}

wireguard_show_client() {
  mapfile -t FILES < <(wireguard_get_client_files_ordered)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "Keine Client-Configs gefunden."
    return
  fi

  wireguard_list_clients
  read -p "Welche Nr. anzeigen? " SELECTION

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Fehler: Bitte eine Nummer eingeben."
    return
  fi

  INDEX=$((SELECTION-1))
  if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#FILES[@]}" ]; then
    echo "Fehler: Ungueltige Auswahl."
    return
  fi

  CONF_FILE="${FILES[$INDEX]}"
  CLIENT_NAME=$(basename "$CONF_FILE" .conf)
  CLIENT_QR="$CLIENT_DIR/${CLIENT_NAME}.png"

  echo ""
  echo "=============================="
  echo "WIREGUARD CLIENT CONFIG"
  echo "=============================="
  echo ""
  echo "Datei: $CONF_FILE"
  echo ""
  cat "$CONF_FILE"

  echo ""
  echo "=============================="
  echo "VALIDIERUNG"
  echo "=============================="
  echo ""

  if wireguard_validate_client_conf "$CONF_FILE"; then
    echo "OK - gueltige WireGuard-Konfiguration erkannt."
  else
    echo "WARNUNG - Konfiguration scheint unvollstaendig oder fehlerhaft."
  fi

  echo ""
  echo "=============================="
  echo "QR-CODE"
  echo "=============================="
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CONF_FILE"
    qrencode -o "$CLIENT_QR" -t png < "$CONF_FILE"
    echo ""
    echo "PNG gespeichert unter:"
    echo "$CLIENT_QR"
  else
    echo "qrencode nicht installiert."
    echo "Installieren mit: apt install qrencode -y"
  fi
}

wireguard_show_help() {
  echo ""
  echo "=============================="
  echo "CLIENT MANAGER HILFE"
  echo "=============================="
  echo ""
  echo "1) Neuen Client erstellen"
  echo "2) Vorhandene Clients anzeigen"
  echo "3) Client-Config inkl. QR-Code anzeigen"
  echo "4) Client entfernen"
  echo "5) Status Dashboard anzeigen"
  echo ""
  echo "Wichtige Pfade:"
  echo "  Server-Config: $WG_CONF"
  echo "  Clients:       $CLIENT_DIR"
  echo ""
}

wireguard_create_client() {
  app_check_base_files
  app_require_wg_running

  echo ""
  echo "Suche naechste freie WireGuard-IP..."
  NEXT_IP=$(wireguard_get_next_ip)

  if [ -z "$NEXT_IP" ]; then
    echo "Fehler: Keine freie IP gefunden."
    exit 1
  fi

  echo "Vorgeschlagene freie IP: $NEXT_IP"
  echo ""
  read -p "Name des Geraets: " CLIENT_NAME

  if [ -z "$CLIENT_NAME" ]; then
    echo "Fehler: Geraetename darf nicht leer sein."
    exit 1
  fi

  CLIENT_NAME=$(wireguard_sanitize_name "$CLIENT_NAME")
  if [ -z "$CLIENT_NAME" ]; then
    echo "Fehler: Geraetename enthaelt keine gueltigen Zeichen."
    exit 1
  fi

  read -p "Client-IP verwenden [$NEXT_IP]: " CLIENT_IP
  if [ -z "$CLIENT_IP" ]; then
    CLIENT_IP="$NEXT_IP"
  fi

  if ! [[ "$CLIENT_IP" =~ ^10\.100\.0\.[0-9]{1,3}$ ]]; then
    echo "Fehler: Ungueltige IP. Erwartet z.B. 10.100.0.3"
    exit 1
  fi

  LAST_OCTET=$(echo "$CLIENT_IP" | awk -F. '{print $4}')
  if [ "$LAST_OCTET" -lt "$START_IP" ] || [ "$LAST_OCTET" -gt "$END_IP" ]; then
    echo "Fehler: IP ausserhalb des erlaubten Bereichs."
    exit 1
  fi

  USED_IPS=$(wireguard_get_used_ips)
  if echo "$USED_IPS" | grep -qx "$CLIENT_IP"; then
    echo "Fehler: IP $CLIENT_IP ist bereits vergeben."
    exit 1
  fi

  wireguard_select_dns
  wireguard_select_allowed_ips

  CLIENT_CONF="$CLIENT_DIR/${CLIENT_NAME}.conf"
  CLIENT_QR="$CLIENT_DIR/${CLIENT_NAME}.png"

  if [ -f "$CLIENT_CONF" ]; then
    echo "Fehler: Client-Datei existiert bereits:"
    echo "$CLIENT_CONF"
    exit 1
  fi

  CLIENT_PRIVATE_KEY=$(wg genkey)
  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  CONF_BACKUP_FILE=$(wireguard_backup_conf)
  TMP_WG_CONF="${WG_CONF}.tmp.$$"
  trap 'rm -f "${TMP_WG_CONF:-}"' EXIT

  cp "$WG_CONF" "$TMP_WG_CONF"
  cat >> "$TMP_WG_CONF" <<EOF

# BEGIN_CLIENT ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
PersistentKeepalive = 25
# END_CLIENT ${CLIENT_NAME}
EOF

  CLIENT_DNS_BLOCK=""
  if [ -n "$DNS_SERVER" ]; then
    CLIENT_DNS_BLOCK="DNS = ${DNS_SERVER}"
  fi

  cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
${CLIENT_DNS_BLOCK}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOF

  mv "$TMP_WG_CONF" "$WG_CONF"
  chmod 600 "$WG_CONF"
  chmod 600 "$CLIENT_CONF"

  if ! wireguard_restart_with_rollback "$CONF_BACKUP_FILE" "$CLIENT_CONF" "$CLIENT_QR"; then
    exit 1
  fi

  echo ""
  echo "Client erstellt:"
  echo "$CLIENT_CONF"
  echo ""
  echo "Verwendete IP: $CLIENT_IP"
  if [ -n "$DNS_SERVER" ]; then
    echo "DNS:           $DNS_SERVER"
  else
    echo "DNS:           kein DNS gesetzt"
  fi
  echo "AllowedIPs:    $CLIENT_ALLOWED_IPS"

  wireguard_show_created_client "$CLIENT_CONF" "$CLIENT_QR"
}

wireguard_remove_client() {
  app_check_base_files

  mapfile -t FILES < <(wireguard_get_client_files_ordered)
  if [ ${#FILES[@]} -eq 0 ]; then
    echo "Keine Client-Configs gefunden."
    return
  fi

  wireguard_list_clients
  read -p "Welche Nr. entfernen? " SELECTION

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Fehler: Bitte eine Nummer eingeben."
    return
  fi

  INDEX=$((SELECTION-1))
  if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#FILES[@]}" ]; then
    echo "Fehler: Ungueltige Auswahl."
    return
  fi

  CONF_FILE="${FILES[$INDEX]}"
  CLIENT_NAME=$(basename "$CONF_FILE" .conf)
  CLIENT_QR="$CLIENT_DIR/${CLIENT_NAME}.png"
  CLIENT_IP=$(grep "^Address =" "$CONF_FILE" | awk '{print $3}' | cut -d'/' -f1)

  echo ""
  echo "Client wird entfernt:"
  echo "Name: $CLIENT_NAME"
  echo "IP:   $CLIENT_IP"
  echo "Datei: $CONF_FILE"
  echo ""

  read -p "Wirklich entfernen? [ja/NEIN]: " CONFIRM
  if [ "$CONFIRM" != "ja" ]; then
    echo "Abgebrochen."
    return
  fi

  CLIENT_PRIVATE_KEY=$(grep "^PrivateKey =" "$CONF_FILE" | cut -d'=' -f2- | xargs)
  if [ -z "$CLIENT_PRIVATE_KEY" ]; then
    echo "Fehler: PrivateKey konnte aus $CONF_FILE nicht gelesen werden."
    return
  fi

  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  CONF_BACKUP_FILE=$(wireguard_backup_conf)
  TMP_WG_CONF="${WG_CONF}.tmp.$$"

  wireguard_remove_peer_by_public_key "$CLIENT_PUBLIC_KEY" "$TMP_WG_CONF"

  if cmp -s "$WG_CONF" "$TMP_WG_CONF"; then
    rm -f "$TMP_WG_CONF"
    echo "Fehler: Passender Peer fuer $CLIENT_NAME wurde in $WG_CONF nicht gefunden."
    return
  fi

  mv "$TMP_WG_CONF" "$WG_CONF"
  chmod 600 "$WG_CONF"

  if ! wireguard_restart_with_rollback "$CONF_BACKUP_FILE"; then
    exit 1
  fi

  rm -f "$CONF_FILE"
  rm -f "$CLIENT_QR"

  echo ""
  echo "Client entfernt:"
  echo "$CLIENT_NAME"
}

dashboard_check_environment() {
  common_require_command wg
  common_require_command awk
  common_require_command grep
  common_require_command date
  common_require_command mkdir
  common_require_command mktemp
  common_require_command sort

  if ! wg show "$WG_IFACE" >/dev/null 2>&1; then
    echo "Fehler: WireGuard Interface $WG_IFACE laeuft nicht."
    exit 1
  fi

  if [ ! -d "$CLIENT_DIR" ]; then
    echo "Fehler: Client-Verzeichnis nicht gefunden: $CLIENT_DIR"
    exit 1
  fi
}

dashboard_init_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  TODAY_KEY=$(date +"%Y-%m-%d")
  MONTH_KEY=$(date +"%Y-%m")
  DASHBOARD_LAST_COUNTERS_FILE="$STATE_DIR/last-counters.tsv"
  DASHBOARD_DAILY_FILE="$STATE_DIR/daily-$TODAY_KEY.tsv"
  DASHBOARD_MONTHLY_FILE="$STATE_DIR/monthly-$MONTH_KEY.tsv"
}

dashboard_format_handshake_age() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    echo "-"
    return
  fi

  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - LAST_HANDSHAKE))

  if [ "$AGE" -lt 60 ]; then
    echo "${AGE}s"
  elif [ "$AGE" -lt 3600 ]; then
    echo "$((AGE / 60))m"
  elif [ "$AGE" -lt 86400 ]; then
    echo "$((AGE / 3600))h"
  else
    echo "$((AGE / 86400))d"
  fi
}

dashboard_format_handshake_compact() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    echo "-"
    return
  fi

  AGE=$(dashboard_format_handshake_age "$LAST_HANDSHAKE")
  STAMP=$(date -d "@$LAST_HANDSHAKE" +"%H:%M:%S")
  echo "$AGE @$STAMP"
}

dashboard_format_status_label() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    common_colorize red "OFFLINE"
    return
  fi

  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - LAST_HANDSHAKE))

  if [ "$AGE" -le "$ONLINE_THRESHOLD" ]; then
    common_colorize green "ONLINE"
  else
    common_colorize yellow "STALE"
  fi
}

dashboard_status_rank() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    echo 2
    return
  fi

  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - LAST_HANDSHAKE))
  if [ "$AGE" -le "$ONLINE_THRESHOLD" ]; then
    echo 0
  else
    echo 1
  fi
}

dashboard_load_peer_state() {
  declare -gA DASHBOARD_PEER_ENDPOINTS=()
  declare -gA DASHBOARD_PEER_HANDSHAKES=()
  declare -gA DASHBOARD_PEER_RX=()
  declare -gA DASHBOARD_PEER_TX=()

  while IFS=$'\t' read -r PUBLIC_KEY PRESHARED_KEY ENDPOINT_DUMP ALLOWED_IPS LAST_HANDSHAKE TRANSFER_RX TRANSFER_TX KEEPALIVE; do
    [ -z "$PUBLIC_KEY" ] && continue
    DASHBOARD_PEER_ENDPOINTS["$PUBLIC_KEY"]="$ENDPOINT_DUMP"
    DASHBOARD_PEER_HANDSHAKES["$PUBLIC_KEY"]="$LAST_HANDSHAKE"
    DASHBOARD_PEER_RX["$PUBLIC_KEY"]="$TRANSFER_RX"
    DASHBOARD_PEER_TX["$PUBLIC_KEY"]="$TRANSFER_TX"
  done < <(wg show "$WG_IFACE" dump | tail -n +2)
}

dashboard_load_client_metadata() {
  DASHBOARD_CLIENT_META_FILE=$(mktemp)
  declare -gA DASHBOARD_CLIENT_NAMES=()
  declare -gA DASHBOARD_CLIENT_WG_IPS=()
  shopt -s nullglob
  FILES=("$CLIENT_DIR"/*.conf)

  for FILE in "${FILES[@]}"; do
    NAME=$(basename "$FILE" .conf)
    WG_IP=$(grep "^Address =" "$FILE" | awk '{print $3}' | cut -d'/' -f1)
    PRIVATE_KEY=$(grep "^PrivateKey =" "$FILE" | cut -d'=' -f2- | xargs || true)

    if [ -z "$PRIVATE_KEY" ]; then
      continue
    fi

    PUBLIC_KEY=$(printf "%s\n" "$PRIVATE_KEY" | wg pubkey)
    DASHBOARD_CLIENT_NAMES["$PUBLIC_KEY"]="$NAME"
    DASHBOARD_CLIENT_WG_IPS["$PUBLIC_KEY"]="$WG_IP"
    printf "%s\t%s\t%s\n" "$NAME" "$PUBLIC_KEY" "$WG_IP" >> "$DASHBOARD_CLIENT_META_FILE"
  done
}

dashboard_peer_display_name() {
  PUBLIC_KEY="$1"
  if [ -n "${DASHBOARD_CLIENT_NAMES[$PUBLIC_KEY]:-}" ]; then
    echo "${DASHBOARD_CLIENT_NAMES[$PUBLIC_KEY]}"
  else
    echo "infra-$(printf "%s" "$PUBLIC_KEY" | cut -c1-8)"
  fi
}

dashboard_load_counter_snapshot() {
  declare -gA DASHBOARD_SNAPSHOT_RX=()
  declare -gA DASHBOARD_SNAPSHOT_TX=()

  [ -f "$DASHBOARD_LAST_COUNTERS_FILE" ] || return

  while IFS=$'\t' read -r PUBLIC_KEY RX_BYTES TX_BYTES; do
    [ -z "$PUBLIC_KEY" ] && continue
    DASHBOARD_SNAPSHOT_RX["$PUBLIC_KEY"]="$RX_BYTES"
    DASHBOARD_SNAPSHOT_TX["$PUBLIC_KEY"]="$TX_BYTES"
  done < "$DASHBOARD_LAST_COUNTERS_FILE"
}

dashboard_save_counter_snapshot() {
  TMP_FILE="${DASHBOARD_LAST_COUNTERS_FILE}.tmp.$$"
  : > "$TMP_FILE"

  for PUBLIC_KEY in "${!DASHBOARD_PEER_RX[@]}"; do
    printf "%s\t%s\t%s\n" "$PUBLIC_KEY" "${DASHBOARD_PEER_RX[$PUBLIC_KEY]}" "${DASHBOARD_PEER_TX[$PUBLIC_KEY]}" >> "$TMP_FILE"
  done

  mv "$TMP_FILE" "$DASHBOARD_LAST_COUNTERS_FILE"
  chmod 600 "$DASHBOARD_LAST_COUNTERS_FILE"
}

dashboard_update_aggregate_file() {
  FILE_PATH="$1"
  PUBLIC_KEY="$2"
  DELTA_RX="$3"
  DELTA_TX="$4"

  TMP_FILE="${FILE_PATH}.tmp.$$"
  MATCHED=0

  if [ -f "$FILE_PATH" ]; then
    while IFS=$'\t' read -r ROW_KEY ROW_RX ROW_TX; do
      [ -z "$ROW_KEY" ] && continue
      if [ "$ROW_KEY" = "$PUBLIC_KEY" ]; then
        ROW_RX=$((ROW_RX + DELTA_RX))
        ROW_TX=$((ROW_TX + DELTA_TX))
        MATCHED=1
      fi
      printf "%s\t%s\t%s\n" "$ROW_KEY" "$ROW_RX" "$ROW_TX" >> "$TMP_FILE"
    done < "$FILE_PATH"
  fi

  if [ "$MATCHED" -eq 0 ]; then
    printf "%s\t%s\t%s\n" "$PUBLIC_KEY" "$DELTA_RX" "$DELTA_TX" >> "$TMP_FILE"
  fi

  mv "$TMP_FILE" "$FILE_PATH"
  chmod 600 "$FILE_PATH"
}

dashboard_update_traffic_history() {
  if [ ! -f "$DASHBOARD_LAST_COUNTERS_FILE" ]; then
    dashboard_save_counter_snapshot
    return
  fi

  dashboard_load_counter_snapshot

  for PUBLIC_KEY in "${!DASHBOARD_PEER_RX[@]}"; do
    CUR_RX="${DASHBOARD_PEER_RX[$PUBLIC_KEY]}"
    CUR_TX="${DASHBOARD_PEER_TX[$PUBLIC_KEY]}"
    PREV_RX="${DASHBOARD_SNAPSHOT_RX[$PUBLIC_KEY]:-0}"
    PREV_TX="${DASHBOARD_SNAPSHOT_TX[$PUBLIC_KEY]:-0}"

    if [ "$CUR_RX" -lt "$PREV_RX" ]; then
      DELTA_RX="$CUR_RX"
    else
      DELTA_RX=$((CUR_RX - PREV_RX))
    fi

    if [ "$CUR_TX" -lt "$PREV_TX" ]; then
      DELTA_TX="$CUR_TX"
    else
      DELTA_TX=$((CUR_TX - PREV_TX))
    fi

    if [ "$DELTA_RX" -gt 0 ] || [ "$DELTA_TX" -gt 0 ]; then
      dashboard_update_aggregate_file "$DASHBOARD_DAILY_FILE" "$PUBLIC_KEY" "$DELTA_RX" "$DELTA_TX"
      dashboard_update_aggregate_file "$DASHBOARD_MONTHLY_FILE" "$PUBLIC_KEY" "$DELTA_RX" "$DELTA_TX"
    fi
  done

  dashboard_save_counter_snapshot
}

dashboard_load_aggregate_maps() {
  FILE_PATH="$1"
  RX_MAP_NAME="$2"
  TX_MAP_NAME="$3"

  eval "declare -gA $RX_MAP_NAME=()"
  eval "declare -gA $TX_MAP_NAME=()"
  [ -f "$FILE_PATH" ] || return

  while IFS=$'\t' read -r PUBLIC_KEY RX_BYTES TX_BYTES; do
    [ -z "$PUBLIC_KEY" ] && continue
    eval "$RX_MAP_NAME[\"\$PUBLIC_KEY\"]=\"$RX_BYTES\""
    eval "$TX_MAP_NAME[\"\$PUBLIC_KEY\"]=\"$TX_BYTES\""
  done < "$FILE_PATH"
}

dashboard_compute_live_pair() {
  PUBLIC_KEY="$1"
  CUR_RX="$2"
  CUR_TX="$3"

  if [ "$DASHBOARD_LAST_RENDER_TS" -eq 0 ]; then
    echo "-"
    return
  fi

  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - DASHBOARD_LAST_RENDER_TS))
  if [ "$ELAPSED" -le 0 ]; then
    echo "-"
    return
  fi

  PREV_RX="${DASHBOARD_SCREEN_PREV_RX[$PUBLIC_KEY]:-0}"
  PREV_TX="${DASHBOARD_SCREEN_PREV_TX[$PUBLIC_KEY]:-0}"

  if [ "$CUR_RX" -lt "$PREV_RX" ]; then
    DELTA_RX="$CUR_RX"
  else
    DELTA_RX=$((CUR_RX - PREV_RX))
  fi

  if [ "$CUR_TX" -lt "$PREV_TX" ]; then
    DELTA_TX="$CUR_TX"
  else
    DELTA_TX=$((CUR_TX - PREV_TX))
  fi

  RATE_RX=$((DELTA_RX / ELAPSED))
  RATE_TX=$((DELTA_TX / ELAPSED))
  echo "$(common_human_bytes "$RATE_RX")/$(common_human_bytes "$RATE_TX")"
}

dashboard_activity_bar() {
  VALUE="$1"
  MAX_VALUE="$2"
  WIDTH=10

  if [ "$MAX_VALUE" -le 0 ]; then
    printf "[..........]"
    return
  fi

  FILLED=$(awk -v value="$VALUE" -v max="$MAX_VALUE" -v width="$WIDTH" 'BEGIN {
    filled = int((value / max) * width + 0.5)
    if (filled < 0) filled = 0
    if (filled > width) filled = width
    print filled
  }')

  EMPTY=$((WIDTH - FILLED))
  printf "[%s%s]" "$(common_repeat_char "#" "$FILLED")" "$(common_repeat_char "." "$EMPTY")"
}

dashboard_summary_card() {
  TITLE="$1"
  VALUE="$2"
  COLOR="$3"
  printf "%-14s %s\n" "$TITLE" "$(common_colorize "$COLOR" "$VALUE")"
}

dashboard_print_footer_hint() {
  if [ "$DASHBOARD_WATCH_MODE" = "yes" ]; then
    echo "$(common_colorize dim "Keys: v/tab Ansicht wechseln | q beenden | Ctrl+C hart abbrechen")"
  else
    echo "$(common_colorize dim "Keys: v/tab Ansicht wechseln | r neu laden | Enter/q zurueck")"
  fi
}

dashboard_print_radar() {
  dashboard_load_peer_state
  dashboard_update_traffic_history
  dashboard_load_aggregate_maps "$DASHBOARD_DAILY_FILE" DASHBOARD_DAILY_RX DASHBOARD_DAILY_TX
  dashboard_load_aggregate_maps "$DASHBOARD_MONTHLY_FILE" DASHBOARD_MONTHLY_RX DASHBOARD_MONTHLY_TX
  dashboard_load_client_metadata

  ONLINE_COUNT=0
  STALE_COUNT=0
  OFFLINE_COUNT=0
  TOTAL_COUNT=0
  TOTAL_RX=0
  TOTAL_TX=0
  TOTAL_DAY=0
  TOTAL_MONTH=0
  MAX_DAY_TOTAL=0
  ROWS_FILE=$(mktemp)

  while IFS=$'\t' read -r NAME PUBLIC_KEY WG_IP; do
    [ -z "$NAME" ] && continue

    LAST_HANDSHAKE="${DASHBOARD_PEER_HANDSHAKES[$PUBLIC_KEY]:-0}"
    ENDPOINT_DUMP="${DASHBOARD_PEER_ENDPOINTS[$PUBLIC_KEY]:-(none)}"
    CUR_RX="${DASHBOARD_PEER_RX[$PUBLIC_KEY]:-0}"
    CUR_TX="${DASHBOARD_PEER_TX[$PUBLIC_KEY]:-0}"
    TODAY_TOTAL=$(( ${DASHBOARD_DAILY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${DASHBOARD_MONTHLY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_MONTHLY_TX[$PUBLIC_KEY]:-0} ))

    RANK=$(dashboard_status_rank "$LAST_HANDSHAKE")
    case "$RANK" in
      0) ONLINE_COUNT=$((ONLINE_COUNT + 1)) ;;
      1) STALE_COUNT=$((STALE_COUNT + 1)) ;;
      2) OFFLINE_COUNT=$((OFFLINE_COUNT + 1)) ;;
    esac

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    TOTAL_RX=$((TOTAL_RX + CUR_RX))
    TOTAL_TX=$((TOTAL_TX + CUR_TX))
    TOTAL_DAY=$((TOTAL_DAY + TODAY_TOTAL))
    TOTAL_MONTH=$((TOTAL_MONTH + MONTH_TOTAL))

    if [ "$TODAY_TOTAL" -gt "$MAX_DAY_TOTAL" ]; then
      MAX_DAY_TOTAL="$TODAY_TOTAL"
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$RANK" "$NAME" "$PUBLIC_KEY" "$WG_IP" "$ENDPOINT_DUMP" "$LAST_HANDSHAKE" "$CUR_RX" "$CUR_TX" >> "$ROWS_FILE"
  done < "$DASHBOARD_CLIENT_META_FILE"

  if common_use_clear; then
    clear
  fi

  echo "$(common_colorize bold "Gate2Home Live WireGuard Radar")"
  echo "$(common_colorize dim "Refresh ${DASHBOARD_WATCH_INTERVAL}s | Threshold ${ONLINE_THRESHOLD}s | State $STATE_DIR")"
  echo ""

  dashboard_summary_card "Zeit" "$(date +"%Y-%m-%d %H:%M:%S %Z")" cyan
  dashboard_summary_card "Interface" "$WG_IFACE" blue
  dashboard_summary_card "Clients" "$TOTAL_COUNT total | $ONLINE_COUNT online | $STALE_COUNT stale | $OFFLINE_COUNT offline" magenta
  dashboard_summary_card "Seit Start" "$(common_human_bytes "$TOTAL_RX") down / $(common_human_bytes "$TOTAL_TX") up" cyan
  dashboard_summary_card "Heute" "$(common_human_bytes "$TOTAL_DAY") gesamt" green
  dashboard_summary_card "Monat" "$(common_human_bytes "$TOTAL_MONTH") gesamt" yellow
  echo ""

  printf "%-22s %-8s %-15s %-23s %-15s %-13s %-13s %-13s %-12s\n" \
    "Client" "State" "Intern" "Extern" "Handshake" "Live RX/TX" "Heute" "Monat" "Pulse"
  common_repeat_char "-" 140
  echo ""

  while IFS=$'\t' read -r RANK NAME PUBLIC_KEY WG_IP ENDPOINT_DUMP LAST_HANDSHAKE CUR_RX CUR_TX; do
    STATUS="$(dashboard_format_status_label "$LAST_HANDSHAKE")"
    HANDSHAKE="$(dashboard_format_handshake_compact "$LAST_HANDSHAKE")"
    LIVE_RATE="$(dashboard_compute_live_pair "$PUBLIC_KEY" "$CUR_RX" "$CUR_TX")"
    TODAY_TOTAL=$(( ${DASHBOARD_DAILY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${DASHBOARD_MONTHLY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_MONTHLY_TX[$PUBLIC_KEY]:-0} ))
    PULSE="$(dashboard_activity_bar "$TODAY_TOTAL" "$MAX_DAY_TOTAL")"

    printf "%-22s %-8s %-15s %-23s %-15s %-13s %-13s %-13s %-12s\n" \
      "$(common_truncate_field "$NAME" 22)" \
      "$STATUS" \
      "$(common_truncate_field "$WG_IP" 15)" \
      "$(common_truncate_field "$ENDPOINT_DUMP" 23)" \
      "$(common_truncate_field "$HANDSHAKE" 15)" \
      "$(common_truncate_field "$LIVE_RATE" 13)" \
      "$(common_truncate_field "$(common_human_bytes "$TODAY_TOTAL")" 13)" \
      "$(common_truncate_field "$(common_human_bytes "$MONTH_TOTAL")" 13)" \
      "$PULSE"

    DASHBOARD_SCREEN_PREV_RX["$PUBLIC_KEY"]="$CUR_RX"
    DASHBOARD_SCREEN_PREV_TX["$PUBLIC_KEY"]="$CUR_TX"
  done < <(sort -t $'\t' -k1,1n -k2,2 "$ROWS_FILE")

  echo ""
  dashboard_print_footer_hint

  DASHBOARD_LAST_RENDER_TS=$(date +%s)
  rm -f "$DASHBOARD_CLIENT_META_FILE" "$ROWS_FILE"
}

dashboard_print_top_lists() {
  TOP_FILE=$(mktemp)

  for PUBLIC_KEY in "${!DASHBOARD_PEER_RX[@]}"; do
    NAME="$(dashboard_peer_display_name "$PUBLIC_KEY")"
    TODAY_TOTAL=$(( ${DASHBOARD_DAILY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${DASHBOARD_MONTHLY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_MONTHLY_TX[$PUBLIC_KEY]:-0} ))
    printf "%s\t%s\t%s\n" "$TODAY_TOTAL" "$MONTH_TOTAL" "$NAME" >> "$TOP_FILE"
  done

  echo "$(common_colorize bold "Top heute")"
  sort -t $'\t' -k1,1nr -k3,3 "$TOP_FILE" | head -n 3 | while IFS=$'\t' read -r TODAY_TOTAL MONTH_TOTAL NAME; do
    printf "  %-22s %s\n" "$(common_truncate_field "$NAME" 22)" "$(common_human_bytes "$TODAY_TOTAL")"
  done
  echo ""

  echo "$(common_colorize bold "Top Monat")"
  sort -t $'\t' -k2,2nr -k3,3 "$TOP_FILE" | head -n 3 | while IFS=$'\t' read -r TODAY_TOTAL MONTH_TOTAL NAME; do
    printf "  %-22s %s\n" "$(common_truncate_field "$NAME" 22)" "$(common_human_bytes "$MONTH_TOTAL")"
  done

  rm -f "$TOP_FILE"
}

dashboard_print_infra_panel() {
  echo "$(common_colorize bold "Infra peers")"
  FOUND_INFRA=0

  for PUBLIC_KEY in "${!DASHBOARD_PEER_RX[@]}"; do
    if [ -n "${DASHBOARD_CLIENT_NAMES[$PUBLIC_KEY]:-}" ]; then
      continue
    fi

    FOUND_INFRA=1
    NAME="$(dashboard_peer_display_name "$PUBLIC_KEY")"
    ENDPOINT_DUMP="${DASHBOARD_PEER_ENDPOINTS[$PUBLIC_KEY]:-(none)}"
    HANDSHAKE="$(dashboard_format_handshake_compact "${DASHBOARD_PEER_HANDSHAKES[$PUBLIC_KEY]:-0}")"
    TOTAL=$(( ${DASHBOARD_PEER_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_PEER_TX[$PUBLIC_KEY]:-0} ))
    printf "  %-18s %-24s %-15s %s\n" \
      "$(common_truncate_field "$NAME" 18)" \
      "$(common_truncate_field "$ENDPOINT_DUMP" 24)" \
      "$(common_truncate_field "$HANDSHAKE" 15)" \
      "$(common_human_bytes "$TOTAL")"
  done

  if [ "$FOUND_INFRA" -eq 0 ]; then
    echo "  Keine separaten Infra-Peers erkannt."
  fi
}

dashboard_print_inspector() {
  dashboard_load_peer_state
  dashboard_update_traffic_history
  dashboard_load_aggregate_maps "$DASHBOARD_DAILY_FILE" DASHBOARD_DAILY_RX DASHBOARD_DAILY_TX
  dashboard_load_aggregate_maps "$DASHBOARD_MONTHLY_FILE" DASHBOARD_MONTHLY_RX DASHBOARD_MONTHLY_TX
  dashboard_load_client_metadata

  if common_use_clear; then
    clear
  fi

  echo "$(common_colorize bold "Gate2Home Inspector View")"
  echo "$(common_colorize dim "Tiefe Ansicht | Refresh ${DASHBOARD_WATCH_INTERVAL}s | Threshold ${ONLINE_THRESHOLD}s")"
  echo ""

  printf "%-24s %-10s %-16s %-24s %-16s %-14s %-14s %-14s\n" \
    "Client" "State" "WG-IP" "Endpoint" "Handshake" "Live" "Heute" "Monat"
  common_repeat_char "=" 138
  echo ""

  DETAIL_FILE=$(mktemp)
  for PUBLIC_KEY in "${!DASHBOARD_CLIENT_NAMES[@]}"; do
    NAME="${DASHBOARD_CLIENT_NAMES[$PUBLIC_KEY]}"
    WG_IP="${DASHBOARD_CLIENT_WG_IPS[$PUBLIC_KEY]:--}"
    ENDPOINT_DUMP="${DASHBOARD_PEER_ENDPOINTS[$PUBLIC_KEY]:-(none)}"
    LAST_HANDSHAKE="${DASHBOARD_PEER_HANDSHAKES[$PUBLIC_KEY]:-0}"
    TODAY_TOTAL=$(( ${DASHBOARD_DAILY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${DASHBOARD_MONTHLY_RX[$PUBLIC_KEY]:-0} + ${DASHBOARD_MONTHLY_TX[$PUBLIC_KEY]:-0} ))
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(dashboard_status_rank "$LAST_HANDSHAKE")" "$PUBLIC_KEY" "$NAME" "$WG_IP" "$ENDPOINT_DUMP" "$TODAY_TOTAL" "$MONTH_TOTAL" >> "$DETAIL_FILE"
  done

  while IFS=$'\t' read -r RANK PUBLIC_KEY NAME WG_IP ENDPOINT_DUMP TODAY_TOTAL MONTH_TOTAL; do
    LAST_HANDSHAKE="${DASHBOARD_PEER_HANDSHAKES[$PUBLIC_KEY]:-0}"
    CUR_RX="${DASHBOARD_PEER_RX[$PUBLIC_KEY]:-0}"
    CUR_TX="${DASHBOARD_PEER_TX[$PUBLIC_KEY]:-0}"
    STATUS="$(dashboard_format_status_label "$LAST_HANDSHAKE")"
    HANDSHAKE="$(dashboard_format_handshake_compact "$LAST_HANDSHAKE")"
    LIVE_RATE="$(dashboard_compute_live_pair "$PUBLIC_KEY" "$CUR_RX" "$CUR_TX")"

    printf "%-24s %-10s %-16s %-24s %-16s %-14s %-14s %-14s\n" \
      "$(common_truncate_field "$NAME" 24)" \
      "$STATUS" \
      "$(common_truncate_field "$WG_IP" 16)" \
      "$(common_truncate_field "$ENDPOINT_DUMP" 24)" \
      "$(common_truncate_field "$HANDSHAKE" 16)" \
      "$(common_truncate_field "$LIVE_RATE" 14)" \
      "$(common_truncate_field "$(common_human_bytes "$TODAY_TOTAL")" 14)" \
      "$(common_truncate_field "$(common_human_bytes "$MONTH_TOTAL")" 14)"

    DASHBOARD_SCREEN_PREV_RX["$PUBLIC_KEY"]="$CUR_RX"
    DASHBOARD_SCREEN_PREV_TX["$PUBLIC_KEY"]="$CUR_TX"
  done < <(sort -t $'\t' -k1,1n -k3,3 "$DETAIL_FILE")

  echo ""
  dashboard_print_top_lists
  echo ""
  dashboard_print_infra_panel
  echo ""
  dashboard_print_footer_hint

  DASHBOARD_LAST_RENDER_TS=$(date +%s)
  rm -f "$DASHBOARD_CLIENT_META_FILE" "$DETAIL_FILE"
}

dashboard_toggle_view() {
  if [ "$DASHBOARD_VIEW_MODE" = "inspector" ]; then
    DASHBOARD_VIEW_MODE="radar"
  else
    DASHBOARD_VIEW_MODE="inspector"
  fi
}

dashboard_drain_stdin() {
  if [ -t 0 ]; then
    while IFS= read -rsn1 -t 0.01 _DASHBOARD_DRAIN_KEY; do
      :
    done
  fi
}

dashboard_render_current_view() {
  if [ "$DASHBOARD_VIEW_MODE" = "inspector" ]; then
    dashboard_print_inspector
  else
    dashboard_print_radar
  fi
}

dashboard_handle_watch_key() {
  KEY="$1"

  case "$KEY" in
    v|V|$'\t')
      dashboard_toggle_view
      return 0
      ;;
    q|Q)
      return 12
      ;;
    *)
      return 1
      ;;
  esac
}

dashboard_handle_once_key() {
  KEY="$1"

  case "$KEY" in
    v|V|$'\t')
      dashboard_toggle_view
      return 10
      ;;
    r|R)
      return 11
      ;;
    q|Q|$'\n'|'')
      return 12
      ;;
    *)
      return 0
      ;;
  esac
}

dashboard_run() {
  DASHBOARD_WATCH_MODE="$1"
  DASHBOARD_WATCH_INTERVAL="${2:-2}"
  DASHBOARD_VIEW_MODE="${3:-radar}"

  dashboard_check_environment
  dashboard_init_state

  if [ "$DASHBOARD_WATCH_MODE" = "auto" ]; then
    if [ -t 1 ]; then
      DASHBOARD_WATCH_MODE="yes"
    else
      DASHBOARD_WATCH_MODE="no"
    fi
  fi

  if [ "$DASHBOARD_WATCH_MODE" = "yes" ]; then
    while true; do
      dashboard_render_current_view

      if [ -t 0 ]; then
        if IFS= read -rsn1 -t "$DASHBOARD_WATCH_INTERVAL" KEY; then
          ACTION=0
          dashboard_handle_watch_key "$KEY" || ACTION="$?"
          if [ "$ACTION" -eq 12 ]; then
            echo ""
            echo "Dashboard beendet."
            dashboard_drain_stdin
            break
          fi
        fi
      else
        sleep "$DASHBOARD_WATCH_INTERVAL"
      fi
    done

    return
  fi

  while true; do
    dashboard_render_current_view

    if ! [ -t 0 ]; then
      break
    fi

    if ! IFS= read -rsn1 KEY; then
      echo ""
      break
    fi
    ACTION=0
    dashboard_handle_once_key "$KEY" || ACTION="$?"

    if [ "$ACTION" -eq 12 ]; then
      echo ""
      dashboard_drain_stdin
      break
    fi
  done
}

backup_cleanup() {
  if [ -n "${BACKUP_WORKDIR:-}" ] && [ -d "$BACKUP_WORKDIR" ]; then
    rm -rf "$BACKUP_WORKDIR"
  fi
}

backup_check_prerequisites() {
  common_require_command tar
  common_require_command rsync
  common_require_command ssh
  common_require_command find
  common_require_command sort

  if [ ! -f "$SSH_KEY" ]; then
    echo "Fehler: SSH-Key nicht gefunden: $SSH_KEY"
    exit 1
  fi
}

backup_rotate_backups() {
  TARGET_DIR="$1"
  KEEP_DAYS="$2"
  KEEP_COUNT="$3"
  FILE_PATTERN="$4"

  find "$TARGET_DIR" -type f -name "$FILE_PATTERN" -mtime +"$KEEP_DAYS" -delete
  mapfile -t BACKUP_FILES < <(find "$TARGET_DIR" -maxdepth 1 -type f -name "$FILE_PATTERN" -printf '%T@ %p\n' | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')

  if [ "${#BACKUP_FILES[@]}" -le "$KEEP_COUNT" ]; then
    return
  fi

  for OLD_FILE in "${BACKUP_FILES[@]:$KEEP_COUNT}"; do
    rm -f "$OLD_FILE"
  done
}

backup_verify_archive() {
  if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "Fehler: Archivpruefung fehlgeschlagen: $BACKUP_FILE"
    exit 1
  fi
}

backup_execute() {
  DATE=$(date +"%Y-%m-%d_%H-%M-%S")
  BACKUP_WORKDIR=""
  BACKUP_FILE="$BACKUP_BASE/gate2home-backup-$DATE.tar.gz"

  backup_check_prerequisites
  trap backup_cleanup EXIT
  umask 077

  mkdir -p "$BACKUP_BASE"
  BACKUP_WORKDIR=$(mktemp -d -t gate2home-backup-XXXXXX)

  echo "=============================="
  echo "Gate2Home Backup gestartet"
  echo "Datum: $DATE"
  echo "=============================="

  mkdir -p "$BACKUP_WORKDIR/etc" "$BACKUP_WORKDIR/opt" "$BACKUP_WORKDIR/system"

  [ -d "/etc/wireguard" ] && cp -a /etc/wireguard "$BACKUP_WORKDIR/etc/"
  if [ -d "$CLIENT_DIR" ]; then
    mkdir -p "$BACKUP_WORKDIR/$(dirname "$CLIENT_ARCHIVE_PATH")"
    cp -a "$CLIENT_DIR" "$BACKUP_WORKDIR/$(dirname "$CLIENT_ARCHIVE_PATH")/"
  fi
  [ -d "/opt/npm" ] && cp -a /opt/npm "$BACKUP_WORKDIR/opt/"
  [ -d "/opt/watchtower" ] && cp -a /opt/watchtower "$BACKUP_WORKDIR/opt/"
  [ -d "/etc/crowdsec" ] && cp -a /etc/crowdsec "$BACKUP_WORKDIR/etc/"
  [ -d "/etc/fail2ban" ] && cp -a /etc/fail2ban "$BACKUP_WORKDIR/etc/"
  [ -d "/etc/ufw" ] && cp -a /etc/ufw "$BACKUP_WORKDIR/etc/"

  systemctl is-enabled wg-quick@wg0 > "$BACKUP_WORKDIR/system/wg-enabled.txt" 2>/dev/null || true
  systemctl status wg-quick@wg0 --no-pager > "$BACKUP_WORKDIR/system/wg-status.txt" 2>/dev/null || true
  docker ps > "$BACKUP_WORKDIR/system/docker-ps.txt" 2>/dev/null || true
  ufw status verbose > "$BACKUP_WORKDIR/system/ufw-status.txt" 2>/dev/null || true
  cscli decisions list > "$BACKUP_WORKDIR/system/crowdsec-decisions.txt" 2>/dev/null || true
  fail2ban-client status > "$BACKUP_WORKDIR/system/fail2ban-status.txt" 2>/dev/null || true

  tar -czf "$BACKUP_FILE" -C "$BACKUP_WORKDIR" .
  chmod 600 "$BACKUP_FILE"
  backup_verify_archive

  echo ""
  echo "Lokales Backup erstellt:"
  echo "$BACKUP_FILE"

  echo ""
  echo "Bereinige lokale Backups..."
  backup_rotate_backups "$BACKUP_BASE" "$LOCAL_KEEP_DAYS" "$LOCAL_KEEP_COUNT" "gate2home-backup-*.tar.gz"
  echo "Lokale Backup-Rotation abgeschlossen."

  echo ""
  echo "Kopiere Backup zum Raspberry..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$RPI_USER@$RPI_HOST" "mkdir -p '$RPI_TARGET'"
  rsync -avz -e "ssh -i $(printf '%q' "$SSH_KEY") -o StrictHostKeyChecking=accept-new" \
    "$BACKUP_FILE" \
    "$RPI_USER@$RPI_HOST:$RPI_TARGET/"

  echo ""
  echo "Bereinige Raspberry-Backups..."
  ssh -i "$SSH_KEY" "$RPI_USER@$RPI_HOST" "
mkdir -p '$RPI_TARGET'
find '$RPI_TARGET' -type f -name 'gate2home-backup-*.tar.gz' -mtime +$RPI_KEEP_DAYS -delete
find '$RPI_TARGET' -maxdepth 1 -type f -name 'gate2home-backup-*.tar.gz' -printf '%T@ %p\n' | sort -rn | awk 'NR > $RPI_KEEP_COUNT { \$1=\"\"; sub(/^ /, \"\"); print }' | while IFS= read -r old_file; do
  rm -f \"\$old_file\"
done
"
  echo "Raspberry Backup-Rotation abgeschlossen."

  echo ""
  echo "Speicheruebersicht VPS:"
  df -h /

  echo ""
  echo "Backup erfolgreich abgeschlossen."
  trap - EXIT
  backup_cleanup
}

restore_cleanup() {
  if [ -n "${RESTORE_WORKDIR:-}" ] && [ -d "$RESTORE_WORKDIR" ]; then
    rm -rf "$RESTORE_WORKDIR"
  fi
}

restore_list_backups() {
  find "$BACKUP_BASE" -maxdepth 1 -type f -name "gate2home-backup-*.tar.gz" | sort
}

restore_select_backup_interactive() {
  mapfile -t BACKUPS < <(restore_list_backups)

  if [ "${#BACKUPS[@]}" -eq 0 ]; then
    echo "Fehler: Keine Backups gefunden in $BACKUP_BASE"
    exit 1
  fi

  echo ""
  echo "Verfuegbare Backups:"
  echo ""
  INDEX=1
  for FILE in "${BACKUPS[@]}"; do
    echo "$INDEX) $(basename "$FILE")"
    INDEX=$((INDEX+1))
  done
  echo ""

  read -p "Welches Backup wiederherstellen? [1]: " SELECTION
  [ -z "$SELECTION" ] && SELECTION=1

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Fehler: Bitte eine Nummer eingeben."
    exit 1
  fi

  INDEX=$((SELECTION-1))
  if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#BACKUPS[@]}" ]; then
    echo "Fehler: Ungueltige Auswahl."
    exit 1
  fi

  RESTORE_BACKUP_FILE="${BACKUPS[$INDEX]}"
}

restore_select_mode_interactive() {
  echo ""
  echo "Restore-Modus auswaehlen:"
  echo ""
  echo "1) wireguard"
  echo "2) clients"
  echo "3) full"
  echo ""

  read -p "Auswahl [1]: " MODE_CHOICE

  case "$MODE_CHOICE" in
    ""|1) RESTORE_MODE="wireguard" ;;
    2) RESTORE_MODE="clients" ;;
    3) RESTORE_MODE="full" ;;
    *)
      echo "Fehler: Ungueltige Auswahl."
      exit 1
      ;;
  esac
}

restore_prepare() {
  common_require_command tar
  common_require_command find
  common_require_command cp
  common_require_command mkdir
  common_require_command systemctl

  if [ -z "$RESTORE_BACKUP_FILE" ]; then
    restore_select_backup_interactive
  fi

  if [ ! -f "$RESTORE_BACKUP_FILE" ]; then
    echo "Fehler: Backup-Datei nicht gefunden: $RESTORE_BACKUP_FILE"
    exit 1
  fi

  if [ "$RESTORE_MODE" = "interactive" ]; then
    restore_select_mode_interactive
  fi

  RESTORE_TS="$(date +"%Y-%m-%d_%H-%M-%S")-$$"
  RESTORE_WORKDIR="$RESTORE_ROOT/$RESTORE_TS"
  PRE_RESTORE_BASE="${PRE_RESTORE_ROOT}/gate2home-$RESTORE_TS"

  mkdir -p "$RESTORE_WORKDIR"
  if ! tar -xzf "$RESTORE_BACKUP_FILE" -C "$RESTORE_WORKDIR"; then
    echo "Fehler: Backup konnte nicht entpackt werden."
    exit 1
  fi
}

restore_log_run() {
  echo "+ $*"
  if [ "$RESTORE_DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

restore_backup_existing_path() {
  SRC_PATH="$1"
  DEST_PATH="$2"

  if [ -e "$SRC_PATH" ]; then
    restore_log_run mkdir -p "$(dirname "$DEST_PATH")"
    restore_log_run cp -a "$SRC_PATH" "$DEST_PATH"
  fi
}

restore_directory_contents() {
  SRC_DIR="$1"
  DEST_DIR="$2"

  if [ ! -d "$SRC_DIR" ]; then
    echo "Hinweis: Backup-Inhalt fehlt, ueberspringe $SRC_DIR"
    return
  fi

  restore_log_run mkdir -p "$DEST_DIR"
  restore_log_run cp -a "$SRC_DIR"/. "$DEST_DIR"/
}

restore_wireguard_mode() {
  echo ""
  echo "Wiederherstellung: WireGuard"
  restore_backup_existing_path "/etc/wireguard" "$PRE_RESTORE_BASE/etc/wireguard"
  restore_directory_contents "$RESTORE_WORKDIR/etc/wireguard" "/etc/wireguard"

  if [ "$RESTORE_DRY_RUN" -eq 0 ] && [ -f /etc/wireguard/wg0.conf ]; then
    chmod 600 /etc/wireguard/wg0.conf
    systemctl restart wg-quick@wg0
  fi
}

restore_clients_mode() {
  echo ""
  echo "Wiederherstellung: WireGuard Clients"
  restore_backup_existing_path "$CLIENT_DIR" "$PRE_RESTORE_BASE/$CLIENT_ARCHIVE_PATH"
  restore_directory_contents "$RESTORE_WORKDIR/$CLIENT_ARCHIVE_PATH" "$CLIENT_DIR"

  if [ "$RESTORE_DRY_RUN" -eq 0 ] && [ -d "$CLIENT_DIR" ]; then
    find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" -exec chmod 600 {} \;
  fi
}

restore_full_mode() {
  echo ""
  echo "Wiederherstellung: Full Restore"

  restore_backup_existing_path "/etc/wireguard" "$PRE_RESTORE_BASE/etc/wireguard"
  restore_backup_existing_path "$CLIENT_DIR" "$PRE_RESTORE_BASE/$CLIENT_ARCHIVE_PATH"
  restore_backup_existing_path "/opt/npm" "$PRE_RESTORE_BASE/opt/npm"
  restore_backup_existing_path "/opt/watchtower" "$PRE_RESTORE_BASE/opt/watchtower"
  restore_backup_existing_path "/etc/crowdsec" "$PRE_RESTORE_BASE/etc/crowdsec"
  restore_backup_existing_path "/etc/fail2ban" "$PRE_RESTORE_BASE/etc/fail2ban"
  restore_backup_existing_path "/etc/ufw" "$PRE_RESTORE_BASE/etc/ufw"

  restore_directory_contents "$RESTORE_WORKDIR/etc/wireguard" "/etc/wireguard"
  restore_directory_contents "$RESTORE_WORKDIR/$CLIENT_ARCHIVE_PATH" "$CLIENT_DIR"
  restore_directory_contents "$RESTORE_WORKDIR/opt/npm" "/opt/npm"
  restore_directory_contents "$RESTORE_WORKDIR/opt/watchtower" "/opt/watchtower"
  restore_directory_contents "$RESTORE_WORKDIR/etc/crowdsec" "/etc/crowdsec"
  restore_directory_contents "$RESTORE_WORKDIR/etc/fail2ban" "/etc/fail2ban"
  restore_directory_contents "$RESTORE_WORKDIR/etc/ufw" "/etc/ufw"

  if [ "$RESTORE_DRY_RUN" -eq 0 ]; then
    if [ -f /etc/wireguard/wg0.conf ]; then
      chmod 600 /etc/wireguard/wg0.conf
      systemctl restart wg-quick@wg0
    fi
    if [ -d "$CLIENT_DIR" ]; then
      find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" -exec chmod 600 {} \;
    fi
  fi
}

restore_execute() {
  RESTORE_DRY_RUN="${1:-0}"
  RESTORE_MODE="interactive"
  RESTORE_BACKUP_FILE=""

  restore_prepare
  trap restore_cleanup EXIT

  echo "=============================="
  echo "Gate2Home Restore gestartet"
  echo "Backup: $RESTORE_BACKUP_FILE"
  echo "Modus:  $RESTORE_MODE"
  if [ "$RESTORE_DRY_RUN" -eq 1 ]; then
    echo "Modus:  Dry-Run"
  fi
  echo "=============================="

  case "$RESTORE_MODE" in
    wireguard) restore_wireguard_mode ;;
    clients) restore_clients_mode ;;
    full) restore_full_mode ;;
  esac

  echo ""
  echo "Vorab-Sicherung des Ist-Zustands:"
  echo "$PRE_RESTORE_BASE"

  if [ "$RESTORE_DRY_RUN" -eq 1 ]; then
    echo ""
    echo "Dry-Run abgeschlossen. Es wurden keine Aenderungen geschrieben."
  else
    echo ""
    echo "Restore erfolgreich abgeschlossen."
  fi

  trap - EXIT
  restore_cleanup
}

client_manager_menu() {
  while true; do
    echo ""
    echo "=============================="
    echo "Client Manager"
    echo "=============================="
    echo ""
    echo "1) Neuen Client erstellen"
    echo "2) Vorhandene Clients anzeigen"
    echo "3) Client-Config inkl. QR-Code anzeigen"
    echo "4) Client entfernen"
    echo "5) Status Dashboard anzeigen"
    echo "6) Hilfe"
    echo "7) Zurueck"
    echo ""

    if ! read -p "Auswahl: " CHOICE; then
      echo ""
      return
    fi
    case "$CHOICE" in
      1) wireguard_create_client ;;
      2) wireguard_list_clients ;;
      3) wireguard_show_client ;;
      4) wireguard_remove_client ;;
      5) dashboard_run "no" 2 "radar" ;;
      6)
        wireguard_show_help
        common_pause_return
        ;;
      7) return ;;
      *) echo "Ungueltige Auswahl." ;;
    esac
  done
}

dashboard_live_menu() {
  echo ""
  echo "Live-Ansicht starten:"
  echo ""
  echo "1) Radar"
  echo "2) Inspector"
  echo "3) Zurueck"
  echo ""

  if ! read -p "Auswahl [1]: " DASHBOARD_CHOICE; then
    echo ""
    return
  fi
  case "$DASHBOARD_CHOICE" in
    ""|1) dashboard_run "yes" 2 "radar" ;;
    2) dashboard_run "yes" 2 "inspector" ;;
    3) return ;;
    *) echo "Ungueltige Auswahl." ;;
  esac
}

backup_menu() {
  echo ""
  if ! read -p "Backup jetzt ausfuehren? [ja/NEIN]: " CONFIRM; then
    echo ""
    return
  fi
  if [ "$CONFIRM" != "ja" ]; then
    echo "Abgebrochen."
    return
  fi

  backup_execute
  common_pause_return
}

restore_menu() {
  echo ""
  echo "Restore starten:"
  echo ""
  echo "1) Echter Restore"
  echo "2) Dry-Run"
  echo "3) Zurueck"
  echo ""

  if ! read -p "Auswahl [1]: " RESTORE_CHOICE; then
    echo ""
    return
  fi
  case "$RESTORE_CHOICE" in
    ""|1) restore_execute 0 ;;
    2) restore_execute 1 ;;
    3) return ;;
    *)
      echo "Ungueltige Auswahl."
      return
      ;;
  esac

  common_pause_return
}

main_menu() {
  while true; do
    app_banner
    echo "1) Client Manager"
    echo "2) Status Dashboard (Snapshot)"
    echo "3) Status Dashboard (Live)"
    echo "4) Backup erstellen"
    echo "5) Restore starten"
    echo "6) Speedtests"
    echo "7) Hilfe"
    echo "8) Beenden"
    echo ""

    if ! read -p "Auswahl: " CHOICE; then
      echo ""
      echo "Beendet."
      exit 0
    fi

    case "$CHOICE" in
      1) client_manager_menu ;;
      2) dashboard_run "no" 2 "radar" ;;
      3) dashboard_live_menu ;;
      4) backup_menu ;;
      5) restore_menu ;;
      6)
        speedtest_menu
        common_pause_return
        ;;
      7)
        app_show_help
        common_pause_return
        ;;
      8)
        echo "Beendet."
        exit 0
        ;;
      *)
        echo "Ungueltige Auswahl."
        common_pause_return
        ;;
    esac
  done
}

common_require_root
main_menu
____W2H_MAIN_SCRIPT____
  chmod 700 "$1"
}
write_wireguard_dashboard_sh() {
  cat > "$1" <<'____W2H_DASHBOARD____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/runtime-paths.sh"

WG_IFACE="wg0"
CLIENT_DIR="$WIREGUARD2HOME_CLIENT_DIR"
STATE_DIR="$WIREGUARD2HOME_STATE_DIR"
ONLINE_THRESHOLD=180
WATCH_MODE="auto"
WATCH_INTERVAL=2
VIEW_MODE="radar"

LAST_COUNTERS_FILE="$STATE_DIR/last-counters.tsv"
TODAY_KEY=$(date +"%Y-%m-%d")
MONTH_KEY=$(date +"%Y-%m")
DAILY_FILE="$STATE_DIR/daily-$TODAY_KEY.tsv"
MONTHLY_FILE="$STATE_DIR/monthly-$MONTH_KEY.tsv"

LAST_RENDER_TS=0
declare -A SCREEN_PREV_RX=()
declare -A SCREEN_PREV_TX=()
declare -A CLIENT_NAMES=()
declare -A CLIENT_WG_IPS=()

check_dependencies() {
  for cmd in wg awk grep date mkdir mktemp sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Fehler: Benoetigtes Kommando nicht gefunden: $cmd"
      exit 1
    fi
  done
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte mit sudo oder als root ausfuehren."
    exit 1
  fi
}

check_environment() {
  if ! wg show "$WG_IFACE" >/dev/null 2>&1; then
    echo "Fehler: WireGuard Interface $WG_IFACE laeuft nicht."
    exit 1
  fi

  if [ ! -d "$CLIENT_DIR" ]; then
    echo "Fehler: Client-Verzeichnis nicht gefunden: $CLIENT_DIR"
    exit 1
  fi
}

init_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

use_colors() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

use_clear() {
  [ -t 1 ] && [ -n "${TERM:-}" ]
}

colorize() {
  COLOR="$1"
  TEXT="$2"

  if ! use_colors; then
    printf "%s" "$TEXT"
    return
  fi

  case "$COLOR" in
    green) printf '\033[32m%s\033[0m' "$TEXT" ;;
    yellow) printf '\033[33m%s\033[0m' "$TEXT" ;;
    red) printf '\033[31m%s\033[0m' "$TEXT" ;;
    cyan) printf '\033[36m%s\033[0m' "$TEXT" ;;
    blue) printf '\033[34m%s\033[0m' "$TEXT" ;;
    magenta) printf '\033[35m%s\033[0m' "$TEXT" ;;
    dim) printf '\033[2m%s\033[0m' "$TEXT" ;;
    bold) printf '\033[1m%s\033[0m' "$TEXT" ;;
    *) printf "%s" "$TEXT" ;;
  esac
}

repeat_char() {
  CHAR="$1"
  COUNT="$2"
  printf "%${COUNT}s" "" | tr " " "$CHAR"
}

human_bytes() {
  BYTES="$1"

  awk -v bytes="$BYTES" '
    function human(value) {
      split("B KiB MiB GiB TiB", units, " ")
      idx = 1
      while (value >= 1024 && idx < 5) {
        value /= 1024
        idx++
      }
      if (idx == 1) {
        return sprintf("%d %s", value, units[idx])
      }
      return sprintf("%.1f %s", value, units[idx])
    }
    BEGIN { print human(bytes) }
  '
}

format_handshake_age() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    echo "-"
    return
  fi

  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - LAST_HANDSHAKE))

  if [ "$AGE" -lt 60 ]; then
    echo "${AGE}s"
    return
  fi

  if [ "$AGE" -lt 3600 ]; then
    echo "$((AGE / 60))m"
    return
  fi

  if [ "$AGE" -lt 86400 ]; then
    echo "$((AGE / 3600))h"
    return
  fi

  echo "$((AGE / 86400))d"
}

format_handshake_compact() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    echo "-"
    return
  fi

  AGE=$(format_handshake_age "$LAST_HANDSHAKE")
  STAMP=$(date -d "@$LAST_HANDSHAKE" +"%H:%M:%S")
  echo "$AGE @$STAMP"
}

format_status_label() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    colorize red "OFFLINE"
    return
  fi

  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - LAST_HANDSHAKE))

  if [ "$AGE" -le "$ONLINE_THRESHOLD" ]; then
    colorize green "ONLINE"
    return
  fi

  colorize yellow "STALE"
}

status_rank() {
  LAST_HANDSHAKE="$1"

  if [ -z "$LAST_HANDSHAKE" ] || [ "$LAST_HANDSHAKE" = "0" ]; then
    echo 2
    return
  fi

  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - LAST_HANDSHAKE))

  if [ "$AGE" -le "$ONLINE_THRESHOLD" ]; then
    echo 0
    return
  fi

  echo 1
}

truncate_field() {
  VALUE="$1"
  WIDTH="$2"

  awk -v value="$VALUE" -v width="$WIDTH" '
    BEGIN {
      if (length(value) <= width) {
        print value
      } else if (width <= 3) {
        print substr(value, 1, width)
      } else {
        print substr(value, 1, width - 3) "..."
      }
    }
  '
}

load_peer_state() {
  declare -gA PEER_ENDPOINTS=()
  declare -gA PEER_HANDSHAKES=()
  declare -gA PEER_RX=()
  declare -gA PEER_TX=()

  while IFS=$'\t' read -r PUBLIC_KEY PRESHARED_KEY ENDPOINT ALLOWED_IPS LAST_HANDSHAKE TRANSFER_RX TRANSFER_TX KEEPALIVE; do
    [ -z "$PUBLIC_KEY" ] && continue
    PEER_ENDPOINTS["$PUBLIC_KEY"]="$ENDPOINT"
    PEER_HANDSHAKES["$PUBLIC_KEY"]="$LAST_HANDSHAKE"
    PEER_RX["$PUBLIC_KEY"]="$TRANSFER_RX"
    PEER_TX["$PUBLIC_KEY"]="$TRANSFER_TX"
  done < <(wg show "$WG_IFACE" dump | tail -n +2)
}

load_client_metadata() {
  CLIENT_META_FILE=$(mktemp)
  declare -gA CLIENT_NAMES=()
  declare -gA CLIENT_WG_IPS=()
  shopt -s nullglob
  FILES=("$CLIENT_DIR"/*.conf)

  for FILE in "${FILES[@]}"; do
    NAME=$(basename "$FILE" .conf)
    WG_IP=$(grep "^Address =" "$FILE" | awk '{print $3}' | cut -d'/' -f1)
    PRIVATE_KEY=$(grep "^PrivateKey =" "$FILE" | cut -d'=' -f2- | xargs || true)

    if [ -z "$PRIVATE_KEY" ]; then
      continue
    fi

    PUBLIC_KEY=$(printf "%s\n" "$PRIVATE_KEY" | wg pubkey)
    CLIENT_NAMES["$PUBLIC_KEY"]="$NAME"
    CLIENT_WG_IPS["$PUBLIC_KEY"]="$WG_IP"
    printf "%s\t%s\t%s\n" "$NAME" "$PUBLIC_KEY" "$WG_IP" >> "$CLIENT_META_FILE"
  done
}

peer_display_name() {
  PUBLIC_KEY="$1"
  if [ -n "${CLIENT_NAMES[$PUBLIC_KEY]:-}" ]; then
    echo "${CLIENT_NAMES[$PUBLIC_KEY]}"
    return
  fi

  if [ -n "${PEER_ENDPOINTS[$PUBLIC_KEY]:-}" ] && echo "${PEER_ENDPOINTS[$PUBLIC_KEY]}" | grep -q "10.100.0.2"; then
    echo "rpi-gateway"
    return
  fi

  echo "infra-$(printf "%s" "$PUBLIC_KEY" | cut -c1-8)"
}

load_counter_snapshot() {
  declare -gA SNAPSHOT_RX=()
  declare -gA SNAPSHOT_TX=()

  if [ ! -f "$LAST_COUNTERS_FILE" ]; then
    return
  fi

  while IFS=$'\t' read -r PUBLIC_KEY RX_BYTES TX_BYTES; do
    [ -z "$PUBLIC_KEY" ] && continue
    SNAPSHOT_RX["$PUBLIC_KEY"]="$RX_BYTES"
    SNAPSHOT_TX["$PUBLIC_KEY"]="$TX_BYTES"
  done < "$LAST_COUNTERS_FILE"
}

save_counter_snapshot() {
  TMP_FILE="${LAST_COUNTERS_FILE}.tmp.$$"

  : > "$TMP_FILE"
  for PUBLIC_KEY in "${!PEER_RX[@]}"; do
    printf "%s\t%s\t%s\n" "$PUBLIC_KEY" "${PEER_RX[$PUBLIC_KEY]}" "${PEER_TX[$PUBLIC_KEY]}" >> "$TMP_FILE"
  done

  mv "$TMP_FILE" "$LAST_COUNTERS_FILE"
  chmod 600 "$LAST_COUNTERS_FILE"
}

update_aggregate_file() {
  FILE_PATH="$1"
  PUBLIC_KEY="$2"
  DELTA_RX="$3"
  DELTA_TX="$4"

  TMP_FILE="${FILE_PATH}.tmp.$$"
  MATCHED=0

  if [ -f "$FILE_PATH" ]; then
    while IFS=$'\t' read -r ROW_KEY ROW_RX ROW_TX; do
      [ -z "$ROW_KEY" ] && continue
      if [ "$ROW_KEY" = "$PUBLIC_KEY" ]; then
        ROW_RX=$((ROW_RX + DELTA_RX))
        ROW_TX=$((ROW_TX + DELTA_TX))
        MATCHED=1
      fi
      printf "%s\t%s\t%s\n" "$ROW_KEY" "$ROW_RX" "$ROW_TX" >> "$TMP_FILE"
    done < "$FILE_PATH"
  fi

  if [ "$MATCHED" -eq 0 ]; then
    printf "%s\t%s\t%s\n" "$PUBLIC_KEY" "$DELTA_RX" "$DELTA_TX" >> "$TMP_FILE"
  fi

  mv "$TMP_FILE" "$FILE_PATH"
  chmod 600 "$FILE_PATH"
}

update_traffic_history() {
  if [ ! -f "$LAST_COUNTERS_FILE" ]; then
    save_counter_snapshot
    return
  fi

  load_counter_snapshot

  for PUBLIC_KEY in "${!PEER_RX[@]}"; do
    CUR_RX="${PEER_RX[$PUBLIC_KEY]}"
    CUR_TX="${PEER_TX[$PUBLIC_KEY]}"
    PREV_RX="${SNAPSHOT_RX[$PUBLIC_KEY]:-0}"
    PREV_TX="${SNAPSHOT_TX[$PUBLIC_KEY]:-0}"

    if [ "$CUR_RX" -lt "$PREV_RX" ]; then
      DELTA_RX="$CUR_RX"
    else
      DELTA_RX=$((CUR_RX - PREV_RX))
    fi

    if [ "$CUR_TX" -lt "$PREV_TX" ]; then
      DELTA_TX="$CUR_TX"
    else
      DELTA_TX=$((CUR_TX - PREV_TX))
    fi

    if [ "$DELTA_RX" -gt 0 ] || [ "$DELTA_TX" -gt 0 ]; then
      update_aggregate_file "$DAILY_FILE" "$PUBLIC_KEY" "$DELTA_RX" "$DELTA_TX"
      update_aggregate_file "$MONTHLY_FILE" "$PUBLIC_KEY" "$DELTA_RX" "$DELTA_TX"
    fi
  done

  save_counter_snapshot
}

load_aggregate_maps() {
  FILE_PATH="$1"
  RX_MAP_NAME="$2"
  TX_MAP_NAME="$3"

  eval "declare -gA $RX_MAP_NAME=()"
  eval "declare -gA $TX_MAP_NAME=()"

  [ -f "$FILE_PATH" ] || return

  while IFS=$'\t' read -r PUBLIC_KEY RX_BYTES TX_BYTES; do
    [ -z "$PUBLIC_KEY" ] && continue
    eval "$RX_MAP_NAME[\"\$PUBLIC_KEY\"]=\"$RX_BYTES\""
    eval "$TX_MAP_NAME[\"\$PUBLIC_KEY\"]=\"$TX_BYTES\""
  done < "$FILE_PATH"
}

compute_live_pair() {
  PUBLIC_KEY="$1"
  CUR_RX="$2"
  CUR_TX="$3"

  if [ "$LAST_RENDER_TS" -eq 0 ]; then
    echo "-"
    return
  fi

  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - LAST_RENDER_TS))
  if [ "$ELAPSED" -le 0 ]; then
    echo "-"
    return
  fi

  PREV_RX="${SCREEN_PREV_RX[$PUBLIC_KEY]:-0}"
  PREV_TX="${SCREEN_PREV_TX[$PUBLIC_KEY]:-0}"

  if [ "$CUR_RX" -lt "$PREV_RX" ]; then
    DELTA_RX="$CUR_RX"
  else
    DELTA_RX=$((CUR_RX - PREV_RX))
  fi

  if [ "$CUR_TX" -lt "$PREV_TX" ]; then
    DELTA_TX="$CUR_TX"
  else
    DELTA_TX=$((CUR_TX - PREV_TX))
  fi

  RATE_RX=$((DELTA_RX / ELAPSED))
  RATE_TX=$((DELTA_TX / ELAPSED))
  echo "$(human_bytes "$RATE_RX")/$(human_bytes "$RATE_TX")"
}

activity_bar() {
  VALUE="$1"
  MAX_VALUE="$2"
  WIDTH=10

  if [ "$MAX_VALUE" -le 0 ]; then
    printf "[..........]"
    return
  fi

  FILLED=$(awk -v value="$VALUE" -v max="$MAX_VALUE" -v width="$WIDTH" 'BEGIN {
    filled = int((value / max) * width + 0.5)
    if (filled < 0) filled = 0
    if (filled > width) filled = width
    print filled
  }')

  EMPTY=$((WIDTH - FILLED))
  printf "[%s%s]" "$(repeat_char "#" "$FILLED")" "$(repeat_char "." "$EMPTY")"
}

summary_card() {
  TITLE="$1"
  VALUE="$2"
  COLOR="$3"
  printf "%-14s %s\n" "$TITLE" "$(colorize "$COLOR" "$VALUE")"
}

print_table_header() {
  printf "%-22s %-8s %-15s %-23s %-15s %-13s %-13s %-13s %-12s\n" \
    "Client" "State" "Intern" "Extern" "Handshake" "Live RX/TX" "Heute" "Monat" "Pulse"
  repeat_char "-" 140
  echo ""
}

print_row() {
  NAME="$1"
  STATUS="$2"
  WG_IP="$3"
  ENDPOINT="$4"
  HANDSHAKE="$5"
  LIVE_RATE="$6"
  TODAY_TOTAL="$7"
  MONTH_TOTAL="$8"
  PULSE="$9"

  printf "%-22s %-8s %-15s %-23s %-15s %-13s %-13s %-13s %-12s\n" \
    "$(truncate_field "$NAME" 22)" \
    "$STATUS" \
    "$(truncate_field "$WG_IP" 15)" \
    "$(truncate_field "$ENDPOINT" 23)" \
    "$(truncate_field "$HANDSHAKE" 15)" \
    "$(truncate_field "$LIVE_RATE" 13)" \
    "$(truncate_field "$TODAY_TOTAL" 13)" \
    "$(truncate_field "$MONTH_TOTAL" 13)" \
    "$PULSE"
}

print_dashboard() {
  load_peer_state
  update_traffic_history
  load_aggregate_maps "$DAILY_FILE" DAILY_RX DAILY_TX
  load_aggregate_maps "$MONTHLY_FILE" MONTHLY_RX MONTHLY_TX
  load_client_metadata

  ONLINE_COUNT=0
  STALE_COUNT=0
  OFFLINE_COUNT=0
  TOTAL_COUNT=0
  TOTAL_RX=0
  TOTAL_TX=0
  TOTAL_DAY=0
  TOTAL_MONTH=0
  MAX_DAY_TOTAL=0

  ROWS_FILE=$(mktemp)

  while IFS=$'\t' read -r NAME PUBLIC_KEY WG_IP; do
    [ -z "$NAME" ] && continue

    LAST_HANDSHAKE="${PEER_HANDSHAKES[$PUBLIC_KEY]:-0}"
    ENDPOINT="${PEER_ENDPOINTS[$PUBLIC_KEY]:-(none)}"
    CUR_RX="${PEER_RX[$PUBLIC_KEY]:-0}"
    CUR_TX="${PEER_TX[$PUBLIC_KEY]:-0}"
    TODAY_TOTAL=$(( ${DAILY_RX[$PUBLIC_KEY]:-0} + ${DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${MONTHLY_RX[$PUBLIC_KEY]:-0} + ${MONTHLY_TX[$PUBLIC_KEY]:-0} ))

    RANK=$(status_rank "$LAST_HANDSHAKE")
    case "$RANK" in
      0) ONLINE_COUNT=$((ONLINE_COUNT + 1)) ;;
      1) STALE_COUNT=$((STALE_COUNT + 1)) ;;
      2) OFFLINE_COUNT=$((OFFLINE_COUNT + 1)) ;;
    esac

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    TOTAL_RX=$((TOTAL_RX + CUR_RX))
    TOTAL_TX=$((TOTAL_TX + CUR_TX))
    TOTAL_DAY=$((TOTAL_DAY + TODAY_TOTAL))
    TOTAL_MONTH=$((TOTAL_MONTH + MONTH_TOTAL))

    if [ "$TODAY_TOTAL" -gt "$MAX_DAY_TOTAL" ]; then
      MAX_DAY_TOTAL="$TODAY_TOTAL"
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$RANK" "$NAME" "$PUBLIC_KEY" "$WG_IP" "$ENDPOINT" "$LAST_HANDSHAKE" "$CUR_RX" "$CUR_TX" >> "$ROWS_FILE"
  done < "$CLIENT_META_FILE"

  if use_clear; then
    clear
  fi

  echo "$(colorize bold "Gate2Home Live WireGuard Radar")"
  echo "$(colorize dim "Refresh ${WATCH_INTERVAL}s | Threshold ${ONLINE_THRESHOLD}s | State $STATE_DIR")"
  echo ""

  summary_card "Zeit" "$(date +"%Y-%m-%d %H:%M:%S %Z")" cyan
  summary_card "Interface" "$WG_IFACE" blue
  summary_card "Clients" "$TOTAL_COUNT total | $ONLINE_COUNT online | $STALE_COUNT stale | $OFFLINE_COUNT offline" magenta
  summary_card "Seit Start" "$(human_bytes "$TOTAL_RX") down / $(human_bytes "$TOTAL_TX") up" cyan
  summary_card "Heute" "$(human_bytes "$TOTAL_DAY") gesamt" green
  summary_card "Monat" "$(human_bytes "$TOTAL_MONTH") gesamt" yellow
  echo ""

  print_table_header

  while IFS=$'\t' read -r RANK NAME PUBLIC_KEY WG_IP ENDPOINT LAST_HANDSHAKE CUR_RX CUR_TX; do
    STATUS="$(format_status_label "$LAST_HANDSHAKE")"
    HANDSHAKE="$(format_handshake_compact "$LAST_HANDSHAKE")"
    LIVE_RATE="$(compute_live_pair "$PUBLIC_KEY" "$CUR_RX" "$CUR_TX")"
    TODAY_TOTAL=$(( ${DAILY_RX[$PUBLIC_KEY]:-0} + ${DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${MONTHLY_RX[$PUBLIC_KEY]:-0} + ${MONTHLY_TX[$PUBLIC_KEY]:-0} ))
    PULSE="$(activity_bar "$TODAY_TOTAL" "$MAX_DAY_TOTAL")"

    print_row \
      "$NAME" \
      "$STATUS" \
      "$WG_IP" \
      "$ENDPOINT" \
      "$HANDSHAKE" \
      "$LIVE_RATE" \
      "$(human_bytes "$TODAY_TOTAL")" \
      "$(human_bytes "$MONTH_TOTAL")" \
      "$PULSE"

    SCREEN_PREV_RX["$PUBLIC_KEY"]="$CUR_RX"
    SCREEN_PREV_TX["$PUBLIC_KEY"]="$CUR_TX"
  done < <(sort -t $'\t' -k1,1n -k2,2 "$ROWS_FILE")

  echo ""
  print_footer_hint

  LAST_RENDER_TS=$(date +%s)
  rm -f "$CLIENT_META_FILE" "$ROWS_FILE"
}

print_top_lists() {
  TOP_FILE=$(mktemp)

  for PUBLIC_KEY in "${!PEER_RX[@]}"; do
    NAME="$(peer_display_name "$PUBLIC_KEY")"
    TODAY_TOTAL=$(( ${DAILY_RX[$PUBLIC_KEY]:-0} + ${DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${MONTHLY_RX[$PUBLIC_KEY]:-0} + ${MONTHLY_TX[$PUBLIC_KEY]:-0} ))
    printf "%s\t%s\t%s\n" "$TODAY_TOTAL" "$MONTH_TOTAL" "$NAME" >> "$TOP_FILE"
  done

  echo "$(colorize bold "Top heute")"
  sort -t $'\t' -k1,1nr -k3,3 "$TOP_FILE" | head -n 3 | while IFS=$'\t' read -r TODAY_TOTAL MONTH_TOTAL NAME; do
    printf "  %-22s %s\n" "$(truncate_field "$NAME" 22)" "$(human_bytes "$TODAY_TOTAL")"
  done
  echo ""

  echo "$(colorize bold "Top Monat")"
  sort -t $'\t' -k2,2nr -k3,3 "$TOP_FILE" | head -n 3 | while IFS=$'\t' read -r TODAY_TOTAL MONTH_TOTAL NAME; do
    printf "  %-22s %s\n" "$(truncate_field "$NAME" 22)" "$(human_bytes "$MONTH_TOTAL")"
  done

  rm -f "$TOP_FILE"
}

print_infra_panel() {
  echo "$(colorize bold "Infra peers")"

  FOUND_INFRA=0
  for PUBLIC_KEY in "${!PEER_RX[@]}"; do
    if [ -n "${CLIENT_NAMES[$PUBLIC_KEY]:-}" ]; then
      continue
    fi

    FOUND_INFRA=1
    NAME="$(peer_display_name "$PUBLIC_KEY")"
    ENDPOINT="${PEER_ENDPOINTS[$PUBLIC_KEY]:-(none)}"
    HANDSHAKE="$(format_handshake_compact "${PEER_HANDSHAKES[$PUBLIC_KEY]:-0}")"
    TOTAL=$(( ${PEER_RX[$PUBLIC_KEY]:-0} + ${PEER_TX[$PUBLIC_KEY]:-0} ))
    printf "  %-18s %-24s %-15s %s\n" \
      "$(truncate_field "$NAME" 18)" \
      "$(truncate_field "$ENDPOINT" 24)" \
      "$(truncate_field "$HANDSHAKE" 15)" \
      "$(human_bytes "$TOTAL")"
  done

  if [ "$FOUND_INFRA" -eq 0 ]; then
    echo "  Keine separaten Infra-Peers erkannt."
  fi
}

print_inspector() {
  load_peer_state
  update_traffic_history
  load_aggregate_maps "$DAILY_FILE" DAILY_RX DAILY_TX
  load_aggregate_maps "$MONTHLY_FILE" MONTHLY_RX MONTHLY_TX
  load_client_metadata

  if use_clear; then
    clear
  fi

  echo "$(colorize bold "Gate2Home Inspector View")"
  echo "$(colorize dim "Tiefe Ansicht | Refresh ${WATCH_INTERVAL}s | Threshold ${ONLINE_THRESHOLD}s")"
  echo ""

  printf "%-24s %-10s %-16s %-24s %-16s %-14s %-14s %-14s\n" \
    "Client" "State" "WG-IP" "Endpoint" "Handshake" "Live" "Heute" "Monat"
  repeat_char "=" 138
  echo ""

  DETAIL_FILE=$(mktemp)
  for PUBLIC_KEY in "${!CLIENT_NAMES[@]}"; do
    NAME="${CLIENT_NAMES[$PUBLIC_KEY]}"
    WG_IP="${CLIENT_WG_IPS[$PUBLIC_KEY]:--}"
    ENDPOINT="${PEER_ENDPOINTS[$PUBLIC_KEY]:-(none)}"
    LAST_HANDSHAKE="${PEER_HANDSHAKES[$PUBLIC_KEY]:-0}"
    CUR_RX="${PEER_RX[$PUBLIC_KEY]:-0}"
    CUR_TX="${PEER_TX[$PUBLIC_KEY]:-0}"
    TODAY_TOTAL=$(( ${DAILY_RX[$PUBLIC_KEY]:-0} + ${DAILY_TX[$PUBLIC_KEY]:-0} ))
    MONTH_TOTAL=$(( ${MONTHLY_RX[$PUBLIC_KEY]:-0} + ${MONTHLY_TX[$PUBLIC_KEY]:-0} ))
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(status_rank "$LAST_HANDSHAKE")" "$PUBLIC_KEY" "$NAME" "$WG_IP" "$ENDPOINT" "$TODAY_TOTAL" "$MONTH_TOTAL" >> "$DETAIL_FILE"
  done

  while IFS=$'\t' read -r RANK PUBLIC_KEY NAME WG_IP ENDPOINT TODAY_TOTAL MONTH_TOTAL; do
    LAST_HANDSHAKE="${PEER_HANDSHAKES[$PUBLIC_KEY]:-0}"
    CUR_RX="${PEER_RX[$PUBLIC_KEY]:-0}"
    CUR_TX="${PEER_TX[$PUBLIC_KEY]:-0}"
    STATUS="$(format_status_label "$LAST_HANDSHAKE")"
    HANDSHAKE="$(format_handshake_compact "$LAST_HANDSHAKE")"
    LIVE_RATE="$(compute_live_pair "$PUBLIC_KEY" "$CUR_RX" "$CUR_TX")"
    printf "%-24s %-10s %-16s %-24s %-16s %-14s %-14s %-14s\n" \
      "$(truncate_field "$NAME" 24)" \
      "$STATUS" \
      "$(truncate_field "$WG_IP" 16)" \
      "$(truncate_field "$ENDPOINT" 24)" \
      "$(truncate_field "$HANDSHAKE" 16)" \
      "$(truncate_field "$LIVE_RATE" 14)" \
      "$(truncate_field "$(human_bytes "$TODAY_TOTAL")" 14)" \
      "$(truncate_field "$(human_bytes "$MONTH_TOTAL")" 14)"

    SCREEN_PREV_RX["$PUBLIC_KEY"]="${PEER_RX[$PUBLIC_KEY]:-0}"
    SCREEN_PREV_TX["$PUBLIC_KEY"]="${PEER_TX[$PUBLIC_KEY]:-0}"
  done < <(sort -t $'\t' -k1,1n -k3,3 "$DETAIL_FILE")

  echo ""
  print_top_lists
  echo ""
  print_infra_panel
  echo ""
  print_footer_hint

  LAST_RENDER_TS=$(date +%s)
  rm -f "$CLIENT_META_FILE" "$DETAIL_FILE"
}

print_footer_hint() {
  if [ "$WATCH_MODE" = "yes" ]; then
    echo "$(colorize dim "Keys: v/tab Ansicht wechseln | q beenden | Ctrl+C hart abbrechen")"
  else
    echo "$(colorize dim "Keys: v/tab Ansicht wechseln | r neu laden | Enter/q zurueck")"
  fi
}

toggle_view() {
  if [ "$VIEW_MODE" = "inspector" ]; then
    VIEW_MODE="radar"
  else
    VIEW_MODE="inspector"
  fi
}

render_current_view() {
  if [ "$VIEW_MODE" = "inspector" ]; then
    print_inspector
  else
    print_dashboard
  fi
}

handle_watch_key() {
  KEY="$1"

  case "$KEY" in
    v|V)
      toggle_view
      return 0
      ;;
    $'\t')
      toggle_view
      return 0
      ;;
    q|Q)
      echo ""
      echo "Dashboard beendet."
      exit 0
      ;;
    *)
      return 1
      ;;
  esac
}

handle_once_key() {
  KEY="$1"

  case "$KEY" in
    v|V)
      toggle_view
      return 10
      ;;
    $'\t')
      toggle_view
      return 10
      ;;
    r|R)
      return 11
      ;;
    q|Q|$'\n'|'')
      return 12
      ;;
    *)
      return 0
      ;;
  esac
}

usage() {
  cat <<EOF
Verwendung:
  $0 [--watch [sekunden]] [--once] [--threshold sekunden] [--view radar|inspector]

Optionen:
  --watch [sek.]     Live-Ansicht mit Auto-Refresh, Standard 2 Sekunden
  --once             Einmaliger Snapshot ohne Refresh
  --threshold sek.   Schwelle fuer online/stale, Standard 180 Sekunden
  --view modus       radar oder inspector, Standard radar
  --help             Diese Hilfe anzeigen
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch)
        WATCH_MODE="yes"
        if [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
          WATCH_INTERVAL="$2"
          shift 2
        else
          shift
        fi
        ;;
      --once)
        WATCH_MODE="no"
        shift
        ;;
      --threshold)
        if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "Fehler: --threshold erwartet eine Zahl in Sekunden."
          exit 1
        fi
        ONLINE_THRESHOLD="$2"
        shift 2
        ;;
      --view)
        if [ $# -lt 2 ]; then
          echo "Fehler: --view erwartet radar oder inspector."
          exit 1
        fi
        VIEW_MODE="$2"
        shift 2
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "Fehler: Unbekannte Option $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root
  check_dependencies
  check_environment
  init_state

  case "$VIEW_MODE" in
    radar|inspector) ;;
    *)
      echo "Fehler: Ungueltige Ansicht: $VIEW_MODE"
      exit 1
      ;;
  esac

  if [ "$WATCH_MODE" = "auto" ]; then
    if [ -t 1 ]; then
      WATCH_MODE="yes"
    else
      WATCH_MODE="no"
    fi
  fi

  if [ "$WATCH_MODE" = "yes" ]; then
    while true; do
      render_current_view

      if [ -t 0 ]; then
        if IFS= read -rsn1 -t "$WATCH_INTERVAL" KEY; then
          handle_watch_key "$KEY" || true
        fi
      else
        sleep "$WATCH_INTERVAL"
      fi
    done
    return
  fi

  while true; do
    render_current_view

    if ! [ -t 0 ]; then
      break
    fi

    if ! IFS= read -rsn1 KEY; then
      echo ""
      break
    fi
    ACTION=0
    handle_once_key "$KEY" || ACTION="$?"

    if [ "$ACTION" -eq 12 ]; then
      echo ""
      break
    fi
  done
}

main "$@"
____W2H_DASHBOARD____
  chmod 700 "$1"
}
write_create_wg_client_sh() {
  cat > "$1" <<'____W2H_CREATE_CLIENT____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/runtime-paths.sh"

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IFACE}.conf"

ENDPOINT="${WIREGUARD2HOME_ENDPOINT:-vpn.example.com:51820}"
WG_NET_PREFIX="10.100.0"
START_IP=3
END_IP=254

CLIENT_DIR="$WIREGUARD2HOME_CLIENT_DIR"
DASHBOARD_SCRIPT="$WIREGUARD2HOME_DASHBOARD_SCRIPT"
DNS_HOME_LABEL="$WIREGUARD2HOME_DNS_HOME_LABEL"
DNS_HOME_VALUE="$WIREGUARD2HOME_DNS_HOME_VALUE"
DNS_ROUTER_LABEL="$WIREGUARD2HOME_DNS_ROUTER_LABEL"
DNS_ROUTER_VALUE="$WIREGUARD2HOME_DNS_ROUTER_VALUE"
LAN_SUBNET="$WIREGUARD2HOME_LAN_SUBNET"

mkdir -p "$CLIENT_DIR"

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte mit sudo oder als root ausführen."
    exit 1
  fi
}

backup_wg_conf() {
  BACKUP_FILE="${WG_CONF}.bak-$(date +"%Y-%m-%d_%H-%M-%S")"
  cp "$WG_CONF" "$BACKUP_FILE"
  echo "$BACKUP_FILE"
}

restore_wg_conf() {
  BACKUP_FILE="$1"

  if [ -f "$BACKUP_FILE" ]; then
    cp "$BACKUP_FILE" "$WG_CONF"
    chmod 600 "$WG_CONF"
  fi
}

restart_wg_with_rollback() {
  BACKUP_FILE="$1"
  CLIENT_CONF_TO_DELETE="${2:-}"
  CLIENT_QR_TO_DELETE="${3:-}"

  if systemctl restart "wg-quick@$WG_IFACE"; then
    return 0
  fi

  echo ""
  echo "Fehler: Neustart von wg-quick@$WG_IFACE fehlgeschlagen."
  echo "Stelle letzte Sicherung wieder her: $BACKUP_FILE"

  restore_wg_conf "$BACKUP_FILE"

  if [ -n "$CLIENT_CONF_TO_DELETE" ]; then
    rm -f "$CLIENT_CONF_TO_DELETE"
  fi

  if [ -n "$CLIENT_QR_TO_DELETE" ]; then
    rm -f "$CLIENT_QR_TO_DELETE"
  fi

  systemctl restart "wg-quick@$WG_IFACE" || true
  return 1
}

check_base_files() {
  if [ ! -f "$WG_CONF" ]; then
    echo "Fehler: $WG_CONF nicht gefunden."
    exit 1
  fi
}

require_wg_running() {
  SERVER_PUBLIC_KEY=$(wg show "$WG_IFACE" public-key 2>/dev/null || true)

  if [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Fehler: WireGuard Interface $WG_IFACE läuft nicht."
    echo "Starte zuerst:"
    echo "systemctl restart wg-quick@$WG_IFACE"
    exit 1
  fi
}

sanitize_name() {
  echo "$1" | tr -cd '[:alnum:]_-'
}

get_used_ips() {
  shopt -s nullglob
  CLIENT_FILES=("$CLIENT_DIR"/*.conf)

  {
    awk -F'[ =/,\t]+' -v prefix="$WG_NET_PREFIX." '
      $1 == "AllowedIPs" {
        for (i = 2; i <= NF; i++) {
          if ($i ~ ("^" prefix "[0-9]+$") && $(i + 1) == "32") {
            print $i
          }
        }
      }
    ' "$WG_CONF" 2>/dev/null || true

    if [ ${#CLIENT_FILES[@]} -gt 0 ]; then
      awk -F'[ =/,\t]+' -v prefix="$WG_NET_PREFIX." '
        $1 == "Address" {
          for (i = 2; i <= NF; i++) {
            if ($i ~ ("^" prefix "[0-9]+$")) {
              print $i
            }
          }
        }
      ' "${CLIENT_FILES[@]}" 2>/dev/null || true
    fi
  } | sort -u
}

get_next_ip() {
  USED_IPS=$(get_used_ips)
  NEXT_IP=""

  for i in $(seq "$START_IP" "$END_IP"); do
    CANDIDATE="${WG_NET_PREFIX}.${i}"
    if ! echo "$USED_IPS" | grep -qx "$CANDIDATE"; then
      NEXT_IP="$CANDIDATE"
      break
    fi
  done

  echo "$NEXT_IP"
}

validate_client_conf() {
  CONF_FILE="$1"

  if [ ! -f "$CONF_FILE" ]; then
    return 1
  fi

  grep -q "^\[Interface\]" "$CONF_FILE" && \
  grep -q "^PrivateKey =" "$CONF_FILE" && \
  grep -q "^Address =" "$CONF_FILE" && \
  grep -q "^\[Peer\]" "$CONF_FILE" && \
  grep -q "^PublicKey =" "$CONF_FILE" && \
  grep -q "^Endpoint =" "$CONF_FILE" && \
  grep -q "^AllowedIPs =" "$CONF_FILE"
}

remove_peer_by_public_key() {
  TARGET_PUBLIC_KEY="$1"
  TMP_FILE="$2"

  awk -v target_key="$TARGET_PUBLIC_KEY" '
    function flush_peer_block() {
      if (!in_peer) {
        return
      }

      if (peer_public_key == target_key) {
        if (pending_comment != "") {
          pending_comment = ""
        }
      } else {
        printf "%s", pending_comment
        printf "%s", peer_block
      }

      pending_comment = ""
      peer_block = ""
      peer_public_key = ""
      in_peer = 0
    }

    BEGIN {
      in_peer = 0
      pending_comment = ""
      peer_block = ""
      peer_public_key = ""
    }

    /^\[Peer\]/ {
      flush_peer_block()
      in_peer = 1
      peer_block = $0 ORS
      next
    }

    in_peer && /^# END_CLIENT / {
      flush_peer_block()
      next
    }

    in_peer && /^# / {
      flush_peer_block()
      pending_comment = pending_comment $0 ORS
      next
    }

    in_peer {
      peer_block = peer_block $0 ORS

      if ($1 == "PublicKey" && $2 == "=") {
        peer_public_key = $3
      }
      next
    }

    /^# END_CLIENT / {
      next
    }

    /^# / {
      pending_comment = pending_comment $0 ORS
      next
    }

    pending_comment != "" {
      if ($0 ~ /^[[:space:]]*$/) {
        pending_comment = pending_comment $0 ORS
        next
      }

      printf "%s", pending_comment
      pending_comment = ""
    }

    {
      print
    }

    END {
      flush_peer_block()

      if (pending_comment != "") {
        printf "%s", pending_comment
      }
    }
  ' "$WG_CONF" > "$TMP_FILE"
}

select_dns() {
  echo ""
  echo "DNS-Server für diesen Client auswählen:"
  echo ""
  echo "--- Heimnetz-DNS (Anfragen gehen durch den Tunnel in dein Heimnetz) ---"
  echo ""
  printf "  1) %-20s %s\n" "$DNS_HOME_LABEL" "$DNS_HOME_VALUE"
  echo "     Wähle diese Option wenn du Pi-hole, AdGuard Home oder einen"
  echo "     eigenen DNS-Server im Heimnetz betreibst."
  echo "     Vorteil: Werbeblocker, eigene DNS-Regeln, lokale Hostnamen."
  echo ""
  printf "  2) %-20s %s\n" "$DNS_ROUTER_LABEL" "$DNS_ROUTER_VALUE"
  echo "     Wähle diese Option wenn kein dedizierter DNS-Server vorhanden"
  echo "     ist und du nur den Router als DNS nutzt."
  echo "     Vorteil: Lokale DHCP-Hostnamen erreichbar (z. B. nas.fritz.box)."
  echo ""
  echo "  Entweder 1 oder 2 – je nachdem was in deinem Heimnetz läuft."
  echo ""
  echo "--- Öffentliche DNS (Anfragen gehen direkt ins Internet) --------------"
  echo ""
  echo "  3) Cloudflare        1.1.1.1, 1.0.0.1"
  echo "  4) Google            8.8.8.8, 8.8.4.4"
  echo "  5) OpenDNS           208.67.222.222, 208.67.220.220"
  echo ""
  echo "--- Sonstiges ---------------------------------------------------------"
  echo ""
  echo "  6) Kein DNS          (Gerät nutzt eigene DNS-Einstellungen)"
  echo "  7) Custom DNS        (eigene Adresse manuell eingeben)"
  echo ""

  read -p "Auswahl [1]: " DNS_CHOICE

  case "$DNS_CHOICE" in
    ""|1)
      DNS_SERVER="$DNS_HOME_VALUE"
      DNS_SELECTION_KIND="home"
      ;;
    2)
      DNS_SERVER="$DNS_ROUTER_VALUE"
      DNS_SELECTION_KIND="router"
      ;;
    3)
      DNS_SERVER="1.1.1.1, 1.0.0.1"
      DNS_SELECTION_KIND="cloudflare"
      ;;
    4)
      DNS_SERVER="8.8.8.8, 8.8.4.4"
      DNS_SELECTION_KIND="google"
      ;;
    5)
      DNS_SERVER="208.67.222.222, 208.67.220.220"
      DNS_SELECTION_KIND="opendns"
      ;;
    6)
      DNS_SERVER=""
      DNS_SELECTION_KIND="none"
      ;;
    7)
      read -p "Custom DNS eintragen, z.B. 192.168.50.53 oder 1.1.1.1, 8.8.8.8: " DNS_SERVER
      if [ -z "$DNS_SERVER" ]; then
        echo "Fehler: DNS darf nicht leer sein."
        exit 1
      fi
      DNS_SELECTION_KIND="custom"
      ;;
    *)
      echo "Ungültige Auswahl."
      exit 1
      ;;
  esac
}

private_dns_routes() {
  printf '%s\n' "$1" | awk -F',' '
    function is_private(ip, octets) {
      split(ip, octets, ".")
      if (octets[1] == 10) return 1
      if (octets[1] == 192 && octets[2] == 168) return 1
      if (octets[1] == 172 && octets[2] >= 16 && octets[2] <= 31) return 1
      return 0
    }
    BEGIN { first = 1 }
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        if ($i != "" && is_private($i)) {
          if (!first) {
            printf ", "
          }
          printf "%s/32", $i
          first = 0
        }
      }
    }
  '
}

apply_home_dns_split_mode() {
  EFFECTIVE_DNS_SERVER="$DNS_SERVER"
  if [ -z "$EFFECTIVE_DNS_SERVER" ] || [ "${DNS_SELECTION_KIND:-home}" = "none" ]; then
    EFFECTIVE_DNS_SERVER="$DNS_HOME_VALUE"
  fi

  HOME_DNS_ROUTES="$(private_dns_routes "$EFFECTIVE_DNS_SERVER")"

  CLIENT_ALLOWED_IPS="${LAN_SUBNET}, 10.100.0.0/24"
  if [ -n "$HOME_DNS_ROUTES" ]; then
    CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS}, ${HOME_DNS_ROUTES}"
  fi

  DNS_SERVER="$EFFECTIVE_DNS_SERVER"
}

apply_split_dns_routes_if_needed() {
  PRIVATE_DNS_ROUTES="$(private_dns_routes "$DNS_SERVER")"
  if [ -n "$PRIVATE_DNS_ROUTES" ]; then
    CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS}, ${PRIVATE_DNS_ROUTES}"
  fi
}

select_allowed_ips() {
  echo ""
  echo "Tunnel-Modus auswählen:"
  echo ""
  echo "1) Full-Tunnel"
  echo "   Gesamter Traffic des Clients läuft durch den VPS."
  echo "   Gut für Reisen, fremde WLANs und wenn alles durch dein VPN soll."
  echo "   Beispiel-Ziel: Internet über VPN, z. B. 1.1.1.1, 8.8.8.8 oder"
  echo "   beliebige Webseiten und Apps."
  echo "   Gesamter Traffic läuft durch VPN"
  echo "   AllowedIPs = 0.0.0.0/0"
  echo ""
  echo "2) Split-Tunnel Heimnetz"
  echo "   Nur Heimnetz und WireGuard-Netz laufen durch den Tunnel."
  echo "   Das normale Internet des Clients bleibt lokal."
  echo "   Beispiel-Ziele: NAS ${LAN_SUBNET%0/24}10, Drucker ${LAN_SUBNET%0/24}20,"
  echo "   Router ${LAN_SUBNET%0/24}1 sowie VPS/andere WG-Clients unter 10.100.0.x."
  echo "   Nur Heimnetz + WireGuard-Netz über VPN"
  echo "   AllowedIPs = ${LAN_SUBNET}, 10.100.0.0/24"
  echo ""
  echo "3) Split-Tunnel einzelne IPs/Netze"
  echo "   Für gezielte Hosts, Dienste oder Teilnetze."
  echo "   Ideal, wenn nur einzelne Ziele über WireGuard erreichbar sein sollen."
  echo "   Beispiel-Ziele: NAS ${LAN_SUBNET%0/24}10/32, Proxmox ${LAN_SUBNET%0/24}20/32,"
  echo "   WG-Netz 10.100.0.0/24."
  echo "   Beispiel: ${LAN_SUBNET%0/24}10/32, ${LAN_SUBNET%0/24}20/32, 10.100.0.0/24"
  echo ""
  echo "4) Split-Tunnel + Heim-DNS-Filter"
  echo "   Noob-freundlich für Handy und Laptop unterwegs."
  echo "   Internet bleibt direkt über Mobilfunk oder lokales WLAN."
  echo "   Heimnetz geht durch den Tunnel und DNS wird fest auf ${DNS_HOME_LABEL}"
  echo "   (${DNS_HOME_VALUE}) gesetzt."
  echo "   Vorteil: weniger Werbung, mehr Privatsphäre und interne Ziele bleiben"
  echo "   erreichbar, ohne dass dein kompletter Internet-Traffic durchs VPN muss."
  echo "   Beispiel-Ziele: NAS ${LAN_SUBNET%0/24}10, Router ${LAN_SUBNET%0/24}1,"
  echo "   Home Assistant ${LAN_SUBNET%0/24}30 plus DNS über ${DNS_HOME_VALUE}."
  echo ""

  read -p "Auswahl [1]: " TUNNEL_CHOICE

  case "$TUNNEL_CHOICE" in
    ""|1)
      CLIENT_ALLOWED_IPS="0.0.0.0/0"
      ;;
    2)
      CLIENT_ALLOWED_IPS="${LAN_SUBNET}, 10.100.0.0/24"
      if [ -n "$DNS_SERVER" ]; then
        apply_split_dns_routes_if_needed
      fi
      ;;
    3)
      echo ""
      echo "Bitte einzelne IPs oder Netze eintragen."
      echo "Wichtig:"
      echo "- Einzelne Hosts mit /32 eintragen"
      echo "- WireGuard-Netz 10.100.0.0/24 ergänzen, wenn Clients sich gegenseitig/VPS erreichen sollen"
      echo ""
      read -p "AllowedIPs: " CLIENT_ALLOWED_IPS

      if [ -z "$CLIENT_ALLOWED_IPS" ]; then
        echo "Fehler: AllowedIPs darf nicht leer sein."
        exit 1
      fi
      if [ -n "$DNS_SERVER" ]; then
        apply_split_dns_routes_if_needed
      fi
      ;;
    4)
      apply_home_dns_split_mode
      ;;
    *)
      echo "Ungültige Auswahl."
      exit 1
      ;;
  esac
}

list_clients() {
  echo ""
  echo "=============================="
  echo "Vorhandene WireGuard Clients"
  echo "=============================="
  echo ""

  mapfile -t FILES < <(get_client_files_ordered)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "Keine Client-Configs gefunden in:"
    echo "$CLIENT_DIR"
    return
  fi

  printf "%-4s %-28s %-18s %-25s %-10s\n" "Nr." "Name" "IP" "DNS" "Status"
  printf "%-4s %-28s %-18s %-25s %-10s\n" "---" "----------------------------" "------------------" "-------------------------" "----------"

  INDEX=1

  for FILE in "${FILES[@]}"; do
    NAME=$(basename "$FILE" .conf)
    IP=$(grep "^Address =" "$FILE" | awk '{print $3}' | cut -d'/' -f1)
    DNS=$(grep "^DNS =" "$FILE" | cut -d'=' -f2- | xargs)

    if validate_client_conf "$FILE"; then
      STATUS="gültig"
    else
      STATUS="fehlerhaft"
    fi

    printf "%-4s %-28s %-18s %-25s %-10s\n" "$INDEX" "$NAME" "$IP" "$DNS" "$STATUS"
    INDEX=$((INDEX+1))
  done

  echo ""
}

get_client_files_ordered() {
  shopt -s nullglob
  FILES=("$CLIENT_DIR"/*.conf)

  if [ ${#FILES[@]} -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${FILES[@]}" | while IFS= read -r FILE; do
    IP="$(grep "^Address =" "$FILE" | awk '{print $3}' | cut -d'/' -f1)"
    if [ -n "$IP" ]; then
      awk -v ip="$IP" -v file="$FILE" '
        BEGIN {
          split(ip, parts, ".")
          printf "%03d.%03d.%03d.%03d\t%s\n", parts[1], parts[2], parts[3], parts[4], file
        }
      '
    else
      printf "999.999.999.999\t%s\n" "$FILE"
    fi
  done | sort | cut -f2-
}

show_created_client() {
  CONF_FILE="$1"
  CLIENT_QR="$2"

  echo ""
  echo "=============================="
  echo "VALIDIERUNG"
  echo "=============================="
  echo ""

  if validate_client_conf "$CONF_FILE"; then
    echo "OK - gültige WireGuard-Konfiguration erkannt."
  else
    echo "FEHLER - wichtige Felder fehlen."
    exit 1
  fi

  echo ""
  echo "=============================="
  echo "WIREGUARD CLIENT CONFIG"
  echo "=============================="
  echo ""

  cat "$CONF_FILE"

  echo ""
  echo "=============================="
  echo "QR-CODE"
  echo "=============================="
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CONF_FILE"
    qrencode -o "$CLIENT_QR" -t png < "$CONF_FILE"

    echo ""
    echo "PNG gespeichert unter:"
    echo "$CLIENT_QR"
  else
    echo "qrencode nicht installiert."
    echo "Installieren mit:"
    echo "apt install qrencode -y"
  fi
}

show_client() {
  mapfile -t FILES < <(get_client_files_ordered)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "Keine Client-Configs gefunden."
    return
  fi

  list_clients

  read -p "Welche Nr. anzeigen? " SELECTION

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Fehler: Bitte eine Nummer eingeben."
    return
  fi

  INDEX=$((SELECTION-1))

  if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#FILES[@]}" ]; then
    echo "Fehler: Ungültige Auswahl."
    return
  fi

  CONF_FILE="${FILES[$INDEX]}"
  CLIENT_NAME=$(basename "$CONF_FILE" .conf)
  CLIENT_QR="$CLIENT_DIR/${CLIENT_NAME}.png"

  echo ""
  echo "=============================="
  echo "WIREGUARD CLIENT CONFIG"
  echo "=============================="
  echo ""
  echo "Datei: $CONF_FILE"
  echo ""

  cat "$CONF_FILE"

  echo ""
  echo "=============================="
  echo "VALIDIERUNG"
  echo "=============================="
  echo ""

  if validate_client_conf "$CONF_FILE"; then
    echo "OK - gültige WireGuard-Konfiguration erkannt."
  else
    echo "WARNUNG - Konfiguration scheint unvollständig oder fehlerhaft."
  fi

  echo ""
  echo "=============================="
  echo "QR-CODE"
  echo "=============================="
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CONF_FILE"
    qrencode -o "$CLIENT_QR" -t png < "$CONF_FILE"

    echo ""
    echo "PNG gespeichert unter:"
    echo "$CLIENT_QR"
  else
    echo "qrencode nicht installiert."
    echo "Installieren mit:"
    echo "apt install qrencode -y"
  fi
}

show_status_dashboard() {
  if [ ! -x "$DASHBOARD_SCRIPT" ]; then
    echo "Fehler: Dashboard-Script nicht gefunden oder nicht ausführbar:"
    echo "$DASHBOARD_SCRIPT"
    return
  fi

  "$DASHBOARD_SCRIPT" --once || true
}

show_help() {
  echo ""
  echo "=============================="
  echo "HILFE"
  echo "=============================="
  echo ""
  echo "1) Neuen Client erstellen"
  echo "   Erstellt eine neue WireGuard-Client-Config mit freier IP,"
  echo "   erweitert wg0.conf und erzeugt optional QR/PNG."
  echo ""
  echo "2) Vorhandene Clients anzeigen"
  echo "   Listet alle gespeicherten Client-Configs mit IP, DNS und Status."
  echo ""
  echo "3) Client-Config inkl. QR-Code anzeigen"
  echo "   Zeigt eine vorhandene .conf an und erzeugt den QR-Code neu."
  echo ""
  echo "4) Client entfernen"
  echo "   Entfernt den Peer aus wg0.conf, loescht .conf und PNG"
  echo "   und erstellt vorher ein Backup von wg0.conf."
  echo ""
  echo "5) Status Dashboard anzeigen"
  echo "   Oeffnet die WireGuard-Statusansicht als Snapshot."
  echo "   Fuer die Live-Ansicht direkt ausfuehren:"
  echo "   $DASHBOARD_SCRIPT --watch"
  echo ""
  echo "6) Hilfe"
  echo "   Zeigt diesen Hilfetext an."
  echo ""
  echo "7) Beenden"
  echo ""
  echo "Wichtige Pfade:"
  echo "  Server-Config: $WG_CONF"
  echo "  Clients:       $CLIENT_DIR"
  echo "  Dashboard:     $DASHBOARD_SCRIPT"
  echo ""
  echo "Hinweis:"
  echo "  Das Script ist fuer Root-Betrieb auf dem VPS gedacht."
  echo ""
}

create_client() {
  check_base_files
  require_wg_running

  echo ""
  echo "Suche nächste freie WireGuard-IP..."

  NEXT_IP=$(get_next_ip)

  if [ -z "$NEXT_IP" ]; then
    echo "Fehler: Keine freie IP im Bereich ${WG_NET_PREFIX}.${START_IP}-${WG_NET_PREFIX}.${END_IP} gefunden."
    exit 1
  fi

  echo "Vorgeschlagene freie IP: $NEXT_IP"
  echo ""

  read -p "Name des Geräts, z.B. iphone-carolin: " CLIENT_NAME

  if [ -z "$CLIENT_NAME" ]; then
    echo "Fehler: Gerätename darf nicht leer sein."
    exit 1
  fi

  CLIENT_NAME=$(sanitize_name "$CLIENT_NAME")

  if [ -z "$CLIENT_NAME" ]; then
    echo "Fehler: Gerätename enthält keine gültigen Zeichen."
    exit 1
  fi

  read -p "Client-IP verwenden [$NEXT_IP]: " CLIENT_IP

  if [ -z "$CLIENT_IP" ]; then
    CLIENT_IP="$NEXT_IP"
  fi

  if ! [[ "$CLIENT_IP" =~ ^10\.100\.0\.[0-9]{1,3}$ ]]; then
    echo "Fehler: Ungültige IP. Erwartet z.B. 10.100.0.3"
    exit 1
  fi

  LAST_OCTET=$(echo "$CLIENT_IP" | awk -F. '{print $4}')

  if [ "$LAST_OCTET" -lt "$START_IP" ] || [ "$LAST_OCTET" -gt "$END_IP" ]; then
    echo "Fehler: IP außerhalb des erlaubten Bereichs."
    exit 1
  fi

  USED_IPS=$(get_used_ips)

  if echo "$USED_IPS" | grep -qx "$CLIENT_IP"; then
    echo "Fehler: IP $CLIENT_IP ist bereits vergeben."
    exit 1
  fi

  select_dns
  select_allowed_ips

  CLIENT_CONF="$CLIENT_DIR/${CLIENT_NAME}.conf"
  CLIENT_QR="$CLIENT_DIR/${CLIENT_NAME}.png"

  if [ -f "$CLIENT_CONF" ]; then
    echo "Fehler: Client-Datei existiert bereits:"
    echo "$CLIENT_CONF"
    exit 1
  fi

  CLIENT_PRIVATE_KEY=$(wg genkey)
  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  BACKUP_FILE=$(backup_wg_conf)
  TMP_WG_CONF="${WG_CONF}.tmp.$$"
  trap 'rm -f "${TMP_WG_CONF:-}"' EXIT

  cp "$WG_CONF" "$TMP_WG_CONF"

  cat >> "$TMP_WG_CONF" <<EOF

# BEGIN_CLIENT ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
PersistentKeepalive = 25
# END_CLIENT ${CLIENT_NAME}
EOF

  CLIENT_DNS_BLOCK=""
  if [ -n "$DNS_SERVER" ]; then
    CLIENT_DNS_BLOCK="DNS = ${DNS_SERVER}"
  fi

  cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
${CLIENT_DNS_BLOCK}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOF

  mv "$TMP_WG_CONF" "$WG_CONF"
  chmod 600 "$WG_CONF"
  chmod 600 "$CLIENT_CONF"

  if ! restart_wg_with_rollback "$BACKUP_FILE" "$CLIENT_CONF" "$CLIENT_QR"; then
    exit 1
  fi

  echo ""
  echo "Client erstellt:"
  echo "$CLIENT_CONF"
  echo ""
  echo "Verwendete IP:"
  echo "$CLIENT_IP"
  echo ""
  echo "DNS:"
  if [ -n "$DNS_SERVER" ]; then
    echo "$DNS_SERVER"
  else
    echo "kein DNS gesetzt"
  fi
  echo ""
  echo "AllowedIPs:"
  echo "$CLIENT_ALLOWED_IPS"

  show_created_client "$CLIENT_CONF" "$CLIENT_QR"
}

remove_client() {
  check_base_files

  mapfile -t FILES < <(get_client_files_ordered)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "Keine Client-Configs gefunden."
    return
  fi

  list_clients

  read -p "Welche Nr. entfernen? " SELECTION

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Fehler: Bitte eine Nummer eingeben."
    return
  fi

  INDEX=$((SELECTION-1))

  if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#FILES[@]}" ]; then
    echo "Fehler: Ungültige Auswahl."
    return
  fi

  CONF_FILE="${FILES[$INDEX]}"
  CLIENT_NAME=$(basename "$CONF_FILE" .conf)
  CLIENT_QR="$CLIENT_DIR/${CLIENT_NAME}.png"
  CLIENT_IP=$(grep "^Address =" "$CONF_FILE" | awk '{print $3}' | cut -d'/' -f1)

  echo ""
  echo "Client wird entfernt:"
  echo "Name: $CLIENT_NAME"
  echo "IP:   $CLIENT_IP"
  echo "Datei: $CONF_FILE"
  echo ""

  read -p "Wirklich entfernen? [ja/NEIN]: " CONFIRM

  if [ "$CONFIRM" != "ja" ]; then
    echo "Abgebrochen."
    return
  fi

  CLIENT_PRIVATE_KEY=$(grep "^PrivateKey =" "$CONF_FILE" | cut -d'=' -f2- | xargs)

  if [ -z "$CLIENT_PRIVATE_KEY" ]; then
    echo "Fehler: PrivateKey konnte aus $CONF_FILE nicht gelesen werden."
    return
  fi

  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  BACKUP_FILE=$(backup_wg_conf)
  TMP_WG_CONF="${WG_CONF}.tmp.$$"

  remove_peer_by_public_key "$CLIENT_PUBLIC_KEY" "$TMP_WG_CONF"

  if cmp -s "$WG_CONF" "$TMP_WG_CONF"; then
    rm -f "$TMP_WG_CONF"
    echo "Fehler: Passender Peer für $CLIENT_NAME wurde in $WG_CONF nicht gefunden."
    return
  fi

  mv "$TMP_WG_CONF" "$WG_CONF"
  chmod 600 "$WG_CONF"

  if ! restart_wg_with_rollback "$BACKUP_FILE"; then
    exit 1
  fi

  rm -f "$CONF_FILE"
  rm -f "$CLIENT_QR"

  echo ""
  echo "Client entfernt:"
  echo "$CLIENT_NAME"
}

main_menu() {
  while true; do
    echo ""
    echo "=============================="
    echo "Gate2Home WireGuard Manager"
    echo "=============================="
    echo ""
    echo "1) Neuen Client erstellen"
    echo "2) Vorhandene Clients anzeigen"
    echo "3) Client-Config inkl. QR-Code anzeigen"
    echo "4) Client entfernen"
    echo "5) Status Dashboard anzeigen"
    echo "6) Hilfe"
    echo "7) Beenden"
    echo ""

    if ! read -p "Auswahl: " CHOICE; then
      echo ""
      echo "Beendet."
      exit 0
    fi

    case "$CHOICE" in
      1) create_client ;;
      2) list_clients ;;
      3) show_client ;;
      4) remove_client ;;
      5) show_status_dashboard ;;
      6) show_help ;;
      7)
        echo "Beendet."
        exit 0
        ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done
}

require_root
umask 077
main_menu
____W2H_CREATE_CLIENT____
  chmod 700 "$1"
}
write_backup_wireguard2home_sh() {
  cat > "$1" <<'____W2H_BACKUP____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/runtime-paths.sh"

DATE=$(date +"%Y-%m-%d_%H-%M-%S")

BACKUP_BASE="$WIREGUARD2HOME_BACKUP_BASE"
BACKUP_WORKDIR=""
BACKUP_FILE="$BACKUP_BASE/gate2home-backup-$DATE.tar.gz"

RPI_USER="$WIREGUARD2HOME_BACKUP_REMOTE_USER"
RPI_HOST="$WIREGUARD2HOME_BACKUP_REMOTE_HOST"
RPI_TARGET="$WIREGUARD2HOME_BACKUP_REMOTE_TARGET"
SSH_KEY="$WIREGUARD2HOME_BACKUP_SSH_KEY"
CLIENT_DIR="$WIREGUARD2HOME_CLIENT_DIR"
CLIENT_ARCHIVE_PATH="$WIREGUARD2HOME_CLIENT_ARCHIVE_PATH"

LOCAL_KEEP_DAYS=14
LOCAL_KEEP_COUNT=30

RPI_KEEP_DAYS=30
RPI_KEEP_COUNT=60

cleanup() {
  if [ -n "${BACKUP_WORKDIR:-}" ] && [ -d "$BACKUP_WORKDIR" ]; then
    rm -rf "$BACKUP_WORKDIR"
  fi
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte mit sudo oder als root ausführen."
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehler: Benötigtes Kommando nicht gefunden: $1"
    exit 1
  fi
}

check_prerequisites() {
  require_command tar
  require_command rsync
  require_command ssh
  require_command find
  require_command sort

  if [ ! -f "$SSH_KEY" ]; then
    echo "Fehler: SSH-Key nicht gefunden: $SSH_KEY"
    exit 1
  fi
}

rotate_backups() {
  TARGET_DIR="$1"
  KEEP_DAYS="$2"
  KEEP_COUNT="$3"
  FILE_PATTERN="$4"

  find "$TARGET_DIR" -type f -name "$FILE_PATTERN" -mtime +"$KEEP_DAYS" -delete

  mapfile -t BACKUP_FILES < <(find "$TARGET_DIR" -maxdepth 1 -type f -name "$FILE_PATTERN" -printf '%T@ %p\n' | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')

  if [ "${#BACKUP_FILES[@]}" -le "$KEEP_COUNT" ]; then
    return
  fi

  for OLD_FILE in "${BACKUP_FILES[@]:$KEEP_COUNT}"; do
    rm -f "$OLD_FILE"
  done
}

verify_archive() {
  if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "Fehler: Archivprüfung fehlgeschlagen: $BACKUP_FILE"
    exit 1
  fi
}

trap cleanup EXIT

require_root
umask 077
check_prerequisites

mkdir -p "$BACKUP_BASE"
BACKUP_WORKDIR=$(mktemp -d -t gate2home-backup-XXXXXX)

echo "=============================="
echo "Gate2Home Backup gestartet"
echo "Datum: $DATE"
echo "=============================="

mkdir -p "$BACKUP_WORKDIR/etc"
mkdir -p "$BACKUP_WORKDIR/opt"
mkdir -p "$BACKUP_WORKDIR/system"

# WireGuard
if [ -d "/etc/wireguard" ]; then
  cp -a /etc/wireguard "$BACKUP_WORKDIR/etc/"
fi

# WireGuard Client Configs
if [ -d "$CLIENT_DIR" ]; then
  mkdir -p "$BACKUP_WORKDIR/$(dirname "$CLIENT_ARCHIVE_PATH")"
  cp -a "$CLIENT_DIR" "$BACKUP_WORKDIR/$(dirname "$CLIENT_ARCHIVE_PATH")/"
fi

# Nginx Proxy Manager
if [ -d "/opt/npm" ]; then
  cp -a /opt/npm "$BACKUP_WORKDIR/opt/"
fi

# Watchtower
if [ -d "/opt/watchtower" ]; then
  cp -a /opt/watchtower "$BACKUP_WORKDIR/opt/"
fi

# CrowdSec
if [ -d "/etc/crowdsec" ]; then
  cp -a /etc/crowdsec "$BACKUP_WORKDIR/etc/"
fi

# Fail2Ban
if [ -d "/etc/fail2ban" ]; then
  cp -a /etc/fail2ban "$BACKUP_WORKDIR/etc/"
fi

# UFW
if [ -d "/etc/ufw" ]; then
  cp -a /etc/ufw "$BACKUP_WORKDIR/etc/"
fi

# Service-Infos
systemctl is-enabled wg-quick@wg0 > "$BACKUP_WORKDIR/system/wg-enabled.txt" 2>/dev/null || true
systemctl status wg-quick@wg0 --no-pager > "$BACKUP_WORKDIR/system/wg-status.txt" 2>/dev/null || true
docker ps > "$BACKUP_WORKDIR/system/docker-ps.txt" 2>/dev/null || true
ufw status verbose > "$BACKUP_WORKDIR/system/ufw-status.txt" 2>/dev/null || true
cscli decisions list > "$BACKUP_WORKDIR/system/crowdsec-decisions.txt" 2>/dev/null || true
fail2ban-client status > "$BACKUP_WORKDIR/system/fail2ban-status.txt" 2>/dev/null || true

# Archiv erstellen
tar -czf "$BACKUP_FILE" -C "$BACKUP_WORKDIR" .
chmod 600 "$BACKUP_FILE"
verify_archive

echo ""
echo "Lokales Backup erstellt:"
echo "$BACKUP_FILE"

# Lokale Rotation
echo ""
echo "Bereinige lokale Backups..."

rotate_backups "$BACKUP_BASE" "$LOCAL_KEEP_DAYS" "$LOCAL_KEEP_COUNT" "gate2home-backup-*.tar.gz"

echo "Lokale Backup-Rotation abgeschlossen."

# Backup zum Raspberry kopieren
echo ""
echo "Kopiere Backup zum Raspberry..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$RPI_USER@$RPI_HOST" "mkdir -p '$RPI_TARGET'"

rsync -avz -e "ssh -i $(printf '%q' "$SSH_KEY") -o StrictHostKeyChecking=accept-new" \
  "$BACKUP_FILE" \
  "$RPI_USER@$RPI_HOST:$RPI_TARGET/"

# Raspberry Rotation
echo ""
echo "Bereinige Raspberry-Backups..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$RPI_USER@$RPI_HOST" "

mkdir -p '$RPI_TARGET'

find '$RPI_TARGET' -type f -name 'gate2home-backup-*.tar.gz' -mtime +$RPI_KEEP_DAYS -delete

find '$RPI_TARGET' -maxdepth 1 -type f -name 'gate2home-backup-*.tar.gz' -printf '%T@ %p\n' | sort -rn | awk 'NR > $RPI_KEEP_COUNT { \$1=\"\"; sub(/^ /, \"\"); print }' | while IFS= read -r old_file; do
  rm -f \"\$old_file\"
done
"

echo "Raspberry Backup-Rotation abgeschlossen."

echo ""
echo "Speicherübersicht VPS:"
df -h /

echo ""
echo "Backup erfolgreich abgeschlossen."
____W2H_BACKUP____
  chmod 700 "$1"
}
write_restore_wireguard2home_sh() {
  cat > "$1" <<'____W2H_RESTORE____'
#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/runtime-paths.sh"

BACKUP_BASE="$WIREGUARD2HOME_BACKUP_BASE"
RESTORE_ROOT="/tmp/gate2home-restore"
RESTORE_TS=$(date +"%Y-%m-%d_%H-%M-%S")
RESTORE_WORKDIR="$RESTORE_ROOT/$RESTORE_TS"
PRE_RESTORE_BASE="${WIREGUARD2HOME_PRE_RESTORE_ROOT}/gate2home-$RESTORE_TS"
CLIENT_DIR="$WIREGUARD2HOME_CLIENT_DIR"
CLIENT_ARCHIVE_PATH="$WIREGUARD2HOME_CLIENT_ARCHIVE_PATH"

MODE="interactive"
DRY_RUN=0
BACKUP_FILE=""

cleanup() {
  if [ -n "${RESTORE_WORKDIR:-}" ] && [ -d "$RESTORE_WORKDIR" ]; then
    rm -rf "$RESTORE_WORKDIR"
  fi
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehler: Benötigtes Kommando nicht gefunden: $1"
    exit 1
  fi
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Fehler: Bitte mit sudo oder als root ausführen."
    exit 1
  fi
}

check_prerequisites() {
  require_command tar
  require_command find
  require_command cp
  require_command mkdir
  require_command systemctl
}

usage() {
  cat <<EOF
Verwendung:
  $0 [--mode wireguard|clients|full] [--backup /pfad/zum/backup.tar.gz] [--dry-run]

Optionen:
  --mode      Restore-Modus: wireguard, clients, full
  --backup    Pfad zu einem Backup-Archiv
  --dry-run   Zeigt nur an, was restored würde
  --help      Diese Hilfe anzeigen
EOF
}

log_run() {
  echo "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

list_backups() {
  find "$BACKUP_BASE" -maxdepth 1 -type f -name "gate2home-backup-*.tar.gz" | sort
}

select_backup_interactive() {
  mapfile -t BACKUPS < <(list_backups)

  if [ "${#BACKUPS[@]}" -eq 0 ]; then
    echo "Fehler: Keine Backups gefunden in $BACKUP_BASE"
    exit 1
  fi

  echo ""
  echo "Verfügbare Backups:"
  echo ""

  INDEX=1
  for FILE in "${BACKUPS[@]}"; do
    echo "$INDEX) $(basename "$FILE")"
    INDEX=$((INDEX+1))
  done

  echo ""
  read -p "Welches Backup wiederherstellen? [1]: " SELECTION

  if [ -z "$SELECTION" ]; then
    SELECTION=1
  fi

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Fehler: Bitte eine Nummer eingeben."
    exit 1
  fi

  INDEX=$((SELECTION-1))

  if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#BACKUPS[@]}" ]; then
    echo "Fehler: Ungültige Auswahl."
    exit 1
  fi

  BACKUP_FILE="${BACKUPS[$INDEX]}"
}

select_mode_interactive() {
  echo ""
  echo "Restore-Modus auswählen:"
  echo ""
  echo "1) wireguard"
  echo "   /etc/wireguard wiederherstellen"
  echo ""
  echo "2) clients"
  echo "   ${CLIENT_DIR} wiederherstellen"
  echo ""
  echo "3) full"
  echo "   alle gesicherten Verzeichnisse wiederherstellen"
  echo ""

  read -p "Auswahl [1]: " MODE_CHOICE

  case "$MODE_CHOICE" in
    ""|1) MODE="wireguard" ;;
    2) MODE="clients" ;;
    3) MODE="full" ;;
    *)
      echo "Fehler: Ungültige Auswahl."
      exit 1
      ;;
  esac
}

prepare_restore() {
  if [ -z "$BACKUP_FILE" ]; then
    select_backup_interactive
  fi

  if [ ! -f "$BACKUP_FILE" ]; then
    echo "Fehler: Backup-Datei nicht gefunden: $BACKUP_FILE"
    exit 1
  fi

  if [ "$MODE" = "interactive" ]; then
    select_mode_interactive
  fi

  mkdir -p "$RESTORE_WORKDIR"

  if ! tar -xzf "$BACKUP_FILE" -C "$RESTORE_WORKDIR"; then
    echo "Fehler: Backup konnte nicht entpackt werden."
    exit 1
  fi
}

backup_existing_path() {
  SRC_PATH="$1"
  DEST_PATH="$2"

  if [ -e "$SRC_PATH" ]; then
    log_run mkdir -p "$(dirname "$DEST_PATH")"
    log_run cp -a "$SRC_PATH" "$DEST_PATH"
  fi
}

restore_directory_contents() {
  SRC_DIR="$1"
  DEST_DIR="$2"

  if [ ! -d "$SRC_DIR" ]; then
    echo "Hinweis: Backup-Inhalt fehlt, überspringe $SRC_DIR"
    return
  fi

  log_run mkdir -p "$DEST_DIR"
  log_run cp -a "$SRC_DIR"/. "$DEST_DIR"/
}

restore_wireguard() {
  echo ""
  echo "Wiederherstellung: WireGuard"

  backup_existing_path "/etc/wireguard" "$PRE_RESTORE_BASE/etc/wireguard"
  restore_directory_contents "$RESTORE_WORKDIR/etc/wireguard" "/etc/wireguard"

  if [ "$DRY_RUN" -eq 0 ] && [ -f /etc/wireguard/wg0.conf ]; then
    chmod 600 /etc/wireguard/wg0.conf
    systemctl restart wg-quick@wg0
  fi
}

restore_clients() {
  echo ""
  echo "Wiederherstellung: WireGuard Clients"

  backup_existing_path "$CLIENT_DIR" "$PRE_RESTORE_BASE/$CLIENT_ARCHIVE_PATH"
  restore_directory_contents "$RESTORE_WORKDIR/$CLIENT_ARCHIVE_PATH" "$CLIENT_DIR"

  if [ "$DRY_RUN" -eq 0 ] && [ -d "$CLIENT_DIR" ]; then
    find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" -exec chmod 600 {} \;
  fi
}

restore_full() {
  echo ""
  echo "Wiederherstellung: Full Restore"

  backup_existing_path "/etc/wireguard" "$PRE_RESTORE_BASE/etc/wireguard"
  backup_existing_path "$CLIENT_DIR" "$PRE_RESTORE_BASE/$CLIENT_ARCHIVE_PATH"
  backup_existing_path "/opt/npm" "$PRE_RESTORE_BASE/opt/npm"
  backup_existing_path "/opt/watchtower" "$PRE_RESTORE_BASE/opt/watchtower"
  backup_existing_path "/etc/crowdsec" "$PRE_RESTORE_BASE/etc/crowdsec"
  backup_existing_path "/etc/fail2ban" "$PRE_RESTORE_BASE/etc/fail2ban"
  backup_existing_path "/etc/ufw" "$PRE_RESTORE_BASE/etc/ufw"

  restore_directory_contents "$RESTORE_WORKDIR/etc/wireguard" "/etc/wireguard"
  restore_directory_contents "$RESTORE_WORKDIR/$CLIENT_ARCHIVE_PATH" "$CLIENT_DIR"
  restore_directory_contents "$RESTORE_WORKDIR/opt/npm" "/opt/npm"
  restore_directory_contents "$RESTORE_WORKDIR/opt/watchtower" "/opt/watchtower"
  restore_directory_contents "$RESTORE_WORKDIR/etc/crowdsec" "/etc/crowdsec"
  restore_directory_contents "$RESTORE_WORKDIR/etc/fail2ban" "/etc/fail2ban"
  restore_directory_contents "$RESTORE_WORKDIR/etc/ufw" "/etc/ufw"

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -f /etc/wireguard/wg0.conf ]; then
      chmod 600 /etc/wireguard/wg0.conf
      systemctl restart wg-quick@wg0
    fi

    if [ -d "$CLIENT_DIR" ]; then
      find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" -exec chmod 600 {} \;
    fi
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        MODE="$2"
        shift 2
        ;;
      --backup)
        BACKUP_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "Fehler: Unbekannte Option $1"
        usage
        exit 1
        ;;
    esac
  done

  case "$MODE" in
    interactive|wireguard|clients|full) ;;
    *)
      echo "Fehler: Ungültiger Restore-Modus: $MODE"
      exit 1
      ;;
  esac
}

main() {
  parse_args "$@"
  require_root
  check_prerequisites
  prepare_restore

  echo "=============================="
  echo "Gate2Home Restore gestartet"
  echo "Backup: $BACKUP_FILE"
  echo "Modus:  $MODE"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "Modus:  Dry-Run"
  fi
  echo "=============================="

  case "$MODE" in
    wireguard) restore_wireguard ;;
    clients) restore_clients ;;
    full) restore_full ;;
  esac

  echo ""
  echo "Vorab-Sicherung des Ist-Zustands:"
  echo "$PRE_RESTORE_BASE"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "Dry-Run abgeschlossen. Es wurden keine Änderungen geschrieben."
    exit 0
  fi

  echo ""
  echo "Restore erfolgreich abgeschlossen."
}

main "$@"
____W2H_RESTORE____
  chmod 700 "$1"
}

# ──────────────────────────────────────────────────────────────────────────────
# Script extraction dispatcher
# ──────────────────────────────────────────────────────────────────────────────

extract_script() {
  local name="$1" target="$2"
  case "$name" in
    runtime-paths.sh)          write_runtime_paths_sh          "$target" ;;
    install-vps.sh)            write_install_vps_sh            "$target" ;;
    install-gateway-host.sh)   write_install_gateway_sh        "$target" ;;
    Wireguard2Home.sh)         write_wireguard2home_sh         "$target" ;;
    wireguard-dashboard.sh)    write_wireguard_dashboard_sh    "$target" ;;
    create-wg-client.sh)       write_create_wg_client_sh       "$target" ;;
    backup-wireguard2home.sh)  write_backup_wireguard2home_sh  "$target" ;;
    restore-wireguard2home.sh) write_restore_wireguard2home_sh "$target" ;;
    *)
      echo "Fehler: Kein eingebettetes Script gefunden: $name" >&2
      return 1
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Script resolution (4-tier: repo clone → already deployed → embedded → GitHub)
# ──────────────────────────────────────────────────────────────────────────────

download_file() {
  local script_name="$1"
  local target_path="$2"
  local url="${RAW_BASE_URL}/${script_name}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$target_path"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$target_path" "$url"
  else
    echo "Fehler: Fuer Downloads wird curl oder wget benoetigt."
    exit 1
  fi
  chmod 700 "$target_path"
}

ensure_local_script() {
  local script_name="$1"
  local default_target="${SERVICE_HOME}/${script_name}"

  # Tier 1: prefer repo-clone directory (when running from git checkout)
  if [ -f "${SCRIPT_DIR}/${script_name}" ]; then
    chmod 700 "${SCRIPT_DIR}/${script_name}"
    echo "${SCRIPT_DIR}/${script_name}"
    return
  fi

  # Hinweis: Eine bereits am Zielpfad liegende (evtl. veraltete) Datei wird
  # bewusst NICHT bevorzugt. Der Bootstrap rollt immer seine eingebetteten
  # Versionen aus, damit Updates (neue Flags, Bugfixes) zuverlaessig greifen.

  # Tier 2: extract from embedded heredoc (Quelle der Wahrheit fuer diesen Bootstrap)
  log "Extrahiere ${script_name} nach ${default_target} ..."
  mkdir -p "$(dirname "$default_target")"
  if extract_script "$script_name" "$default_target" 2>/dev/null; then
    echo "$default_target"
    return
  fi

  # Tier 4: GitHub fallback (e.g. if repo becomes public)
  log "Lade ${script_name} von GitHub ..."
  download_file "$script_name" "$default_target"
  echo "$default_target"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH / SCP helpers
#
# Hinweis: BatchMode wird bewusst NICHT gesetzt, damit auf einem frischen VPS
# (noch kein SSH-Key hinterlegt) die interaktive Passwort-Abfrage funktioniert.
# Per ControlMaster/ControlPath wird die Verbindung gemultiplext, sodass das
# Passwort nur einmal eingegeben werden muss, auch wenn mehrere SSH/SCP-Aufrufe
# erfolgen.
# ──────────────────────────────────────────────────────────────────────────────

SSH_CONTROL_PATH=""

ssh_mux_start() {
  if [ -n "$SSH_CONTROL_PATH" ]; then
    return
  fi
  local mux_dir
  mux_dir="$(mktemp -d "${TMPDIR:-/tmp}/w2h-ssh.XXXXXX")"
  SSH_CONTROL_PATH="${mux_dir}/cm"
}

ssh_mux_stop() {
  if [ -z "$SSH_CONTROL_PATH" ]; then
    return
  fi
  local ssh_key_opt=()
  if [ -n "$VPS_SSH_KEY" ]; then
    ssh_key_opt=(-i "$VPS_SSH_KEY")
  fi
  if [ -n "${VPS_HOST:-}" ]; then
    ssh "${ssh_key_opt[@]}" -o ControlPath="$SSH_CONTROL_PATH" -O exit "$VPS_HOST" >/dev/null 2>&1 || true
  fi
  rm -rf "$(dirname "$SSH_CONTROL_PATH")" 2>/dev/null || true
  SSH_CONTROL_PATH=""
}

build_ssh_cmd() {
  local out='ssh'
  if [ -n "$VPS_SSH_KEY" ]; then
    out+="$(printf ' -i %q' "$VPS_SSH_KEY")"
  fi
  out+=' -o StrictHostKeyChecking=accept-new'
  if [ -n "$SSH_CONTROL_PATH" ]; then
    out+="$(printf ' -o ControlMaster=auto -o ControlPath=%q -o ControlPersist=60' "$SSH_CONTROL_PATH")"
  fi
  printf '%s' "$out"
}

build_scp_cmd() {
  local out='scp'
  if [ -n "$VPS_SSH_KEY" ]; then
    out+="$(printf ' -i %q' "$VPS_SSH_KEY")"
  fi
  out+=' -o StrictHostKeyChecking=accept-new'
  if [ -n "$SSH_CONTROL_PATH" ]; then
    out+="$(printf ' -o ControlMaster=auto -o ControlPath=%q -o ControlPersist=60' "$SSH_CONTROL_PATH")"
  fi
  printf '%s' "$out"
}

# ──────────────────────────────────────────────────────────────────────────────
# Upload scripts to VPS via SCP (replaces GitHub download on VPS)
# ──────────────────────────────────────────────────────────────────────────────

upload_scripts_to_vps() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  (
    trap 'rm -rf "$tmp_dir"' EXIT

    log "Extrahiere VPS-Skripte lokal ..."
    extract_script "install-vps.sh"    "$tmp_dir/install-vps.sh"
    extract_script "Wireguard2Home.sh" "$tmp_dir/Wireguard2Home.sh"

    local ssh_cmd scp_cmd
    ssh_cmd="$(build_ssh_cmd)"
    scp_cmd="$(build_scp_cmd)"

    log "Erstelle Installationsverzeichnis auf VPS ..."
    $ssh_cmd "$VPS_HOST" "mkdir -p $(shell_escape "$REMOTE_INSTALL_DIR")"

    log "Lade Skripte auf VPS hoch (scp) ..."
    $scp_cmd "$tmp_dir/install-vps.sh" "$tmp_dir/Wireguard2Home.sh" \
      "${VPS_HOST}:${REMOTE_INSTALL_DIR}/"
  )
}

# ──────────────────────────────────────────────────────────────────────────────
# Installation plan summary with confirmation
# ──────────────────────────────────────────────────────────────────────────────

show_install_plan() {
  echo ""
  echo "══════════════════════════════════════════════════"
  echo " ${APP_NAME} — Installationsplan"
  echo "══════════════════════════════════════════════════"
  printf " Rolle       : %s\n" "$ROLE"
  if [ "$ROLE" = "gateway" ]; then
    printf " VPS-Host    : %s\n" "$VPS_HOST"
    printf " WG-Endpoint : %s:%s\n" "$VPS_ENDPOINT_HOST" "$WG_LISTEN_PORT"
  fi
  printf " LAN-Subnetz : %s\n" "$LAN_SUBNET"
  printf " DNS Heimnetz: %s -> %s\n" "$DNS_HOME_LABEL" "$DNS_HOME_VALUE"
  printf " DNS Router  : %s -> %s\n" "$DNS_ROUTER_LABEL" "$DNS_ROUTER_VALUE"
  echo ""
  case "$ROLE" in
    vps)
      echo " Pakete (dieser Host — VPS):"
      echo "   wireguard, qrencode, rsync, iperf3, openssh-server, ..."
      ;;
    gateway)
      echo " Pakete (Gateway-Host, dieser Host):"
      echo "   wireguard, rsync, iperf3, openssh-server, ..."
      echo " Pakete (VPS remote via SSH):"
      echo "   wireguard, qrencode, rsync, iperf3, openssh-server, ..."
      ;;
  esac
  echo "══════════════════════════════════════════════════"
  echo ""
  if [ -t 0 ]; then
    read -r -p "Installation starten? [J/n]: " _plan_ans
    case "${_plan_ans:-J}" in
      [nN]) echo "Abgebrochen."; exit 0 ;;
    esac
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Remote VPS installer invocation
# ──────────────────────────────────────────────────────────────────────────────

run_vps_installer_remote() {
  local ssh_cmd vps_cmd
  ssh_cmd="$(build_ssh_cmd)"
  vps_cmd="$(shell_escape "$REMOTE_INSTALL_DIR/install-vps.sh") \
    --service-user $(shell_escape "$REMOTE_SERVICE_USER") \
    --service-home $(shell_escape "$REMOTE_SERVICE_HOME") \
    --listen-port $(shell_escape "$WG_LISTEN_PORT") \
    --lan-subnet $(shell_escape "$LAN_SUBNET") \
    --dns-home-label $(shell_escape "$DNS_HOME_LABEL") \
    --dns-home-value $(shell_escape "$DNS_HOME_VALUE") \
    --dns-router-label $(shell_escape "$DNS_ROUTER_LABEL") \
    --dns-router-value $(shell_escape "$DNS_ROUTER_VALUE")"
  $ssh_cmd "$VPS_HOST" "$vps_cmd"
}

fetch_remote_value() {
  local remote_cmd="$1"
  local ssh_cmd
  ssh_cmd="$(build_ssh_cmd)"
  $ssh_cmd "$VPS_HOST" "$remote_cmd"
}

# ──────────────────────────────────────────────────────────────────────────────
# Transfer the gateway peer block to the VPS and merge it into wg0.conf
# ──────────────────────────────────────────────────────────────────────────────

apply_peer_to_vps() {
  local local_peer="/etc/wireguard/vps-peer.conf"
  if [ ! -f "$local_peer" ]; then
    log "Hinweis: ${local_peer} nicht gefunden – Peer-Block wird nicht automatisch uebertragen."
    return 0
  fi

  local ssh_cmd scp_cmd
  ssh_cmd="$(build_ssh_cmd)"
  scp_cmd="$(build_scp_cmd)"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  (
    trap 'rm -rf "$tmp_dir"' EXIT

    # Idempotentes Merge-Skript fuer den VPS
    cat > "$tmp_dir/merge-peer.sh" <<'____W2H_MERGE_PEER____'
#!/bin/bash
set -euo pipefail
WG_IFACE="wg0"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
PEER_FILE="$1"

pubkey="$(awk -F' = ' '/^PublicKey/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$PEER_FILE")"
if [ -z "$pubkey" ]; then
  echo "Fehler: Kein PublicKey in $PEER_FILE gefunden." >&2
  exit 1
fi

if [ ! -f "$WG_CONF" ]; then
  echo "Fehler: $WG_CONF existiert nicht." >&2
  exit 1
fi

# Vorhandenen [Peer]-Block mit gleichem PublicKey entfernen (idempotent)
tmp_conf="$(mktemp)"
awk -v key="$pubkey" '
  BEGIN { RS=""; FS="\n" }
  {
    if ($0 ~ /\[Peer\]/ && $0 ~ key) { next }
    printf "%s%s", (printed++ ? "\n\n" : ""), $0
  }
  END { if (printed) print "" }
' "$WG_CONF" > "$tmp_conf"

# Neuen Peer-Block anhaengen
{
  echo ""
  cat "$PEER_FILE"
} >> "$tmp_conf"

install -m 600 "$tmp_conf" "$WG_CONF"
rm -f "$tmp_conf"

# Live anwenden, ohne bestehende Tunnel zu kappen
if command -v wg-quick >/dev/null 2>&1 && wg show "$WG_IFACE" >/dev/null 2>&1; then
  if ! wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null; then
    systemctl restart "wg-quick@${WG_IFACE}" 2>/dev/null || true
  fi
else
  systemctl restart "wg-quick@${WG_IFACE}" 2>/dev/null || true
fi
echo "Peer ${pubkey} in ${WG_CONF} aktiv."
____W2H_MERGE_PEER____

    log "Uebertrage Peer-Block auf den VPS ..."
    $scp_cmd "$local_peer" "${VPS_HOST}:${REMOTE_INSTALL_DIR}/vps-peer.conf"
    $scp_cmd "$tmp_dir/merge-peer.sh" "${VPS_HOST}:${REMOTE_INSTALL_DIR}/merge-peer.sh"

    log "Trage Peer-Block auf dem VPS ein und lade WireGuard neu ..."
    $ssh_cmd "$VPS_HOST" "bash $(shell_escape "${REMOTE_INSTALL_DIR}/merge-peer.sh") $(shell_escape "${REMOTE_INSTALL_DIR}/vps-peer.conf") && rm -f $(shell_escape "${REMOTE_INSTALL_DIR}/merge-peer.sh") $(shell_escape "${REMOTE_INSTALL_DIR}/vps-peer.conf")"
  )
}

# ──────────────────────────────────────────────────────────────────────────────
# Local VPS installation
# ──────────────────────────────────────────────────────────────────────────────

install_vps_local() {
  local installer_path w2h_src
  installer_path="$(ensure_local_script "install-vps.sh")"
  w2h_src="$(ensure_local_script "Wireguard2Home.sh")"

  "$installer_path" \
    --script-source "$w2h_src" \
    --service-user "$SERVICE_USER" \
    --service-home "$SERVICE_HOME" \
    --listen-port "$WG_LISTEN_PORT" \
    --lan-subnet "$LAN_SUBNET" \
    --dns-home-label "$DNS_HOME_LABEL" \
    --dns-home-value "$DNS_HOME_VALUE" \
    --dns-router-label "$DNS_ROUTER_LABEL" \
    --dns-router-value "$DNS_ROUTER_VALUE" \
    ${RASPBERRY_INSTALL_ARGS[@]+"${RASPBERRY_INSTALL_ARGS[@]}"}

  local active_server_key=""
  local backup_key=""
  local vps_host_hint="${VPS_HOST:-root@YOUR_VPS_HOST}"

  if [ -f /etc/wireguard/server_public.key ]; then
    active_server_key="$(cat /etc/wireguard/server_public.key)"
  fi

  if [ -f "${SERVICE_HOME}/.ssh/gate2home_backup.pub" ]; then
    backup_key="$(cat "${SERVICE_HOME}/.ssh/gate2home_backup.pub")"
  fi

  local endpoint_hint="${VPS_ENDPOINT_HOST:-vpn.example.com}:${WG_LISTEN_PORT}"

  echo ""
  echo "Copy & Paste fuer den Gateway-Host:"
  echo ""
  printf "curl -fsSL %s/install-wireguard2home.sh -o %s/install-wireguard2home.sh && chmod +x %s/install-wireguard2home.sh && %s/install-wireguard2home.sh --role gateway --vps-host %s --service-user %s --service-home %s --remote-service-user %s --remote-service-home %s --server-public-key %s --vps-backup-public-key %s --server-endpoint %s --lan-subnet %s\n" \
    "$(shell_escape "$RAW_BASE_URL")" \
    "$(shell_escape "$SERVICE_HOME")" \
    "$(shell_escape "$SERVICE_HOME")" \
    "$(shell_escape "$SERVICE_HOME")" \
    "$(shell_escape "$vps_host_hint")" \
    "$(shell_escape "$SERVICE_USER")" \
    "$(shell_escape "$SERVICE_HOME")" \
    "$(shell_escape "$SERVICE_USER")" \
    "$(shell_escape "$SERVICE_HOME")" \
    "$(shell_escape "$active_server_key")" \
    "$(shell_escape "$backup_key")" \
    "$(shell_escape "$endpoint_hint")" \
    "$(shell_escape "$LAN_SUBNET")"
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Gateway-Host local + VPS remote installation
# ──────────────────────────────────────────────────────────────────────────────

install_gateway_local_and_vps_remote() {
  ensure_ssh_client

  if [ -z "$VPS_HOST" ]; then
    echo "Fehler: Fuer den Gateway-Modus ist --vps-host USER@HOST erforderlich."
    exit 1
  fi

  local gateway_installer
  gateway_installer="$(ensure_local_script "install-gateway-host.sh")"

  # Verbindung multiplexen: Passwort (falls noch kein Key auf dem VPS liegt)
  # muss nur einmal eingegeben werden und gilt fuer alle folgenden SSH/SCP-Aufrufe.
  ssh_mux_start
  trap 'ssh_mux_stop' EXIT
  echo ""
  echo "Hinweis: Falls der VPS noch keinen SSH-Key kennt, wirst du jetzt einmal"
  echo "nach dem VPS-Passwort gefragt."

  upload_scripts_to_vps
  run_vps_installer_remote

  if [ -z "$SERVER_PUBLIC_KEY" ]; then
    SERVER_PUBLIC_KEY="$(fetch_remote_value 'cat /etc/wireguard/server_public.key')"
  fi

  if [ -z "$VPS_BACKUP_PUBLIC_KEY" ]; then
    VPS_BACKUP_PUBLIC_KEY="$(fetch_remote_value "cat $(shell_escape "${REMOTE_SERVICE_HOME}/.ssh/gate2home_backup.pub")")"
  fi

  "$gateway_installer" \
    --service-user "$SERVICE_USER" \
    --service-home "$SERVICE_HOME" \
    --server-public-key "$SERVER_PUBLIC_KEY" \
    --vps-backup-public-key "$VPS_BACKUP_PUBLIC_KEY" \
    --server-endpoint "${VPS_ENDPOINT_HOST}:${WG_LISTEN_PORT}" \
    --lan-subnet "$LAN_SUBNET" \
    "${RASPBERRY_INSTALL_ARGS[@]}"

  # Gateway-Peer automatisch auf den VPS uebertragen und WireGuard neu laden
  apply_peer_to_vps

  ssh_mux_stop
  trap - EXIT

  echo ""
  echo "Der VPS wurde remote vorbereitet und der Gateway-Host lokal installiert."
  echo "Der Peer-Block des Gateway-Hosts wurde automatisch in die wg0.conf des VPS"
  echo "eingetragen und WireGuard neu geladen. Eine manuelle Uebernahme ist nicht noetig."
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Update mode: refresh deployed runtime scripts (keeps config & keys)
# ──────────────────────────────────────────────────────────────────────────────

UPDATE_SCRIPT_SET="runtime-paths.sh Wireguard2Home.sh wireguard-dashboard.sh create-wg-client.sh backup-wireguard2home.sh restore-wireguard2home.sh"

run_update_local() {
  log "Aktualisiere Runtime-Skripte in ${SERVICE_HOME} ..."
  mkdir -p "$SERVICE_HOME"
  local name
  for name in $UPDATE_SCRIPT_SET; do
    extract_script "$name" "${SERVICE_HOME}/${name}"
  done
  log "Lokale Skripte aktualisiert. WireGuard-Konfiguration und Schluessel bleiben unveraendert."
}

run_update_remote_vps() {
  ensure_ssh_client
  ssh_mux_start
  trap 'ssh_mux_stop' EXIT
  echo ""
  echo "Hinweis: Falls noch kein SSH-Key auf dem VPS liegt, wirst du einmal nach dem Passwort gefragt."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local ssh_cmd scp_cmd name
  ssh_cmd="$(build_ssh_cmd)"
  scp_cmd="$(build_scp_cmd)"

  for name in $UPDATE_SCRIPT_SET; do
    extract_script "$name" "${tmp_dir}/${name}"
  done

  log "Lade aktualisierte Skripte auf den VPS (${REMOTE_SERVICE_HOME}) ..."
  $ssh_cmd "$VPS_HOST" "mkdir -p $(shell_escape "$REMOTE_SERVICE_HOME")"
  for name in $UPDATE_SCRIPT_SET; do
    $scp_cmd "${tmp_dir}/${name}" "${VPS_HOST}:${REMOTE_SERVICE_HOME}/${name}"
  done
  $ssh_cmd "$VPS_HOST" "chmod 700 $(shell_escape "$REMOTE_SERVICE_HOME")/Wireguard2Home.sh 2>/dev/null || true"

  rm -rf "$tmp_dir"
  ssh_mux_stop
  trap - EXIT
  log "VPS-Skripte aktualisiert."
}

run_update() {
  if [ "$ROLE" = "auto" ]; then
    ROLE="$(detect_role)"
  fi

  run_update_local

  if [ "$ROLE" = "gateway" ] && [ -n "$VPS_HOST" ]; then
    run_update_remote_vps
  fi

  echo ""
  echo "Update abgeschlossen."
  if [ "$ROLE" = "gateway" ] && [ -z "$VPS_HOST" ]; then
    echo "Hinweis: Fuer ein VPS-Update zusaetzlich --vps-host USER@HOST angeben."
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  require_root

  if [ "$UPDATE_MODE" -eq 1 ]; then
    run_update
    exit 0
  fi

  ask_role_if_needed
  ask_gateway_connection_if_needed
  ask_infra_config_if_needed
  show_install_plan

  case "$ROLE" in
    vps)     install_vps_local ;;
    gateway) install_gateway_local_and_vps_remote ;;
    *)       echo "Fehler: Unbekannte Rolle: $ROLE"; exit 1 ;;
  esac
}

main "$@"
