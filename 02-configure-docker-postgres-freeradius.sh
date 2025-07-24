#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "--- Running Jportal.com - Modular Deployment Script 2/3 (Configure Services) ---"

# Secrets passed from bootstrap script as environment variables
# DB_PASSWORD - provided as env var
# RADIUS_SHARED_SECRET - provided as env var

# FreeRADIUS configuration paths
FR_MODS_PATH="/etc/freeradius/3.0/mods-available"
FR_ENABLED_PATH="/etc/freeradius/3.0/mods-enabled"
FR_CLIENTS_CONF="/etc/freeradius/3.0/clients.conf"
FR_DEFAULT_SITE="/etc/freeradius/3.0/sites-available/default"
FR_SQL_SCHEMA_DIR="/etc/freeradius/3.0/mods-config/sql/main/postgresql"

echo "--- Configuring Docker and user permissions ---"
echo "Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker
echo "Adding current user ('$USER') to 'docker' group if not already added..."
if ! getent group docker | grep -q "\b$USER\b"; then
    sudo usermod -aG docker "$USER"
    echo "User '$USER' added to 'docker' group."
    echo "IMPORTANT: For Docker commands to work without 'sudo' *immediately*, you might need to LOG OUT of this SSH session and LOG BACK IN, then re-run the FULL BOOTSTRAP SCRIPT (00-bootstrap.sh)."
else
    echo "User '$USER' is already in 'docker' group."
fi
echo ""

echo "--- Configuring PostgreSQL ---"
# Check if database already exists to avoid errors on re-run
if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "jportal_db"; then
    echo "Creating PostgreSQL database 'jportal_db' and user 'jportal_user'..."
    sudo -u postgres psql -c "CREATE DATABASE jportal_db;"
    sudo -u postgres psql -c "CREATE USER jportal_user WITH PASSWORD '$DB_PASSWORD';"
    sudo -u postgres psql -c "ALTER ROLE jportal_user SET client_encoding TO 'utf8';"
    sudo -u postgres psql -c "ALTER ROLE jportal_user SET default_transaction_isolation TO 'read committed';"
    sudo -u postgres psql -c "ALTER ROLE jportal_user SET timezone TO 'UTC';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE jportal_db TO jportal_user;"
else
    echo "PostgreSQL database 'jportal_db' already exists. Skipping creation."
fi

# Find the actual PostgreSQL config file paths using psql
echo "Detecting PostgreSQL configuration file paths using psql..."
PG_CONF_PATH_FULL=$(sudo -u postgres psql -t -P format=unaligned -c 'SHOW config_file;' 2>/dev/null | tr -d '\r' || true)
PG_HBA_CONF_PATH_FULL=$(sudo -u postgres psql -t -P format=unaligned -c 'SHOW hba_file;' 2>/dev/null | tr -d '\r' || true)

# Fallback mechanism if dynamic detection fails or provides empty path
if [ -z "$PG_CONF_PATH_FULL" ] || [ -z "$PG_HBA_CONF_PATH_FULL" ]; then
    echo "WARNING: Dynamic detection of PostgreSQL config files failed or returned empty paths. Falling back to common paths."
    if [ -f "/etc/postgresql/16/main/postgresql.conf" ]; then
        PG_CONF_PATH_FULL="/etc/postgresql/16/main/postgresql.conf"
        PG_HBA_CONF_PATH_FULL="/etc/postgresql/16/main/pg_hba.conf"
        echo "Using fallback path for PostgreSQL 16."
    elif [ -f "/etc/postgresql/15/main/postgresql.conf" ]; then
        PG_CONF_PATH_FULL="/etc/postgresql/15/main/postgresql.conf"
        PG_HBA_CONF_PATH_FULL="/etc/postgresql/15/main/pg_hba.conf"
        echo "Using fallback path for PostgreSQL 15."
    elif [ -f "/etc/postgresql/14/main/postgresql.conf" ]; then
        PG_CONF_PATH_FULL="/etc/postgresql/14/main/postgresql.conf"
        PG_HBA_CONF_PATH_FULL="/etc/postgresql/14/main/pg_hba.conf"
        echo "Using fallback path for PostgreSQL 14."
    else
        echo "ERROR: Cannot find PostgreSQL configuration files even with common fallbacks. Exiting."
        exit 1
    fi
fi

PG_CONF="$PG_CONF_PATH_FULL"
PG_HBA_CONF="$PG_HBA_CONF_PATH_FULL"

echo "Using postgresql.conf at: $PG_CONF"
echo "Using pg_hba.conf at: $PG_HBA_CONF"

# Allow connections from Docker bridge network
if ! sudo grep -q "listen_addresses = '*'" "$PG_CONF"; then
    echo "Configuring PostgreSQL to listen on all interfaces..."
    echo "listen_addresses = '*'" | sudo tee -a "$PG_CONF" > /dev/null
else
    echo "PostgreSQL already configured to listen on all interfaces."
fi

# Remove any existing 172.16.0.0/12 entry to avoid duplicates before adding
if sudo grep -q "host    jportal_user    jportal_db      172.16.0.0/12" "$PG_HBA_CONF"; then
    echo "Removing existing Docker bridge entry in pg_hba.conf to prevent duplicates."
    sudo sed -i '/host    jportal_user    jportal_db      172.16.0.0\/12/d' "$PG_HBA_CONF"
fi
echo "Allowing PostgreSQL connections from Docker bridge network (172.16.0.0/12)..."
echo "host    jportal_user    jportal_db      172.16.0.0/12           md5" | sudo tee -a "$PG_HBA_CONF" > /dev/null

sudo systemctl restart postgresql
echo "PostgreSQL configured and restarted."
echo ""

echo "--- Configuring FreeRADIUS for PostgreSQL ---"
FR_MODS_PATH="/etc/freeradius/3.0/mods-available"
FR_ENABLED_PATH="/etc/freeradius/3.0/mods-enabled"
FR_CLIENTS_CONF="/etc/freeradius/3.0/clients.conf"
FR_DEFAULT_SITE="/etc/freeradius/3.0/sites-available/default"
FR_SQL_SCHEMA_DIR="/etc/freeradius/3.0/mods-config/sql/main/postgresql"

# Enable SQL module
if [ ! -L "$FR_ENABLED_PATH/sql" ]; then
    echo "Enabling FreeRADIUS SQL module..."
    sudo ln -s "$FR_MODS_PATH/sql" "$FR_ENABLED_PATH/sql" || true
else
    echo "FreeRADIUS SQL module already enabled."
fi

# Configure SQL module for PostgreSQL
echo "Updating FreeRADIUS SQL module configuration..."
sudo sed -i 's/dialect = "sqlite"/dialect = "postgresql"/' "$FR_MODS_PATH/sql"
sudo sed -i 's/driver = "rlm_sql_null"/driver = "rlm_sql_${dialect}"/' "$FR_MODS_PATH/sql"
sudo sed -i 's/#\s*server\s*=\s*"localhost"/server = "127.0.0.1"/' "$FR_MODS_PATH/sql"
sudo sed -i 's/#\s*port\s*=\s*3306/port = 5432/' "$FR_MODS_PATH/sql"
sudo sed -i 's/#\s*login\s*=\s*"radius"/login = "jportal_user"/' "$FR_MODS_PATH/sql"
sudo sed -i 's/#\s*password\s*=\s*"radpass"/password = "'"$DB_PASSWORD"'"/' "$FR_MODS_PATH/sql"
sudo sed -i 's/#\s*radius_db\s*=\s*"radius"/radius_db = "jportal_db"/' "$FR_MODS_PATH/sql"
sudo sed -i 's/#\s*readclients\s*=\s*no/readclients = yes/' "$FR_MODS_PATH/sql"

# Apply FreeRADIUS SQL schema to jportal_db
echo "Applying FreeRADIUS PostgreSQL schema to 'jportal_db'..."
if ! sudo -u postgres psql -d jportal_db -c '\dt' 2>/dev/null | grep -q "radcheck"; then
    echo "Executing schema.sql..."
    sudo cat "$FR_SQL_SCHEMA_DIR/schema.sql" | sudo -u postgres psql -d jportal_db
    echo "Executing setup.sql..."
    sudo cat "$FR_SQL_SCHEMA_DIR/setup.sql" | sudo -u postgres psql -d jportal_db
else
    echo "FreeRADIUS schema already applied to 'jportal_db'. Skipping."
fi

# Configure default FreeRADIUS site to use SQL for authentication, authorization, accounting
echo "Updating default FreeRADIUS site configuration to use SQL module..."
if ! sudo grep -q -E '^authorize \{\s*\n\s*[^#]*sql' "$FR_DEFAULT_SITE"; then
    sudo sed -i '/^authorize {/a \        sql' "$FR_DEFAULT_SITE"
    echo "Added 'sql' to 'authorize' section."
fi
if ! sudo grep -q -E '^authenticate \{\s*\n\s*[^#]*sql' "$FR_DEFAULT_SITE"; then
    sudo sed -i '/^authenticate {/a \        sql' "$FR_DEFAULT_SITE"
    echo "Added 'sql' to 'authenticate' section."
fi
if ! sudo grep -q -E '^post-auth \{\s*\n\s*[^#]*sql' "$FR_DEFAULT_SITE"; then
    sudo sed -i '/^post-auth {/a \        sql' "$FR_DEFAULT_SITE"
    echo "Added 'sql' to 'post-auth' section (for accounting)."
fi

# Completely overwriting FreeRADIUS clients.conf for clean client definitions
echo "Completely overwriting FreeRADIUS clients.conf for clean client definitions..."

read -r -d '' FR_CLIENTS_CONF_CONTENT << 'EOF_FR_CLIENTS'
#
#  clients.conf        A configuration file for the FreeRADIUS server.
#  Managed by Jportal.com deployment script. DO NOT EDIT MANUALLY.
#
#  See the clients(5) manpage for more information.
#
#  The general format is:
#
#  client <name> {
#        ipaddr = <IPv4 address> | <IPv6 address>
#        secret = <shared secret>
#        netmask = <IPv4 netmask> | <IPv6 netmask>
#        # or
#        # shortname = <name>
#        #
#        # require_message_authenticator = yes
#        #
#        # nas_type = <type> (e.g. cisco, vivant, etc.)
#        #
#        # Add this in 3.0.17 to allow dynamic clients
#        # dynamic_clients = yes
#        #
#        # For client side proxying of requests. Only
#        # necessary if you are running a server which proxies
#        # requests that also authenticates requests itself.
#        #
#        # client_side_proxy = yes
#  }
#
#  You can specify clients by IP address, hostname,
#  or network address.
#
#  Standard localhost IPv4 client
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123 # Default FreeRADIUS secret
    require_message_authenticator = yes
}

# Standard localhost IPv6 client
client localhost_ipv6 {
    ipv6addr = ::1
    secret = testing123 # Default FreeRADIUS secret
    require_message_authenticator = yes
}

#  Jportal.com clients added by deployment script
client jportal_localhost {
    ipaddr = 127.0.0.1
    secret = $RADIUS_SHARED_SECRET
    require_message_authenticator = yes
}
client jportal_docker_bridge {
    ipaddr = 172.17.0.0/16
    secret = $RADIUS_SHARED_SECRET
    require_message_authenticator = yes
}
EOF_FR_CLIENTS

# Write the content to the clients.conf file, overwriting existing content
echo "$FR_CLIENTS_CONF_CONTENT" | sudo tee "$FR_CLIENTS_CONF" > /dev/null
echo "FreeRADIUS clients.conf overwritten and updated with Jportal.com clients."


sudo systemctl restart freeradius
echo "FreeRADIUS configured and restarted."
echo ""

echo "█████████████████████████████████████████████████████████████"
echo "██                                                         ██"
echo "██    Jportal.com - Script 2/3 Completed!                  ██"
echo "██                                                         ██"
echo "█████████████████████████████████████████████████████████████"
echo ""
echo "Please review the output above for any errors."
echo "If no errors, you can proceed to the next script: 03-deploy-django-app.sh"
