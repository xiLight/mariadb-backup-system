#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/heal.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

# Self-healing for the Galera cluster:
#   - restarts stopped node containers
#   - restarts nodes that are stuck (not responding / non-Primary) after
#     3 consecutive failed checks
#   - recovers a completely dead cluster by bootstrapping from the node
#     with the newest data (grastate.dat seqno / safe_to_bootstrap)
#   - restarts HAProxy if it is down
#
# Run once (e.g. via cron every minute) or as a daemon with --daemon.

HEAL_INTERVAL="${HEAL_INTERVAL:-30}"
STRIKE_LIMIT=3
STRIKE_DIR="./logs/.heal_strikes"
DAEMON_MODE=false
RECOVER_ONLY=false

case "$1" in
  --daemon)
    DAEMON_MODE=true
    ;;
  --recover)
    RECOVER_ONLY=true
    ;;
  --help)
    echo "Usage: $0 [--daemon|--recover]"
    echo ""
    echo "  (no option)  Run one healing check (suitable for cron)"
    echo "  --daemon     Run continuously, checking every ${HEAL_INTERVAL}s (HEAL_INTERVAL)"
    echo "  --recover    Force full-cluster recovery (bootstrap from newest node)"
    echo ""
    echo "Cron example (check every minute):"
    echo "  * * * * * cd $(pwd) && ./heal.sh >/dev/null 2>&1"
    exit 0
    ;;
esac

mkdir -p "$STRIKE_DIR"

get_strikes() {
  cat "$STRIKE_DIR/$1" 2>/dev/null || echo 0
}

add_strike() {
  local strikes
  strikes=$(( $(get_strikes "$1") + 1 ))
  echo "$strikes" > "$STRIKE_DIR/$1"
  echo "$strikes"
}

clear_strikes() {
  rm -f "$STRIKE_DIR/$1"
}

# Pick the node with the newest data for bootstrapping:
# prefer safe_to_bootstrap:1, otherwise the highest seqno in grastate.dat.
pick_bootstrap_node() {
  local best_node="" best_seqno=-2 node datadir seqno stb

  for node in "${CLUSTER_NODES[@]}"; do
    datadir=$(node_datadir "$node")
    [[ -f "$datadir/grastate.dat" ]] || continue

    stb=$(awk '/^safe_to_bootstrap:/ {print $2}' "$datadir/grastate.dat")
    seqno=$(awk '/^seqno:/ {print $2}' "$datadir/grastate.dat")

    if [[ "$stb" == "1" ]]; then
      echo "$node"
      return 0
    fi

    if [[ "$seqno" =~ ^-?[0-9]+$ ]] && (( seqno > best_seqno )); then
      best_seqno=$seqno
      best_node=$node
    fi
  done

  if [[ -n "$best_node" ]]; then
    echo "$best_node"
  else
    echo "node1"
  fi
}

full_cluster_recovery() {
  log_warning "=== FULL CLUSTER RECOVERY ==="

  compose_cluster stop node1 node2 node3 2>/dev/null

  local bootstrap_node
  bootstrap_node=$(pick_bootstrap_node)
  log_info "Bootstrapping from $(node_container "$bootstrap_node") (newest data)"

  touch "$(node_datadir "$bootstrap_node")/force_bootstrap"
  compose_cluster up -d "$bootstrap_node" || {
    log_error "Failed to create/start $(node_container "$bootstrap_node") - see the docker error above"
    return 1
  }

  if ! wait_node_synced "$bootstrap_node"; then
    log_error "Bootstrap node $(node_container "$bootstrap_node") failed to start - manual intervention required"
    log_error "Check: docker logs $(node_container "$bootstrap_node")"
    return 1
  fi

  log_info "Rejoining remaining nodes..."
  local node
  for node in "${CLUSTER_NODES[@]}"; do
    [[ "$node" == "$bootstrap_node" ]] && continue
    compose_cluster up -d "$node"
  done

  for node in "${CLUSTER_NODES[@]}"; do
    [[ "$node" == "$bootstrap_node" ]] && continue
    wait_node_synced "$node" || log_warning "$node did not rejoin yet - will retry on next heal run"
  done

  compose_cluster up -d haproxy
  log_success "=== Cluster recovery completed ==="
}

heal_once() {
  # Never initialized -> nothing to heal
  if [[ ! -d "./cluster_data" ]]; then
    log_info "No cluster data found - nothing to heal (run ./cluster.sh init first)"
    return 0
  fi

  local running=0 node
  for node in "${CLUSTER_NODES[@]}"; do
    node_running "$node" && running=$((running + 1))
  done

  # Whole cluster down: containers won't self-start into a valid cluster
  # (a bootstrap node is required), so do a coordinated recovery.
  if [[ "$running" -eq 0 ]]; then
    log_warning "All cluster nodes are down"
    full_cluster_recovery
    return $?
  fi

  # Heal individual nodes
  for node in "${CLUSTER_NODES[@]}"; do
    local container
    container=$(node_container "$node")

    if ! node_running "$node"; then
      log_warning "$container is not running - starting it"
      compose_cluster up -d "$node"
      clear_strikes "$node"
      continue
    fi

    if node_is_synced "$node"; then
      clear_strikes "$node"
      continue
    fi

    # Node is running but not synced: could be joining (SST) or stuck.
    # Only restart after several consecutive failed checks.
    local state strikes
    state=$(node_wsrep "$node" wsrep_local_state_comment)

    if [[ "$state" == "Donor/Desynced" || "$state" == "Joining"* || "$state" == "Joined" ]]; then
      log_info "$container is in transient state '$state' - leaving it alone"
      clear_strikes "$node"
      continue
    fi

    strikes=$(add_strike "$node")
    log_warning "$container is unhealthy (state: ${state:-not responding}, strike $strikes/$STRIKE_LIMIT) - diagnose with: docker logs --tail 30 $container"

    if (( strikes >= STRIKE_LIMIT )); then
      log_warning "Restarting $container after $STRIKE_LIMIT failed checks"
      docker restart "$container" >/dev/null 2>&1 || compose_cluster up -d "$node"
      clear_strikes "$node"
    fi
  done

  # Heal HAProxy
  if ! container_running "$(node_container haproxy)"; then
    log_warning "HAProxy is not running - starting it"
    compose_cluster up -d haproxy
  fi

  local healthy
  healthy=$(cluster_healthy_count)
  if [[ "$healthy" -eq 3 ]]; then
    log_info "Heal check OK: 3/3 nodes synced"
  else
    log_warning "Heal check: $healthy/3 nodes synced"
  fi
}

if [[ "$RECOVER_ONLY" == "true" ]]; then
  full_cluster_recovery
  exit $?
fi

if [[ "$DAEMON_MODE" == "true" ]]; then
  log_info "Starting heal daemon (interval: ${HEAL_INTERVAL}s) - stop with Ctrl+C"
  while true; do
    heal_once
    sleep "$HEAL_INTERVAL"
  done
else
  heal_once
fi
