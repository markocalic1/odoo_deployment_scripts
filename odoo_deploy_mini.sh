#!/bin/bash
set -e

# --- Settings ---
ODOO_SERVICE="odoo"          # systemd service name
SRC_DIR="/opt/odoo/src"      # folder where repos are located

echo "========================================="
echo "       Odoo Deployment Script"
echo "========================================="

# Detect repo folder (only one folder expected)
REPO=$(find "$SRC_DIR" -maxdepth 1 -mindepth 1 -type d | head -n 1)

if [ -z "$REPO" ]; then
    echo "❌ ERROR: No repositories found in $SRC_DIR"
    exit 1
fi

echo "Using repo: $REPO"
cd "$REPO"

echo "→ Pulling latest changes..."
git pull

echo "→ Restarting Odoo service..."
systemctl restart "$ODOO_SERVICE"

echo "========================================="
echo "  ✅ Deploy complete!"
echo "========================================="

