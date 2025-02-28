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

# 日志函数 ------------------------------------------------------
log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS] $*${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}[WARNING] $*${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR] $*${COLOR_RESET}" >&2; }

# 输入验证函数 --------------------------------------------------
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

# 端口管理函数 -------------------------------------------------
check_port() {
  local port=$1
  log_info "检查端口 ${port} 状态..."
  
  if pid=$(lsof -i :"${port}" -sTCP:LISTEN -t 2>/dev/null); then
    local process_info=$(ps -p "${pid}" -o comm=,pid=)
    log_warn "端口 ${port} 被占用: ${process_info}"
    
    read -rp "是否暂停此进程？[Y/n] " choice
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

# 证书管理函数 -------------------------------------------------
setup_cert_dir() {
  log_info "初始化证书目录: ${CERT_DIR}"
  mkdir -p "${CERT_DIR}" || {
    log_error "目录创建失败，请检查权限"
    exit 1
  }
  chmod 700 "${CERT_DIR}"
  log_success "目录权限已设置"
}

install_certificate() {
  local domain=$1 key_file=$2 crt_file=$3
  
  log_info "开始申请SSL证书（CA: ${ACME_SERVER}）..."
  
  if acme.sh --issue --server "${ACME_SERVER}" \
             -d "${domain}" \
             --standalone \
             -k ec-256; then
    log_success "证书申请成功"
  else
    log_error "证书申请失败"
    exit 1
  fi

  log_info "正在安装证书..."
  acme.sh --install-cert -d "${domain}" --ecc \
    --key-file "${CERT_DIR}/${key_file}" \
    --fullchain-file "${CERT_DIR}/${crt_file}" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书续期成功！请检查服务状态。' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

  [[ -f "${CERT_DIR}/${key_file}" && -f "${CERT_DIR}/${crt_file}" ]] || {
    log_error "证书文件未正确生成"
    exit 1
  }
}

# 自动续期配置 -------------------------------------------------
configure_auto_renew() {
  log_info "配置自动续期..."
  
  acme.sh --upgrade --auto-upgrade

  if ! crontab -l | grep -q "acme.sh --cron"; then
    (crontab -l 2>/dev/null; \
     echo "0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\"") | crontab -
  fi

  if crontab -l | grep -q "acme.sh --cron"; then
    log_success "自动续期已启用（每日0点检查）"
  else
    log_error "自动续期配置失败"
    exit 1
  fi
}

# 依赖检查函数 -------------------------------------------------
check_dependencies() {
  if ! command -v acme.sh &>/dev/null; then
    log_warn "自动安装 acme.sh..."
    install_acme_sh
  fi

  local required_tools=(lsof ps kill mkdir chmod)
  for tool in "${required_tools[@]}"; do
    if ! command -v $tool &>/dev/null; then
      log_error "系统缺少必要工具: $tool"
      exit 1
    fi
  done
}

install_acme_sh() {
  log_info "开始安装 acme.sh..."
  
  local BRANCH="master"
  local INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/$BRANCH/acme.sh"
  
  local download_cmd=""
  if command -v curl &>/dev/null; then
    download_cmd="curl -L"
  elif command -v wget &>/dev/null; then
    download_cmd="wget -O -"
  else
    log_error "需要 curl 或 wget 进行安装"
    exit 1
  fi

  if ! $download_cmd "$INSTALL_SCRIPT_URL" | sh -s -- --install-online; then
    log_error "acme.sh 安装失败"
    exit 1
  fi

  [ -f ~/.acme.sh/acme.sh ] || {
    log_error "安装验证失败"
    exit 1
  }
  
  log_success "acme.sh 安装完成"
  source ~/.bashrc
}

# 主程序 -------------------------------------------------------
main() {
  trap 'restore_processes' EXIT

  check_dependencies
  validate_email "${DEFAULT_EMAIL}"

  read -rp "请输入申请证书的域名（例如：example.com）：" domain
  validate_domain "${domain}"

  read -rp "私钥文件名（默认：${domain}.key）：" key_file
  key_file=${key_file:-"${domain}.key"}

  read -rp "证书文件名（默认：${domain}.crt）：" crt_file
  crt_file=${crt_file:-"${domain}.crt"}

  check_port 80
  check_port 443

  setup_cert_dir

  if [ ! -f ~/.acme.sh/account.conf ]; then
    acme.sh --register-account -m "${DEFAULT_EMAIL}"
  fi

  acme.sh --set-default-ca --server "${ACME_SERVER}"
  install_certificate "${domain}" "${key_file}" "${crt_file}"
  configure_auto_renew

  log_success "SSL证书部署完成！"
  echo -e "证书路径：\n私钥文件：${CERT_DIR}/${key_file}\n证书文件：${CERT_DIR}/${crt_file}"
}

main "$@"
