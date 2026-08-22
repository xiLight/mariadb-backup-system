#!/bin/bash
cd "$(dirname "$0")/.."

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/cluster.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

usage() {
  echo "Nutzung: $0 COMMAND"
  echo ""
  echo "Galera Cluster Management:"
  echo "  init            Ersteinrichtung des Clusters (Bootstrapt Node1, verbindet Node2/3, startet HAProxy)"
  echo "  start           Startet einen bereits initialisierten Cluster"
  echo "  stop            Stoppt den gesamten Cluster (erst HAProxy, dann Nodes)"
  echo "  status          Zeigt Cluster- und Replikations-Status"
  echo "  reinit [--yes]  Kompletter Abriss und Neuaufbau des Clusters von Grund auf:"
  echo "                  Holt ein neues Subnetz via Portolan, LÖSCHT alle Cluster-Daten"
  echo "                  und führt dann einen sauberen 'init' durch"
  echo "  drill           Kontrollierter Failover-Test: Stoppt Node1, prüft ob der"
  echo "                  Cluster weiterarbeitet, und bringt Node1 wieder online"
  echo ""
  echo "Rolling Updates: ./scripts/update.sh | Self-Healing: ./scripts/heal.sh"
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
      log_error "Netzwerk '$net' nutzt bereits das Subnetz $subnet (dein GALERA_SUBNET)."
      log_info "Das ist meist ein Überbleibsel eines alten Stacks. Behebe es mit:"
      log_info "  docker network rm $net"
      log_info "oder wähle ein anderes GALERA_SUBNET in der .env-Datei."
      return 1
    fi
  done
  return 0
}

cmd_init() {
  if [[ -f "./cluster_data/node1/grastate.dat" ]]; then
    log_error "Cluster ist bereits initialisiert (cluster_data/node1/grastate.dat existiert)."
    log_info "Nutze './scripts/cluster.sh start' zum Starten, oder './scripts/heal.sh' um einen kaputten Cluster wiederherzustellen."
    exit 1
  fi

  log_info "Initialisiere neuen 3-Node Galera-Cluster..."

  check_subnet_conflict || exit 1

  mkdir -p cluster_data/node1 cluster_data/node2 cluster_data/node3
  touch cluster_data/node1/force_bootstrap

  log_info "Erstelle Cluster-Image..."
  compose_cluster build node1 || { log_error "Image-Build fehlgeschlagen!"; exit 1; }

  log_info "Bootstrapping für Node1 läuft..."
  compose_cluster up -d node1 || {
    log_error "Node1 konnte nicht erstellt/gestartet werden - siehe Docker-Fehlermeldung oben."
    exit 1
  }

  wait_node_synced node1 || {
    log_error "Bootstrap fehlgeschlagen. Prüfe Logs mit: docker logs $(node_container node1)"
    exit 1
  }

  log_info "Füge Node2 und Node3 hinzu (initialer State-Transfer kann etwas dauern)..."
  compose_cluster up -d node2 node3 || {
    log_error "Node2/Node3 konnten nicht erstellt/gestartet werden - siehe Docker-Fehlermeldung oben."
    exit 1
  }

  wait_node_synced node2 || exit 1
  wait_node_synced node3 || exit 1

  log_info "Starte HAProxy..."
  compose_cluster up -d haproxy

  log_success "Cluster erfolgreich initialisiert: 3 Nodes synchronisiert, HAProxy auf Port ${HAPROXY_PORT:-3306} (Stats: ${HAPROXY_STATS_PORT:-8404})"
  print_cluster_status
}

cmd_start() {
  if [[ ! -f "./cluster_data/node1/grastate.dat" && ! -f "./cluster_data/node2/grastate.dat" && ! -f "./cluster_data/node3/grastate.dat" ]]; then
    log_error "Cluster ist noch nicht initialisiert. Führe aus: ./scripts/cluster.sh init"
    exit 1
  fi

  if [[ $(cluster_healthy_count) -gt 0 ]]; then
    log_info "Cluster läuft bereits (teilweise) - starte verbleibende Services."
    compose_cluster up -d
    print_cluster_status
    return 0
  fi

  # All nodes are down: this is a full-cluster cold start, which needs a
  # bootstrap node. heal.sh knows how to pick the node with the newest data.
  log_info "Alle Nodes sind offline - übergebe Cold-Start an heal.sh (Safe Bootstrap)."
  ./scripts/heal.sh --recover
}

cmd_stop() {
  log_info "Stoppe Cluster..."
  compose_cluster stop haproxy
  compose_cluster stop node3 node2 node1
  log_success "Cluster gestoppt. Neustart mit: ./scripts/cluster.sh start"
}

# Full teardown + clean re-initialization with a Portolan-managed subnet.
# DESTRUCTIVE: removes all cluster data - only the encrypted backups survive.
cmd_reinit() {
  log_warning "Die Neu-Initialisierung LÖSCHT den gesamten Cluster inklusive ALLER darin enthaltenen Datenbanken!"
  log_info "Nur ./backups (verschlüsselt) bleibt erhalten. Danach wird ein frischer Cluster aufgebaut."

  if [[ "$1" != "--yes" ]]; then
    read -p "Wirklich alles löschen und neu initialisieren? (Tippe 'yes' zum Bestätigen): " confirm
    if [[ "$confirm" != "yes" ]]; then
      log_info "Neu-Initialisierung abgebrochen."
      exit 0
    fi
  fi

  # Fetch a collision-free subnet from Portolan and persist it in .env
  if command -v portolan &>/dev/null; then
    portolan sync &>/dev/null || true
    local new_subnet
    new_subnet=$(portolan next-subnet 3 24 | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '[:space:]')
    if [[ "$new_subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      set_env_value GALERA_SUBNET "$new_subnet"
      GALERA_SUBNET="$new_subnet"
      log_success "Neues Galera-Subnetz von Portolan bezogen: $new_subnet"
    else
      log_warning "Portolan lieferte kein nutzbares Subnetz zurück (Ergebnis: '${new_subnet:-empty}')."
      log_warning "Behalte GALERA_SUBNET=${GALERA_SUBNET:-172.28.66.0/24}"
    fi
  else
    log_warning "Portolan ist nicht installiert - behalte GALERA_SUBNET=${GALERA_SUBNET:-172.28.66.0/24}"
  fi

  log_info "Reiße alten Cluster ab (Container + Netzwerk)..."
  compose_cluster down || log_warning "compose down hat Fehler gemeldet - erzwinge Cleanup trotzdem."

  # Belt and braces: compose down can leave the network behind when the
  # subnet in .env changed since creation - remove it explicitly
  local own_net="${STACK_NAME}-cluster_galera"
  if docker network ls --format '{{.Name}}' | grep -qx "$own_net"; then
    docker network rm "$own_net" >/dev/null 2>&1 && log_info "Verwaistes Netzwerk $own_net entfernt."
  fi

  rm -rf ./cluster_data

  cmd_init

  # Mirror the new state into Portolan's registry
  if command -v portolan &>/dev/null; then
    portolan sync &>/dev/null || true
    portolan reserve "${HAPROXY_PORT:-3306}" mariadb "mariadb-backup-system haproxy" &>/dev/null || true
    portolan reserve "${HAPROXY_STATS_PORT:-8404}" haproxy-stats "mariadb-backup-system stats" &>/dev/null || true
    log_info "Portolan-Registry wurde aktualisiert (Netzwerk-Sync + Port-Reservierungen)."
  fi
}

# Controlled failover drill: proves that the cluster survives losing node1
# and that HAProxy fails over. Run quarterly, outside peak hours.
cmd_drill() {
  if [[ $(cluster_healthy_count) -ne 3 ]]; then
    log_error "Für einen Drill muss der Cluster komplett gesund sein (3/3 synchronisiert) - breche ab."
    print_cluster_status
    exit 1
  fi

  log_warning "Failover Drill: Node1 wird für etwa 30 Sekunden gestoppt!"
  read -p "Wirklich fortfahren? (Tippe 'yes' zum Bestätigen): " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_info "Drill abgebrochen."
    exit 0
  fi

  # Pause self-healing - otherwise the heal cron restarts node1 mid-drill
  # and "repairs" the intentional outage before we can measure failover
  touch ./logs/.heal_paused
  trap 'rm -f ./logs/.heal_paused' EXIT
  log_info "Self-Healing ist für die Dauer des Drills pausiert."

  log_info "Stoppe $(node_container node1)..."
  docker stop "$(node_container node1)" >/dev/null

  # HAProxy needs fall(3) x inter(3s) ~ 9-12s to mark node1 down
  sleep 15

  # The cluster must stay primary and reachable through HAProxy
  local drill_ok=true
  if [[ $(cluster_healthy_count) -ne 2 ]]; then
    log_error "Erwartete 2/3 gesunde Nodes während des Drills, bekam aber $(cluster_healthy_count)."
    drill_ok=false
  fi

  # haproxy_check has no privileges but may log in - perfect for a probe.
  # --skip-ssl: since 11.4 clients enforce TLS verification on TCP, which a
  # passwordless user cannot satisfy - this probe tests failover, not TLS.
  # Retry a few times: the failover window itself may still be settling.
  local probe_ok=false attempt
  for attempt in 1 2 3; do
    if docker exec "$(node_container node2)" mariadb -h haproxy --skip-ssl -u haproxy_check -e "SELECT 1;" >/dev/null 2>&1; then
      probe_ok=true
      break
    fi
    sleep 5
  done

  if [[ "$probe_ok" == "true" ]]; then
    log_success "HAProxy Failover funktioniert: Anfragen werden auch ohne Node1 verarbeitet."
  else
    log_error "Datenbank-Anfrage über HAProxy ist während des Ausfalls von Node1 FEHLGESCHLAGEN."
    drill_ok=false
  fi

  log_info "Bringe Node1 wieder online..."
  docker start "$(node_container node1)" >/dev/null
  wait_node_synced node1 || drill_ok=false

  rm -f ./logs/.heal_paused
  log_info "Self-Healing fortgesetzt."

  if [[ "$drill_ok" == "true" ]]; then
    log_success "=== DRILL BESTANDEN: Failover und Wiederherstellung funktionieren wie erwartet! ==="
  else
    log_error "=== DRILL FEHLGESCHLAGEN - Überprüfe das System, bevor du dich auf das Failover verlässt! ==="
    exit 1
  fi
}

cmd_status() {
  print_cluster_status

  local healthy
  healthy=$(cluster_healthy_count)
  if [[ "$healthy" -eq 3 ]]; then
    log_success "Cluster ist vollständig gesund (3/3 Nodes synchronisiert)."
  elif [[ "$healthy" -gt 0 ]]; then
    log_warning "Cluster ist eingeschränkt ($healthy/3 Nodes synchronisiert) - evtl. ./scripts/heal.sh ausführen."
  else
    log_error "Cluster ist down (0/3 Nodes synchronisiert) - führe ./scripts/heal.sh aus, um ihn wiederherzustellen."
  fi

  if container_running "$(node_container haproxy)"; then
    log_info "HAProxy: läuft (Stats: http://localhost:${HAPROXY_STATS_PORT:-8404})"
  else
    log_warning "HAProxy: läuft nicht!"
  fi
}

case "$1" in
  init)   cmd_init ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  reinit) shift; cmd_reinit "$@" ;;
  drill)  cmd_drill ;;
  *)      usage ;;
esac
