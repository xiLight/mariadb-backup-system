#!/bin/bash
# Shared helpers for Galera cluster management (cluster.sh, update.sh, heal.sh).
# Requires: .env sourced, lib/logging.sh sourced.

CLUSTER_COMPOSE_FILE="${CLUSTER_COMPOSE_FILE:-docker-compose.cluster.yml}"
CLUSTER_NODES=(mariadb-node1 mariadb-node2 mariadb-node3)
CLUSTER_SYNC_TIMEOUT="${CLUSTER_SYNC_TIMEOUT:-600}"

compose_cluster() {
  docker compose -f "$CLUSTER_COMPOSE_FILE" "$@"
}

# mariadb-node2 -> ./cluster_data/node2
node_datadir() {
  echo "./cluster_data/node${1#mariadb-node}"
}

node_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

node_query() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$1" mariadb -u root -N -e "$2" 2>/dev/null
}

# Value of a wsrep status variable, e.g. node_wsrep mariadb-node1 wsrep_local_state_comment
node_wsrep() {
  node_query "$1" "SHOW STATUS LIKE '$2';" | awk '{print $2}'
}

# A node is healthy when it is part of the primary component and fully synced
node_is_synced() {
  local state status
  state=$(node_wsrep "$1" wsrep_local_state_comment)
  status=$(node_wsrep "$1" wsrep_cluster_status)
  [[ "$state" == "Synced" && "$status" == "Primary" ]]
}

cluster_size() {
  node_wsrep "$1" wsrep_cluster_size
}

# Wait until a node is synced with the cluster (polls every 5s)
wait_node_synced() {
  local node="$1" timeout="${2:-$CLUSTER_SYNC_TIMEOUT}"
  local waited=0

  log_info "Waiting for $node to become Synced (timeout: ${timeout}s)..."
  while (( waited < timeout )); do
    if node_running "$node" && node_is_synced "$node"; then
      log_success "$node is Synced (cluster size: $(cluster_size "$node"))"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  log_error "$node did not reach Synced state within ${timeout}s"
  return 1
}

# Check that all nodes are up and synced; returns number of healthy nodes
cluster_healthy_count() {
  local count=0 node
  for node in "${CLUSTER_NODES[@]}"; do
    if node_running "$node" && node_is_synced "$node"; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

print_cluster_status() {
  local node state status size
  echo ""
  printf "%-16s %-10s %-12s %-10s %-6s\n" "NODE" "CONTAINER" "STATE" "CLUSTER" "SIZE"
  echo "----------------------------------------------------------"
  for node in "${CLUSTER_NODES[@]}"; do
    if node_running "$node"; then
      state=$(node_wsrep "$node" wsrep_local_state_comment)
      status=$(node_wsrep "$node" wsrep_cluster_status)
      size=$(cluster_size "$node")
      printf "%-16s %-10s %-12s %-10s %-6s\n" "$node" "running" "${state:-n/a}" "${status:-n/a}" "${size:-n/a}"
    else
      printf "%-16s %-10s %-12s %-10s %-6s\n" "$node" "stopped" "-" "-" "-"
    fi
  done
  echo ""
}
