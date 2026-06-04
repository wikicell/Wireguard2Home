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

# Laufzeit-Konfiguration (Endpoint, DNS-Presets, Pfade, Service-User)
_conf_file="${WIREGUARD2HOME_CONFIG_FILE:-/etc/wireguard2home.conf}"
if [ -f "$_conf_file" ]; then
  cp -a "$_conf_file" "$BACKUP_WORKDIR/etc/wireguard2home.conf"
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

# Uptime Kuma (Datenbank mit Monitoren, Incidents und Zugangsdaten)
if [ -d "/opt/uptime-kuma" ]; then
  cp -a /opt/uptime-kuma "$BACKUP_WORKDIR/opt/"
fi

# CrowdSec Docker-Stack (/opt/crowdsec) und Host-Konfiguration (/etc/crowdsec)
if [ -d "/opt/crowdsec" ]; then
  cp -a /opt/crowdsec "$BACKUP_WORKDIR/opt/"
fi
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
