#!/bin/bash
set -e

# Update Odoo modules on local DB
# Usage: sudo bash odoo-update-modules.sh <instance_name> <module1,module2>

INSTANCE_NAME="$1"
MODULES="$2"

if [ -z "$INSTANCE_NAME" ] || [ -z "$MODULES" ]; then
    echo "Usage: $0 <instance_name> <module1,module2>"
    echo "Example: $0 staging19 sale,stock,account"
    exit 1
fi

CONFIG_FILE="/etc/odoo_deploy/${INSTANCE_NAME}.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [ -z "$DB_NAME" ]; then
    echo "❌ DB_NAME not set in $CONFIG_FILE"
    exit 1
fi
if [ -z "$OE_HOME" ]; then
    echo "❌ OE_HOME not set in $CONFIG_FILE"
    exit 1
fi
if [ -z "$OE_USER" ]; then
    echo "❌ OE_USER not set in $CONFIG_FILE"
    exit 1
fi

SERVICE="${SERVICE_NAME:-odoo}"
ODOO_BIN="$OE_HOME/odoo/odoo-bin"
VENV_PY="$OE_HOME/venv/bin/python3"

if [ ! -x "$VENV_PY" ]; then
    echo "❌ Python venv not found: $VENV_PY"
    exit 1
fi
if [ ! -f "$ODOO_BIN" ]; then
    echo "❌ Odoo binary not found: $ODOO_BIN"
    exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
if [ ! -f "$SERVICE_FILE" ]; then
    echo "❌ Service file not found: $SERVICE_FILE"
    exit 1
fi

CONFIG_PATH=$(grep -oP '(?<=-c ).+' "$SERVICE_FILE" | tr -d ' ')
if [ ! -f "$CONFIG_PATH" ]; then
    echo "❌ Could not read Odoo config path: $CONFIG_PATH"
    exit 1
fi

echo "========================================="
echo " Update Odoo Modules"
echo "-----------------------------------------"
echo " Instance: $INSTANCE_NAME"
echo " DB:       $DB_NAME"
echo " Modules:  $MODULES"
echo " Service:  $SERVICE"
echo " Config:   $CONFIG_PATH"
echo "========================================="

systemctl stop "$SERVICE" || true

sudo -u "$OE_USER" "$VENV_PY" "$ODOO_BIN" -c "$CONFIG_PATH" -d "$DB_NAME" -u "$MODULES" --stop-after-init

systemctl start "$SERVICE"

echo "✅ Modules updated successfully"
