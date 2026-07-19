#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/tune.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

# Suggests InnoDB/Galera tuning values from host resources and (if reachable)
# live DB metrics. Prints recommendations; --apply writes them to .env and
# rolls the change out (rolling restart in cluster mode).
#
# Budget model: in cluster mode all 3 nodes share the host, so the buffer
# pool is sized as (usable RAM / 3) * 0.65 per node.

APPLY=false
RAM_BUDGET_GB=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --apply)     APPLY=true; shift ;;
    --ram)       RAM_BUDGET_GB="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [--ram GB] [--apply]"
      echo ""
      echo "  --ram GB   RAM (GB) dedicated to the database (default: auto-detected total)"
      echo "  --apply    Write the recommendations to .env and roll them out"
      echo "  --help     Show this help message"
      exit 0
      ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

is_cluster() { [[ -d "./cluster_data" ]]; }

# --- Gather host facts -----------------------------------------------------
CPU_CORES=$(nproc 2>/dev/null || echo 2)
TOTAL_RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
[[ -z "$TOTAL_RAM_GB" || "$TOTAL_RAM_GB" -lt 1 ]] && TOTAL_RAM_GB=2
[[ -z "$RAM_BUDGET_GB" ]] && RAM_BUDGET_GB="$TOTAL_RAM_GB"

# Node count for the budget split
if is_cluster; then NODES=3; else NODES=1; fi

# Rotational disk detection for io_capacity (best effort)
detect_io_capacity() {
  local dev rota
  dev=$(df --output=source . 2>/dev/null | tail -1 | sed 's|/dev/||; s|[0-9]*$||')
  rota=$(cat "/sys/block/${dev}/queue/rotational" 2>/dev/null)
  case "$rota" in
    0) echo 1000 ;;   # SSD (SATA baseline; NVMe users can raise to 2500)
    1) echo 200 ;;    # HDD
    *) echo 1000 ;;   # unknown -> assume SSD
  esac
}

# --- Compute recommendations ----------------------------------------------
# Per-node buffer pool: 65% of the per-node RAM slice, capped for sanity
POOL_GB=$(( RAM_BUDGET_GB * 65 / 100 / NODES ))
(( POOL_GB < 1 )) && POOL_GB=1
REC_BUFFER_POOL="${POOL_GB}G"

# Log file ~25% of buffer pool, clamped to [128M, 2G]
LOG_MB=$(( POOL_GB * 1024 / 4 ))
(( LOG_MB < 128 )) && LOG_MB=128
(( LOG_MB > 2048 )) && LOG_MB=2048
REC_LOG_FILE="${LOG_MB}M"

REC_IO_CAPACITY=$(detect_io_capacity)
REC_GCACHE="512M"
REC_TMP_TABLE="128M"

# max_connections: leave the .env value if already set, else a sane default
REC_MAX_CONN="${DB_MAX_CONNECTIONS:-300}"

# --- Live metrics (advisory) ----------------------------------------------
live_metrics() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MARIADB_CONTAINER" || return 1

  local reads read_requests hit_rate tmp_disk tmp_all
  read_requests=$(db_metric "Innodb_buffer_pool_read_requests")
  reads=$(db_metric "Innodb_buffer_pool_reads")
  tmp_disk=$(db_metric "Created_tmp_disk_tables")
  tmp_all=$(db_metric "Created_tmp_tables")

  echo ""
  log_info "=== Live metrics (advisory) ==="
  if [[ "$read_requests" =~ ^[0-9]+$ && "$read_requests" -gt 0 ]]; then
    hit_rate=$(awk "BEGIN{printf \"%.2f\", (1 - $reads/$read_requests) * 100}")
    log_info "InnoDB buffer pool hit rate: ${hit_rate}% (>=99.9% is healthy; lower -> more RAM helps)"
  fi
  if [[ "$tmp_all" =~ ^[0-9]+$ && "$tmp_all" -gt 0 ]]; then
    local pct=$(( tmp_disk * 100 / tmp_all ))
    log_info "Temp tables spilled to disk: ${pct}% (${tmp_disk}/${tmp_all}; high -> raise tmp_table_size)"
  fi
}

db_metric() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" \
    mariadb -u root -N -e "SHOW GLOBAL STATUS LIKE '$1';" 2>/dev/null | awk '{print $2}'
}

# --- Report ----------------------------------------------------------------
echo ""
log_info "=== Host ==="
log_info "CPU cores: $CPU_CORES | Total RAM: ${TOTAL_RAM_GB}G | DB budget: ${RAM_BUDGET_GB}G | Nodes: $NODES"

echo ""
log_info "=== Recommended tuning (per node, conservative) ==="
[[ -n "$DB_BUFFER_POOL_SIZE" ]] && log_info "(current .env DB_BUFFER_POOL_SIZE = $DB_BUFFER_POOL_SIZE)"
log_info "DB_BUFFER_POOL_SIZE = $REC_BUFFER_POOL   (x$NODES = $(( POOL_GB * NODES ))G of the ${RAM_BUDGET_GB}G budget; you can push higher on a dedicated host)"
log_info "DB_LOG_FILE_SIZE    = $REC_LOG_FILE"
log_info "DB_IO_CAPACITY      = $REC_IO_CAPACITY   ($([ "$REC_IO_CAPACITY" = 200 ] && echo HDD || echo SSD) detected - NVMe? raise to 2500)"
log_info "DB_MAX_CONNECTIONS  = $REC_MAX_CONN"
log_info "DB_TMP_TABLE_SIZE   = $REC_TMP_TABLE"
log_info "GALERA_GCACHE_SIZE  = $REC_GCACHE"

live_metrics || log_info "(DB not reachable - skipping live metrics)"

if [[ "$APPLY" != "true" ]]; then
  echo ""
  log_info "Review the values above, then apply with: ./tune.sh --apply"
  log_info "(or set them manually in .env)"
  exit 0
fi

# --- Apply -----------------------------------------------------------------
set_env_value() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

echo ""
log_warning "This writes the values to .env and restarts the database to apply them."
if [[ -t 0 ]]; then
  read -p "Continue? (type 'yes' to confirm): " confirm
  [[ "$confirm" == "yes" ]] || { log_info "Cancelled"; exit 0; }
fi

set_env_value DB_BUFFER_POOL_SIZE "$REC_BUFFER_POOL"
set_env_value DB_LOG_FILE_SIZE "$REC_LOG_FILE"
set_env_value DB_IO_CAPACITY "$REC_IO_CAPACITY"
set_env_value DB_MAX_CONNECTIONS "$REC_MAX_CONN"
set_env_value DB_TMP_TABLE_SIZE "$REC_TMP_TABLE"
set_env_value GALERA_GCACHE_SIZE "$REC_GCACHE"
log_success "Tuning written to .env"

if is_cluster; then
  log_info "Rolling restart to apply (one node at a time)..."
  touch ./logs/.heal_paused
  trap 'rm -f ./logs/.heal_paused' EXIT
  for node in "${CLUSTER_NODES[@]}"; do
    container=$(node_container "$node")
    log_info "--- $container ---"
    compose_cluster up -d --no-deps --force-recreate "$node" >/dev/null 2>&1
    wait_node_synced "$node" || { log_error "$container did not resync - aborting rollout"; exit 1; }
  done
  rm -f ./logs/.heal_paused
  log_success "All nodes restarted with new tuning"
else
  log_info "Restarting the container to apply..."
  docker compose up -d --force-recreate >/dev/null 2>&1
  log_success "Restarted with new tuning"
fi
