#!/bin/bash

# 检查并升级当前 Debian 或 Ubuntu 版本
echo "正在检查操作系统版本..."
OS_VERSION=$(lsb_release -si)
if [[ "$OS_VERSION" != "Debian" && "$OS_VERSION" != "Ubuntu" ]]; then
    echo "此脚本仅支持 Debian 或 Ubuntu 系统！"
    exit 1
fi

echo "当前系统为: $OS_VERSION"
echo "正在更新系统..."
sudo apt-get update && sudo apt-get upgrade -y

# 检查旧版本 Docker
if command -v docker > /dev/null; then
    echo "检测到旧版本 Docker，是否保留旧版本？（y/n），10秒后默认选择 'n' ..."
    read -t 10 KEEP_OLD
    if [[ "$KEEP_OLD" != "y" ]]; then
        echo "将停止现有正在运行的容器..."
        sudo docker ps -q | xargs -r sudo docker stop
        echo "正在卸载旧版本 Docker..."
        sudo apt-get remove -y docker docker-engine docker.io containerd runc
    else
        echo "保留旧版本 Docker."
    fi
else
    echo "未检测到旧版本 Docker."
fi

# 安装 Docker
echo "正在安装 Docker..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce

# 检查 Docker 安装是否成功
if ! command -v docker > /dev/null; then
    echo "Docker 安装失败，退出..."
    exit 1
fi

echo "Docker 安装成功！"

# 安装 Docker Compose
echo "正在安装 Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 2)
sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 检查 Docker Compose 安装是否成功
if ! command -v docker-compose > /dev/null; then
    echo "Docker Compose 安装失败，退出..."
    exit 1
fi

echo "Docker Compose 安装成功！"

# 完成
echo "Docker 和 Docker Compose 安装完成！"