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

  echo "Pruefe Archiv-Integritaet..."
  if ! tar -tzf "$BACKUP_FILE" > /dev/null 2>&1; then
    echo "Fehler: Backup-Archiv ist beschaedigt oder unvollstaendig: $BACKUP_FILE"
    echo "Kein Restore durchgefuehrt – bestehende Daten sind unveraendert."
    exit 1
  fi

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

restore_docker_stacks() {
  # Docker-Netzwerk anlegen falls nicht vorhanden
  if command -v docker >/dev/null 2>&1; then
    if ! docker network inspect gate2home_proxy >/dev/null 2>&1; then
      echo "Lege Docker-Netzwerk gate2home_proxy an..."
      log_run docker network create gate2home_proxy
    fi
    # Alle vorhandenen Stacks starten
    local stack
    for stack in /opt/npm /opt/uptime-kuma /opt/watchtower /opt/crowdsec; do
      if [ -f "${stack}/docker-compose.yml" ]; then
        echo "Starte Docker-Stack: ${stack} ..."
        if [ "$DRY_RUN" -eq 0 ]; then
          ( cd "$stack" && docker compose up -d ) \
            || echo "Hinweis: Stack ${stack} konnte nicht gestartet werden – bitte manuell pruefen."
        else
          echo "  [dry-run] cd ${stack} && docker compose up -d"
        fi
      fi
    done
  else
    echo "Hinweis: Docker nicht gefunden – Stacks muessen nach der Paketinstallation"
    echo "manuell gestartet werden: cd /opt/<stack> && docker compose up -d"
  fi
}

restore_full() {
  echo ""
  echo "Wiederherstellung: Full Restore"

  local _conf_file="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"

  # Sicherung des Ist-Zustands
  backup_existing_path "/etc/wireguard"  "$PRE_RESTORE_BASE/etc/wireguard"
  backup_existing_path "$CLIENT_DIR"     "$PRE_RESTORE_BASE/$CLIENT_ARCHIVE_PATH"
  backup_existing_path "/opt/npm"        "$PRE_RESTORE_BASE/opt/npm"
  backup_existing_path "/opt/uptime-kuma" "$PRE_RESTORE_BASE/opt/uptime-kuma"
  backup_existing_path "/opt/watchtower" "$PRE_RESTORE_BASE/opt/watchtower"
  backup_existing_path "/opt/crowdsec"   "$PRE_RESTORE_BASE/opt/crowdsec"
  backup_existing_path "/etc/crowdsec"   "$PRE_RESTORE_BASE/etc/crowdsec"
  backup_existing_path "/etc/fail2ban"   "$PRE_RESTORE_BASE/etc/fail2ban"
  backup_existing_path "/etc/ufw"        "$PRE_RESTORE_BASE/etc/ufw"
  backup_existing_path "$_conf_file"     "$PRE_RESTORE_BASE/etc/wireguard2home.conf"

  # Restore
  restore_directory_contents "$RESTORE_WORKDIR/etc/wireguard"     "/etc/wireguard"
  restore_directory_contents "$RESTORE_WORKDIR/$CLIENT_ARCHIVE_PATH" "$CLIENT_DIR"
  restore_directory_contents "$RESTORE_WORKDIR/opt/npm"           "/opt/npm"
  restore_directory_contents "$RESTORE_WORKDIR/opt/uptime-kuma"   "/opt/uptime-kuma"
  restore_directory_contents "$RESTORE_WORKDIR/opt/watchtower"    "/opt/watchtower"
  restore_directory_contents "$RESTORE_WORKDIR/opt/crowdsec"      "/opt/crowdsec"
  restore_directory_contents "$RESTORE_WORKDIR/etc/crowdsec"      "/etc/crowdsec"
  restore_directory_contents "$RESTORE_WORKDIR/etc/fail2ban"      "/etc/fail2ban"
  restore_directory_contents "$RESTORE_WORKDIR/etc/ufw"           "/etc/ufw"

  # wireguard2home.conf restaurieren (Endpoint, DNS, Pfade)
  if [ -f "$RESTORE_WORKDIR/etc/wireguard2home.conf" ]; then
    log_run cp -a "$RESTORE_WORKDIR/etc/wireguard2home.conf" "$_conf_file"
    log_run chmod 600 "$_conf_file"
    echo "Laufzeit-Konfiguration wiederhergestellt: ${_conf_file}"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -f /etc/wireguard/wg0.conf ]; then
      chmod 600 /etc/wireguard/wg0.conf
      systemctl restart wg-quick@wg0
    fi
    if [ -d "$CLIENT_DIR" ]; then
      find "$CLIENT_DIR" -maxdepth 1 -type f -name "*.conf" -exec chmod 600 {} \;
    fi
  fi

  # Docker-Netzwerk anlegen und Stacks starten
  restore_docker_stacks
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
