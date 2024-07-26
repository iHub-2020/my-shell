#!/bin/bash

# 更新系统包列表并升级现有软件包
sudo apt-get update && sudo apt-get upgrade -y

# 安装必要的软件包
sudo apt-get install -y curl wget gnupg2 software-properties-common

# 添加 PostgreSQL 官方仓库并安装 PostgreSQL
wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib

# 提示用户输入 PostgreSQL 用户名和密码
read -t 30 -p "请输入 PostgreSQL 用户名（默认：admin）： " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-admin}

read -t 30 -s -p "请输入 PostgreSQL 密码（默认：password）： " POSTGRES_PASSWORD
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-password}
echo

# 设置 PostgreSQL
sudo -i -u postgres psql -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
sudo -i -u postgres psql -c "CREATE DATABASE imaticdb WITH OWNER $POSTGRES_USER;"

# 安装 Node.js 和 Yarn
curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -
sudo apt-get install -y nodejs
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt-get update && sudo apt-get install -y yarn

# 下载并安装 Joplin 服务器
mkdir -p /opt/joplin
cd /opt/joplin
git clone https://github.com/laurent22/joplin.git
cd joplin/packages/server
yarn install
yarn run build

# 创建 Joplin 服务器的服务文件
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

# 启动并启用 Joplin 服务器服务
sudo systemctl daemon-reload
sudo systemctl start joplin-server
sudo systemctl enable joplin-server

# 提示是否绑定域名
echo "请输入要绑定的域名（如果没有域名，将使用本地IP地址）："
read -t 15 -p "域名（留空使用本地IP）： " DOMAIN

if [ -z "$DOMAIN" ]; then
    IP=$(hostname -I | awk '{print $1}')
    DOMAIN=$IP
    echo "未输入域名，将使用本地IP地址：$DOMAIN"
else
    echo "绑定域名：$DOMAIN"
    # 安装 Certbot 并申请 SSL/TLS 证书
    sudo apt-get install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m your-email@example.com
fi

# 安装并配置 Nginx
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

    # SSL/TLS 配置
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF

# 启用 Nginx 配置
sudo ln -s /etc/nginx/sites-available/joplin /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# 打印完成信息
if [ "$DOMAIN" == "$IP" ]; then
    echo "Joplin Server 安装完成！您可以通过 http://$DOMAIN:22300 访问 Joplin 服务器。"
else
    echo "Joplin Server 安装完成！您可以通过 https://$DOMAIN 访问 Joplin 服务器。"
fi
