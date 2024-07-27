#!/bin/bash

# Author: reyanmatic
# Version: 1.4

# Function to install a package if not already installed
install_if_not_installed() {
    if ! dpkg -l | grep -q "$1"; then
        sudo apt-get install -y "$1"
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

# Check existing PostgreSQL data
if [ -d "db_data" ]; then
    echo "PostgreSQL data directory already exists."
    read -t 15 -p "Do you want to keep it? (default: y) [y/n]: " KEEP_DB_DATA
    KEEP_DB_DATA=${KEEP_DB_DATA:-y}
    if [ "$KEEP_DB_DATA" == "n" ]; then
        sudo rm -rf db_data
        echo "Old PostgreSQL data removed."
    else
        echo "Keeping existing PostgreSQL data."
    fi
fi

# Prompt user for IP address or domain
APP_BASE_URL=$(prompt_with_default "Enter the IP address or domain for Joplin" "192.168.1.188:22300")

# Create Docker Compose configuration file
sudo tee joplin-docker-compose.yml > /dev/null <<EOF
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
      - "22300:22300"
    environment:
      APP_BASE_URL: "http://$APP_BASE_URL"
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

# Function to clone Git repository with retries and caching
clone_with_retries() {
    local repo_url=$1
    local target_dir=$2
    local retry_interval=$3
    local max_retries=10
    local retries=0

    # Adjust Git configuration to handle large files and prevent timeouts
    git config --global http.postBuffer 524288000
    git config --global http.lowSpeedLimit 0
    git config --global http.lowSpeedTime 999999

    while [ $retries -lt $max_retries ]; do
        if [ -d "$target_dir/.git" ]; then
            echo "Resuming existing clone in $target_dir..."
            git -C $target_dir fetch origin --depth 1
        else
            echo "Cloning repository $repo_url..."
            git clone --depth 1 --no-single-branch $repo_url $target_dir
        fi

        if [ $? -eq 0 ]; then
            echo "Repository cloned successfully."
            return 0
        else
            retries=$((retries + 1))
            echo "Clone failed. Retrying in $retry_interval seconds... ($retries/$max_retries)"
            sleep $retry_interval
        fi
    done

    echo "Failed to clone repository after $max_retries attempts."
    return 1
}

# Clone Joplin repository with retries and caching
clone_with_retries "https://github.com/laurent22/joplin.git" "/opt/joplin/joplin" 20

if [[ $? -ne 0 ]]; then
    echo "Failed to clone Joplin repository. Exiting..."
    exit 1
fi

cd /opt/joplin/joplin/packages/server || { echo "Failed to change directory to joplin/packages/server"; exit 1; }
npm install
npm run build

if [[ "$APP_BASE_URL" == *":"* ]]; then
    # If the user entered an IP address, skip Nginx and SSL configuration
    echo "Skipping Nginx and SSL configuration as the input is an IP address."
else
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
        proxy_pass http://localhost:22300;
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
fi

# Check service status
sudo docker-compose -f joplin-docker-compose.yml ps

# Check logs
sudo docker-compose -f joplin-docker-compose.yml logs

echo "Joplin Server installation completed! You can access it via http://$APP_BASE_URL"
