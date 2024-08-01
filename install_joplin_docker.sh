#!/bin/bash

# Author: reyanmatic
# Version: 5.4

# Function to install a package if not already installed
install_if_not_installed() {
    if ! dpkg -l | grep -q "$1"; then
        sudo apt-get install -y "$1"
    fi
}

# Function to install Docker Compose plugin if not already installed
install_docker_compose_plugin() {
    if ! docker compose version &> /dev/null; then
        echo "Docker Compose plugin not found. Installing..."
        DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
        mkdir -p $DOCKER_CONFIG/cli-plugins
        curl -SL https://github.com/docker/compose/releases/download/v2.11.2/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
        chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
    else
        echo "Docker Compose plugin is already installed."
    fi
}

# Function to prompt user for input with a default value
prompt_with_default() {
    local prompt_text=$1
    local default_value=$2
    read -p "$prompt_text (default: $default_value): " input_value
    input_value=${input_value:-$default_value}
    echo "$input_value"
}

# Function to check and configure UFW
configure_ufw() {
    if ! sudo ufw status &> /dev/null; then
        install_if_not_installed ufw
        sudo ufw allow 22,80,443,22300/tcp
        sudo ufw --force enable
    else
        echo "UFW is already installed."
        if ! sudo ufw status | grep -q "22/tcp"; then
            sudo ufw allow 22/tcp
        fi
        if ! sudo ufw status | grep -q "80/tcp"; then
            sudo ufw allow 80/tcp
        fi
        if ! sudo ufw status | grep -q "443/tcp"; then
            sudo ufw allow 443/tcp
        fi
        if ! sudo ufw status | grep -q "22300/tcp"; then
            sudo ufw allow 22300/tcp
        fi
        sudo ufw reload
    fi
    sudo ufw status
}

# Function to handle PostgreSQL database operations
handle_postgres_db() {
    local choice
    echo "PostgreSQL database detected. Choose an option:"
    echo "1. Keep existing database"
    echo "2. Modify username and password"
    echo "3. Delete old database and create a new one"
    read -p "Enter choice [1-3]: " choice

    case $choice in
        1)
            echo "Keeping existing database..."
            # No additional action needed
            ;;
        2)
            modify_postgres_user
            ;;
        3)
            delete_and_create_postgres_db
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

# Function to ensure the postgres user exists
ensure_postgres_user_exists() {
    sudo docker exec joplin-db-1 psql -U admin -d joplin -c "SELECT 1 FROM pg_roles WHERE rolname='postgres';" | grep -q 1 || \
    sudo docker exec joplin-db-1 psql -U admin -d joplin -c "CREATE USER postgres WITH SUPERUSER PASSWORD 'postgres';"
}

# Function to modify PostgreSQL username and password
modify_postgres_user() {
    echo "Modifying PostgreSQL username and password..."
    ensure_postgres_user_exists

    local current_user=$(prompt_with_default "Enter current PostgreSQL username" "admin")
    local new_user=$(prompt_with_default "Enter new PostgreSQL username" "new_user")
    local new_password=$(prompt_with_default "Enter new PostgreSQL password" "new_password")

    sudo docker exec joplin-db-1 psql -U postgres -c "ALTER USER $current_user WITH PASSWORD '$new_password';"
    sudo docker exec joplin-db-1 psql -U postgres -c "CREATE USER $new_user WITH PASSWORD '$new_password';"
    sudo docker exec joplin-db-1 psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE joplin TO $new_user;"
    sudo docker exec joplin-db-1 psql -U postgres -c "REASSIGN OWNED BY $current_user TO $new_user;"
    sudo docker exec joplin-db-1 psql -U postgres -c "ALTER USER $new_user WITH SUPERUSER;"
    # Optionally, drop the old user if no longer needed
    sudo docker exec joplin-db-1 psql -U postgres -c "DROP USER IF EXISTS $current_user;"

    POSTGRES_USER=$new_user
    POSTGRES_PASSWORD=$new_password

    update_joplin_config
}

# Function to delete old PostgreSQL database and create a new one
delete_and_create_postgres_db() {
    echo "Deleting old PostgreSQL database and creating a new one..."

    # Ensure the PostgreSQL container is running
    sudo docker compose -f joplin-docker-compose.yml up -d db

    # Wait for the PostgreSQL service to be ready
    sleep 10

    ensure_postgres_user_exists

    # Disconnect all sessions from the joplin database
    sudo docker exec joplin-db-1 psql -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'joplin';"

    # Drop the database and user
    sudo docker exec joplin-db-1 psql -U postgres -c "DROP DATABASE IF EXISTS joplin;"
    sudo docker exec joplin-db-1 psql -U postgres -c "DROP USER IF EXISTS $POSTGRES_USER;"

    # Prompt for new username and password
    POSTGRES_USER=$(prompt_with_default "Enter new PostgreSQL username" "admin")
    POSTGRES_PASSWORD=$(prompt_with_default "Enter new PostgreSQL password" "password")

    # Create new database and user
    sudo docker exec joplin-db-1 psql -U postgres -c "CREATE DATABASE joplin;"
    sudo docker exec joplin-db-1 psql -U postgres -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
    sudo docker exec joplin-db-1 psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE joplin TO $POSTGRES_USER;"
    sudo docker exec joplin-db-1 psql -U postgres -c "ALTER USER $POSTGRES_USER WITH SUPERUSER;"

    update_joplin_config
}

# Function to update Joplin configuration file
update_joplin_config() {
    NEW_DOCKER_COMPOSE=$(cat <<EOF
services:
  db:
    image: postgres:latest
    restart: unless-stopped
    environment:
      POSTGRES_DB: joplin
      POSTGRES_USER: $POSTGRES_USER
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
    volumes:
      - db_data:/var/lib/postgresql/data

  app:
    image: joplin/server:latest
    restart: unless-stopped
    ports:
      - "22300:22300"
    environment:
      APP_BASE_URL: "http://$APP_BASE_URL:22300"
      DB_CLIENT: pg
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DATABASE: joplin
      POSTGRES_USER: $POSTGRES_USER
      POSTGRES_PORT: 5432
      POSTGRES_HOST: db
      DISABLE_NTP: "1"
    depends_on:
      - db

volumes:
  db_data:
EOF
)
    echo "$NEW_DOCKER_COMPOSE" | sudo tee joplin-docker-compose.yml > /dev/null
    echo "Joplin configuration updated."
}

# Function to install Docker if not already installed
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
    else
        echo "Docker is already installed."
    fi
}

# Function to pull Docker image with retries
pull_docker_image() {
    local image=$1
    local retries=5
    local count=0

    until [ $count -ge $retries ]; do
        sudo docker pull $image && break
        count=$((count + 1))
        echo "Retrying Docker image pull ($count/$retries)..."
        sleep 10
    done

    if [ $count -ge $retries ]; then
        echo "Failed to pull Docker image after $retries attempts."
        exit 1
    fi
}

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Check and remove old install_joplin_docker.sh if exists
if [ -f "/root/install_joplin_docker.sh" ]; then
    echo "Old install_joplin_docker.sh found. Removing..."
    sudo rm /root/install_joplin_docker.sh
fi

# Download the latest install_joplin_docker.sh
echo "Downloading the latest install_joplin_docker.sh..."
wget -O /root/install_joplin_docker.sh https://raw.githubusercontent.com/iHub-2020/my-shell/main/install_joplin_docker.sh
chmod +x /root/install_joplin_docker.sh

# Install Docker if not installed
install_docker

# Install Docker Compose plugin
install_docker_compose_plugin

# Configure UFW
configure_ufw

# Create Joplin directory
sudo mkdir -p /opt/joplin
cd /opt/joplin

# Check if PostgreSQL data volume exists
if sudo docker volume ls | grep -q "joplin_db_data"; then
    handle_postgres_db
else
    echo "No existing PostgreSQL database found. Creating a new one..."
    POSTGRES_USER=$(prompt_with_default "Enter PostgreSQL username" "admin")
    POSTGRES_PASSWORD=$(prompt_with_default "Enter PostgreSQL password" "password")
    sudo docker volume create joplin_db_data
    sudo docker run --rm -v joplin_db_data:/var/lib/postgresql/data busybox chown -R 999:999 /var/lib/postgresql/data

    sudo docker run --rm --name temp-postgres -e POSTGRES_USER=$POSTGRES_USER -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD -e POSTGRES_DB=joplin -v joplin_db_data:/var/lib/postgresql/data -d postgres
    sleep 10 # Wait for the database to initialize
    sudo docker stop temp-postgres
fi

# Prompt user for IP address or domain
APP_BASE_URL=$(prompt_with_default "Enter the IP address or domain for Joplin" "192.168.1.100")

# Validate IP address or domain
if [[ ! "$APP_BASE_URL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$APP_BASE_URL" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "Invalid IP address or domain. Exiting."
    exit 1
fi

# Create Docker Compose configuration file
update_joplin_config

# Pull the latest Joplin server Docker image with retry
echo "Pulling the latest Joplin server Docker image..."
pull_docker_image joplin/server:latest

# Start the Docker containers using Docker Compose
{
    sudo docker compose -f joplin-docker-compose.yml down
    sudo docker compose -f joplin-docker-compose.yml up -d
} || {
    echo "Installation interrupted or failed. Please check the logs for details."
    exit 1
}

# 确认 NTP 检查在 Joplin 容器中被禁用
sudo docker exec -it $(sudo docker ps -q -f "ancestor=joplin/server:latest") bash -c "
sed -i '/const ntp_1 = require(\"@joplin/lib/ntp\");/a\
if (process.env.DISABLE_NTP === \"true\") {\
    console.log(\"NTP check disabled\");\
    return;\
}' /home/joplin/packages/server/dist/app.js
"

# Check if the APP_BASE_URL is an IP address or a domain
if [[ ! "$APP_BASE_URL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # If the user entered a domain, configure Nginx and SSL
    # Check if Nginx is installed
    if ! command -v nginx &> /dev/null; then
        echo "Nginx is not installed. Installing Nginx..."
        sudo apt-get install -y nginx
    else
        echo "Nginx is already installed."
    fi

    # Install Certbot for SSL certificates
    install_if_not_installed certbot
    install_if_not_installed python3-certbot-nginx

    # Check existing SSL certificates
    KEEP_CERTS=$(prompt_with_default "SSL certificates for $APP_BASE_URL already exist. Do you want to keep them?" "y")
    if [ "$KEEP_CERTS" == "n" ]; then
        sudo certbot delete --cert-name $APP_BASE_URL
        echo "Old SSL certificates removed."
        sudo certbot --nginx -d $APP_BASE_URL --non-interactive --agree-tos -m your-email@example.com
    else
        echo "Keeping existing SSL certificates."
    fi

    # Configure Nginx
    sudo tee /etc/nginx/sites-available/joplin > /dev/null <<EOF
server {
    listen 80;
    server_name $APP_BASE_URL;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $APP_BASE_URL;

    ssl_certificate /etc/letsencrypt/live/$APP_BASE_URL/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$APP_BASE_URL/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://localhost:22300;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$
