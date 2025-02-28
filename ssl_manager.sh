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
INTERFERED_PROCS=()  # 用于保存被冻结的干涉进程PID
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

# 自动冻结干涉进程（如 nginx） -----------------------------------
suspend_interfering_processes() {
  local interfering_process="nginx"  # 这里泛指可能干涉申请证书的进程，可根据需要修改或扩展
  local pids
  pids=$(pgrep "$interfering_process" || true)
  if [ -n "$pids" ]; then
    for pid in $pids; do
      if kill -STOP "$pid" 2>/dev/null; then
        log_info "已冻结干涉进程 $interfering_process (PID: $pid)"
        INTERFERED_PROCS+=("$pid")
      fi
    done
  else
    log_info "未检测到干涉进程 $interfering_process"
  fi
}

# 恢复之前被冻结的干涉进程 ---------------------------------------
resume_interfering_processes() {
  local interfering_process="nginx"
  if [ ${#INTERFERED_PROCS[@]} -gt 0 ]; then
    for pid in "${INTERFERED_PROCS[@]}"; do
      if kill -CONT "$pid" 2>/dev/null; then
        log_info "已恢复干涉进程 $interfering_process (PID: $pid)"
      else
        log_warn "恢复干涉进程 (PID: $pid) 失败，可能该进程已退出"
      fi
    done
    # 清空数组，以防后续误用
    INTERFERED_PROCS=()
  fi
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
    return 1
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
  
  # 如果检测到端口占用或出现 nginx 干涉，自动冻结干涉进程
  suspend_interfering_processes
  
  local max_retries=3
  local retry_delay=10
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if ~/.acme.sh/acme.sh --issue --server "${ACME_SERVER}" \
         -d "${domain}" \
         --standalone \
         -k ec-256; then
      log_success "证书申请成功"
      break
    else
      log_warn "证书申请异常，第 $attempt 次尝试失败..."
      if [ $attempt -eq $max_retries ]; then
        log_error "关键错误：证书申请尝试 3 次均失败"
        resume_interfering_processes
        return 1
      fi
      sleep $((retry_delay * 2 ** (attempt-1)))
      attempt=$((attempt+1))
    fi
  done

  # 安装证书（安装成功后依然恢复干涉进程）
  ~/.acme.sh/acme.sh --install-cert -d "${domain}" --ecc \
    --key-file "${CERT_DIR}/${domain}.key" \
    --fullchain-file "${CERT_DIR}/${domain}.crt" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书续期成功！请检查服务状态。' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

  if ! openssl x509 -in "${CERT_DIR}/${domain}.crt" -noout -subject -dates >/dev/null; then
    log_error "证书完整性校验失败"
    resume_interfering_processes
    return 1
  fi

  # 无论成功与否，都恢复之前被冻结进程
  resume_interfering_processes
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

  # 请将 "yourdomain.com" 替换为实际需要申请证书的域名
  certificate_orchestrator "yourdomain.com" || exit 1
}

main
