#!/bin/bash

# Check and upgrade the current Debian or Ubuntu version
echo "Checking the operating system version..."
OS_VERSION=$(lsb_release -si)
if [[ "$OS_VERSION" != "Debian" && "$OS_VERSION" != "Ubuntu" ]]; then
    echo "This script only supports Debian or Ubuntu systems!"
    exit 1
fi

echo "Current system: $OS_VERSION"
echo "Updating the system..."
sudo apt-get update && sudo apt-get upgrade -y

# Check for old Docker version
if command -v docker > /dev/null; then
    echo "Detected old version of Docker, do you want to keep it? (y/n), default is 'n' after 10 seconds ..."
    read -t 10 KEEP_OLD
    if [[ "$KEEP_OLD" != "y" ]]; then
        echo "Stopping existing running containers..."
        sudo docker ps -q | xargs -r sudo docker stop
        echo "Uninstalling old version of Docker..."
        sudo apt-get remove -y docker docker-engine docker.io containerd runc
    else
        echo "Keeping old version of Docker."
    fi
else
    echo "No old version of Docker detected."
fi

# Install Docker
echo "Installing Docker..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce

# Check if Docker installation was successful
if ! command -v docker > /dev/null; then
    echo "Docker installation failed, exiting..."
    exit 1
fi

echo "Docker installation successful!"

# Install Docker Compose
echo "Installing Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 2)
sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Check if Docker Compose installation was successful
if ! command -v docker-compose > /dev/null; then
    echo "Docker Compose installation failed, exiting..."
    exit 1
fi

echo "Docker Compose installation successful!"

# Completion
echo "Docker and Docker Compose installation completed!"
