#!/bin/bash

# Author: reyanmatic
# Version: 3.2

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
    echo $input_value
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

# Function to check network environment (currently commented out)
# check_network_environment() {
#     if ping -c 1 google.com &> /dev/null; then
#         echo "Using default NTP server."
#         sudo ntpdate -u pool.ntp.org
#     else
#         echo "Using Alibaba NTP server."
#         sudo ntpdate -u time1.aliyun.com
#     fi
# }

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

# Configure UFW
configure_ufw

# Update NTP time synchronization server (currently commented out)
# check_network_environment
# echo "NTP server setup completed."

# Create Joplin directory
sudo mkdir -p /opt/joplin
cd /opt/joplin

# Prompt user for PostgreSQL username and password
OLD_POSTGRES_USER=$(grep -oP '(?<=POSTGRES_USER: ).*' joplin-docker-compose.yml 2>/dev/null)
OLD_POSTGRES_PASSWORD=$(grep -oP '(?<=POSTGRES_PASSWORD: ).*' joplin-docker-compose.yml 2>/dev/null)

POSTGRES_USER=$(prompt_with_default "Enter PostgreSQL username" "${OLD_POSTGRES_USER:-admin}")
POSTGRES_PASSWORD=$(prompt_with_default "Enter PostgreSQL password" "${OLD_POSTGRES_PASSWORD:-password}")

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
    KEEP_DB_DATA=$(prompt_with_default "Do you want to keep the existing PostgreSQL data?" "y")
    if [ "$KEEP_DB_DATA" == "n" ]; then
        sudo rm -rf /opt/joplin/db_data
        echo "Old PostgreSQL data removed."
    elif [ "$POSTGRES_USER" != "$OLD_POSTGRES_USER" ] || [ "$POSTGRES_PASSWORD" != "$OLD_POSTGRES_PASSWORD" ]; then
        echo "Old PostgreSQL data must be removed due to changes in username or password."
        sudo rm -rf /opt/joplin/db_data
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
