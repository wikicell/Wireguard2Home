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
