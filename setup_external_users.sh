#!/bin/bash
cd "$(dirname "$0")"

echo "Setting up MariaDB with external user access..."

# 1. Stop and remove existing container and volumes
echo "1. Stopping and removing existing container..."
docker compose down -v

# 2. Remove existing database data to force reinitialization
echo "2. Removing existing database data..."
rm -rf "./mariadb_data"

# 3. Rebuild the image to ensure entrypoint changes are included
echo "3. Rebuilding MariaDB image..."
docker compose build --no-cache mariadb

# 4. Start container again (users will be created automatically via entrypoint.sh)
echo "4. Starting container with new configuration..."
docker compose up -d

# 5. Wait for MariaDB to start and initialize
echo "5. Waiting for MariaDB to start and initialize..."
sleep 15

# 6. Check container logs
echo "6. Checking container logs..."
docker logs mariadb --tail 20

# 6.1. Create users
echo "6.1. Creating users..."
./create_users_manually.sh

echo "Setup complete!"
