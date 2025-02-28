#!/bin/bash

# 存储被终止的进程信息
TERMINATED_PROCESSES=()

# 检查80和443端口是否被占用，并提示是否终止进程
check_ports_and_handle() {
  local PORT=$1
  echo "正在检查端口 $PORT 是否被占用..."
  
  # 检查端口是否被占用
  if lsof -i :$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "警告：端口 $PORT 已被占用！"
    
    # 检测占用端口的进程信息
    local PID=$(lsof -i :$PORT -sTCP:LISTEN -t)
    local PROCESS_NAME=$(ps -p $PID -o comm=)
    echo "占用端口 $PORT 的进程是：$PROCESS_NAME (PID: $PID)"
    
    # 提示用户是否终止进程
    read -p "是否终止该进程？(输入 Y 终止，否则按回车跳过): " TERMINATE
    if [[ "$TERMINATE" == "Y" ]]; then
      echo "正在终止进程 $PROCESS_NAME (PID: $PID)..."
      kill -STOP $PID  # 暂停进程（而非直接杀死）
      TERMINATED_PROCESSES+=("$PID")
      echo "进程 $PROCESS_NAME (PID: $PID) 已被暂停。"
    else
      echo "未终止进程 $PROCESS_NAME (PID: $PID)，请自行处理。"
      exit 1
    fi
  else
    echo "端口 $PORT 未被占用，继续执行..."
  fi
}

# 恢复被暂停的进程
restore_processes() {
  if [[ ${#TERMINATED_PROCESSES[@]} -gt 0 ]]; then
    echo "正在恢复之前被终止的进程..."
    for PID in "${TERMINATED_PROCESSES[@]}"; do
      if kill -CONT $PID >/dev/null 2>&1; then
        echo "进程 PID: $PID 已恢复。"
      else
        echo "进程 PID: $PID 恢复失败，请手动检查。"
      fi
    done
  fi
}

# 主流程
main() {
  # 检查 acme.sh 是否已安装
  if ! [ -x "$(command -v acme.sh)" ]; then
    echo "acme.sh 未安装，请先安装 acme.sh！"
    echo "安装命令：curl https://get.acme.sh | sh"
    exit 1
  fi

  # 设置默认邮箱
  DEFAULT_EMAIL="test@gmail.com"
  echo "默认邮箱已设置为: $DEFAULT_EMAIL"
  ~/.acme.sh/acme.sh --register-account -m $DEFAULT_EMAIL

  # 检查80和443端口占用
  check_ports_and_handle 80
  check_ports_and_handle 443

  # 交互式输入域名、.key 和 .crt 文件名称
  read -p "请输入您要申请证书的域名: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "域名不能为空！"
    exit 1
  fi

  read -p "请输入私钥文件名 (默认: private.key): " KEY_FILE
  KEY_FILE=${KEY_FILE:-private.key}

  read -p "请输入证书文件名 (默认: cert.crt): " CRT_FILE
  CRT_FILE=${CRT_FILE:-cert.crt}

  # 设置默认 CA 为 Let's Encrypt
  acme.sh --set-default-ca --server letsencrypt

  # 申请证书
  echo "正在申请域名 $DOMAIN 的证书..."
  acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
  local ISSUE_STATUS=$?

  # 创建目标目录并安装证书
  if [ $ISSUE_STATUS -eq 0 ]; then
    CERT_DIR="/root/cert"
    mkdir -p "$CERT_DIR"

    acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CERT_DIR/$KEY_FILE" \
      --fullchain-file "$CERT_DIR/$CRT_FILE"

    echo "证书申请成功！"
    echo "私钥路径: $CERT_DIR/$KEY_FILE"
    echo "证书路径: $CERT_DIR/$CRT_FILE"
  else
    echo "证书申请失败，请检查日志！"
  fi

  # 恢复被暂停的进程
  restore_processes
}

# 捕获脚本退出信号，确保恢复被暂停的进程
trap restore_processes EXIT

# 执行主流程
main
