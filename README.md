使用方法：


[ ! -d "docker-deployer" ] && git clone https://github.com/iHub-2020/docker-deployer.git && \
cd docker-deployer && \
chmod +x install_docker.sh && \
./install_docker.sh && \
cd .. && \
rm -rf docker-deployer || echo "目录 'docker-deployer' 已存在，跳过克隆。"
