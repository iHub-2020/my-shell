#!/bin/bash

# Author: reyanmatic
# Version: 2.1

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
    read -t 60 -p "$prompt_text (default: $default_value): " input_value
    input_value=${input_value:-$default_value}
    echo $input_value
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

# Check if UFW is installed and configure firewall
install_if_not_installed ufw
sudo ufw allow 22,80,443,22300/tcp
sudo ufw enable
sudo ufw status

# Update NTP time synchronization server
install_if_not_installed ntpdate
sudo ntpdate time1.aliyun.com

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
version: '3.8'

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
      - "$PORT:$PORT"
    environment:
      APP_BASE_URL: "http://$APP_BASE_URL:$PORT"
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

# Check if existing Docker Compose file is different from the new one
if [ -f joplin-docker-compose.yml ] && ! diff <(echo "$NEW_DOCKER_COMPOSE") joplin-docker-compose.yml > /dev/null; then
    echo "Docker Compose configuration has changed."
    # Stop existing Docker containers
    sudo docker compose -f joplin-docker-compose.yml down
    
    # Prompt to clean PostgreSQL data
    read -t 15 -p "Do you want to keep the existing PostgreSQL data? (default: y) [y/n]: " KEEP_DB_DATA
    KEEP_DB_DATA=${KEEP_DB_DATA:-y}
    if [ "$KEEP_DB_DATA" == "n" ]; then
        sudo rm -rf /opt/joplin/db_data
        echo "Old PostgreSQL data removed."
    else
        echo "Keeping existing PostgreSQL data."
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

if [[ "$APP_BASE_URL" == *.* ]]; then
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
    if [ -d "/etc/letsencrypt/live/$APP_BASE_URL" ]; then
        echo "SSL certificates for $APP_BASE_URL already exist."
        read -t 15 -p "Do you want to keep them? (default: y) [y/n]: " KEEP_CERTS
        KEEP_CERTS=${KEEP_CERTS:-y}
        if [ "$KEEP_CERTS" == "n" ]; then
            sudo certbot delete --cert-name $APP_BASE_URL
            echo "Old SSL certificates removed."
            sudo certbot --nginx -d $APP_BASE_URL --non-interactive --agree-tos -m your-email@example.com
        else
            echo "Keeping existing SSL certificates."
        fi
    else
        # Obtain new SSL certificates
        sudo certbot --nginx -d $APP_BASE_URL --non-interactive --agree-tos -m your-email@example.com
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
    sudo ln -s /etc/nginx/sites-available/joplin /etc/nginx/sites-enabled/ || sudo rm /etc/nginx/sites-enabled/joplin && sudo ln -s /etc/nginx/sites-available/joplin /etc/nginx/sites-enabled/
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
