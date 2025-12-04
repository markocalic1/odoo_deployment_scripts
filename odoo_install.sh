#!/bin/bash
set -e

###############################################################################
# UNIVERSAL ODOO INSTALLER (supports 19.0, 20.0, master…)
# Works on Ubuntu 20.04 / 22.04 / 24.04
# Installs Odoo Community + custom repo + systemd service
# CLEAN, FUTURE-PROOF, INSTANCE-AGNOSTIC
# Author: Marko Čalić (refaktorirano)
###############################################################################

echo "============== ODOO UNIVERSAL INSTALLER =============="

# -------------------------------
# Interactive settings
# -------------------------------

read -p "Odoo system user (example: odoo19, odoo20, odoo-dev): " OE_USER
read -p "Install directory (example: /opt/odoo19): " OE_HOME
read -p "Custom modules repo SSH URL: " REPO_URL
read -p "Branch for your repo (main/staging/dev): " BRANCH
read -p "PostgreSQL user (recommended: same as system user): " PG_USER
read -p "Odoo version to install (e.g. 19.0, 20.0, master): " OE_VERSION
read -p "Odoo config file name (example: odoo19.conf): " CONF_NAME
read -p "Systemd service name (example: odoo19): " SERVICE_NAME
read -p "Odoo port (default 8069): " OE_PORT
OE_PORT=${OE_PORT:-8069}

echo "---------------------------------------------------------"
echo "System user:        $OE_USER"
echo "Install directory:  $OE_HOME"
echo "Repo:               $REPO_URL"
echo "Repo branch:        $BRANCH"
echo "PostgreSQL user:    $PG_USER"
echo "Odoo version:       $OE_VERSION"
echo "Config file:        $CONF_NAME"
echo "Service name:       $SERVICE_NAME"
echo "Odoo port:          $OE_PORT"
echo "---------------------------------------------------------"
sleep 2

# -------------------------------
# Install dependencies
# -------------------------------

echo "[1/8] Installing system packages..."
apt update
apt install -y git python3 python3-pip python3-venv \
    postgresql postgresql-contrib \
    build-essential libpq-dev libxml2-dev libxslt1-dev zlib1g-dev \
    libldap2-dev libsasl2-dev libjpeg-dev libfreetype6-dev libssl-dev \
    wkhtmltopdf

# -------------------------------
# PostgreSQL setup
# -------------------------------

echo "[2/8] Creating PostgreSQL user..."
sudo -u postgres createuser -s $PG_USER || true

# -------------------------------
# Create user and directories
# -------------------------------

echo "[3/8] Creating system user and folder structure..."

adduser --system --quiet --shell=/bin/bash --home $OE_HOME --group $OE_USER || true

mkdir -p $OE_HOME/log
mkdir -p $OE_HOME/src
mkdir -p $OE_HOME/odoo

chown -R $OE_USER:$OE_USER $OE_HOME

# -------------------------------
# Clone your repo
# -------------------------------

echo "[4/8] Cloning custom modules..."
sudo -u $OE_USER git clone -b $BRANCH $REPO_URL $OE_HOME/src

# -------------------------------
# Install Odoo
# -------------------------------

echo "[5/8] Downloading Odoo $OE_VERSION..."
sudo -u $OE_USER git clone --depth 1 -b $OE_VERSION https://github.com/odoo/odoo.git $OE_HOME/odoo

# -------------------------------
# Python venv setup
# -------------------------------

echo "[6/8] Creating virtualenv..."
python3 -m venv $OE_HOME/venv
$OE_HOME/venv/bin/pip install --upgrade pip wheel

echo "[7/8] Installing Odoo requirements..."
$OE_HOME/venv/bin/pip install -r $OE_HOME/odoo/requirements.txt

if [ -f "$OE_HOME/src/requirements.txt" ]; then
  echo "Installing custom module requirements..."
  $OE_HOME/venv/bin/pip install -r $OE_HOME/src/requirements.txt
fi

# -------------------------------
# Configuration
# -------------------------------

echo "[8/8] Generating configuration file..."

ADMIN_PASS=$(openssl rand -hex 16)

cat <<EOF >/etc/$CONF_NAME
[options]
admin_passwd = $ADMIN_PASS
db_host = False
db_port = False
db_user = $PG_USER
db_password = False
addons_path = $OE_HOME/odoo/addons,$OE_HOME/src
logfile = $OE_HOME/log/odoo.log
http_port = $OE_PORT
proxy_mode = True
EOF

chown $OE_USER:$OE_USER /etc/$CONF_NAME
chmod 640 /etc/$CONF_NAME

# -------------------------------
# Systemd service
# -------------------------------

echo "Creating systemd service..."

cat <<EOF >/etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Odoo Service ($SERVICE_NAME)
After=network.target postgresql.service

[Service]
Type=simple
User=$OE_USER
Group=$OE_USER
WorkingDirectory=$OE_HOME
ExecStart=$OE_HOME/venv/bin/python3 $OE_HOME/odoo/odoo-bin -c /etc/$CONF_NAME
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now $SERVICE_NAME

echo "================ INSTALLATION COMPLETE ================"
echo "Service:     systemctl status $SERVICE_NAME"
echo "Config:      /etc/$CONF_NAME"
echo "Repo path:   $OE_HOME/src"
echo "Odoo path:   $OE_HOME/odoo"
echo "Odoo port:   $OE_PORT"
echo "Admin Pass:  $ADMIN_PASS"
echo "======================================================="

