# Docker-Shell

![GitHub Stars](https://img.shields.io/github/stars/iHub-2020/docker-shell?style=social)
![GitHub Forks](https://img.shields.io/github/forks/iHub-2020/docker-shell?style=social)
![GitHub Issues](https://img.shields.io/github/issues/iHub-2020/docker-shell)
![GitHub License](https://img.shields.io/github/license/iHub-2020/docker-shell)

一个自动安装 Docker Engine 和 Docker Compose 的一键脚本。

## 功能介绍

自动检测并升级当前系统（支持 Debian 和 Ubuntu）  
检查并可选卸载旧版本的 Docker  
安装最新版本的 Docker Engine  
安装最新版本的 Docker Compose  

## 使用方法

只需执行以下命令：

```sh
git clone https://github.com/iHub-2020/docker-shell.git && cd docker-shell && chmod +x install_docker.sh && ./install_docker.sh
