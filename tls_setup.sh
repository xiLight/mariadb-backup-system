#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/tls_setup.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }
source "./lib/cluster.sh"

STACK_NAME="${STACK_NAME:-mariadb}"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
TLS_DIR="./tls"
DOMAIN="${TLS_DOMAIN:-$(hostname -f 2>/dev/null || hostname)}"
MODE=""
IMPORT_CERT=""
IMPORT_KEY=""
EXTRA_IPS=()

# Sets up TLS for MariaDB client connections. The MySQL protocol negotiates
# TLS in-protocol (STARTTLS-style), so it MUST terminate at mariadbd itself -
# a TLS-terminating proxy cannot work. Certs live in ./tls, the entrypoint
# enables them server-side, and clients use --ssl on the NORMAL ports.

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Enables server-side TLS on all MariaDB nodes. Clients then connect"
  echo "with TLS on the normal ports (write/read) - no separate TLS port."
  echo ""
  echo "OPTIONS:"
  echo "  --self-signed        Generate own CA + server cert (default)"
  echo "  --domain NAME        Hostname for the certificate (default: $DOMAIN)"
  echo "  --ip ADDR            Additional IP for the certificate (repeatable) -"
  echo "                       required if clients connect via IP with verification"
  echo "  --import CERT KEY    Import existing PEM cert (fullchain) + key,"
  echo "                       e.g. from Traefik/Caddy/Coolify or certbot"
  echo "  --status             Show current TLS status and exit"
  echo "  --help               Show this help message"
  echo ""
  echo "Re-issue the server cert (e.g. to add an IP) - the CA is KEPT, so"
  echo "already distributed ca.pem files stay valid:"
  echo "  rm tls/server-cert.pem tls/server-key.pem tls/server.pem"
  echo "  $0 --self-signed --domain db.example.com --ip 203.0.113.10"
  echo ""
  echo "Client example:"
  echo "  mariadb --host <server> --port <write-port> --ssl --ssl-ca tls/ca.pem -u <user> -p"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --self-signed) MODE="self-signed"; shift ;;
    --domain)      DOMAIN="$2"; shift 2 ;;
    --ip)          EXTRA_IPS+=("$2"); shift 2 ;;
    --import)      MODE="import"; IMPORT_CERT="$2"; IMPORT_KEY="$3"; shift 3 ;;
    --status)      MODE="status"; shift ;;
    --help)        usage ;;
    *)             log_error "Unknown option: $1"; exit 1 ;;
  esac
done
MODE="${MODE:-self-signed}"

is_cluster() {
  [[ -d "./cluster_data" ]]
}

# Detect ACME blockers: a reverse proxy (Coolify/Traefik/Caddy) usually owns
# ports 80/443, so standalone certbot/ACME is not possible on this host.
detect_proxies() {
  local proxies
  proxies=$(docker ps --format '{{.Names}} ({{.Image}})' 2>/dev/null | grep -iE 'traefik|caddy|coolify-proxy' || true)
  if [[ -n "$proxies" ]]; then
    log_info "Detected reverse proxy container(s) on this host:"
    echo "$proxies" | sed 's/^/    /'
    log_info "Ports 80/443 are likely owned by them - standalone ACME is not possible."
    log_info "Tip: import their existing certificates instead: $0 --import fullchain.pem key.pem"
  elif ss -tlnp 2>/dev/null | grep -qE ':(80|443)\s'; then
    log_info "Something is listening on port 80/443 - standalone ACME would conflict."
  else
    log_info "Ports 80/443 look free - you could also use certbot and then: $0 --import"
  fi
}

# Migration: remove the obsolete HAProxy TLS listener from the old
# (non-functional) proxy-termination approach.
remove_legacy_haproxy_tls() {
  if [[ -f haproxy.d/10-tls.cfg ]]; then
    log_info "Removing obsolete HAProxy TLS listener (TLS now terminates at mariadbd)"
    rm -f haproxy.d/10-tls.cfg
    local haproxy_container="${STACK_NAME}-haproxy"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$haproxy_container"; then
      docker restart "$haproxy_container" >/dev/null 2>&1
    fi
  fi
}

# TLS is active once mariadbd reports a usable cipher on a TLS connection.
# The CA file inside the container lets the passwordless check user pass
# the client-side certificate verification (default since MariaDB 11.4).
node_tls_works() {
  local container="$1"
  docker exec "$container" mariadb -h 127.0.0.1 --ssl \
    --ssl-ca /etc/mysql/tls-runtime/ca.pem -u haproxy_check \
    -N -e "SHOW STATUS LIKE 'Ssl_cipher';" 2>/dev/null | awk '{print $2}' | grep -q .
}

# Apply the certs: recreate/restart each node so the entrypoint picks them
# up (rolling in cluster mode - never more than one node down).
apply_server_tls() {
  remove_legacy_haproxy_tls

  if is_cluster; then
    log_info "Enabling TLS on all cluster nodes (rolling, one node at a time)..."
    local node container
    for node in "${CLUSTER_NODES[@]}"; do
      container=$(node_container "$node")
      log_info "--- $container ---"
      compose_cluster up -d --no-deps "$node" >/dev/null 2>&1
      docker restart "$container" >/dev/null
      if ! wait_node_synced "$node"; then
        log_error "$container did not come back Synced - aborting rollout"
        log_error "Remaining nodes are untouched and still serving"
        exit 1
      fi
      if node_tls_works "$container"; then
        log_success "$container: TLS active"
      else
        log_warning "$container: TLS not active - check docker logs $container"
      fi
    done
  else
    log_info "Enabling TLS on the single node..."
    docker compose up -d >/dev/null 2>&1
    docker restart "$MARIADB_CONTAINER" >/dev/null
    sleep 5
    if node_tls_works "$MARIADB_CONTAINER"; then
      log_success "$MARIADB_CONTAINER: TLS active"
    else
      log_warning "TLS not verified - check: docker logs $MARIADB_CONTAINER"
    fi
  fi

  echo ""
  log_success "Server-side TLS is enabled - clients connect on the NORMAL ports:"
  log_info "  Write: mariadb --host <server> --port ${HAPROXY_PORT:-${MARIADB_PORT:-3306}} --ssl --ssl-ca $(pwd)/tls/ca.pem -u <user> -p"
  [[ -n "${HAPROXY_READ_PORT:-}" ]] && log_info "  Read:  same with --port ${HAPROXY_READ_PORT}"
  log_info "Distribute tls/ca.pem to clients (public, no secret). NEVER share the *-key.pem files."
  log_info "Connections without --ssl still work (plaintext) - TLS is offered, not enforced."
}

show_status() {
  if [[ -f "$TLS_DIR/server-cert.pem" ]]; then
    log_info "Certificate present: $TLS_DIR/server-cert.pem"
    openssl x509 -in "$TLS_DIR/server-cert.pem" -noout -subject -enddate 2>/dev/null | sed 's/^/    /'
    openssl x509 -in "$TLS_DIR/server-cert.pem" -noout -ext subjectAltName 2>/dev/null | tail -1 | sed 's/^/    /'
  else
    log_info "No certificate yet - run: $0 --self-signed"
  fi

  local container
  if is_cluster; then container=$(node_container node1); else container="$MARIADB_CONTAINER"; fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    if node_tls_works "$container"; then
      log_success "Server-side TLS: ACTIVE (checked on $container)"
    else
      log_info "Server-side TLS: not active (enable: $0 --self-signed)"
    fi
  fi
}

case "$MODE" in
  status)
    show_status
    exit 0
    ;;

  self-signed)
    detect_proxies
    mkdir -p "$TLS_DIR"
    chmod 700 "$TLS_DIR"

    if [[ -f "$TLS_DIR/server-cert.pem" ]]; then
      log_warning "Certificate already exists - to regenerate: rm tls/server-cert.pem tls/server-key.pem tls/server.pem"
    else
      log_info "Generating CA and server certificate for '$DOMAIN'..."

      gen_failed() {
        log_error "Certificate generation FAILED at step: $1"
        rm -f "$TLS_DIR"/server.pem "$TLS_DIR"/server-cert.pem "$TLS_DIR"/server.csr "$TLS_DIR"/san.ext
        exit 1
      }

      # Reuse an existing CA: re-issuing the server cert must NOT invalidate
      # ca.pem files already distributed to clients
      if [[ -f "$TLS_DIR/ca.pem" && -f "$TLS_DIR/ca-key.pem" ]]; then
        log_info "Reusing existing CA ($TLS_DIR/ca.pem) - distributed copies stay valid"
      else
        openssl genrsa -out "$TLS_DIR/ca-key.pem" 4096 2>/dev/null \
          || gen_failed "CA key"
        openssl req -new -x509 -days 3650 -key "$TLS_DIR/ca-key.pem" \
          -out "$TLS_DIR/ca.pem" -subj "/CN=${STACK_NAME}-backup-ca" 2>/dev/null \
          || gen_failed "CA certificate"
      fi

      openssl genrsa -out "$TLS_DIR/server-key.pem" 4096 2>/dev/null \
        || gen_failed "server key"
      openssl req -new -key "$TLS_DIR/server-key.pem" \
        -out "$TLS_DIR/server.csr" -subj "/CN=$DOMAIN" 2>/dev/null \
        || gen_failed "certificate signing request"

      SAN="DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"
      for extra_ip in "${EXTRA_IPS[@]}"; do
        SAN="$SAN,IP:$extra_ip"
      done
      printf "subjectAltName=%s" "$SAN" > "$TLS_DIR/san.ext"
      log_info "Certificate SANs: $SAN"

      openssl x509 -req -days 825 -in "$TLS_DIR/server.csr" \
        -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca-key.pem" -CAcreateserial \
        -extfile "$TLS_DIR/san.ext" \
        -out "$TLS_DIR/server-cert.pem" 2>/dev/null \
        || gen_failed "server certificate signing"

      cat "$TLS_DIR/server-cert.pem" "$TLS_DIR/server-key.pem" > "$TLS_DIR/server.pem"
      chmod 600 "$TLS_DIR"/*.pem
      rm -f "$TLS_DIR/server.csr" "$TLS_DIR/ca.srl" "$TLS_DIR/san.ext"

      # Final proof: public key of cert and private key must match
      CERT_PUB=$(openssl x509 -in "$TLS_DIR/server-cert.pem" -noout -pubkey 2>/dev/null)
      KEY_PUB=$(openssl pkey -in "$TLS_DIR/server-key.pem" -pubout 2>/dev/null)
      [[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] \
        || gen_failed "final verification (cert/key mismatch)"

      log_success "Certificates generated and verified in $TLS_DIR/"
    fi

    apply_server_tls
    ;;

  import)
    [[ -f "$IMPORT_CERT" && -f "$IMPORT_KEY" ]] || { log_error "Cert or key file not found: $IMPORT_CERT / $IMPORT_KEY"; exit 1; }

    # Sanity: cert and key must belong together (public key comparison
    # works for RSA and ECDSA - Let's Encrypt certs are often ECDSA)
    CERT_PUB=$(openssl x509 -in "$IMPORT_CERT" -noout -pubkey 2>/dev/null)
    KEY_PUB=$(openssl pkey -in "$IMPORT_KEY" -pubout 2>/dev/null)
    if [[ -z "$CERT_PUB" || -z "$KEY_PUB" || "$CERT_PUB" != "$KEY_PUB" ]]; then
      log_error "Certificate and key do not match (or files are not valid PEM)"
      exit 1
    fi

    mkdir -p "$TLS_DIR"
    chmod 700 "$TLS_DIR"
    cp "$IMPORT_CERT" "$TLS_DIR/server-cert.pem"
    cp "$IMPORT_KEY" "$TLS_DIR/server-key.pem"
    cat "$IMPORT_CERT" "$IMPORT_KEY" > "$TLS_DIR/server.pem"
    chmod 600 "$TLS_DIR"/*.pem
    log_success "Certificate imported to $TLS_DIR/"
    log_info "Note: clients should use the issuing CA (e.g. Let's Encrypt root) as --ssl-ca"
    log_info "Re-run this import when the source certificate renews (cron-able)"

    apply_server_tls
    ;;
esac
