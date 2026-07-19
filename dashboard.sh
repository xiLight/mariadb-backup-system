#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
INTERVAL=5
MODE="tui"
HTML_FILE="status.html"

while [[ $# -gt 0 ]]; do
  case $1 in
    --once)
      MODE="once"
      shift
      ;;
    --html)
      MODE="html"
      [[ -n "$2" && "$2" != --* ]] && { HTML_FILE="$2"; shift; }
      shift
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Live dashboard for the MariaDB backup system."
      echo ""
      echo "  (no option)      Live TUI, refreshes every ${INTERVAL}s (q or Ctrl+C to quit)"
      echo "  --once           Print the dashboard once and exit"
      echo "  --html [FILE]    Write an auto-refreshing HTML page (default: status.html)"
      echo "  --interval N     Refresh interval in seconds"
      echo ""
      echo "The HTML file is written locally and not served - open it directly"
      echo "or access it remotely via SSH tunnel to avoid exposing DB internals."
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

is_cluster() {
  [[ -d "./cluster_data" ]]
}

db_exec_dash() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" mariadb -u root -N -e "$1" 2>/dev/null
}

human_size() {
  local bytes=${1:-0}
  if (( bytes >= 1073741824 )); then
    echo "$(( bytes / 1073741824 )).$(( bytes % 1073741824 * 10 / 1073741824 )) GB"
  elif (( bytes >= 1048576 )); then
    echo "$(( bytes / 1048576 )) MB"
  elif (( bytes >= 1024 )); then
    echo "$(( bytes / 1024 )) KB"
  else
    echo "$bytes B"
  fi
}

file_age_text() {
  local mtime=$1 age
  age=$(( $(date +%s) - mtime ))
  if (( age >= 86400 )); then
    echo "$(( age / 86400 ))d ago"
  elif (( age >= 3600 )); then
    echo "$(( age / 3600 ))h ago"
  else
    echo "$(( age / 60 ))m ago"
  fi
}

# --- Data collection -------------------------------------------------------
# Fills COLLECT_* variables; every value degrades to "n/a" when unavailable.
collect_data() {
  COLLECT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  # Server basics
  COLLECT_DB_UP="no"
  COLLECT_VERSION="n/a"
  COLLECT_UPTIME="n/a"
  COLLECT_CONNECTIONS="n/a"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MARIADB_CONTAINER"; then
    local basics
    basics=$(db_exec_dash "SELECT VERSION(); SHOW STATUS LIKE 'Uptime'; SHOW STATUS LIKE 'Threads_connected';")
    if [[ -n "$basics" ]]; then
      COLLECT_DB_UP="yes"
      COLLECT_VERSION=$(sed -n '1p' <<< "$basics" | awk '{print $1}')
      local uptime_s
      uptime_s=$(sed -n '2p' <<< "$basics" | awk '{print $2}')
      [[ "$uptime_s" =~ ^[0-9]+$ ]] && COLLECT_UPTIME="$(( uptime_s / 86400 ))d $(( uptime_s % 86400 / 3600 ))h"
      COLLECT_CONNECTIONS=$(sed -n '3p' <<< "$basics" | awk '{print $2}')
    fi
  fi

  # Databases with sizes (name|size_mb per line)
  COLLECT_DATABASES=""
  if [[ "$COLLECT_DB_UP" == "yes" ]]; then
    COLLECT_DATABASES=$(db_exec_dash "
      SELECT table_schema, COALESCE(ROUND(SUM(data_length+index_length)/1048576,1),0)
      FROM information_schema.tables
      WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
      GROUP BY table_schema ORDER BY table_schema;" | awk '{print $1"|"$2}')
  fi

  # Cluster state (node|running|state|cluster|size per line)
  COLLECT_CLUSTER=""
  COLLECT_HAPROXY="n/a"
  if is_cluster; then
    local node state status size
    for node in "${CLUSTER_NODES[@]}"; do
      if node_running "$node"; then
        state=$(node_wsrep "$node" wsrep_local_state_comment)
        status=$(node_wsrep "$node" wsrep_cluster_status)
        size=$(cluster_size "$node")
        COLLECT_CLUSTER+="$(node_container "$node")|running|${state:-n/a}|${status:-n/a}|${size:-n/a}"$'\n'
      else
        COLLECT_CLUSTER+="$(node_container "$node")|stopped|-|-|-"$'\n'
      fi
    done
    container_running "$(node_container haproxy)" && COLLECT_HAPROXY="running" || COLLECT_HAPROXY="stopped"
  fi

  # Backups per database (db|count|latest_size|latest_age per line)
  COLLECT_BACKUPS=""
  COLLECT_BACKUP_TOTAL_SIZE=0
  COLLECT_BACKUP_COUNT=0
  local db latest count fsize mtime
  for db in $(ls "$BACKUP_DIR"/*_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort -u); do
    count=$(ls "$BACKUP_DIR/${db}"_*_*.sql.gz.enc 2>/dev/null | wc -l)
    latest=$(ls -1t "$BACKUP_DIR/${db}"_full_*.sql.gz.enc 2>/dev/null | head -1)
    fsize=$(stat -c%s "$latest" 2>/dev/null || stat -f%z "$latest" 2>/dev/null || echo 0)
    mtime=$(stat -c%Y "$latest" 2>/dev/null || stat -f%m "$latest" 2>/dev/null || echo 0)
    COLLECT_BACKUPS+="${db}|${count}|$(human_size "$fsize")|$(file_age_text "$mtime")"$'\n'
  done
  for f in "$BACKUP_DIR"/*.enc; do
    [[ -f "$f" ]] || continue
    COLLECT_BACKUP_COUNT=$((COLLECT_BACKUP_COUNT + 1))
    COLLECT_BACKUP_TOTAL_SIZE=$((COLLECT_BACKUP_TOTAL_SIZE + $(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)))
  done

  # Binlogs and disk
  COLLECT_BINLOG_COUNT=$(find "$BACKUP_DIR/binlogs" -name "mysql-bin.*" ! -name "*.index" 2>/dev/null | wc -l)
  COLLECT_DISK_FREE=$(df -Pk . 2>/dev/null | awk 'NR==2 {printf "%.1f GB", $4/1048576}')
  COLLECT_BACKUP_DIR_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

  # Recent activity
  COLLECT_LAST_BACKUP_LOG=$(tail -3 logs/backup.log 2>/dev/null)
  COLLECT_LAST_HEAL_LOG=$(tail -3 logs/heal.log 2>/dev/null)
}

# --- TUI rendering ---------------------------------------------------------
render_tui() {
  local out=""
  out+="${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
  out+="${BLUE}║        MariaDB Backup System - Dashboard   ($COLLECT_TIME)  ║${NC}\n"
  out+="${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}\n\n"

  if [[ "$COLLECT_DB_UP" == "yes" ]]; then
    out+="${GREEN}● Server:${NC} up  |  Version: $COLLECT_VERSION  |  Uptime: $COLLECT_UPTIME  |  Connections: $COLLECT_CONNECTIONS\n"
  else
    out+="${RED}● Server:${NC} DOWN ($MARIADB_CONTAINER not reachable)\n"
  fi
  out+="${CYAN}  Disk free:${NC} ${COLLECT_DISK_FREE:-n/a}  |  Backup dir: ${COLLECT_BACKUP_DIR_SIZE:-0} ($COLLECT_BACKUP_COUNT files)  |  Binlogs: $COLLECT_BINLOG_COUNT\n\n"

  if is_cluster; then
    out+="${WHITE}CLUSTER${NC}  (HAProxy: $COLLECT_HAPROXY)\n"
    out+="$(printf '  %-18s %-9s %-12s %-9s %-4s' CONTAINER STATUS STATE CLUSTER SIZE)\n"
    while IFS='|' read -r c r s cl sz; do
      [[ -z "$c" ]] && continue
      local color=$RED
      [[ "$s" == "Synced" ]] && color=$GREEN
      [[ "$r" == "running" && "$s" != "Synced" ]] && color=$YELLOW
      out+="$(printf "  ${color}%-18s %-9s %-12s %-9s %-4s${NC}" "$c" "$r" "$s" "$cl" "$sz")\n"
    done <<< "$COLLECT_CLUSTER"
    out+="\n"
  fi

  out+="${WHITE}DATABASES${NC}\n"
  if [[ -n "$COLLECT_DATABASES" ]]; then
    while IFS='|' read -r name size; do
      [[ -z "$name" ]] && continue
      out+="$(printf '  %-30s %10s MB' "$name" "$size")\n"
    done <<< "$COLLECT_DATABASES"
  else
    out+="  (server not reachable)\n"
  fi
  out+="\n${WHITE}BACKUPS${NC}\n"
  if [[ -n "$COLLECT_BACKUPS" ]]; then
    out+="$(printf '  %-24s %6s %12s %10s' DATABASE FILES LATEST AGE)\n"
    while IFS='|' read -r name count size age; do
      [[ -z "$name" ]] && continue
      local color=$GREEN
      [[ "$age" == *d* ]] && color=$YELLOW
      out+="$(printf "  ${color}%-24s %6s %12s %10s${NC}" "$name" "$count" "$size" "$age")\n"
    done <<< "$COLLECT_BACKUPS"
  else
    out+="  ${YELLOW}No backups found - run: ./backup.sh --full${NC}\n"
  fi

  if [[ -n "$COLLECT_LAST_BACKUP_LOG" ]]; then
    out+="\n${WHITE}LAST BACKUP ACTIVITY${NC}\n"
    out+=$(sed 's/^/  /' <<< "$COLLECT_LAST_BACKUP_LOG")"\n"
  fi
  if [[ -n "$COLLECT_LAST_HEAL_LOG" ]]; then
    out+="\n${WHITE}LAST HEAL ACTIVITY${NC}\n"
    out+=$(sed 's/^/  /' <<< "$COLLECT_LAST_HEAL_LOG")"\n"
  fi

  clear
  echo -e "$out"
  [[ "$MODE" == "tui" ]] && echo -e "${CYAN}Refresh: ${INTERVAL}s  |  q = quit${NC}"
}

# --- HTML rendering --------------------------------------------------------
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

render_html() {
  local cluster_rows="" db_rows="" backup_rows=""

  if is_cluster; then
    while IFS='|' read -r c r s cl sz; do
      [[ -z "$c" ]] && continue
      local cls="bad"
      [[ "$s" == "Synced" ]] && cls="ok"
      [[ "$r" == "running" && "$s" != "Synced" ]] && cls="warn"
      cluster_rows+="<tr class=\"$cls\"><td>$c</td><td>$r</td><td>$s</td><td>$cl</td><td>$sz</td></tr>"
    done <<< "$COLLECT_CLUSTER"
  fi

  while IFS='|' read -r name size; do
    [[ -z "$name" ]] && continue
    db_rows+="<tr><td>$(html_escape <<< "$name")</td><td>$size MB</td></tr>"
  done <<< "$COLLECT_DATABASES"

  while IFS='|' read -r name count size age; do
    [[ -z "$name" ]] && continue
    local cls="ok"
    [[ "$age" == *d* ]] && cls="warn"
    backup_rows+="<tr class=\"$cls\"><td>$(html_escape <<< "$name")</td><td>$count</td><td>$size</td><td>$age</td></tr>"
  done <<< "$COLLECT_BACKUPS"

  local server_badge="<span class=\"badge bad\">DOWN</span>"
  [[ "$COLLECT_DB_UP" == "yes" ]] && server_badge="<span class=\"badge ok\">UP</span>"

  cat > "$HTML_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="$INTERVAL">
<title>MariaDB Backup Dashboard</title>
<style>
  body { font-family: system-ui, sans-serif; background: #10151c; color: #dce3ea; margin: 2rem; }
  h1 { font-size: 1.3rem; } h2 { font-size: 1rem; margin-top: 1.6rem; color: #8ab4d8; }
  .meta { color: #7a8794; font-size: .85rem; }
  table { border-collapse: collapse; margin-top: .5rem; min-width: 420px; }
  th, td { padding: .35rem .8rem; text-align: left; border-bottom: 1px solid #26303b; font-size: .9rem; }
  th { color: #8ab4d8; font-weight: 600; }
  tr.ok td:first-child { border-left: 3px solid #3fb950; }
  tr.warn td:first-child { border-left: 3px solid #d29922; }
  tr.bad td:first-child { border-left: 3px solid #f85149; }
  .badge { padding: .15rem .6rem; border-radius: 4px; font-size: .8rem; font-weight: 700; }
  .badge.ok { background: #1c3524; color: #3fb950; } .badge.bad { background: #3a1d20; color: #f85149; }
  .cards { display: flex; gap: 1rem; flex-wrap: wrap; margin-top: 1rem; }
  .card { background: #161d26; border: 1px solid #26303b; border-radius: 8px; padding: .8rem 1.2rem; }
  .card b { display: block; font-size: 1.1rem; } .card span { color: #7a8794; font-size: .8rem; }
</style>
</head>
<body>
<h1>MariaDB Backup System $server_badge</h1>
<p class="meta">Generated: $COLLECT_TIME &middot; auto-refresh every ${INTERVAL}s &middot; container: $MARIADB_CONTAINER</p>
<div class="cards">
  <div class="card"><b>${COLLECT_VERSION}</b><span>Version</span></div>
  <div class="card"><b>${COLLECT_UPTIME}</b><span>Uptime</span></div>
  <div class="card"><b>${COLLECT_CONNECTIONS}</b><span>Connections</span></div>
  <div class="card"><b>${COLLECT_DISK_FREE:-n/a}</b><span>Disk free</span></div>
  <div class="card"><b>${COLLECT_BACKUP_DIR_SIZE:-0}</b><span>Backups ($COLLECT_BACKUP_COUNT files)</span></div>
  <div class="card"><b>${COLLECT_BINLOG_COUNT}</b><span>Binlogs</span></div>
</div>
$(if is_cluster; then
  echo "<h2>Cluster (HAProxy: $COLLECT_HAPROXY)</h2>"
  echo "<table><tr><th>Container</th><th>Status</th><th>State</th><th>Cluster</th><th>Size</th></tr>$cluster_rows</table>"
fi)
<h2>Databases</h2>
<table><tr><th>Database</th><th>Size</th></tr>${db_rows:-<tr><td colspan=2>server not reachable</td></tr>}</table>
<h2>Backups</h2>
<table><tr><th>Database</th><th>Files</th><th>Latest</th><th>Age</th></tr>${backup_rows:-<tr><td colspan=4>no backups yet</td></tr>}</table>
</body>
</html>
HTMLEOF
}

# --- Main ------------------------------------------------------------------
case "$MODE" in
  once)
    collect_data
    render_tui
    ;;
  html)
    collect_data
    render_html
    log_success "Dashboard written to $HTML_FILE (auto-refreshes every ${INTERVAL}s while regenerated)"
    log_info "Keep it current with: watch -n $INTERVAL ./dashboard.sh --html $HTML_FILE"
    ;;
  tui)
    trap 'clear; exit 0' INT TERM
    while true; do
      collect_data
      render_tui
      read -t "$INTERVAL" -n 1 key 2>/dev/null
      [[ "$key" == "q" ]] && { clear; exit 0; }
    done
    ;;
esac
