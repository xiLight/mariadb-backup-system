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
  echo "  init      First-time cluster setup (bootstraps node1, joins node2/3, starts HAProxy)"
  echo "  start     Start an already initialized cluster"
  echo "  stop      Stop the whole cluster (HAProxy first, then nodes)"
  echo "  status    Show cluster and replication status"
  echo ""
  echo "Rolling updates: ./update.sh | Self-healing: ./heal.sh"
  exit 0
}

cmd_init() {
  if [[ -f "./cluster_data/node1/grastate.dat" ]]; then
    log_error "Cluster already initialized (cluster_data/node1/grastate.dat exists)."
    log_info "Use './cluster.sh start' to start it, or './heal.sh' to recover a broken cluster."
    exit 1
  fi

  log_info "Initializing new 3-node Galera cluster..."

  mkdir -p cluster_data/node1 cluster_data/node2 cluster_data/node3
  touch cluster_data/node1/force_bootstrap

  log_info "Building cluster image..."
  compose_cluster build mariadb-node1 || { log_error "Image build failed"; exit 1; }

  log_info "Bootstrapping node1..."
  compose_cluster up -d mariadb-node1

  wait_node_synced mariadb-node1 || {
    log_error "Bootstrap failed. Check: docker logs mariadb-node1"
    exit 1
  }

  log_info "Joining node2 and node3 (initial state transfer may take a while)..."
  compose_cluster up -d mariadb-node2 mariadb-node3

  wait_node_synced mariadb-node2 || exit 1
  wait_node_synced mariadb-node3 || exit 1

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
  compose_cluster stop mariadb-node3 mariadb-node2 mariadb-node1
  log_success "Cluster stopped. Restart with: ./cluster.sh start"
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

  if node_running mariadb-haproxy; then
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
  *)      usage ;;
esac
