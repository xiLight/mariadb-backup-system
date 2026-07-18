#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/db_admin.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

usage() {
  echo "Usage: $0 COMMAND [ARGS]"
  echo ""
  echo "Database and user management (works in single-node and cluster mode;"
  echo "in cluster mode changes replicate to all nodes automatically):"
  echo ""
  echo "  create-database NAME              Create a database"
  echo "  create-user NAME [PASSWORD]       Create a user (password generated if omitted)"
  echo "  provision NAME [PASSWORD]         Create database + user of the same name"
  echo "                                    with ALL privileges on that database only"
  echo "  create-superuser NAME [PASSWORD]  Create a user with full access to ALL"
  echo "                                    databases (GRANT OPTION included)"
  echo "  list                              List databases and users"
  echo ""
  echo "Without NAME the command asks interactively."
  exit 0
}

# Users and database names: conservative charset to stay quoting-safe
validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || {
    log_error "Invalid name '$1' (allowed: a-z, A-Z, 0-9, _, - / max 64 chars)"
    exit 1
  }
}

# Passwords end up inside single-quoted SQL - refuse characters that would break out
validate_password() {
  case "$1" in
    *"'"*|*'\'*)
      log_error "Password must not contain single quotes or backslashes"
      exit 1
      ;;
  esac
  [[ ${#1} -ge 8 ]] || {
    log_error "Password too short (minimum 8 characters)"
    exit 1
  }
}

gen_password() {
  openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Determine connection method (password via MYSQL_PWD, not on the command line)
DOCKER_ENV=(-e MYSQL_PWD="$MARIADB_ROOT_PASSWORD")
if docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  :
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  DOCKER_ENV=()
else
  log_error "Cannot connect to MariaDB container: $MARIADB_CONTAINER"
  exit 1
fi

db_exec() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root "$@"
}

db_query() {
  db_exec -N -e "$1"
}

user_exists() {
  [[ "$(db_query "SELECT COUNT(*) FROM mysql.user WHERE User='$1' AND Host='%';")" != "0" ]]
}

database_exists() {
  db_query "SHOW DATABASES;" | grep -qx "$1"
}

# Where clients reach this instance (for the credentials summary)
connection_hint() {
  local port
  port=$(grep -E '^(HAPROXY_PORT|MARIADB_PORT)=' .env 2>/dev/null | head -1 | cut -d= -f2)
  echo "localhost:${port:-3306}"
}

print_credentials() {
  local name="$1" password="$2" scope="$3"
  echo ""
  log_info "=== CREDENTIALS ==="
  echo -e "${YELLOW}User:     $name${NC}"
  echo -e "${YELLOW}Password: $password${NC}"
  echo -e "${YELLOW}Host:     $(connection_hint)${NC}"
  echo -e "${YELLOW}Access:   $scope${NC}"
  echo ""
  log_warning "Save these credentials securely - the password is not stored anywhere!"
}

ask_name() {
  local prompt="$1" name
  read -p "$prompt: " name
  [[ -n "$name" ]] || { log_error "No name given"; exit 1; }
  echo "$name"
}

# Returns the given password or generates one
resolve_password() {
  if [[ -n "$1" ]]; then
    validate_password "$1"
    echo "$1"
  else
    gen_password
  fi
}

cmd_create_database() {
  local name="${1:-$(ask_name "Database name")}"
  validate_name "$name"

  if database_exists "$name"; then
    log_warning "Database '$name' already exists - nothing to do"
    return 0
  fi

  db_exec -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" ||
    { log_error "Failed to create database '$name'"; exit 1; }
  log_success "Database '$name' created"
}

cmd_create_user() {
  local name="${1:-$(ask_name "Username")}"
  validate_name "$name"

  if user_exists "$name"; then
    log_error "User '$name'@'%' already exists"
    exit 1
  fi

  local password
  password=$(resolve_password "$2")

  db_exec -e "CREATE USER '$name'@'%' IDENTIFIED BY '$password'; FLUSH PRIVILEGES;" ||
    { log_error "Failed to create user '$name'"; exit 1; }
  log_success "User '$name'@'%' created (no privileges yet - grant with 'provision' or manually)"
  print_credentials "$name" "$password" "no privileges granted"
}

cmd_provision() {
  local name="${1:-$(ask_name "Name (used for database AND user)")}"
  validate_name "$name"

  if user_exists "$name"; then
    log_error "User '$name'@'%' already exists - choose another name or grant manually"
    exit 1
  fi

  local password
  password=$(resolve_password "$2")

  if database_exists "$name"; then
    log_info "Database '$name' already exists - creating user and granting access to it"
  else
    db_exec -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" ||
      { log_error "Failed to create database '$name'"; exit 1; }
    log_success "Database '$name' created"
  fi

  db_exec -e "CREATE USER '$name'@'%' IDENTIFIED BY '$password';
              GRANT ALL PRIVILEGES ON \`$name\`.* TO '$name'@'%';
              FLUSH PRIVILEGES;" ||
    { log_error "Failed to create user '$name'"; exit 1; }

  log_success "User '$name'@'%' created with ALL privileges on database '$name'"
  print_credentials "$name" "$password" "ALL privileges on database '$name' only"
}

cmd_create_superuser() {
  local name="${1:-$(ask_name "Superuser name")}"
  validate_name "$name"

  if user_exists "$name"; then
    log_error "User '$name'@'%' already exists"
    exit 1
  fi

  log_warning "A superuser has FULL access to ALL databases (incl. GRANT OPTION)."
  if [[ -t 0 ]]; then
    read -p "Create superuser '$name'? (type 'yes' to confirm): " confirm
    [[ "$confirm" == "yes" ]] || { log_info "Cancelled"; exit 0; }
  fi

  local password
  password=$(resolve_password "$2")

  db_exec -e "CREATE USER '$name'@'%' IDENTIFIED BY '$password';
              GRANT ALL PRIVILEGES ON *.* TO '$name'@'%' WITH GRANT OPTION;
              FLUSH PRIVILEGES;" ||
    { log_error "Failed to create superuser '$name'"; exit 1; }

  log_success "Superuser '$name'@'%' created"
  print_credentials "$name" "$password" "ALL databases (superuser, incl. GRANT OPTION)"
}

cmd_list() {
  echo ""
  echo "Databases:"
  echo "----------"
  db_query "SHOW DATABASES;" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" | sed 's/^/  /'
  echo ""
  echo "Users:"
  echo "------"
  db_exec -e "SELECT User, Host FROM mysql.user WHERE User NOT IN ('', 'mysql', 'mariadb.sys', 'haproxy_check') ORDER BY User, Host;"
  echo ""
}

case "$1" in
  create-database) shift; cmd_create_database "$@" ;;
  create-user)     shift; cmd_create_user "$@" ;;
  provision)       shift; cmd_provision "$@" ;;
  create-superuser) shift; cmd_create_superuser "$@" ;;
  list)            cmd_list ;;
  *)               usage ;;
esac
