#!/bin/bash
set -eo pipefail

# 颜色定义
COLOR_INFO='\033[34m'
COLOR_SUCCESS='\033[32m'
COLOR_WARNING='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_RESET='\033[0m'

# 全局状态变量
NGINX_STOPPED=0

show_step() {
  echo -e "\n${COLOR_INFO}[STEP $1] $2${COLOR_RESET}"
}

show_success() {
  echo -e "${COLOR_SUCCESS}$1${COLOR_RESET}"
}

show_error() {
  echo -e "${COLOR_ERROR}$1${COLOR_RESET}"
}

check_port_conflict() {
  local port=$1
  if ss -tulpn | grep -q ":${port} "; then
    show_error "检测到端口 ${port} 被占用，请先停止相关服务"
    exit 1
  fi
}

install_certbot() {
  show_step 1 "安装Certbot"
  sudo snap install core
  sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
  show_success "Certbot安装完成"
}

request_certificate() {
  show_step 2 "申请证书"
  read -p "请输入域名：" domain
  
  check_port_conflict 80
  check_port_conflict 443

  if certbot certonly --standalone \
    --register-unsafely-without-email \
    --non-interactive \
    --agree-tos \
    -d "$domain"; then
    show_success "证书申请成功"
    echo "证书存储位置：/etc/letsencrypt/live/${domain}/"
  else
    show_error "证书申请失败"
    exit 1
  fi
}

main() {
  install_certbot
  request_certificate
}

main "$@"
