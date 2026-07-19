#!/bin/bash
cd "$(dirname "$0")"

source "./lib/logging.sh"

LOG_FILE="./logs/notify.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

# Sends a message to every configured channel (ntfy, Discord, Telegram).
# Used by backup.sh / heal.sh / offsite_sync.sh / restore_test.sh on
# failures and important events - never breaks the caller (best effort).
#
# Usage:
#   ./notify.sh LEVEL TITLE MESSAGE...   LEVEL: info|warning|error|success
#   ./notify.sh --heartbeat              ping HEARTBEAT_URL (e.g. Uptime-Kuma)
#   ./notify.sh --test                   send a test message to all channels

HOSTNAME_TAG=$(hostname 2>/dev/null || echo "mariadb-backup")

send_ntfy() {
  local level="$1" title="$2" message="$3" prio="default"
  case "$level" in
    error)   prio="urgent" ;;
    warning) prio="high" ;;
    success) prio="low" ;;
  esac
  curl -fsS --max-time 10 \
    -H "Title: [$HOSTNAME_TAG] $title" \
    -H "Priority: $prio" \
    -d "$message" \
    "$NOTIFY_NTFY_URL" >/dev/null 2>&1
}

send_discord() {
  local level="$1" title="$2" message="$3" color=3447003
  case "$level" in
    error)   color=15548997 ;;
    warning) color=16776960 ;;
    success) color=5763719 ;;
  esac
  local payload
  payload=$(printf '{"embeds":[{"title":"[%s] %s","description":"%s","color":%d}]}' \
    "$HOSTNAME_TAG" "$title" "$message" "$color")
  curl -fsS --max-time 10 -H "Content-Type: application/json" \
    -d "$payload" "$NOTIFY_DISCORD_WEBHOOK" >/dev/null 2>&1
}

send_telegram() {
  local title="$2" message="$3"
  curl -fsS --max-time 10 \
    --data-urlencode "chat_id=$NOTIFY_TELEGRAM_CHAT_ID" \
    --data-urlencode "text=[$HOSTNAME_TAG] $title
$message" \
    "https://api.telegram.org/bot${NOTIFY_TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

send_all() {
  local level="$1" title="$2" message="$3" sent=0

  command -v curl >/dev/null 2>&1 || { log_warning "curl not installed - cannot send notifications"; return 1; }

  if [[ -n "$NOTIFY_NTFY_URL" ]]; then
    send_ntfy "$level" "$title" "$message" && sent=$((sent + 1)) || log_warning "ntfy notification failed"
  fi
  if [[ -n "$NOTIFY_DISCORD_WEBHOOK" ]]; then
    send_discord "$level" "$title" "$message" && sent=$((sent + 1)) || log_warning "Discord notification failed"
  fi
  if [[ -n "$NOTIFY_TELEGRAM_BOT_TOKEN" && -n "$NOTIFY_TELEGRAM_CHAT_ID" ]]; then
    send_telegram "$level" "$title" "$message" && sent=$((sent + 1)) || log_warning "Telegram notification failed"
  fi

  if [[ $sent -gt 0 ]]; then
    log_info "Notification sent to $sent channel(s): [$level] $title"
  fi
  return 0
}

case "$1" in
  --heartbeat)
    if [[ -n "$HEARTBEAT_URL" ]]; then
      if curl -fsS --max-time 10 "$HEARTBEAT_URL" >/dev/null 2>&1; then
        log_info "Heartbeat ping sent"
      else
        log_warning "Heartbeat ping failed"
      fi
    fi
    exit 0
    ;;
  --test)
    send_all info "Test notification" "If you can read this, notifications are working."
    exit 0
    ;;
  --help|"")
    echo "Usage: $0 LEVEL TITLE MESSAGE...    (LEVEL: info|warning|error|success)"
    echo "       $0 --heartbeat              ping HEARTBEAT_URL"
    echo "       $0 --test                   send a test message"
    echo ""
    echo "Channels are configured in .env: NOTIFY_NTFY_URL, NOTIFY_DISCORD_WEBHOOK,"
    echo "NOTIFY_TELEGRAM_BOT_TOKEN + NOTIFY_TELEGRAM_CHAT_ID, HEARTBEAT_URL"
    exit 0
    ;;
  *)
    LEVEL="$1"
    TITLE="$2"
    shift 2
    send_all "$LEVEL" "$TITLE" "$*"
    ;;
esac
