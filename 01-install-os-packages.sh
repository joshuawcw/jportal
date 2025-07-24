#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "--- Running Jportal.com - Modular Deployment Script 1/3 (Install OS Packages) ---"

echo "Updating system and installing core packages..."
sudo apt update -y
sudo apt upgrade -y

echo "Installing nginx, python3, postgresql, freeradius, docker, git, dos2unix and their dependencies..."
sudo apt install -y nginx python3 python3-pip python3-venv postgresql postgresql-contrib freeradius freeradius-postgresql docker.io docker-compose git curl dos2unix

echo "Script 1/3 completed successfully."
