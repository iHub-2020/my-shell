#!/bin/bash
set -eo pipefail

# 配置区 ===========================================
CERT_DIR="/root/cert"
DEFAULT_EMAIL="admin@yourdomain.com"
ACME_SERVER="letsencrypt"
NOTICE_DAYS_BEFORE_EXPIRE=7
# ================================================

COLOR_INFO='\033[34m'
COLOR_SUCCESS='\033[32m'
COLOR_WARNING='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_RESET='\033[0m'

TERMINATED_PROCESSES=()

log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS] $*${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}[WARNING] $*${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR] $*${COLOR_RESET}" >&2; }

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

check_port() {
  local port=$1
  log_info "正在检查端口 ${port} 占用情况..."

  local pids
  pids=$(lsof -i :"${port}" -sTCP:LISTEN -t 2>/dev/null)
  
  if [ -n "$pids" ]; then
    for pid in $pids; do
      if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log_warn "跳过无效PID: $pid"
        continue
      fi
      
      local process_info
      process_info=$(ps -p "$pid" -o comm=,pid= 2>/dev/null)
      
      if [ -z "$process_info" ]; then
        log_warn "无法获取进程 $pid 的信息（可能已终止）"
        continue
      fi
      
      log_warn "端口 ${port} 被进程占用: ${process_info}"
      
      read -rp "是否暂停该进程 (PID: ${pid})？[Y/n] " choice
      case "${choice:-Y}" in
        y|Y)
          log_info "正在暂停进程 ${pid}..."
          if kill -STOP "${pid}"; then
            TERMINATED_PROCESSES+=("${pid}")
            log_success "进程 ${pid} 已暂停"
          else
            log_error "进程暂停失败"
            exit 1
          fi
          ;;
        *)
          log_error "操作已取消"
          exit 1
          ;;
      esac
    done
  else
    log_success "端口 ${port} 可用"
  fi
}

restore_processes() {
  [[ ${#TERMINATED_PROCESSES[@]} -eq 0 ]] && return
  log_info "正在恢复被暂停的进程..."
  for pid in "${TERMINATED_PROCESSES[@]}"; do
    if kill -CONT "${pid}" >/dev/null 2>&1; then
      log_success "进程 ${pid} 已恢复运行"
    else
      log_warn "进程 ${pid} 恢复失败（可能已终止）"
    fi
  done
}

setup_cert_dir() {
  log_info "初始化证书目录: ${CERT_DIR}"
  mkdir -p "${CERT_DIR}" && chmod 700 "${CERT_DIR}"
  log_success "目录权限已设置"
}

install_certificate() {
  local domain=$1 key_file=$2 crt_file=$3
  log_info "开始申请SSL证书（CA: ${ACME_SERVER}）..."
  
  acme.sh --issue --server "${ACME_SERVER}" -d "${domain}" --standalone -k ec-256
  acme.sh --install-cert -d "${domain}" --ecc \
    --key-file "${CERT_DIR}/${key_file}" \
    --fullchain-file "${CERT_DIR}/${crt_file}" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书续期成功！' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

  [[ -f "${CERT_DIR}/${key_file}" && -f "${CERT_DIR}/${crt_file}" ]] || {
    log_error "证书文件未正确生成"
    exit 1
  }
}

configure_auto_renew() {
  acme.sh --upgrade --auto-upgrade
  crontab -l | grep -q "acme.sh --cron" || \
    (crontab -l 2>/dev/null; echo "0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\"") | crontab -
}

install_acme_sh() {
  command -v curl >/dev/null && download_cmd="curl -sSL" || download_cmd="wget -qO -"
  $download_cmd https://get.acme.sh | bash
  export PATH="$HOME/.acme.sh:$PATH"
}

check_dependencies() {
  command -v acme.sh >/dev/null 2>&1 || install_acme_sh
  for tool in lsof ps kill mkdir chmod; do
    command -v $tool >/dev/null || { log_error "缺少依赖: $tool"; exit 1; }
  done
}

main() {
  trap 'restore_processes' EXIT
  check_dependencies
  validate_email "${DEFAULT_EMAIL}"

  read -rp "请输入申请证书的域名：" domain
  validate_domain "${domain}"

  read -rp "请输入私钥文件名（默认：${domain}.key）：" key_file
  key_file=${key_file:-"${domain}.key"}

  read -rp "请输入证书文件名（默认：${domain}.crt）：" crt_file
  crt_file=${crt_file:-"${domain}.crt"}

  check_port 80
  check_port 443
  setup_cert_dir

  [ -f ~/.acme.sh/account.conf ] || acme.sh --register-account -m "${DEFAULT_EMAIL}"
  acme.sh --set-default-ca --server "${ACME_SERVER}"
  install_certificate "${domain}" "${key_file}" "${crt_file}"
  configure_auto_renew

  log_success "SSL证书部署完成！路径：${CERT_DIR}/"
}

main "$@"
