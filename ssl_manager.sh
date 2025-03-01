#!/bin/bash
set -eo pipefail

# ==================== 配置区 ====================
CERT_DIR="/root/cert"                       # 证书存储目录
DEFAULT_EMAIL="admin@yourdomain.com"        # 管理员邮箱
ACME_SERVER="letsencrypt"                   # 证书颁发机构
# ================================================

# 颜色定义
COLOR_STEP='\033[35m'    # 步骤提示-紫色
COLOR_INFO='\033[34m'     # 常规信息-蓝色
COLOR_SUCCESS='\033[32m' # 成功-绿色
COLOR_WARNING='\033[33m' # 警告-黄色
COLOR_ERROR='\033[31m'    # 错误-红色
COLOR_RESET='\033[0m'     # 重置颜色

# 全局状态变量
declare -A SERVICE_STATUS  # 记录服务状态
CERT_ISSUED=0

# ==================== 可视化步骤函数 ====================
step_begin() {
  echo -e "${COLOR_STEP}
============================================================
[STEP $1] $2
============================================================
${COLOR_RESET}"
}

step_detail() {
  echo -e "${COLOR_INFO}  ↳ $1${COLOR_RESET}"
}

success_mark() {
  echo -e "${COLOR_SUCCESS}  ✓ $1${COLOR_RESET}"
}

error_mark() {
  echo -e "${COLOR_ERROR}  ✗ $1${COLOR_RESET}"
}

# ==================== 核心功能模块 ====================

# 模块1：系统环境预检
pre_check() {
  step_begin 1 "系统环境预检"
  
  # 1.1 权限检查
  step_detail "验证root权限"
  [ "$(id -u)" -ne 0 ] && {
    error_mark "必须使用root权限运行"
    exit 1
  }
  success_mark "权限验证通过"

  # 1.2 依赖检查
  step_detail "检查系统依赖"
  required_commands=(curl ss systemctl lsof)
  missing_counter=0
  for cmd in "${required_commands[@]}"; do
    if ! command -v $cmd &>/dev/null; then
      error_mark "缺少依赖: $cmd"
      ((missing_counter++))
    fi
  done
  
  [ $missing_counter -gt 0 ] && {
    error_mark "缺少 $missing_counter 个关键依赖"
    exit 1
  }
  success_mark "所有依赖已满足"
}

# 模块2：智能服务管理
manage_services() {
  step_begin 2 "服务状态管理"

  # 2.1 检测并停止Nginx
  step_detail "处理Nginx服务"
  if systemctl is-active --quiet nginx; then
    read -rp "  检测到Nginx运行中，是否停止服务？[Y/n] " choice </dev/tty
    if [[ "${choice:-Y}" =~ ^[Yy]$ ]]; then
      if systemctl stop nginx; then
        SERVICE_STATUS["nginx"]="stopped"
        success_mark "Nginx服务已停止"
      else
        error_mark "Nginx停止失败"
        exit 1
      fi
    else
      error_mark "用户选择保持Nginx运行"
      exit 1
    fi
  else
    success_mark "Nginx服务未运行"
  fi

  # 2.2 检查其他服务
  step_detail "检查其他端口占用"
  for port in 80 443; do
    local pids=$(ss -ltnpH "sport = :$port" | awk '{print $6}' | cut -d, -f2 | sort -u)
    [ -z "$pids" ] && continue
    
    for pid in $pids; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if [ "$pid" != "1" ]; then  # 排除init进程
        error_mark "发现非服务进程占用端口 $port (PID:$pid)"
        exit 1
      fi
    done
  done
}

# 模块3：证书签发流程
issue_certificate() {
  step_begin 3 "证书签发"
  
  # 3.1 域名输入
  while true; do
    read -rp "请输入申请证书的完整域名：" domain </dev/tty
    if [[ "$domain" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
      break
    else
      error_mark "域名格式无效，请重新输入"
    fi
  done

  # 3.2 签发证书
  step_detail "启动证书签发"
  for i in {1..3}; do
    if ~/.acme.sh/acme.sh --issue --server $ACME_SERVER \
       -d "$domain" \
       --standalone \
       -k ec-256; then
      CERT_ISSUED=1
      success_mark "证书签发成功"
      break
    else
      [[ $i -eq 3 ]] && {
        error_mark "证书签发失败（已尝试3次）"
        return 1
      }
      step_detail "第${i}次重试..."
      sleep $((i*5))
    fi
  done

  # 3.3 安装证书
  step_detail "安装证书文件"
  mkdir -p "$CERT_DIR" && chmod 700 "$CERT_DIR"
  ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --key-file "$CERT_DIR/${domain}.key" \
    --fullchain-file "$CERT_DIR/${domain}.crt" \
    --reloadcmd "systemctl reload nginx" \
    --renew-hook "echo '证书已更新' | mail -s '证书通知' $DEFAULT_EMAIL"
  success_mark "证书安装完成"
}

# 模块4：环境恢复
restore_environment() {
  step_begin 4 "环境恢复"

  # 4.1 重启Nginx服务
  if [[ "${SERVICE_STATUS[nginx]}" == "stopped" ]] && [ $CERT_ISSUED -eq 1 ]; then
    step_detail "重启Nginx服务"
    if systemctl start nginx; then
      success_mark "Nginx服务已恢复"
    else
      error_mark "Nginx启动失败"
    fi
  fi
}

# ==================== 主程序 ====================
main() {
  trap 'restore_environment' EXIT
  pre_check
  manage_services
  issue_certificate
}

main "$@"
