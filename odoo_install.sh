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

read -p "Odoo system user [odoo]: " OE_USER
OE_USER=${OE_USER:-odoo}

read -p "Install directory [/opt/$OE_USER]: " OE_HOME
OE_HOME=${OE_HOME:-/opt/$OE_USER}

read -p "Custom modules repo SSH URL (leave empty to skip): " REPO_URL

read -p "Branch [main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "PostgreSQL user [$OE_USER]: " PG_USER
PG_USER=${PG_USER:-$OE_USER}

read -p "Odoo version [19.0]: " OE_VERSION
OE_VERSION=${OE_VERSION:-19.0}

read -p "Config file name [$OE_USER.conf]: " CONF_NAME
CONF_NAME=${CONF_NAME:-$OE_USER.conf}

read -p "Systemd service name [$OE_USER]: " SERVICE_NAME
SERVICE_NAME=${SERVICE_NAME:-$OE_USER}

read -p "Port [8069]: " OE_PORT
OE_PORT=${OE_PORT:-8069}

read -p "Install wkhtmltopdf [Y/n]: " INSTALL_WKHTMLTOPDF
INSTALL_WKHTMLTOPDF=${INSTALL_WKHTMLTOPDF:-Y}

if [[ "$INSTALL_WKHTMLTOPDF" =~ ^[Yy]$ ]]; then
    INSTALL_WKHTMLTOPDF="True"
else
    INSTALL_WKHTMLTOPDF="False"
fi

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
echo "Install wkhtmltopdf:$INSTALL_WKHTMLTOPDF"
echo "---------------------------------------------------------"
sleep 2

# -------------------------------
# Install dependencies
# -------------------------------

echo "[1/9] Installing system packages..."
apt update
apt install -y git python3 python3-pip python3-venv \
    postgresql postgresql-contrib \
    build-essential libpq-dev libxml2-dev libxslt1-dev zlib1g-dev \
    libldap2-dev libsasl2-dev libjpeg-dev libfreetype6-dev libssl-dev


# -------------------------------
# PostgreSQL setup
# -------------------------------

echo "[2/9] Creating PostgreSQL user..."
sudo -u postgres createuser -s $PG_USER || true


# -------------------------------
# Create user and directories
# -------------------------------

echo "[3/9] Creating system user and folder structure..."
if id "$OE_USER" >/dev/null 2>&1; then
    echo "System user $OE_USER already exists."
else
    adduser --system --quiet --shell=/bin/bash --home $OE_HOME --group $OE_USER
fi

mkdir -p $OE_HOME/log
mkdir -p $OE_HOME/src
mkdir -p $OE_HOME/odoo

chown -R $OE_USER:$OE_USER $OE_HOME


# -------------------------------
# Clone your repo (optional)
# -------------------------------

echo "[4/9] Processing custom addons repository..."

if [ -n "$REPO_URL" ]; then
    if [ ! -d "$OE_HOME/src/.git" ]; then
        echo "→ Cloning custom modules..."
        sudo -u $OE_USER git clone -b $BRANCH $REPO_URL $OE_HOME/src
    else
        echo "→ Custom repo exists, updating..."
        cd $OE_HOME/src
        sudo -u $OE_USER git fetch origin $BRANCH
        sudo -u $OE_USER git reset --hard origin/$BRANCH
    fi
else
    echo "→ No repo provided, skipping custom modules."
fi

# -------------------------------
# Install wkhtmltopdf (optional)
# -------------------------------

if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo "=== Installing wkhtmltopdf (0.12.6.1 - patched Qt) ==="

  cd /tmp
  sudo wget -O wkhtml.deb \
    https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb

  sudo apt install -y ./wkhtml.deb
  rm wkhtml.deb

  sudo ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
  sudo ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage

  echo "wkhtmltopdf installed successfully!"
else
  echo "wkhtmltopdf installation skipped."
fi


# -------------------------------
# Install Odoo core
# -------------------------------

echo "[5/9] Installing or updating Odoo source..."

if [ ! -d "$OE_HOME/odoo/.git" ]; then
    echo "→ Odoo directory empty, cloning fresh..."
    sudo -u $OE_USER git clone --depth 1 -b $OE_VERSION https://github.com/odoo/odoo.git $OE_HOME/odoo
else
    echo "→ Odoo directory exists, pulling latest changes..."
    cd $OE_HOME/odoo
    sudo -u $OE_USER git fetch --depth 1 origin $OE_VERSION
    sudo -u $OE_USER git reset --hard origin/$OE_VERSION
fi

# -------------------------------
# Python venv setup
# -------------------------------

echo "[6/9] Creating virtualenv..."
if [ ! -d "$OE_HOME/venv" ]; then
    echo "→ Creating new virtualenv..."
    python3 -m venv $OE_HOME/venv
else
    echo "→ Virtualenv already exists, reusing..."
fi
$OE_HOME/venv/bin/pip install --upgrade pip wheel


# -------------------------------
# Install requirements
# -------------------------------

echo "[7/9] Installing Odoo requirements..."
$OE_HOME/venv/bin/pip install -r $OE_HOME/odoo/requirements.txt

if [ -f "$OE_HOME/src/requirements.txt" ]; then
  echo "Installing custom module requirements..."
  $OE_HOME/venv/bin/pip install -r $OE_HOME/src/requirements.txt
fi


# -------------------------------
# Configuration
# -------------------------------

echo "[8/9] Generating configuration file..."

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

echo "[9/9] Creating systemd service..."

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

