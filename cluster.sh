#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/cluster.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

usage() {
  echo "Usage: $0 COMMAND"
  echo ""
  echo "Galera cluster management:"
  echo "  init            First-time cluster setup (bootstraps node1, joins node2/3, starts HAProxy)"
  echo "  start           Start an already initialized cluster"
  echo "  stop            Stop the whole cluster (HAProxy first, then nodes)"
  echo "  status          Show cluster and replication status"
  echo "  reinit [--yes]  Tear down and rebuild the cluster from scratch:"
  echo "                  fetches a fresh subnet via Portolan, DELETES all cluster"
  echo "                  data, then runs a clean init"
  echo ""
  echo "Rolling updates: ./update.sh | Self-healing: ./heal.sh"
  exit 0
}

set_env_value() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

# Detect networks of other/old stacks that already occupy GALERA_SUBNET -
# docker would fail with "Pool overlaps with other one on this address space"
check_subnet_conflict() {
  local subnet="${GALERA_SUBNET:-172.28.66.0/24}"
  local own_net="${STACK_NAME}-cluster_galera"
  local net

  for net in $(docker network ls --format '{{.Name}}'); do
    [[ "$net" == "$own_net" ]] && continue
    if docker network inspect "$net" 2>/dev/null | grep -q "\"Subnet\": \"$subnet\""; then
      log_error "Network '$net' already uses subnet $subnet (your GALERA_SUBNET)."
      log_info "Usually a leftover from an old stack name. Fix with:"
      log_info "  docker network rm $net"
      log_info "or set a different GALERA_SUBNET in .env"
      return 1
    fi
  done
  return 0
}

cmd_init() {
  if [[ -f "./cluster_data/node1/grastate.dat" ]]; then
    log_error "Cluster already initialized (cluster_data/node1/grastate.dat exists)."
    log_info "Use './cluster.sh start' to start it, or './heal.sh' to recover a broken cluster."
    exit 1
  fi

  log_info "Initializing new 3-node Galera cluster..."

  check_subnet_conflict || exit 1

  mkdir -p cluster_data/node1 cluster_data/node2 cluster_data/node3
  touch cluster_data/node1/force_bootstrap

  log_info "Building cluster image..."
  compose_cluster build node1 || { log_error "Image build failed"; exit 1; }

  log_info "Bootstrapping node1..."
  compose_cluster up -d node1 || {
    log_error "Failed to create/start node1 - see the docker error above"
    exit 1
  }

  wait_node_synced node1 || {
    log_error "Bootstrap failed. Check: docker logs $(node_container node1)"
    exit 1
  }

  log_info "Joining node2 and node3 (initial state transfer may take a while)..."
  compose_cluster up -d node2 node3 || {
    log_error "Failed to create/start node2/node3 - see the docker error above"
    exit 1
  }

  wait_node_synced node2 || exit 1
  wait_node_synced node3 || exit 1

  log_info "Starting HAProxy..."
  compose_cluster up -d haproxy

  log_success "Cluster initialized: 3 nodes synced, HAProxy on port ${HAPROXY_PORT:-3306} (stats: ${HAPROXY_STATS_PORT:-8404})"
  print_cluster_status
}

cmd_start() {
  if [[ ! -f "./cluster_data/node1/grastate.dat" && ! -f "./cluster_data/node2/grastate.dat" && ! -f "./cluster_data/node3/grastate.dat" ]]; then
    log_error "Cluster not initialized yet. Run: ./cluster.sh init"
    exit 1
  fi

  if [[ $(cluster_healthy_count) -gt 0 ]]; then
    log_info "Cluster is already (partially) running - starting remaining services"
    compose_cluster up -d
    print_cluster_status
    return 0
  fi

  # All nodes are down: this is a full-cluster cold start, which needs a
  # bootstrap node. heal.sh knows how to pick the node with the newest data.
  log_info "All nodes are down - delegating cold start to heal.sh (safe bootstrap)"
  ./heal.sh --recover
}

cmd_stop() {
  log_info "Stopping cluster..."
  compose_cluster stop haproxy
  compose_cluster stop node3 node2 node1
  log_success "Cluster stopped. Restart with: ./cluster.sh start"
}

# Full teardown + clean re-initialization with a Portolan-managed subnet.
# DESTRUCTIVE: removes all cluster data - only the encrypted backups survive.
cmd_reinit() {
  log_warning "Re-initialization DELETES the whole cluster including ALL databases in it!"
  log_info "Only ./backups (encrypted) survives. A fresh cluster is built afterwards."

  if [[ "$1" != "--yes" ]]; then
    read -p "Really delete and re-initialize the cluster? (type 'yes' to confirm): " confirm
    if [[ "$confirm" != "yes" ]]; then
      log_info "Re-initialization cancelled"
      exit 0
    fi
  fi

  # Fetch a collision-free subnet from Portolan and persist it in .env
  if command -v portolan &>/dev/null; then
    portolan sync &>/dev/null || true
    local new_subnet
    new_subnet=$(portolan next-subnet 2>/dev/null | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '[:space:]')
    if [[ "$new_subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      set_env_value GALERA_SUBNET "$new_subnet"
      GALERA_SUBNET="$new_subnet"
      log_success "New Galera subnet from Portolan: $new_subnet"
    else
      log_warning "Portolan returned no usable subnet (got: '${new_subnet:-empty}')"
      log_warning "Keeping GALERA_SUBNET=${GALERA_SUBNET:-172.28.66.0/24}"
    fi
  else
    log_warning "Portolan not installed - keeping GALERA_SUBNET=${GALERA_SUBNET:-172.28.66.0/24}"
  fi

  log_info "Tearing down the old cluster (containers + network)..."
  compose_cluster down
  rm -rf ./cluster_data

  cmd_init

  # Mirror the new state into Portolan's registry
  if command -v portolan &>/dev/null; then
    portolan sync &>/dev/null || true
    portolan reserve "${HAPROXY_PORT:-3306}" mariadb "mariadb-backup-system haproxy" &>/dev/null || true
    portolan reserve "${HAPROXY_STATS_PORT:-8404}" haproxy-stats "mariadb-backup-system stats" &>/dev/null || true
    log_info "Portolan registry updated (network sync + port reservations)"
  fi
}

cmd_status() {
  print_cluster_status

  local healthy
  healthy=$(cluster_healthy_count)
  if [[ "$healthy" -eq 3 ]]; then
    log_success "Cluster is fully healthy (3/3 nodes synced)"
  elif [[ "$healthy" -gt 0 ]]; then
    log_warning "Cluster is degraded ($healthy/3 nodes synced) - consider running ./heal.sh"
  else
    log_error "Cluster is down (0/3 nodes synced) - run ./heal.sh to recover"
  fi

  if container_running "$(node_container haproxy)"; then
    log_info "HAProxy: running (stats: http://localhost:${HAPROXY_STATS_PORT:-8404})"
  else
    log_warning "HAProxy: not running"
  fi
}

case "$1" in
  init)   cmd_init ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  reinit) shift; cmd_reinit "$@" ;;
  *)      usage ;;
esac
