#!/bin/bash
# Copyright (c) 2026 Wireguard2Home / Gate2Home / https://github.com/wikicell. All rights reserved.
set -e

APP_NAME="Wireguard2Home"
W2H_VERSION="1.2.0"
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
    echo "Fehler: Root-Rechte benoetigt (fuer wg, systemctl, iptables)."
    echo "  -> Starte erneut mit: sudo $0"
    exit 1
  fi
}

common_pause_return() {
  echo ""
  read -p "Enter fuer Zurueck..." _ || true
}

common_is_yes() {
  # Akzeptiert ja/j/yes/y in beliebiger Gross-/Kleinschreibung.
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    ja|j|yes|y) return 0 ;;
    *) return 1 ;;
  esac
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

app_status_line() {
  # Kompakte Statuszeile: Tunnel, Endpoint, Clients, Gateway-Handshake.
  local _tunnel="inaktiv" _clients=0 _gw="—" _ep="$ENDPOINT"

  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    _tunnel="aktiv"
  fi

  if [ -d "$CLIENT_DIR" ]; then
    _clients=$(find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Gateway-Host = Peer mit 10.100.0.2 in den AllowedIPs; letzten Handshake ablesen
  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    local _gw_key
    _gw_key=$(wg show "$WG_IFACE" allowed-ips 2>/dev/null | awk '/10\.100\.0\.2\/32/ {print $1; exit}')
    if [ -n "$_gw_key" ]; then
      local _hs
      _hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk -v k="$_gw_key" '$1==k {print $2; exit}')
      if [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null; then
        local _age=$(( $(date +%s) - _hs ))
        if [ "$_age" -lt 180 ]; then
          _gw="verbunden (vor ${_age}s)"
        else
          _gw="stale (vor ${_age}s)"
        fi
      else
        _gw="kein Handshake"
      fi
    fi
  fi

  printf "  Tunnel: %-8s  Clients: %-3s  Gateway: %s\n" "$_tunnel" "$_clients" "$_gw"
  printf "  Endpoint: %s\n" "$_ep"
  if [ "${_ep%%:*}" = "vpn.example.com" ]; then
    printf "  \033[33m! Endpoint ist noch Platzhalter — Client-Configs waeren ungueltig\033[0m\n"
  fi
}

app_banner() {
  echo ""
  echo "========================================"
  echo "$APP_NAME  v${W2H_VERSION}"
  echo "========================================"
  app_status_line
  echo "========================================"
  echo ""
}

app_check_base_files() {
  if [ ! -f "$WG_CONF" ]; then
    echo "Fehler: $WG_CONF nicht gefunden."
    echo "  -> Wurde der VPS-Installer ausgefuehrt? install-wireguard2home.sh --role vps"
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

wireguard_reload_live() {
  # Wendet die neue wg0.conf live an, ohne bestehende Tunnel zu unterbrechen.
  # wg syncconf braucht 'wg-quick strip' (entfernt PostUp/PostDown), da
  # syncconf nur [Interface]/[Peer]-Direktiven akzeptiert.
  if command -v wg-quick >/dev/null 2>&1 && wg show "$WG_IFACE" >/dev/null 2>&1; then
    if wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE" 2>/dev/null) 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback: vollstaendiger Neustart (unterbricht aktive Sessions)
  systemctl restart "wg-quick@$WG_IFACE"
}

wireguard_restart_with_rollback() {
  CONF_BACKUP_FILE="$1"
  CLIENT_CONF_TO_DELETE="${2:-}"
  CLIENT_QR_TO_DELETE="${3:-}"

  if wireguard_reload_live; then
    return 0
  fi

  echo ""
  echo "Fehler: WireGuard-Reload fuer $WG_IFACE fehlgeschlagen."
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

  # Exklusives Lock waehrend der gesamten Client-Erstellung – verhindert,
  # dass zwei gleichzeitige Aufrufe dieselbe freie IP vergeben.
  _wg_lock_file="${WG_DIR}/.wg-client-create.lock"
  exec {_wg_lock_fd}>"$_wg_lock_file"
  if ! flock -n "$_wg_lock_fd" 2>/dev/null; then
    echo "Fehler: Ein anderer Client-Erstellungsprozess laeuft gerade. Bitte warten."
    exec {_wg_lock_fd}>&- 2>/dev/null || true
    return 1
  fi

  echo ""
  echo "Suche naechste freie WireGuard-IP..."
  NEXT_IP=$(wireguard_get_next_ip)

  if [ -z "$NEXT_IP" ]; then
    echo "Fehler: Keine freie IP im Bereich ${WG_NET_PREFIX}.${START_IP}-${WG_NET_PREFIX}.${END_IP} gefunden."
    echo "  -> Alle ${END_IP} Adressen vergeben? Entferne ungenutzte Clients (Menue 1 -> 4)."
    exec {_wg_lock_fd}>&- 2>/dev/null || true
    return 1
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
  trap 'rm -f "${TMP_WG_CONF:-}"; exec {_wg_lock_fd}>&- 2>/dev/null || true' EXIT

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

  # Lock freigeben (FD schliessen gibt den flock frei)
  exec {_wg_lock_fd}>&- 2>/dev/null || true
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
  if ! common_is_yes "$CONFIRM"; then
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
    echo "  -> Starten mit: systemctl restart wg-quick@$WG_IFACE"
    exit 1
  fi

  if [ ! -d "$CLIENT_DIR" ]; then
    echo "Fehler: Client-Verzeichnis nicht gefunden: $CLIENT_DIR"
    echo "  -> Lege zuerst einen Client an (Menue 1 -> 1)."
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

  # Kein eval – nameref verhindert Code-Injektion aus der TSV-Statusdatei.
  declare -gA "$RX_MAP_NAME=()" 2>/dev/null || true
  declare -gA "$TX_MAP_NAME=()" 2>/dev/null || true
  declare -n _drx_ref="$RX_MAP_NAME"
  declare -n _dtx_ref="$TX_MAP_NAME"
  _drx_ref=()
  _dtx_ref=()
  [ -f "$FILE_PATH" ] || return

  while IFS=$'\t' read -r PUBLIC_KEY RX_BYTES TX_BYTES; do
    [ -z "$PUBLIC_KEY" ] && continue
    [[ "$RX_BYTES" =~ ^[0-9]+$ ]] || continue
    [[ "$TX_BYTES" =~ ^[0-9]+$ ]] || continue
    _drx_ref["$PUBLIC_KEY"]="$RX_BYTES"
    _dtx_ref["$PUBLIC_KEY"]="$TX_BYTES"
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
  # Laufzeit-Konfiguration (Endpoint, DNS-Presets, Pfade)
  _w2h_conf="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"
  [ -f "$_w2h_conf" ] && cp -a "$_w2h_conf" "$BACKUP_WORKDIR/etc/wireguard2home.conf"
  if [ -d "$CLIENT_DIR" ]; then
    mkdir -p "$BACKUP_WORKDIR/$(dirname "$CLIENT_ARCHIVE_PATH")"
    cp -a "$CLIENT_DIR" "$BACKUP_WORKDIR/$(dirname "$CLIENT_ARCHIVE_PATH")/"
  fi
  [ -d "/opt/npm" ]         && cp -a /opt/npm         "$BACKUP_WORKDIR/opt/"
  [ -d "/opt/uptime-kuma" ] && cp -a /opt/uptime-kuma "$BACKUP_WORKDIR/opt/"
  [ -d "/opt/watchtower" ]  && cp -a /opt/watchtower  "$BACKUP_WORKDIR/opt/"
  [ -d "/opt/crowdsec" ]    && cp -a /opt/crowdsec    "$BACKUP_WORKDIR/opt/"
  [ -d "/etc/crowdsec" ]    && cp -a /etc/crowdsec    "$BACKUP_WORKDIR/etc/"
  [ -d "/etc/fail2ban" ]    && cp -a /etc/fail2ban    "$BACKUP_WORKDIR/etc/"
  [ -d "/etc/ufw" ]         && cp -a /etc/ufw         "$BACKUP_WORKDIR/etc/"

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

  # Sicherstellen dass RPI_KEEP_COUNT und RPI_KEEP_DAYS numerisch sind
  if ! [[ "${RPI_KEEP_COUNT:-}" =~ ^[0-9]+$ ]] || [ "${RPI_KEEP_COUNT:-0}" -lt 1 ]; then
    log "Warnung: RPI_KEEP_COUNT='${RPI_KEEP_COUNT:-}' ist kein gueltiger Wert – benutze Standardwert 60."
    RPI_KEEP_COUNT=60
  fi
  if ! [[ "${RPI_KEEP_DAYS:-}" =~ ^[0-9]+$ ]] || [ "${RPI_KEEP_DAYS:-0}" -lt 1 ]; then
    log "Warnung: RPI_KEEP_DAYS='${RPI_KEEP_DAYS:-}' ist kein gueltiger Wert – benutze Standardwert 30."
    RPI_KEEP_DAYS=30
  fi

  echo ""
  echo "Bereinige Raspberry-Backups..."
  local _keep_count="$RPI_KEEP_COUNT"
  local _keep_days="$RPI_KEEP_DAYS"
  ssh -i "$SSH_KEY" "$RPI_USER@$RPI_HOST" "
mkdir -p '$RPI_TARGET'
find '$RPI_TARGET' -type f -name 'gate2home-backup-*.tar.gz' -mtime +${_keep_days} -delete
find '$RPI_TARGET' -maxdepth 1 -type f -name 'gate2home-backup-*.tar.gz' -printf '%T@ %p\n' | sort -rn | awk 'NR > ${_keep_count} { \$1=\"\"; sub(/^ /, \"\"); print }' | while IFS= read -r old_file; do
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

  echo "Pruefe Archiv-Integritaet..."
  if ! tar -tzf "$RESTORE_BACKUP_FILE" >/dev/null 2>&1; then
    echo "Fehler: Backup-Archiv ist beschaedigt oder unvollstaendig: $RESTORE_BACKUP_FILE"
    echo "Kein Restore durchgefuehrt – bestehende Daten sind unveraendert."
    exit 1
  fi

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

  local _w2h_conf="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"

  restore_backup_existing_path "/etc/wireguard"  "$PRE_RESTORE_BASE/etc/wireguard"
  restore_backup_existing_path "$CLIENT_DIR"      "$PRE_RESTORE_BASE/$CLIENT_ARCHIVE_PATH"
  restore_backup_existing_path "/opt/npm"         "$PRE_RESTORE_BASE/opt/npm"
  restore_backup_existing_path "/opt/uptime-kuma" "$PRE_RESTORE_BASE/opt/uptime-kuma"
  restore_backup_existing_path "/opt/watchtower"  "$PRE_RESTORE_BASE/opt/watchtower"
  restore_backup_existing_path "/opt/crowdsec"    "$PRE_RESTORE_BASE/opt/crowdsec"
  restore_backup_existing_path "/etc/crowdsec"    "$PRE_RESTORE_BASE/etc/crowdsec"
  restore_backup_existing_path "/etc/fail2ban"    "$PRE_RESTORE_BASE/etc/fail2ban"
  restore_backup_existing_path "/etc/ufw"         "$PRE_RESTORE_BASE/etc/ufw"
  restore_backup_existing_path "$_w2h_conf"       "$PRE_RESTORE_BASE/etc/wireguard2home.conf"

  restore_directory_contents "$RESTORE_WORKDIR/etc/wireguard"     "/etc/wireguard"
  restore_directory_contents "$RESTORE_WORKDIR/$CLIENT_ARCHIVE_PATH" "$CLIENT_DIR"
  restore_directory_contents "$RESTORE_WORKDIR/opt/npm"           "/opt/npm"
  restore_directory_contents "$RESTORE_WORKDIR/opt/uptime-kuma"   "/opt/uptime-kuma"
  restore_directory_contents "$RESTORE_WORKDIR/opt/watchtower"    "/opt/watchtower"
  restore_directory_contents "$RESTORE_WORKDIR/opt/crowdsec"      "/opt/crowdsec"
  restore_directory_contents "$RESTORE_WORKDIR/etc/crowdsec"      "/etc/crowdsec"
  restore_directory_contents "$RESTORE_WORKDIR/etc/fail2ban"      "/etc/fail2ban"
  restore_directory_contents "$RESTORE_WORKDIR/etc/ufw"           "/etc/ufw"

  # wireguard2home.conf restaurieren
  if [ -f "$RESTORE_WORKDIR/etc/wireguard2home.conf" ]; then
    if [ "$RESTORE_DRY_RUN" -eq 0 ]; then
      cp -a "$RESTORE_WORKDIR/etc/wireguard2home.conf" "$_w2h_conf"
      chmod 600 "$_w2h_conf"
      echo "Laufzeit-Konfiguration wiederhergestellt: ${_w2h_conf}"
    fi
  fi

  if [ "$RESTORE_DRY_RUN" -eq 0 ]; then
    if [ -f /etc/wireguard/wg0.conf ]; then
      chmod 600 /etc/wireguard/wg0.conf
      systemctl restart wg-quick@wg0
    fi
    if [ -d "$CLIENT_DIR" ]; then
      find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" -exec chmod 600 {} \;
    fi
    # Docker-Netzwerk und Stacks starten
    if command -v docker >/dev/null 2>&1; then
      docker network inspect gate2home_proxy >/dev/null 2>&1 || docker network create gate2home_proxy
      for _stack in /opt/npm /opt/uptime-kuma /opt/watchtower /opt/crowdsec; do
        if [ -f "${_stack}/docker-compose.yml" ]; then
          ( cd "$_stack" && docker compose up -d ) \
            || echo "Hinweis: Stack ${_stack} konnte nicht gestartet werden."
        fi
      done
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
  if ! common_is_yes "$CONFIRM"; then
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
    ""|1)
      echo ""
      echo "WARNUNG: Ein echter Restore ueberschreibt die aktuelle Konfiguration:"
      echo "  - /etc/wireguard (Keys + wg0.conf)"
      echo "  - Client-Verzeichnis, Docker-Stacks (bei Full-Restore)"
      echo "  - WireGuard wird anschliessend neu gestartet (Tunnel kurz unterbrochen)"
      echo ""
      echo "Der aktuelle Zustand wird vorher automatisch gesichert."
      echo ""
      if ! read -p "Restore wirklich durchfuehren? [ja/NEIN]: " _rconfirm; then
        echo ""; return
      fi
      if ! common_is_yes "$_rconfirm"; then
        echo "Abgebrochen."
        return
      fi
      restore_execute 0
      ;;
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
    echo "  Verwalten"
    echo "    1) Client Manager"
    echo "    2) Status Dashboard (Snapshot)"
    echo "    3) Status Dashboard (Live)"
    echo ""
    echo "  Wartung"
    echo "    4) Backup erstellen"
    echo "    5) Restore starten"
    echo "    6) Speedtests"
    echo ""
    echo "    7) Hilfe"
    echo "    8) Beenden"
    echo ""

    if ! read -p "Auswahl [1]: " CHOICE; then
      echo ""
      echo "Beendet."
      exit 0
    fi

    case "${CHOICE:-1}" in
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

validate_endpoint() {
  # Platzhalter-Endpoint erkennen und korrigieren bevor Clients erstellt werden.
  # ENDPOINT wird in dieser Shell-Instanz aktualisiert UND dauerhaft in die Config geschrieben.
  [ "${ENDPOINT%%:*}" = "vpn.example.com" ] || return 0

  local _cfg="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"
  echo ""
  echo "⚠️  Der WireGuard-Endpoint ist noch auf den Platzhalter gesetzt:"
  echo "   ${ENDPOINT}"
  echo "   Client-Configs wuerden mit dieser falschen Adresse erstellt."
  echo ""
  echo "Bitte die oeffentliche IP oder den Hostnamen des VPS eingeben."
  echo "(Nur auf dem VPS ausfuehren — nicht vom Gateway-Host aus!)"
  echo ""
  read -r -p "VPS-Endpoint HOST:PORT (z. B. 1.2.3.4:51820): " _ep
  if [ -z "$_ep" ] || [ "${_ep%%:*}" = "vpn.example.com" ]; then
    echo "Fehler: Kein gueltiger Endpoint angegeben."
    echo "Manuell setzen: WIREGUARD2HOME_ENDPOINT=DEINE_VPS_IP:51820 in ${_cfg}"
    exit 1
  fi
  # Port-Suffix ergaenzen falls nicht angegeben
  [[ "$_ep" != *:* ]] && _ep="${_ep}:51820"
  # In Config schreiben
  if grep -q '^WIREGUARD2HOME_ENDPOINT=' "$_cfg" 2>/dev/null; then
    sed -i "s|^WIREGUARD2HOME_ENDPOINT=.*|WIREGUARD2HOME_ENDPOINT=$(printf '%q' "$_ep")|" "$_cfg"
  else
    printf 'WIREGUARD2HOME_ENDPOINT=%q\n' "$_ep" >> "$_cfg"
  fi
  # Sofort in dieser Instanz wirksam
  ENDPOINT="$_ep"
  echo "Endpoint auf ${ENDPOINT} gesetzt."
  echo ""
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --backup-only)
        common_require_root
        backup_execute
        exit 0
        ;;
      --help|-h)
        echo "Wireguard2Home v${W2H_VERSION}"
        echo ""
        echo "Optionen:"
        echo "  --backup-only   Backup sofort ausfuehren (nicht-interaktiv, fuer Cron)"
        echo "  --help          Diese Hilfe anzeigen"
        exit 0
        ;;
      *)
        echo "Unbekannte Option: $1"
        exit 1
        ;;
    esac
  done
}

parse_args "$@"
common_require_root
validate_endpoint
main_menu
