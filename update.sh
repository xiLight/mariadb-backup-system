#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/update.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

# Rolling update with zero downtime:
#   1. git pull the latest version of this repository
#   2. rebuild the MariaDB image
#   3. update node1 while node2/node3 keep serving traffic (HAProxy fails over)
#   4. wait until node1 has rejoined and is fully Synced
#   5. repeat for node2, then node3 - each waits for the previous node
#   6. reload HAProxy
# Aborts immediately if the cluster is not fully healthy before or during
# the update, so at no point fewer than 2 healthy nodes serve traffic.

SKIP_PULL=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-pull)
      SKIP_PULL=true
      shift
      ;;
    --yes)
      SKIP_CONFIRM=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Rolling update: git pull + rebuild + restart nodes one by one."
      echo "In single-node mode (docker-compose.yml) it does a simple update instead."
      echo ""
      echo "OPTIONS:"
      echo "  --skip-pull    Don't run git pull, only rebuild and roll the update"
      echo "  --yes          Skip the confirmation prompt"
      echo "  --help         Show this help message"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

UPDATE_START_TIME=$(date +%s)

# --- Step 1: Pull latest version ------------------------------------------
if [[ "$SKIP_PULL" == "false" ]]; then
  log_info "Pulling latest version from git..."

  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    log_warning "Local changes detected in tracked files:"
    git status --short | grep -v '^??' | sed 's/^/    /'
    log_warning "A clean tree is expected - runtime files (tls, .env, haproxy.d/10-tls.cfg) are gitignored."
    log_warning "Discard unexpected changes with: git checkout -- <file>   (or stash them)"
  fi

  OLD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
  if ! git pull --ff-only; then
    log_error "git pull failed - the files listed above are blocking it."
    log_error "Fix with 'git checkout -- <file>' or 'git stash', then re-run. Or use --skip-pull."
    exit 1
  fi
  NEW_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)

  if [[ "$OLD_COMMIT" == "$NEW_COMMIT" ]]; then
    log_info "Already up to date ($NEW_COMMIT)"
  else
    log_success "Updated: $OLD_COMMIT -> $NEW_COMMIT"
  fi
fi

# --- Step 2: Detect mode ---------------------------------------------------
CLUSTER_RUNNING=$(compose_cluster ps -q node1 node2 node3 2>/dev/null | wc -l)

if [[ "$CLUSTER_RUNNING" -eq 0 ]]; then
  if [[ -d "./cluster_data" ]]; then
    log_error "Cluster installation detected but no nodes are running."
    log_error "Start/recover it first: ./cluster.sh start (or ./heal.sh), then re-run the update."
    exit 1
  fi

  log_info "No Galera cluster detected - performing single-node update"

  if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -p "Rebuild and restart the single MariaDB container? (type 'yes' to confirm): " confirm
    [[ "$confirm" != "yes" ]] && { log_info "Update cancelled"; exit 0; }
  fi

  docker compose up -d --build || { log_error "Single-node update failed"; exit 1; }
  log_success "Single-node update completed"
  exit 0
fi

# --- Step 3: Rolling cluster update ---------------------------------------
log_info "Galera cluster detected - performing rolling update"

HEALTHY=$(cluster_healthy_count)
if [[ "$HEALTHY" -lt 3 ]]; then
  log_error "Cluster is not fully healthy ($HEALTHY/3 nodes synced)."
  log_error "A rolling update needs all 3 nodes. Run ./heal.sh first."
  print_cluster_status
  exit 1
fi
log_success "Pre-flight check passed: all 3 nodes are synced"

if [[ "$SKIP_CONFIRM" != "true" ]]; then
  echo ""
  log_warning "Rolling update: each node restarts once (traffic fails over automatically)"
  read -p "Continue? (type 'yes' to confirm): " confirm
  [[ "$confirm" != "yes" ]] && { log_info "Update cancelled"; exit 0; }
fi

log_info "Building updated image..."
compose_cluster build node1 || { log_error "Image build failed - nothing was changed"; exit 1; }

for node in "${CLUSTER_NODES[@]}"; do
  CONTAINER=$(node_container "$node")
  echo ""
  log_info "=== Updating $CONTAINER (remaining nodes keep serving traffic) ==="

  compose_cluster up -d --no-deps --force-recreate "$node" || {
    log_error "Failed to recreate $CONTAINER - aborting update"
    exit 1
  }

  if ! wait_node_synced "$node"; then
    log_error "$CONTAINER did not rejoin the cluster - ABORTING update."
    log_error "The remaining nodes are still serving. Investigate with: docker logs $CONTAINER"
    exit 1
  fi

  SIZE=$(cluster_size "$node")
  if [[ "$SIZE" != "3" ]]; then
    log_error "Cluster size is $SIZE (expected 3) after updating $CONTAINER - aborting"
    exit 1
  fi

  log_success "=== $CONTAINER updated and back in sync ==="
done

log_info "Refreshing HAProxy..."
compose_cluster up -d haproxy

UPDATE_DURATION=$(( $(date +%s) - UPDATE_START_TIME ))

echo ""
log_success "Rolling update completed in ${UPDATE_DURATION}s - zero downtime, all 3 nodes on the new version"
print_cluster_status
