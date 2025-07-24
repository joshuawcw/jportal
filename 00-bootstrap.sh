#!/bin/bash
set -e

# --- Configuration (EDIT THIS SCRIPT ON YOUR HOST BEFORE UPLOADING TO GITHUB!) ---
# This is the base URL where your modular scripts (01, 02, 03) are hosted.
# REPLACE THIS with the RAW URL to the 'main' branch of your GitHub repository.
GITHUB_RAW_URL_BASE="https://raw.githubusercontent.com/joshuawcw/jportal/main" # Example: https://raw.githubusercontent.com/YourUsername/jportal-deploy/main

# Get VM_IP_ADDRESS from command line argument
VM_IP_ADDRESS="$1"
if [ -z "$VM_IP_ADDRESS" ]; then
    echo "ERROR: VM_IP_ADDRESS not provided."
    echo "Usage: curl -fsSL ${GITHUB_RAW_URL_BASE}/00-bootstrap.sh | bash -s -- <YOUR_VM_IP_ADDRESS>"
    exit 1
fi

echo "█████████████████████████████████████████████████████████████"
echo "██                                                         ██"
echo "██      Jportal.com - Unified Bootstrap Installer          ██"
echo "██            (Downloads & Executes Modular Scripts)       ██"
echo "█████████████████████████████████████████████████████████████"
echo ""
echo "VM IP Address: $VM_IP_ADDRESS"
echo "Scripts will be downloaded from: $GITHUB_RAW_URL_BASE"
echo ""

# Auto-generate secrets (these will be passed to subsequent scripts)
echo "Generating secure passwords and keys..."
DB_PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9-_!@#$%^&*()_+' | head -c 32 ; echo)
RADIUS_SHARED_SECRET=$(head /dev/urandom | tr -dc 'A-Za-z0-9-_!@#$%^&*()_+' | head -c 32 ; echo)
DJANGO_SECRET_KEY=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
echo "Secrets generated."

# Create a temporary directory for scripts
TMP_SCRIPT_DIR=$(mktemp -d -t jportal-XXXXXXXXXX)
echo "Downloading scripts to temporary directory: $TMP_SCRIPT_DIR"
cd "$TMP_SCRIPT_DIR"

# Download modular scripts
echo "Downloading 01-install-os-packages.sh..."
curl -fsSL "${GITHUB_RAW_URL_BASE}/01-install-os-packages.sh" -o 01-install-os-packages.sh
echo "Downloading 02-configure-docker-postgres-freeradius.sh..."
curl -fsSL "${GITHUB_RAW_URL_BASE}/02-configure-docker-postgres-freeradius.sh" -o 02-configure-docker-postgres-freeradius.sh
echo "Downloading 03-deploy-django-app.sh..."
curl -fsSL "${GITHUB_RAW_URL_BASE}/03-deploy-django-app.sh" -o 03-deploy-django-app.sh

# Make them executable
chmod +x 01-install-os-packages.sh 02-configure-docker-postgres-freeradius.sh 03-deploy-django-app.sh
echo "Scripts downloaded and made executable."

# Execute scripts sequentially, passing secrets and VM_IP_ADDRESS as environment variables
echo "--- Running Script 1/3: 01-install-os-packages.sh ---"
./01-install-os-packages.sh
echo "Script 1/3 completed."

echo "--- Running Script 2/3: 02-configure-docker-postgres-freeradius.sh ---"
DB_PASSWORD="$DB_PASSWORD" RADIUS_SHARED_SECRET="$RADIUS_SHARED_SECRET" ./02-configure-docker-postgres-freeradius.sh
echo "Script 2/3 completed."

echo "--- Running Script 3/3: 03-deploy-django-app.sh ---"
DB_PASSWORD="$DB_PASSWORD" RADIUS_SHARED_SECRET="$RADIUS_SHARED_SECRET" DJANGO_SECRET_KEY="$DJANGO_SECRET_KEY" VM_IP_ADDRESS="$VM_IP_ADDRESS" ./03-deploy-django-app.sh
echo "Script 3/3 completed."

# Clean up temporary directory
echo "Cleaning up temporary scripts directory: $TMP_SCRIPT_DIR"
rm -rf "$TMP_SCRIPT_DIR"

echo ""
echo "█████████████████████████████████████████████████████████████"
echo "██                                                         ██"
echo "██    Jportal.com - Full Deployment Completed!             ██"
echo "██                                                         ██"
echo "█████████████████████████████████████████████████████████████"
echo ""
echo "You can now access your Jportal.com development environment:"
echo "- **Django Admin:** http://${VM_IP_ADDRESS}/admin/"
echo "- **Jportal Portal (placeholder):** http://${VM_IP_ADDRESS}/portal/"
echo "- **Jportal Admin Portal (placeholder):** http://${VM_IP_ADDRESS}/admin-portal/"
echo "- **Jportal Auth Management (placeholder):** http://${VM_IP_ADDRESS}/auth-mgmt/"
echo ""
echo "Remember your Django Superuser credentials created during the last step."
echo "You can check service status with 'docker-compose ps' or 'sudo systemctl status freeradius'."
echo "To stop services: 'docker-compose down' (from /home/administrator/jportal_project)"
echo "To restart services: 'docker-compose restart' (from /home/administrator/jportal_project)"
