#!/bin/bash

# Author: Reyanmatic
# Version: 4.0
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

# 删除现有的 Docker Compose 配置文件
if [ -f "/opt/joplin/joplin-docker-compose.yml" ]; then
    sudo rm /opt/joplin/joplin-docker-compose.yml
fi

# 下载最新的 install_joplin_docker.sh
echo "Downloading the latest install_joplin_docker.sh..."
wget -O /root/install_joplin_docker.sh https://raw.githubusercontent.com/iHub-2020/docker-shell/main/install_docker.sh
chmod +x /root/install_joplin_docker.sh

# 检查 Docker 是否已安装
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Installing Docker..."
    /root/install_joplin_docker.sh
else
    echo "Docker is already installed."
fi

# 安装 Docker Compose 插件
install_docker_compose_plugin

# 配置 UFW
configure_ufw

# 创建数据持久化卷
docker volume create joplin_data

# 创建 Joplin 目录
sudo mkdir -p /opt/joplin
cd /opt/joplin

# 提示用户输入 PostgreSQL 用户名和密码
POSTGRES_USER=$(prompt_with_default "Enter PostgreSQL username" "admin")
POSTGRES_PASSWORD=$(prompt_with_default "Enter PostgreSQL password" "password")

# 设置默认端口
PORT=22300

# 提示用户输入 IP 地址或域名
APP_BASE_URL=$(prompt_with_default "Enter the IP address or domain for Joplin" "192.168.1.100")

# 创建 Docker Compose 配置文件
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
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_DB=joplin

  app:
    image: joplin/server:latest
    depends_on:
      - db
    ports:
      - "${PORT}:${PORT}"
    restart: unless-stopped
    environment:
      - APP_PORT=${PORT}
      - APP_BASE_URL=http://${APP_BASE_URL}:${PORT}
      - DB_CLIENT=pg
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DATABASE=joplin
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PORT=5432
      - POSTGRES_HOST=db
EOF
)

# 检查现有的 Docker Compose 文件是否与新文件不同
if [ -f joplin-docker-compose.yml ] && ! diff <(echo "$NEW_DOCKER_COMPOSE") joplin-docker-compose.yml > /dev/null; then
    echo "Docker Compose configuration has changed."
    # 停止现有 Docker 容器
    sudo docker compose -f joplin-docker-compose.yml down
    
    # 提示是否清理 PostgreSQL 数据
    KEEP_DB_DATA=$(prompt_with_default "Do you want to keep the existing PostgreSQL data?" "y")
    if [ "$KEEP_DB_DATA" == "n" ]; then
        sudo docker volume rm joplin_data
        docker volume create joplin_data
        echo "Old PostgreSQL data removed."
    fi
    
    # 更新 Docker Compose 文件
    echo "$NEW_DOCKER_COMPOSE" | sudo tee joplin-docker-compose.yml > /dev/null
else
    echo "$NEW_DOCKER_COMPOSE" | sudo tee joplin-docker-compose.yml > /dev/null
fi

# 函数：重试拉取 Docker 镜像
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

# 拉取最新的 Joplin 服务器 Docker 镜像
echo "Pulling the latest Joplin server Docker image..."
pull_docker_image joplin/server:latest

# 使用 Docker Compose 启动容器
sudo docker compose -f joplin-docker-compose.yml up -d

# 函数：等待容器准备就绪
wait_for_container() {
    local container_name=$1
    local retries=10
    local count=0

    until [ $count -ge $retries ]; do
        if [ "$(sudo docker inspect -f '{{.State.Running}}' $container_name 2>/dev/null)" == "true" ]; then
            echo "$container_name is ready."
            return
        fi
        count=$((count + 1))
        echo "Waiting for $container_name to be ready ($count/$retries)..."
        sleep 10
    done

    if [ $count -ge $retries ]; then
        echo "Failed to wait for $container_name to be ready."
        exit 1
    fi
}

# 等待 Joplin 容器完全启动
wait_for_container "app"

# 获取 Joplin 应用容器的 ID
JOPLIN_CONTAINER_ID=$(sudo docker ps -q -f "name=app")

# 函数：在指定文件中替换 NTP 服务器
replace_ntp_server() {
    local file_path=$1
    local ntp_server="time1.aliyun.com"
    sudo docker exec -u 0 $JOPLIN_CONTAINER_ID /bin/sh -c "sed -i 's|pool.ntp.org|$ntp_server|g' $file_path"
}

# 在指定文件中替换 NTP 服务器
replace_ntp_server "/home/joplin/packages/lib/vendor/ntp-client.js"
replace_ntp_server "/home/joplin/packages/server/src/env.ts"
replace_ntp_server "/home/joplin/packages/server/dist/env.js"

# 检查 APP_BASE_URL 是 IP 地址还是域名
if [[ ! "$APP_BASE_URL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # 如果用户输入的是域名，配置 Nginx 和 SSL
    # 检查是否安装了 Nginx
    if ! command -v nginx &> /dev/null; then
        echo "Nginx is not installed. Installing Nginx..."
        sudo apt-get install -y nginx
    else
        echo "Nginx is already installed."
    fi

    # 安装 Certbot 以获取 SSL 证书
    install_if_not_installed certbot
    install_if_not_installed python3-certbot-nginx

    # 检查现有的 SSL 证书
    KEEP_CERTS=$(prompt_with_default "SSL certificates for $APP_BASE_URL already exist. Do you want to keep them?" "y")
    if [ "$KEEP_CERTS" == "n" ]; then
        sudo certbot delete --cert-name $APP_BASE_URL
        echo "Old SSL certificates removed."
        sudo certbot --nginx -d $APP_BASE_URL --non-interactive --agree-tos -m your-email@example.com
    else
        echo "Keeping existing SSL certificates."
    fi

    # 配置 Nginx
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

    # 启用 Nginx 配置
    sudo rm -f /etc/nginx/sites-enabled/joplin
    sudo ln -s /etc/nginx/sites-available/joplin /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl restart nginx

    # 显示成功消息，提供 HTTPS URL
    echo "Joplin Server installation completed! You can access it via https://$APP_BASE_URL"
else
    # 显示成功消息，提供 HTTP URL
    echo "Joplin Server installation completed! You can access it via http://$APP_BASE_URL:$PORT"
fi

# 检查服务状态
sudo docker compose -f joplin-docker-compose.yml ps

# 检查日志
sudo docker compose -f joplin-docker-compose.yml logs
