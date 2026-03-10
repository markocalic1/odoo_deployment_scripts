#!/bin/bash
set -e

# Detect Odoo systemd service (first match)
SERVICE=$(ls /etc/systemd/system | grep -E '^odoo.*\.service$' | head -n 1 | sed 's/.service//')

if [ -z "$SERVICE" ]; then
    echo "❌ Could not detect Odoo service. Enter service name manually:"
    read -p "Service name: " SERVICE
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

if [ ! -f "$SERVICE_FILE" ]; then
    SERVICE_FILE="/lib/systemd/system/${SERVICE}.service"
    [ -f "$SERVICE_FILE" ] || SERVICE_FILE="/usr/lib/systemd/system/${SERVICE}.service"
    if [ ! -f "$SERVICE_FILE" ]; then
        echo "❌ Service file not found: /etc/systemd/system/${SERVICE}.service"
        exit 1
    fi
fi

# Extract config path
CONFIG=$(awk '
    /^ExecStart=/ {
        line = substr($0, index($0, "=") + 1)
        n = split(line, args, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
            if (args[i] == "-c" || args[i] == "--config") {
                print args[i + 1]
                exit
            }
            if (args[i] ~ /^--config=/) {
                sub(/^--config=/, "", args[i])
                print args[i]
                exit
            }
        }
    }
' "$SERVICE_FILE" | tr -d "\"'")

if [ ! -f "$CONFIG" ]; then
    for candidate in "/etc/${SERVICE}.conf" "/etc/odoo.conf"; do
        if [ -f "$candidate" ]; then
            CONFIG="$candidate"
            break
        fi
    done
fi

if [ ! -f "$CONFIG" ]; then
    echo "❌ Could not read Odoo config path: $CONFIG"
    exit 1
fi

# Extract Odoo home path from ExecStart
ODOO_HOME=$(grep -oP "(?<=WorkingDirectory=).*" "$SERVICE_FILE")

if [ ! -d "$ODOO_HOME" ]; then
    echo "❌ Odoo home directory not found: $ODOO_HOME"
    exit 1
fi

VENV="$ODOO_HOME/venv/bin/python3"
ODOO_BIN="$ODOO_HOME/odoo/odoo-bin"

echo "========================================="
echo " Launching Odoo Shell"
echo " Service:  $SERVICE"
echo " Config:   $CONFIG"
echo " Venv:     $VENV"
echo " Bin:      $ODOO_BIN"
echo "========================================="

$VENV "$ODOO_BIN" shell -c "$CONFIG"
