#!/bin/bash
set -eo pipefail

# 配置区（根据需求修改）===========================================
CERT_DIR="/root/cert"                  # 证书存储路径
DEFAULT_EMAIL="admin@yourdomain.com"   # 管理员邮箱（接收通知）
ACME_SERVER="letsencrypt"              # 证书颁发机构：letsencrypt/letsencrypt_test
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

# 日志函数 ------------------------------------------------------
log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS] $*${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}[WARNING] $*${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR] $*${COLOR_RESET}" >&2; }

# 新增的自动安装函数 --------------------------------------------
install_acme_sh() {
  log_info "开始自动安装acme.sh..."
  
  # 选择下载工具
  if command -v curl >/dev/null 2>&1; then
    _get="curl -L"
  elif command -v wget >/dev/null 2>&1; then
    _get="wget -O -"
  else
    log_error "需要 curl 或 wget 来执行安装"
    exit 1
  fi

  # 执行安装流程
  if ! $_get https://get.acme.sh | sh -s -- --install-online; then
    log_error "acme.sh安装失败"
    exit 1
  fi
  
  # 刷新环境变量
  source ~/.bashrc
  log_success "acme.sh安装完成"
}

# 修改后的依赖检查部分 ------------------------------------------
check_dependencies() {
  # 检查acme.sh
  if ! command -v acme.sh >/dev/null 2>&1; then
    install_acme_sh
  fi

  # 检查系统工具
  local required_tools=(lsof ps kill mkdir chmod)
  for tool in "${required_tools[@]}"; do
    if ! command -v $tool >/dev/null; then
      log_error "缺少系统依赖: $tool"
      exit 1
    fi
  done
}

# 原有其他函数保持不变（validate_email、validate_domain、check_port等）...
# [...] 此处保持原有函数代码不变

# 修改后的主程序 ------------------------------------------------
main() {
  trap 'restore_processes' EXIT

  # 依赖检查（新增自动安装）
  check_dependencies

  # 原有流程保持不变
  validate_email "${DEFAULT_EMAIL}"

  read -rp "请输入申请证书的域名（例如：example.com）：" domain
  validate_domain "${domain}"

  read -rp "请输入私钥文件名（默认：${domain}.key）：" key_file
  key_file=${key_file:-"${domain}.key"}

  read -rp "请输入证书文件名（默认：${domain}.crt）：" crt_file
  crt_file=${crt_file:-"${domain}.crt"}

  check_port 80
  check_port 443

  setup_cert_dir

  if [ ! -f ~/.acme.sh/account.conf ]; then
    log_info "注册ACME账户..."
    acme.sh --register-account -m "${DEFAULT_EMAIL}"
  fi

  acme.sh --set-default-ca --server "${ACME_SERVER}"

  install_certificate "${domain}" "${key_file}" "${crt_file}"
  
  configure_auto_renew

  log_success "SSL证书部署完成！"
  echo -e "证书路径：\n私钥文件：${CERT_DIR}/${key_file}\n证书文件：${CERT_DIR}/${crt_file}"
}

main "$@"
