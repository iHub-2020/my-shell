#!/bin/bash

# Author: Reyanmatic
# Version: 2.7

# Function to clean up script and directory
cleanup() {
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
    if [ -d "$SCRIPT_DIR" ] && [ "$SCRIPT_DIR" != "$HOME" ]; then
        echo "Removing directory: $SCRIPT_DIR"
        cd "$SCRIPT_DIR" || exit
        cd .. && rm -rf "$SCRIPT_DIR"
    else
        echo "Directory $SCRIPT_DIR does not exist or is the home directory."
    fi

    echo "Docker and Docker Compose installation completed!"
}

# Ensure cleanup is called on script exit
trap cleanup EXIT

# Function to wait for apt lock release
wait_for_apt() {
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo "Waiting for other apt processes to finish..."
        sleep 5
    done
}

# Check and upgrade the current Debian or Ubuntu version
echo "Checking the operating system version..."
OS_VERSION=$(lsb_release -si)
if [[ "$OS_VERSION" != "Debian" && "$OS_VERSION" != "Ubuntu" ]]; then
    echo "This script only supports Debian or Ubuntu systems!"
    exit 1
fi

echo "Current system: $OS_VERSION"
echo "Updating the system..."
wait_for_apt
sudo apt-get update && sudo apt-get upgrade -y

# Ensure git is installed
if ! command -v git > /dev/null; then
    echo "Git is not installed. Installing Git..."

    # Check for running apt processes
    wait_for_apt

    # Force release of APT locks
    echo "Releasing APT locks..."
    sudo rm -f /var/lib/dpkg/lock-frontend
    sudo rm -f /var/lib/dpkg/lock
    sudo rm -f /var/cache/apt/archives/lock

    # Reconfigure package manager
    echo "Reconfiguring package manager..."
    sudo dpkg --configure -a

    # Update package list
    echo "Updating package list..."
    sudo apt update

    # Install git
    echo "Installing git..."
    sudo apt install -y git
fi

# Check for old Docker version
if command -v docker > /dev/null; then
    echo "Detected old version of Docker. Do you want to keep it? (N/y), default is 'N' after 15 seconds ..."
    read -t 15 KEEP_OLD
    if [[ "$KEEP_OLD" != "y" ]]; then
        wait_for_apt
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
wait_for_apt
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

wait_for_apt
sudo apt-get update
wait_for_apt
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Check if Docker installation was successful
if ! command -v docker > /dev/null; then
    echo "Docker installation failed, exiting..."
    exit 1
fi

echo "Docker installation successful!"

# Display Docker Engine version
DOCKER_VERSION=$(docker --version)
echo "Docker Engine version: $DOCKER_VERSION"

# Install Docker Compose using Docker's official plugin method
echo "Installing Docker Compose..."
wait_for_apt
sudo apt-get install -y docker-compose-plugin

# Check if Docker Compose installation was successful
if ! docker compose version > /dev/null 2>&1; then
    echo "Docker Compose installation failed, but continuing to cleanup..."
else
    echo "Docker Compose installation successful!"
    # Display Docker Compose version
    DOCKER_COMPOSE_VERSION_OUTPUT=$(docker compose version)
    echo "Docker Compose version: $DOCKER_COMPOSE_VERSION_OUTPUT"
fi

# Output final versions of Docker and Docker Compose
echo "Final Docker version: $DOCKER_VERSION"
echo "Final Docker Compose version: ${DOCKER_COMPOSE_VERSION_OUTPUT:-"Not installed"}"

# Clean up: Remove the script and the current directory
cleanup
