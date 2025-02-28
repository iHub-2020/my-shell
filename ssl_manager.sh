#!/bin/bash
set -eo pipefail

配置区（根据需求修改）===========================================
CERT_DIR="/root/cert" # 证书存储路径
DEFAULT_EMAIL="admin@yourdomain.com" # 管理员邮箱（接收通知）
ACME_SERVER="letsencrypt" # 证书颁发机构：letsencrypt/letsencrypt_test
NOTICE_DAYS_BEFORE_EXPIRE=7 # 证书过期前提醒天数

颜色定义
COLOR_INFO='\033[34m'
COLOR_SUCCESS='\033[32m'
COLOR_WARNING='\033[33m'
COLOR_ERROR='\033[31m'
COLOR_RESET='\033[0m'

全局变量
TERMINATED_PROCESSES=() # 用于通过 kill -STOP 暂停的进程
STOPPED_SERVICES=() # 用于记录通过 systemctl 停止的服务（如 nginx）

================================================================
日志函数 ------------------------------------------------------
log_info() { echo -e "${COLOR_INFO}[INFO] $${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS] $${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}[WARNING] $${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR] $${COLOR_RESET}" >&2; }

输入验证函数 --------------------------------------------------
validate_email() {
[[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+.[A-Za-z]{2,}$ ]] || {
log_error "邮箱格式无效: $1"
exit 1
}
}

validate_domain() {
[[ "$1" =~ ^([a-zA-Z0-9-]+.)+[a-zA-Z]{2,}$ ]] || {
log_error "域名格式无效: $1"
exit 1
}
}

端口管理函数 -------------------------------------------------
check_port() {
local port=$1
log_info "正在检查端口 ${port} 占用情况..."

if pid=$(lsof -i :"${port}" -sTCP:LISTEN -t 2>/dev/null); then
local process_info
process_info=$(ps -p "${pid}" -o comm=,pid=)
log_warn "端口 ${port} 被进程占用: ${process_info}"

awk

复制
# 如果占用进程为 nginx，则建议使用 systemctl 停止服务
if ps -p "${pid}" -o comm= | grep -q "nginx"; then
  read -rp "检测到 nginx 占用端口 ${port}，是否停止 nginx 服务？[Y/n] " choice < /dev/tty
  case "${choice:-Y}" in
    y|Y)
      log_info "正在停止 nginx 服务..."
      if systemctl stop nginx; then
        STOPPED_SERVICES+=("nginx")
        log_success "nginx 服务已停止"
      else
        log_error "nginx 停止失败"
        exit 1
      fi
      ;;
    *)
      log_error "操作已取消，无法继续申请证书"
      exit 1
      ;;
  esac
else
  # 对于其他进程使用 kill -STOP 冻结
  read -rp "是否暂停该进程 (PID: ${pid})？[Y/n] " choice < /dev/tty
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
else
log_success "端口 ${port} 可用"
fi
}

恢复停止或冻结的进程/服务 ---------------------------------------
restore_processes() {

如果曾使用 systemctl 停止了服务，则重启它们
if [ ${#STOPPED_SERVICES[@]} -gt 0 ]; then
log_info "正在启动之前停止的服务..."
for service in "${STOPPED_SERVICES[@]}"; do
if systemctl start "$service"; then
log_success "服务 $service 已启动"
else
log_warn "服务 $service 启动失败"
fi
done
fi

恢复之前通过 kill -STOP 暂停的进程
if [ ${#TERMINATED_PROCESSES[@]} -gt 0 ]; then
log_info "正在恢复被暂停的进程..."
for pid in "${TERMINATED_PROCESSES[@]}"; do
if kill -CONT "${pid}" >/dev/null 2>&1; then
log_success "进程 ${pid} 已恢复运行"
else
log_warn "进程 ${pid} 恢复失败（可能已终止）"
fi
done
fi
}

证书管理函数 -------------------------------------------------
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

申请证书
if acme.sh --issue --server "${ACME_SERVER}"
-d "${domain}"
--standalone
-k ec-256; then
log_success "证书申请成功"
else
log_error "证书申请失败"
exit 1
fi

安装证书
log_info "正在安装证书到指定路径..."
acme.sh --install-cert -d "${domain}" --ecc
--key-file "${CERT_DIR}/${key_file}"
--fullchain-file "${CERT_DIR}/${crt_file}"
--reloadcmd "systemctl reload nginx"
--renew-hook "echo '证书续期成功！请检查服务状态。' | mail -s '证书更新通知' ${DEFAULT_EMAIL}"

验证文件
if [[ -f "${CERT_DIR}/${key_file}" && -f "${CERT_DIR}/${crt_file}" ]]; then
log_success "证书文件生成成功"
else
log_error "证书文件未正确生成"
exit 1
fi
}

自动续期配置 -------------------------------------------------
configure_auto_renew() {
log_info "正在配置自动续期..."

启用自动更新
acme.sh --upgrade --auto-upgrade

添加cron任务
if ! crontab -l 2>/dev/null | grep -q "acme.sh --cron"; then
log_info "添加自动续期定时任务..."
(crontab -l 2>/dev/null;
echo "0 0 * * * "${HOME}/.acme.sh"/acme.sh --cron --home "${HOME}/.acme.sh"") | crontab -
fi

验证配置
if crontab -l 2>/dev/null | grep -q "acme.sh --cron"; then
log_success "自动续期已启用（每日0点检查）"
else
log_error "自动续期配置失败！"
exit 1
fi
}

自动安装acme.sh模块 -------------------------------------------------
install_acme_sh() {
log_info "开始自动安装acme.sh..."

选择下载工具
local download_cmd
if command -v curl >/dev/null; then
download_cmd="curl -sSL"
elif command -v wget >/dev/null; then
download_cmd="wget -qO -"
else
log_error "需要 curl 或 wget 来执行安装"
exit 1
fi

执行安装流程
if $download_cmd https://get.acme.sh | bash -s -- ; then
export PATH="$HOME/.acme.sh:$PATH"
source ~/.bashrc >/dev/null 2>&1
if ! command -v acme.sh >/dev/null; then
log_error "acme.sh未正确安装"
exit 1
fi
log_success "acme.sh安装完成"
else
log_error "acme.sh安装失败"
exit 1
fi
}

依赖检查 -----------------------------------------------------
check_dependencies() {

检查acme.sh
if ! command -v acme.sh >/dev/null 2>&1; then
install_acme_sh
fi

检查系统工具
local required_tools=(lsof ps kill mkdir chmod)
for tool in "${required_tools[@]}"; do
if ! command -v "$tool" >/dev/null; then
log_error "缺少系统依赖: $tool"
exit 1
fi
done
}

主程序 -------------------------------------------------------
main() {
trap 'restore_processes' EXIT

依赖检查
check_dependencies

邮箱验证
validate_email "${DEFAULT_EMAIL}"

用户输入（确保从终端获取交互信息）
read -rp "请输入申请证书的域名（例如：example.com）： " domain < /dev/tty
validate_domain "${domain}"

read -rp "请输入私钥文件名（默认：${domain}.key）： " key_file < /dev/tty
key_file=${key_file:-"${domain}.key"}

read -rp "请输入证书文件名（默认：${domain}.crt）： " crt_file < /dev/tty
crt_file=${crt_file:-"${domain}.crt"}

端口检查
check_port 80
check_port 443

初始化环境
setup_cert_dir

注册账户（首次需要）
if [ ! -f ~/.acme.sh/account.conf ]; then
log_info "注册ACME账户..."
acme.sh --register-account -m "${DEFAULT_EMAIL}"
fi

设置证书颁发机构
acme.sh --set-default-ca --server "${ACME_SERVER}"

申请安装证书
install_certificate "${domain}" "${key_file}" "${crt_file}"

配置自动续期
configure_auto_renew

log_success "SSL证书部署完成！"
echo -e "证书路径：\n私钥文件：${CERT_DIR}/${key_file}\n证书文件：${CERT_DIR}/${crt_file}"
}

执行入口
main "$@"
