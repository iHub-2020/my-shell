#!/bin/bash

# Author: reyanmatic
# Version: 1.1
# Project URL: https://github.com/iHub-2020/my-shell/install_joplin.sh

# Update system package list and upgrade existing packages
sudo apt-get update && sudo apt-get upgrade -y

# Install necessary packages
sudo apt-get install -y curl wget gnupg2 software-properties-common

# Add PostgreSQL official repository and install PostgreSQL
wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib

# Prompt user to enter PostgreSQL username and password
read -t 60 -p "Enter PostgreSQL username (default: admin): " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-admin}

read -t 60 -s -p "Enter PostgreSQL password (default: password): " POSTGRES_PASSWORD
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-password}
echo

# Configure PostgreSQL
sudo -i -u postgres psql -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
sudo -i -u postgres psql -c "CREATE DATABASE imaticdb WITH OWNER $POSTGRES_USER;"

# Install Node.js and Yarn
curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -
sudo apt-get install -y nodejs
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt-get update && sudo apt-get install -y yarn

# Download and install Joplin server
sudo mkdir -p /opt/joplin
sudo chown $(whoami):$(whoami) /opt/joplin
cd /opt/joplin
git clone https://github.com/laurent22/joplin.git
cd joplin/packages/server
yarn install
yarn run build

# Create Joplin server service file
sudo tee /etc/systemd/system/joplin-server.service > /dev/null <<EOF
[Unit]
Description=Joplin Server
After=network.target postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=/opt/joplin/joplin/packages/server
ExecStart=/usr/bin/yarn start
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Start and enable Joplin server service
sudo systemctl daemon-reload
sudo systemctl start joplin-server
sudo systemctl enable joplin-server

# Prompt for domain binding
echo "Enter the domain to bind (leave empty to use local IP):"
read -t 60 -p "Domain (default: local IP): " DOMAIN

if [ -z "$DOMAIN" ]; then
    IP=$(hostname -I | awk '{print $1}')
    DOMAIN=$IP
    echo "No domain entered, using local IP: $DOMAIN"
else
    echo "Binding domain: $DOMAIN"
    # Install Certbot and obtain SSL/TLS certificate
    sudo apt-get install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m your-email@example.com
fi

# Install and configure Nginx
sudo apt-get install -y nginx
sudo tee /etc/nginx/sites-available/joplin > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:22300;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SSL/TLS configuration
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF

# Enable Nginx configuration
sudo ln -s /etc/nginx/sites-available/joplin /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# Print completion message
if [ "$DOMAIN" == "$IP" ]; then
    echo "Joplin Server installation completed! You can access it via http://$DOMAIN:22300"
else
    echo "Joplin Server installation completed! You can access it via https://$DOMAIN"
fi
