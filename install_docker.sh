#!/bin/bash

# Author: Reyanmatic
# Version: 1.4

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
    echo "Detected old version of Docker. Do you want to keep it? (N/y), default is 'N' after 15 seconds ..."
    read -t 15 KEEP_OLD
    if [[ "$KEEP_OLD" != "y" ]]; then
        echo "Stopping existing running containers..."
        sudo docker ps -q | xargs -r sudo docker stop
        echo "Uninstalling old version of Docker..."
        sudo apt-get remove -y docker docker-engine docker.io containerd runc
    else
        echo "Keeping the old version of Docker."
    fi
else
    echo "No old version of Docker detected."
fi

# Install Docker
echo "Installing Docker..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# Determine the correct Docker repository based on OS
if [[ "$OS_VERSION" == "Ubuntu" ]]; then
    echo "Adding Docker's official GPG key and repository for Ubuntu..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
elif [[ "$OS_VERSION" == "Debian" ]]; then
    echo "Adding Docker's official GPG key and repository for Debian..."
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
    echo "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
fi

sudo apt-get update
sudo apt-get install -y docker-ce

# Check if Docker installation was successful
if ! command -v docker > /dev/null; then
    echo "Docker installation failed, exiting..."
    exit 1
fi

echo "Docker installation successful!"

# Display Docker Engine version
echo "Docker Engine version:"
docker --version

# Install Docker Compose
echo "Installing Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)

# Download Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

# Verify the download was successful
if [[ ! -s /usr/local/bin/docker-compose ]]; then
    echo "Failed to download Docker Compose, exiting..."
    exit 1
fi

# Make it executable
sudo chmod +x /usr/local/bin/docker-compose

# Check if Docker Compose installation was successful
if ! command -v docker-compose > /dev/null; then
    echo "Docker Compose installation failed, exiting..."
    exit 1
fi

echo "Docker Compose installation successful!"

# Display Docker Compose version
echo "Docker Compose version:"
docker-compose --version

# Clean up: Remove the script and the current directory
echo "Cleaning up..."
SCRIPT_PATH=$(realpath "$0") # 获取脚本的绝对路径
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# Delete the script
if [ -f "$SCRIPT_PATH" ]; then
    echo "Deleting script: $SCRIPT_PATH"
    rm "$SCRIPT_PATH"
else
    echo "Script $SCRIPT_PATH does not exist."
fi

# Check directory exists
if [ -d "$SCRIPT_DIR" ]; then
    echo "Removing directory: $SCRIPT_DIR"
    cd "$SCRIPT_DIR" || exit
    cd .. && rm -rf "$SCRIPT_DIR"
else
    echo "Directory $SCRIPT_DIR does not exist."
fi

# Output final versions of Docker and Docker Compose
echo "Final Docker version:"
docker --version
echo "Final Docker Compose version:"
docker-compose --version

echo "Docker and Docker Compose installation completed!"
