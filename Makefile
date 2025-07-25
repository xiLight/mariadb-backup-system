# MariaDB Backup System Makefile

.PHONY: help install env start stop restart status backup backup-full backup-incremental restore cleanup health logs clean build

# Default target
help:
	@echo "MariaDB Backup System Commands:"
	@echo ""
	@echo "Setup & Management:"
	@echo "  make install          - Install and configure the system"
	@echo "  make start            - Start MariaDB container"
	@echo "  make stop             - Stop MariaDB container"
	@echo "  make restart          - Restart MariaDB container"
	@echo "  make status           - Show container status"
	@echo "  make health           - Run health check"
	@echo "  make build            - Build MariaDB container"
	@echo ""
	@echo "Backup Operations:"
	@echo "  make backup           - Create incremental backup"
	@echo "  make backup-full      - Create full backup"
	@echo "  make backup-empty     - Create full backup including empty DBs"
	@echo ""
	@echo "Maintenance:"
	@echo "  make cleanup          - Clean old backups and logs"
	@echo "  make cleanup-backups  - Clean old backups only"
	@echo "  make cleanup-logs     - Clean old logs only"
	@echo ""
	@echo "Monitoring:"
	@echo "  make logs             - Show MariaDB logs"
	@echo "  make logs-backup      - Show backup logs"
	@echo "  make logs-follow      - Follow MariaDB logs"
	@echo ""
	@echo "Development:"
	@echo "  make env              - Create .env file with generated passwords"
	@echo "  make clean            - Clean all containers and volumes"
	@echo "  make reset            - Reset everything (DANGER!)"

# Installation and setup
env:
	@echo "Setting up environment configuration..."
	@if [ -f ".env" ]; then \
		echo "WARNING: .env file already exists. Backing up to .env.backup"; \
		cp .env .env.backup; \
	fi
	@if [ ! -f ".env.example" ]; then \
		echo "ERROR: .env.example file not found!"; \
		exit 1; \
	fi
	@cp .env.example .env
	@echo "Created .env from .env.example"
	@echo "Generating secure passwords..."
	@ROOT_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	APP_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	DB1_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	DB2_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	DB3_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	DB4_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	DB5_PASS=$$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25); \
	sed -i "s/your_secure_root_password_here/$$ROOT_PASS/g" .env; \
	sed -i "s/your_secure_app_password_here/$$APP_PASS/g" .env; \
	sed -i "s/db1_password/$$DB1_PASS/g" .env; \
	sed -i "s/db2_password/$$DB2_PASS/g" .env; \
	sed -i "s/db3_password/$$DB3_PASS/g" .env; \
	sed -i "s/db4_password/$$DB4_PASS/g" .env; \
	sed -i "s/db5_password/$$DB5_PASS/g" .env; \
	echo "Generated secure passwords for all databases"; \
	echo ""; \
	echo "Generated credentials:"; \
	echo "Root Password:     $$ROOT_PASS"; \
	echo "App Password:      $$APP_PASS"; \
	echo "Database 1 Pass:   $$DB1_PASS"; \
	echo "Database 2 Pass:   $$DB2_PASS"; \
	echo "Database 3 Pass:   $$DB3_PASS"; \
	echo "Database 4 Pass:   $$DB4_PASS"; \
	echo "Database 5 Pass:   $$DB5_PASS"; \
	echo ""; \
	echo "WARNING: Please save these credentials securely!"

install:
	@echo "Installing MariaDB Backup System..."
	@chmod +x install.sh
	@./install.sh

# Container management
start:
	@echo "Starting MariaDB container..."
	@docker-compose up -d

stop:
	@echo "Stopping MariaDB container..."
	@docker-compose down

restart:
	@echo "Restarting MariaDB container..."
	@docker-compose restart

status:
	@echo "Container Status:"
	@docker-compose ps
	@echo ""
	@echo "MariaDB Status:"
	@docker exec mariadb mariadb -u root -p$(shell grep MARIADB_ROOT_PASSWORD .env | cut -d= -f2) -e "SHOW STATUS LIKE 'Uptime%';" 2>/dev/null || echo "Cannot connect to MariaDB"

build:
	@echo "Building MariaDB container..."
	@docker-compose build

# Backup operations
backup:
	@echo "Creating incremental backup..."
	@./backup.sh

backup-full:
	@echo "Creating full backup..."
	@./backup.sh --full

backup-empty:
	@echo "Creating full backup including empty databases..."
	@./backup.sh --full --include-empty

# Restore operations
restore:
	@echo "Starting restore process..."
	@./restore.sh

# Cleanup operations
cleanup: cleanup-backups cleanup-logs

cleanup-backups:
	@echo "Cleaning old backups..."
	@./cleanup_backups.sh

cleanup-logs:
	@echo "Cleaning old logs..."
	@./log_cleanup.sh

# Health and monitoring
health:
	@echo "Running health check..."
	@./health_check.sh

health-test:
	@echo "Running health check with backup test..."
	@./health_check.sh --test-backup

# Logging
logs:
	@echo "Showing MariaDB logs (last 100 lines):"
	@docker logs --tail 100 mariadb

logs-backup:
	@echo "Showing backup logs:"
	@tail -n 50 logs/backup.log 2>/dev/null || echo "No backup logs found"

logs-follow:
	@echo "Following MariaDB logs (Ctrl+C to stop):"
	@docker logs -f mariadb

# Development and maintenance
clean:
	@echo "Cleaning containers and images..."
	@docker-compose down -v
	@docker system prune -f

reset: clean
	@echo "WARNING: This will delete ALL data and backups!"
	@read -p "Are you sure? (type 'yes' to confirm): " confirm && [ "$$confirm" = "yes" ] || exit 1
	@rm -rf mariadb_data/ backups/ logs/
	@docker-compose down -v --remove-orphans
	@docker volume prune -f
	@echo "System reset complete"

# Configuration
config:
	@echo "Current configuration:"
	@echo "====================="
	@cat .env | grep -E '^[A-Z]' | head -10
	@echo "..."
	@echo ""
	@echo "Edit configuration: nano .env"

# Quick database access
mysql: mariadb
mariadb:
	@echo "Connecting to MariaDB..."
	@docker exec -it mariadb mariadb -u root -p$(shell grep MARIADB_ROOT_PASSWORD .env | cut -d= -f2)

# Show disk usage
disk-usage:
	@echo "Backup disk usage:"
	@du -sh backups/ 2>/dev/null || echo "No backups directory"
	@echo ""
	@echo "Container disk usage:"
	@du -sh mariadb_data/ 2>/dev/null || echo "No data directory"

# Show recent backups
list-backups:
	@echo "Recent backups:"
	@ls -lah backups/*.enc 2>/dev/null | head -10 || echo "No encrypted backups found"
	@echo ""
	@echo "Binary logs:"
	@ls -lah backups/binlogs/ 2>/dev/null | head -5 || echo "No binary logs found"

# Show backup statistics
backup-stats:
	@echo "Backup Statistics:"
	@echo "=================="
	@echo "Total backups: $$(find backups -name '*.enc' 2>/dev/null | wc -l)"
	@echo "Total size: $$(du -sh backups/ 2>/dev/null | cut -f1 || echo '0')"
	@echo "Oldest backup: $$(find backups -name '*.enc' -exec ls -lt {} + 2>/dev/null | tail -1 | awk '{print $$6,$$7,$$8,$$9}' || echo 'None')"
	@echo "Newest backup: $$(find backups -name '*.enc' -exec ls -lt {} + 2>/dev/null | head -2 | tail -1 | awk '{print $$6,$$7,$$8,$$9}' || echo 'None')"
