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

reload_wg_live() {
  # Wendet die neue wg0.conf live an ohne bestehende Tunnel zu unterbrechen.
  # wg syncconf erfordert wg-quick strip (entfernt PostUp/PostDown), da
  # syncconf nur [Interface]/[Peer]-Direktiven akzeptiert.
  if command -v wg-quick >/dev/null 2>&1 && wg show "$WG_IFACE" >/dev/null 2>&1; then
    if wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE" 2>/dev/null) 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback: vollstaendiger Neustart (unterbricht aktive Sessions)
  log "wg syncconf nicht moeglich – falle zurueck auf systemctl restart."
  systemctl restart "wg-quick@$WG_IFACE"
}

restart_wg_with_rollback() {
  BACKUP_FILE="$1"
  CLIENT_CONF_TO_DELETE="${2:-}"
  CLIENT_QR_TO_DELETE="${3:-}"

  if reload_wg_live; then
    return 0
  fi

  echo ""
  echo "Fehler: WireGuard-Reload fehlgeschlagen."
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

  # Exklusives Lock waehrend der gesamten Client-Erstellung verhindern,
  # dass zwei gleichzeitige Aufrufe dieselbe IP vergeben.
  local _lock_fd _lock_file="${WG_DIR}/.wg-client-create.lock"
  exec {_lock_fd}>"$_lock_file"
  if ! flock -n "$_lock_fd" 2>/dev/null; then
    echo "Fehler: Ein anderer Client-Erstellungsprozess laeuft gerade. Bitte warten."
    exit 1
  fi
  trap 'flock -u "$_lock_fd"; exec {_lock_fd}>&-' EXIT

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
