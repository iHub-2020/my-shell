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
DOMAIN=""
# ================================================================

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
  log_info "正在检查端口 ${port} 占用情况..."
  
  if pid=$(lsof -i :"${port}" -sTCP:LISTEN -t 2>/dev/null); then
    local process_info
    process_info=$(ps -p "${pid}" -o comm=,pid=)
    log_warn "端口 ${port} 被进程占用: ${process_info}"
    
    read -rp "是否暂停此进程？[Y/n] " choice
    case "${choice:-Y}" in
      y|Y)
        log_info "正在暂停进程 ${pid}..."
        if kill -STOP "${pid}"; then
          TERMINATED_PROCESSES+=("${pid}")
          log_success "进程 ${pid} 已暂停"
        else
          log_error "进程暂停失败"
          return 1
        fi
        ;;
      *)
        log_error "操作已取消"
        return 1
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
  
  # 申请证书（增加重试机制）
  for i in {1..3}; do
    if ~/.acme.sh/acme.sh --issue --server "${ACME_SERVER}" \
               -d "${domain}" \
               --standalone \
               -k ec-256; then
      log_success "证书申请成功"
      break
    else
      log_warn "证书申请失败，第${i}次重试..."
      sleep 5
      [[ $i -eq 3 ]] && log_error "证书申请失败" && return 1
    fi
  done

  # 安装证书
  log_info "正在安装证书到指定路径..."
  ~/.acme.sh/acme.sh --install-cert -d "${domain}" --ecc \
    --key-file "${CERT_DIR}/${key_file}" \
    --fullchain-file "${CERT_DIR}/${crt_file}" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书续期成功！请检查服务状态。' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

  # 验证文件
  [[ -f "${CERT_DIR}/${key_file}" && -f "${CERT_DIR}/${crt_file}" ]] || {
    log_error "证书文件未正确生成"
    return 1
  }
}

# 自动续期配置 -------------------------------------------------
configure_auto_renew() {
  log_info "正在配置自动续期..."
  
  ~/.acme.sh/acme.sh --upgrade --auto-upgrade

  if ! crontab -l | grep -q "acme.sh --cron"; then
    log_info "添加自动续期定时任务..."
    (crontab -l 2>/dev/null; \
     echo "0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\"") | crontab -
  fi

  if crontab -l | grep -q "acme.sh --cron"; then
    log_success "自动续期已启用（每日0点检查）"
  else
    log_error "自动续期配置失败！"
    return 1
  fi
}

# 自动安装模块 -------------------------------------------------
install_acme_sh() {
  log_info "开始自动安装acme.sh..."
  
  # 安装系统依赖
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl lsof procps

  # 执行标准安装
  if curl -sSL https://get.acme.sh | bash -s -- ; then
    log_success "acme.sh安装完成"
  else
    log_error "acme.sh安装失败"
    return 1
  fi
}

# 主程序 -------------------------------------------------------
main() {
  trap 'restore_processes' EXIT

  # 检查root权限
  [[ $EUID -ne 0 ]] && log_error "必须使用root权限运行" && exit 1

  # 自动安装
  install_acme_sh || exit 1

  # 邮箱验证
  validate_email "${DEFAULT_EMAIL}" || exit 1

  # 用户输入
  read -rp "请输入申请证书的域名（例如：example.com）：" DOMAIN
  validate_domain "${DOMAIN}" || exit 1

  # 端口检查
  check_port 80 || exit 1
  check_port 443 || exit 1

  # 初始化环境
  setup_cert_dir || exit 1

  # 账户注册
  if [ ! -f ~/.acme.sh/account.conf ]; then
    log_info "注册ACME账户..."
    ~/.acme.sh/acme.sh --register-account -m "${DEFAULT_EMAIL}" || exit 1
  fi

  # 设置CA
  ~/.acme.sh/acme.sh --set-default-ca --server "${ACME_SERVER}" || exit 1

  # 申请证书
  install_certificate "${DOMAIN}" "${DOMAIN}.key" "${DOMAIN}.crt" || exit 1
  
  # 配置续期
  configure_auto_renew || exit 1

  # 输出结果
  log_success "SSL证书部署完成！"
  echo -e "证书路径：\n私钥文件：${CERT_DIR}/${DOMAIN}.key\n证书文件：${CERT_DIR}/${DOMAIN}.crt"
}

# 执行入口
main
