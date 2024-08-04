#!/bin/bash

# Author: Reyanmatic
# Version: 3.9
# Last Modified: 2024-08-04

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
        curl -SL https://github.com/docker/compose/releases/download/latest/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
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

# Function to clean up scripts
cleanup() {
    echo "Cleaning up..."
    if [ -f "/root/get-docker.sh" ]; then
        echo "Deleting /root/get-docker.sh"
        sudo rm /root/get-docker.sh
    fi
    if [ -f "/root/install_joplin_docker.sh" ]; then
        echo "Deleting /root/install_joplin_docker.sh"
        sudo rm /root/install_joplin_docker.sh
    fi
}

# Ensure cleanup is called on script exit
trap cleanup EXIT

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Remove old scripts if they exist
cleanup

# Download the latest install_joplin_docker.sh
echo "Downloading the latest install_joplin_docker.sh..."
wget -O /root/install_joplin_docker.sh https://raw.githubusercontent.com/iHub-2020/docker-shell/main/install_docker.sh
chmod +x /root/install_joplin_docker.sh

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Installing Docker..."
    /root/install_joplin_docker.sh
else
    echo "Docker is already installed."
fi

# Install Docker Compose plugin
install_docker_compose_plugin

# Configure UFW
configure_ufw

# Create a data persistent volume
docker volume create joplin_data

# Create Joplin directory
sudo mkdir -p /opt/joplin
cd /opt/joplin

# Prompt user for PostgreSQL username and password
POSTGRES_USER=$(prompt_with_default "Enter PostgreSQL username" "admin")
POSTGRES_PASSWORD=$(prompt_with_default "Enter PostgreSQL password" "password")

# Set default port
PORT=22300

# Prompt user for IP address or domain
APP_BASE_URL=$(prompt_with_default "Enter the IP address or domain for Joplin" "192.168.1.100")

# Create Docker Compose configuration file
NEW_DOCKER_COMPOSE=$(cat <<EOF
version: '3'

services:
  db:
    image: postgres:16
    volumes:
      - /var/lib/docker/volumes/joplin_data/_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=$POSTGRES_PASSWORD
      - POSTGRES_USER=$POSTGRES_USER
      - POSTGRES_DB=joplin

  app:
    image: joplin/server:latest
    depends_on:
      - db
    ports:
      - "$PORT:$PORT"
    restart: unless-stopped
    environment:
      - APP_PORT=$PORT
      - APP_BASE_URL=http://$APP_BASE_URL:$PORT
      - DB_CLIENT=pg
      - POSTGRES_PASSWORD=$POSTGRES_PASSWORD
      - POSTGRES_DATABASE=joplin
      - POSTGRES_USER=$POSTGRES_USER
      - POSTGRES_PORT=5432
      - POSTGRES_HOST=db
EOF
)

# Check if existing Docker Compose file is different from the new one
if [ -f joplin-docker-compose.yml ] && ! diff <(echo "$NEW_DOCKER_COMPOSE") joplin-docker-compose.yml > /dev/null; then
    echo "Docker Compose configuration has changed."
    # Stop existing Docker containers
    sudo docker compose -f joplin-docker-compose.yml down
    
    # Prompt to clean PostgreSQL data
    KEEP_DB_DATA=$(prompt_with_default "Do you want to keep the existing PostgreSQL data?" "y")
    if [ "$KEEP_DB_DATA" == "n" ]; then
        sudo rm -rf /opt/joplin/db_data
        echo "Old PostgreSQL data removed."
    fi
    
    # Update Docker Compose file
    echo "$NEW_DOCKER_COMPOSE" | sudo tee joplin-docker-compose.yml > /dev/null
else
    echo "$NEW_DOCKER_COMPOSE" | sudo tee joplin-docker-compose.yml > /dev/null
fi

# Pull the latest Joplin server Docker image
echo "Pulling the latest Joplin server Docker image..."
sudo docker pull joplin/server:latest

# Start the Docker containers using Docker Compose
sudo docker compose -f joplin-docker-compose.yml up -d

# Wait for Joplin container to be fully up and running
echo "Waiting for Joplin container to be ready..."
sleep 20

# Get the container ID of the Joplin app
JOPLIN_CONTAINER_ID=$(sudo docker ps -q -f "ancestor=joplin/server:latest")

# Function to replace NTP server in specified files
replace_ntp_server() {
    local file_path=$1
    local ntp_server="time1.aliyun.com"
    sudo docker exec -u 0 -it $JOPLIN_CONTAINER_ID /bin/sh -c "sed -i 's|pool.ntp.org|$ntp_server|g' $file_path"
}

# Replace NTP server in specified files
replace_ntp_server "/home/joplin/packages/lib/vendor/ntp-client.js"
replace_ntp_server "/home/joplin/packages/server/src/env.ts"
replace_ntp_server "/home/joplin/packages/server/dist/env.js"

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
        proxy_pass http://localhost:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Enable Nginx configuration
    sudo rm -f /etc/nginx/sites-enabled/joplin
    sudo ln -s /etc/nginx/sites-available/joplin /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl restart nginx

    # Display success message with HTTPS URL
    echo "Joplin Server installation completed! You can access it via https://$APP_BASE_URL"
else
    # Display success message with HTTP URL
    echo "Joplin Server installation completed! You can access it via http://$APP_BASE_URL:$PORT"
fi

# Check service status
sudo docker compose -f joplin-docker-compose.yml ps

# Check logs
sudo docker compose -f joplin-docker-compose.yml logs
