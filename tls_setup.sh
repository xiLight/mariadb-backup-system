#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/tls_setup.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

STACK_NAME="${STACK_NAME:-mariadb}"
TLS_DIR="./tls"
DOMAIN="${TLS_DOMAIN:-$(hostname -f 2>/dev/null || hostname)}"
MODE=""
IMPORT_CERT=""
IMPORT_KEY=""

# Sets up TLS termination for MariaDB client connections in HAProxy:
#   - own CA + server certificate (self-signed, default), or
#   - import existing certificates (e.g. from Coolify/Traefik/Caddy)
# Traffic node<->node stays on the isolated galera network (unencrypted
# by design); this protects the client-facing port.

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Enables the TLS listener in HAProxy (port \${HAPROXY_TLS_PORT:-3316})."
  echo ""
  echo "OPTIONS:"
  echo "  --self-signed        Generate own CA + server cert (default)"
  echo "  --domain NAME        Hostname for the certificate (default: $DOMAIN)"
  echo "  --import CERT KEY    Import existing PEM cert (fullchain) + key,"
  echo "                       e.g. from Traefik/Caddy/Coolify or certbot"
  echo "  --status             Show current TLS status and exit"
  echo "  --help               Show this help message"
  echo ""
  echo "After setup, clients connect with TLS:"
  echo "  mariadb --host <server> --port \${HAPROXY_TLS_PORT:-3316} --ssl --ssl-ca tls/ca.pem ..."
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --self-signed) MODE="self-signed"; shift ;;
    --domain)      DOMAIN="$2"; shift 2 ;;
    --import)      MODE="import"; IMPORT_CERT="$2"; IMPORT_KEY="$3"; shift 3 ;;
    --status)      MODE="status"; shift ;;
    --help)        usage ;;
    *)             log_error "Unknown option: $1"; exit 1 ;;
  esac
done
MODE="${MODE:-self-signed}"

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

enable_haproxy_listener() {
  if grep -q "^listen mariadb-tls" haproxy.cfg; then
    log_info "TLS listener already enabled in haproxy.cfg"
  else
    sed -i 's/^#\(listen mariadb-tls\)/\1/; s/^#\(    bind \*:3316\)/\1/; s/^#\(    option mysql-check user haproxy_check\)/\1/; s/^#\(    default-server inter 3s fall 3 rise 2\)/\1/; s/^#\(    server node[0-9] node[0-9]:3306 check.*\)/\1/' haproxy.cfg
    grep -q "^listen mariadb-tls" haproxy.cfg || { log_error "Failed to enable TLS listener in haproxy.cfg"; exit 1; }
    log_success "TLS listener enabled in haproxy.cfg"
  fi

  local haproxy_container="${STACK_NAME}-haproxy"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$haproxy_container"; then
    log_info "Restarting HAProxy to apply TLS configuration..."
    docker restart "$haproxy_container" >/dev/null
    sleep 3
    if docker ps --format '{{.Names}}' | grep -qx "$haproxy_container"; then
      log_success "HAProxy restarted - TLS available on port ${HAPROXY_TLS_PORT:-3316}"
    else
      log_error "HAProxy did not come back up - check: docker logs $haproxy_container"
      exit 1
    fi
  else
    log_info "HAProxy not running - TLS will be active on the next cluster start"
  fi
}

show_status() {
  if [[ -f "$TLS_DIR/server.pem" ]]; then
    log_info "Certificate present: $TLS_DIR/server.pem"
    openssl x509 -in "$TLS_DIR/server.pem" -noout -subject -enddate 2>/dev/null | sed 's/^/    /'
  else
    log_info "No certificate yet - run: $0 --self-signed"
  fi
  if grep -q "^listen mariadb-tls" haproxy.cfg; then
    log_info "HAProxy TLS listener: enabled (port ${HAPROXY_TLS_PORT:-3316})"
  else
    log_info "HAProxy TLS listener: disabled"
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

    if [[ -f "$TLS_DIR/server.pem" ]]; then
      log_warning "Certificate already exists - re-run after 'rm tls/server.pem' to regenerate"
    else
      log_info "Generating CA and server certificate for '$DOMAIN'..."

      gen_failed() {
        log_error "Certificate generation FAILED at step: $1"
        rm -f "$TLS_DIR"/server.pem "$TLS_DIR"/server-cert.pem "$TLS_DIR"/server.csr
        exit 1
      }

      openssl genrsa -out "$TLS_DIR/ca-key.pem" 4096 2>/dev/null \
        || gen_failed "CA key"
      openssl req -new -x509 -days 3650 -key "$TLS_DIR/ca-key.pem" \
        -out "$TLS_DIR/ca.pem" -subj "/CN=${STACK_NAME}-backup-ca" 2>/dev/null \
        || gen_failed "CA certificate"

      openssl genrsa -out "$TLS_DIR/server-key.pem" 4096 2>/dev/null \
        || gen_failed "server key"
      openssl req -new -key "$TLS_DIR/server-key.pem" \
        -out "$TLS_DIR/server.csr" -subj "/CN=$DOMAIN" 2>/dev/null \
        || gen_failed "certificate signing request"
      printf "subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1" "$DOMAIN" > "$TLS_DIR/san.ext"
      openssl x509 -req -days 825 -in "$TLS_DIR/server.csr" \
        -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca-key.pem" -CAcreateserial \
        -extfile "$TLS_DIR/san.ext" \
        -out "$TLS_DIR/server-cert.pem" 2>/dev/null \
        || gen_failed "server certificate signing"

      cat "$TLS_DIR/server-cert.pem" "$TLS_DIR/server-key.pem" > "$TLS_DIR/server.pem"
      chmod 600 "$TLS_DIR"/*.pem
      rm -f "$TLS_DIR/server.csr" "$TLS_DIR/ca.srl" "$TLS_DIR/san.ext"

      # Final proof: the combined PEM must contain a valid cert whose public
      # key matches the private key (works for RSA and ECDSA)
      CERT_PUB=$(openssl x509 -in "$TLS_DIR/server.pem" -noout -pubkey 2>/dev/null)
      KEY_PUB=$(openssl pkey -in "$TLS_DIR/server.pem" -pubout 2>/dev/null)
      [[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] \
        || gen_failed "final verification (cert/key mismatch)"

      log_success "Certificates generated and verified in $TLS_DIR/ (CA valid 10y, server cert 825d)"
    fi

    enable_haproxy_listener
    echo ""
    log_info "Clients connect with TLS like this:"
    log_info "  mariadb --host <server> --port ${HAPROXY_TLS_PORT:-3316} --ssl --ssl-ca $(pwd)/tls/ca.pem -u <user> -p"
    log_info "Distribute tls/ca.pem to the clients (public, no secret). NEVER share ca-key.pem/server-key.pem."
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
    cat "$IMPORT_CERT" "$IMPORT_KEY" > "$TLS_DIR/server.pem"
    chmod 600 "$TLS_DIR/server.pem"
    log_success "Certificate imported to $TLS_DIR/server.pem"
    log_info "Note: re-run this import when the source certificate renews (cron-able)"

    enable_haproxy_listener
    ;;
esac
