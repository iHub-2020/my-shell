#!/bin/bash
set -eo pipefail

# 配置区（根据需求修改）===========================================
CERT_DIR="/root/cert"                  # 证书存储路径
DEFAULT_EMAIL="admin@yourdomain.com"   # 管理员邮箱（接收通知）
ACME_SERVER="letsencrypt"              # 证书颁发机构
NOTICE_DAYS_BEFORE_EXPIRE=7            # 证书过期前提醒天数

# 颜色定义
COLOR_INFO='\033[34m'
COLOR_SUCCESS='\033[32m'
COLOR_WARNING='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_RESET='\033[0m'

# 全局变量
TERMINATED_PROCESSES=()
# ================================================================

# 增强型日志函数 ------------------------------------------------
log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS] $*${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}[WARNING] $*${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR] $*${COLOR_RESET}" >&2; }

# 输入验证增强模块 ----------------------------------------------
validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || {
    log_error "邮箱格式无效: $1"
    exit 1
  }
}

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || {
    log_error "域名格式无效: $1"
    exit 1
  }
}

# 智能端口管理 -------------------------------------------------
smart_port_check() {
  local port=$1
  log_info "正在深度扫描端口 ${port}..."
  
  for tool in lsof ss netstat; do
    if command -v "$tool" >/dev/null; then
      case $tool in
        lsof)
          pid=$(lsof -i :$port -sTCP:LISTEN -t 2>/dev/null)
          ;;
        ss)
          pid=$(ss -ltnpH "sport = :$port" | awk '{print $6}' | cut -d, -f2 | uniq)
          ;;
        netstat)
          pid=$(netstat -tlpn 2>/dev/null | awk -v port=":$port" '$4 ~ port {print $7}' | cut -d/ -f1)
          ;;
      esac
      [ -n "$pid" ] && break
    fi
  done

  if [ -n "$pid" ]; then
    log_warn "端口 ${port} 被进程占用 (PID: $pid)"
    read -rp "是否暂停此进程？[Y/n] " choice
    case "${choice:-Y}" in
      y|Y)
        log_info "正在智能暂停进程..."
        if kill -STOP "$pid"; then
          TERMINATED_PROCESSES+=("$pid")
          log_success "进程已冻结"
        else
          log_error "进程操作失败，错误码: $?"
          return 1
        fi
        ;;
      *)
        log_error "操作中断"
        return 1
        ;;
    esac
  else
    log_success "端口 ${port} 畅通"
  fi
}

# 自动化环境修复 -----------------------------------------------
auto_fix_environment() {
  log_info "启动系统自愈程序..."
  
  mkdir -p /etc/ssl/private
  chmod 710 /etc/ssl/private
  
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf
  
  timedatectl set-ntp true
  systemctl restart systemd-timesyncd
}

# 网络连通性终极测试 -------------------------------------------
network_health_check() {
  log_info "执行全方位网络诊断..."
  
  local test_urls=(
    "https://acme-v02.api.letsencrypt.org"
    "https://github.com"
    "https://google.com"
  )
  
  for url in "${test_urls[@]}"; do
    if ! curl --connect-timeout 10 -Is "$url" >/dev/null; then
      log_error "网络连通性故障: 无法访问 $url"
      return 1
    fi
  done
  log_success "网络状态：优秀"
}

# 证书管理增强模块 ---------------------------------------------
certificate_orchestrator() {
  local domain=$1
  validate_domain "$domain"
  log_info "启动智能证书编排系统，为域名: $domain"
  
  local max_retries=5
  local retry_delay=10
  
  for ((i=1; i<=max_retries; i++)); do
    if ~/.acme.sh/acme.sh --issue --server "${ACME_SERVER}" \
               -d "${domain}" \
               --standalone \
               -k ec-256; then
      break
    else
      log_warn "证书申请异常，正在启动第 ${i} 次重试..."
      sleep $((retry_delay * 2 ** (i-1)))
      if [ $i -eq $max_retries ]; then
        log_error "关键错误：证书申请永久失败"
        return 1
      fi
    fi
  done

  ~/.acme.sh/acme.sh --install-cert -d "${domain}" --ecc \
    --key-file "${CERT_DIR}/${domain}.key" \
    --fullchain-file "${CERT_DIR}/${domain}.crt" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书续期成功！请检查服务状态。' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

  if ! openssl x509 -in "${CERT_DIR}/${domain}.crt" -noout -subject -dates >/dev/null; then
    log_error "证书完整性校验失败"
    return 1
  fi

  log_success "证书申请及安装成功"
}

# 系统依赖智能安装 ---------------------------------------------
dependency_resolver() {
  log_info "启动智能依赖解析引擎..."
  
  declare -A pkg_map=(
    ["debian"]="curl lsof procps coreutils gnupg2 systemd"
    ["ubuntu"]="curl lsof procps coreutils gnupg2 systemd"
    ["centos"]="curl lsof procps-ng coreutils gnupg2 systemd"
  )
  
  os_id=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]')
  
  if [ -z "${pkg_map[$os_id]}" ]; then
    log_error "不兼容的操作系统: $os_id"
    return 1
  fi
  
  case $os_id in
    "debian"|"ubuntu")
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq ${pkg_map[$os_id]}
      ;;
    "centos")
      yum install -y -q ${pkg_map[$os_id]}
      ;;
  esac
  
  # 安装 acme.sh
  curl -sSL https://get.acme.sh | bash -s --
}

# 主流程 ---------------------------------------------------------
main() {
  dependency_resolver || exit 1
  auto_fix_environment || exit 1
  network_health_check || exit 1

  mkdir -p "${CERT_DIR}"

  # 请将 “yourdomain.com” 替换为实际需要申请证书的域名
  certificate_orchestrator "yourdomain.com" || exit 1
}

main
