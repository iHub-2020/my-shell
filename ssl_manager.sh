#!/bin/bash
set -eo pipefail

# 颜色定义
COLOR_INFO='\033[34m'
COLOR_SUCCESS='\033[32m'
COLOR_WARNING='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_RESET='\033[0m'

# 系统检测
check_system() {
  if ! command -v snap >/dev/null 2>&1; then
    echo -e "${COLOR_ERROR}检测到系统未安装snapd，正在自动安装...${COLOR_RESET}"
    sudo apt-get update -qq && sudo apt-get install -y snapd
    sudo systemctl enable --now snapd.socket
    export PATH=$PATH:/snap/bin
  fi
}

# 安装Certbot
install_certbot() {
  echo -e "\n${COLOR_INFO}[STEP 1] 安装Certbot${COLOR_RESET}"
  sudo snap install core
  sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
  echo -e "${COLOR_SUCCESS}Certbot安装完成 ✓${COLOR_RESET}"
}

# 申请证书
request_certificate() {
  echo -e "\n${COLOR_INFO}[STEP 2] 申请证书${COLOR_RESET}"
  read -p "请输入域名：" domain

  # 端口检测
  for port in 80 443; do
    if ss -tulpn | grep -q ":${port} "; then
      echo -e "${COLOR_ERROR}检测到端口 ${port} 被占用，请先停止相关服务 ✗${COLOR_RESET}"
      exit 1
    fi
  done

  # 执行签发
  if certbot certonly --standalone \
    --register-unsafely-without-email \
    --non-interactive \
    --agree-tos \
    -d "$domain"; then
    echo -e "${COLOR_SUCCESS}证书申请成功 ✓"
    echo -e "证书存储位置：/etc/letsencrypt/live/${domain}/${COLOR_RESET}"
  else
    echo -e "${COLOR_ERROR}证书申请失败 ✗${COLOR_RESET}"
    exit 1
  fi
}

# 主流程
main() {
  check_system
  install_certbot
  request_certificate
}

main "$@"
