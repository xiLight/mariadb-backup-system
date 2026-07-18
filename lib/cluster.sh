#!/bin/bash
# Shared helpers for Galera cluster management (cluster.sh, update.sh, heal.sh).
# Requires: .env sourced, lib/logging.sh sourced.
#
# Naming: compose SERVICE names are static (node1, node2, node3, haproxy);
# CONTAINER names are unique per stack instance: ${STACK_NAME}-node1 etc.
# Helpers take the service name and map to the container where needed.

CLUSTER_COMPOSE_FILE="${CLUSTER_COMPOSE_FILE:-docker-compose.cluster.yml}"
CLUSTER_NODES=(node1 node2 node3)
CLUSTER_SYNC_TIMEOUT="${CLUSTER_SYNC_TIMEOUT:-600}"
STACK_NAME="${STACK_NAME:-mariadb}"

compose_cluster() {
  docker compose -f "$CLUSTER_COMPOSE_FILE" "$@"
}

# node1 -> ${STACK_NAME}-node1 (also: haproxy -> ${STACK_NAME}-haproxy)
node_container() {
  echo "${STACK_NAME}-$1"
}

# node1 -> ./cluster_data/node1
node_datadir() {
  echo "./cluster_data/$1"
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

node_running() {
  container_running "$(node_container "$1")"
}

node_query() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$(node_container "$1")" mariadb -u root -N -e "$2" 2>/dev/null
}

# Value of a wsrep status variable, e.g. node_wsrep node1 wsrep_local_state_comment
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

# Wait until a node is synced with the cluster (polls every 5s).
# Prints progress on state changes and the container log on failure,
# so a broken join is diagnosable immediately.
wait_node_synced() {
  local node="$1" timeout="${2:-$CLUSTER_SYNC_TIMEOUT}"
  local container waited=0 state last_state=""
  container=$(node_container "$node")

  log_info "Waiting for $container to become Synced (timeout: ${timeout}s)..."
  while (( waited < timeout )); do
    if node_running "$node" && node_is_synced "$node"; then
      log_success "$container is Synced (cluster size: $(cluster_size "$node"))"
      return 0
    fi

    state=$(node_wsrep "$node" wsrep_local_state_comment)
    [[ -z "$state" ]] && state="starting/not responding"
    if [[ "$state" != "$last_state" ]]; then
      log_info "  $container: $state"
      last_state="$state"
    fi

    sleep 5
    waited=$((waited + 5))
  done

  log_error "$container did not reach Synced state within ${timeout}s"
  log_error "Last container log lines (look for SST/wsrep errors):"
  docker logs --tail 20 "$container" 2>&1 | sed 's/^/    /'
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
  printf "%-20s %-10s %-12s %-10s %-6s\n" "CONTAINER" "STATUS" "STATE" "CLUSTER" "SIZE"
  echo "--------------------------------------------------------------"
  for node in "${CLUSTER_NODES[@]}"; do
    if node_running "$node"; then
      state=$(node_wsrep "$node" wsrep_local_state_comment)
      status=$(node_wsrep "$node" wsrep_cluster_status)
      size=$(cluster_size "$node")
      printf "%-20s %-10s %-12s %-10s %-6s\n" "$(node_container "$node")" "running" "${state:-n/a}" "${status:-n/a}" "${size:-n/a}"
    else
      printf "%-20s %-10s %-12s %-10s %-6s\n" "$(node_container "$node")" "stopped" "-" "-" "-"
    fi
  done
  echo ""
}
