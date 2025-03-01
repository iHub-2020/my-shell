#!/bin/bash
set -eo pipefail

# 配置区 ===========================================
CERT_DIR="/root/cert"                       # 证书存储目录
DEFAULT_EMAIL="admin@yourdomain.com"        # 管理员邮箱（用于账户注册和通知）
ACME_SERVER="letsencrypt"                   # 证书颁发机构
NOTICE_DAYS_BEFORE_EXPIRE=7                 # 证书过期提醒天数（暂未启用）
# =================================================

# 颜色定义
COLOR_INFO='\033[34m'
COLOR_SUCCESS='\033[32m'
COLOR_WARNING='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_RESET='\033[0m'

# 全局变量
TERMINATED_PROCESSES=()

# 日志函数
log_info() {
  echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"
}
log_success() {
  echo -e "${COLOR_SUCCESS}[SUCCESS] $*${COLOR_RESET}"
}
log_warn() {
  echo -e "${COLOR_WARNING}[WARNING] $*${COLOR_RESET}"
}
log_error() {
  echo -e "${COLOR_ERROR}[ERROR] $*${COLOR_RESET}" >&2
}

# 输入验证函数
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

# 端口管理函数（含 nginx 特殊处理）
check_port() {
  local port=$1
  log_info "【步骤X】检查端口 ${port} 占用情况..."

  local pids
  pids=$(lsof -i :"${port}" -sTCP:LISTEN -t 2>/dev/null)
  if [ -n "$pids" ]; then
    for pid in $pids; do
      if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log_warn "跳过无效PID: $pid"
        continue
      fi

      local proc_name
      proc_name=$(ps -p "$pid" -o comm= 2>/dev/null)
      if [ -z "$proc_name" ]; then
        log_warn "无法获取进程 $pid 的信息（可能已终止）"
        continue
      fi

      log_warn "端口 ${port} 被进程占用: ${proc_name} (PID: ${pid})"

      # 如果检测到 nginx 占用端口，提示是否停止 nginx 服务
      if [ "$proc_name" = "nginx" ]; then
        read -rp "检测到 nginx 占用端口 ${port}，是否停止 nginx 服务？[Y/n] " choice
        case "${choice:-Y}" in
          y|Y)
            log_info "正在停止 nginx 服务..."
            if systemctl stop nginx; then
              log_success "nginx 服务已停止"
            else
              log_error "停止 nginx 服务失败"
              exit 1
            fi
            ;;
          *)
            log_error "操作已取消，无法继续申请证书"
            exit 1
            ;;
        esac
      else
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
      fi
    done
  else
    log_success "端口 ${port} 可用"
  fi
}

restore_processes() {
  if [ ${#TERMINATED_PROCESSES[@]} -eq 0 ]; then
    return
  fi
  log_info "正在恢复被暂停的进程..."
  for pid in "${TERMINATED_PROCESSES[@]}"; do
    if kill -CONT "${pid}" >/dev/null 2>&1; then
      log_success "进程 ${pid} 已恢复运行"
    else
      log_warn "进程 ${pid} 恢复失败（可能已终止）"
    fi
  done
}

# 证书管理函数
setup_cert_dir() {
  log_info "【步骤6】初始化证书目录: ${CERT_DIR}"
  mkdir -p "${CERT_DIR}" && chmod 700 "${CERT_DIR}"
  log_success "证书目录准备完毕"
}

install_certificate() {
  local domain=$1
  local key_file=$2
  local crt_file=$3

  log_info "【步骤9】开始申请SSL证书（CA: ${ACME_SERVER}）..."
  if acme.sh --issue --server "${ACME_SERVER}" -d "${domain}" --standalone -k ec-256; then
    log_success "SSL证书申请成功"
  else
    log_error "SSL证书申请失败"
    exit 1
  fi

  log_info "【步骤9】安装证书到指定路径..."
  acme.sh --install-cert -d "${domain}" --ecc \
    --key-file "${CERT_DIR}/${key_file}" \
    --fullchain-file "${CERT_DIR}/${crt_file}" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书续期成功！' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

  if [[ -f "${CERT_DIR}/${key_file}" && -f "${CERT_DIR}/${crt_file}" ]]; then
    log_success "证书文件生成成功"
  else
    log_error "证书文件生成失败"
    exit 1
  fi
}

configure_auto_renew() {
  log_info "【步骤10】配置自动续期..."

  if acme.sh --upgrade --auto-upgrade; then
    log_success "自动更新已启用"
  else
    log_warn "自动更新启用失败，请检查acme.sh配置"
  fi

  if crontab -l 2>/dev/null | grep -q "acme.sh --cron"; then
    log_success "cron定时任务已存在"
  else
    (crontab -l 2>/dev/null; echo "0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\"") | crontab -
    log_success "cron定时任务添加成功"
  fi
}

install_acme_sh() {
  log_info "【步骤1】开始安装acme.sh..."
  local download_cmd=""
  if command -v curl >/dev/null; then
    download_cmd="curl -sSL"
  elif command -v wget >/dev/null; then
    download_cmd="wget -qO -"
  else
    log_error "请安装 curl 或 wget"
    exit 1
  fi
  if $download_cmd https://get.acme.sh | bash; then
    export PATH="$HOME/.acme.sh:$PATH"
    log_success "acme.sh安装成功"
  else
    log_error "acme.sh安装失败"
    exit 1
  fi
}

check_dependencies() {
  log_info "【步骤1】检查系统依赖..."
  command -v acme.sh >/dev/null 2>&1 || install_acme_sh
  for tool in lsof ps kill mkdir chmod; do
    if ! command -v $tool >/dev/null 2>&1; then
      log_error "缺少依赖: $tool"
      exit 1
    fi
  done
  log_success "所有依赖就绪"
}

# 主程序
main() {
  trap 'restore_processes' EXIT

  log_info "SSL Manager 脚本开始执行..."

  check_dependencies

  log_info "【步骤2】验证管理员邮箱：${DEFAULT_EMAIL}"
  validate_email "${DEFAULT_EMAIL}"

  log_info "【步骤3】获取用户输入..."
  read -rp "请输入申请证书的域名（例如：example.com）：" domain </dev/tty
  validate_domain "${domain}"

  read -rp "请输入私钥文件名（默认：${domain}.key）：" key_file </dev/tty
  key_file=${key_file:-"${domain}.key"}

  read -rp "请输入证书文件名（默认：${domain}.crt）：" crt_file </dev/tty
  crt_file=${crt_file:-"${domain}.crt"}

  log_info "【步骤4】开始检查端口..."
  check_port 80
  check_port 443

  log_info "【步骤5】准备证书存储目录..."
  setup_cert_dir

  log_info "【步骤7】注册ACME账户（如未注册）..."
  [ -f ~/.acme.sh/account.conf ] || acme.sh --register-account -m "${DEFAULT_EMAIL}"

  log_info "【步骤8】设置默认证书颁发机构..."
  acme.sh --set-default-ca --server "${ACME_SERVER}"

  install_certificate "${domain}" "${key_file}" "${crt_file}"

  configure_auto_renew

  log_success "【步骤11】SSL证书部署完成！证书文件存放于: ${CERT_DIR}/"
}

main "$@"
