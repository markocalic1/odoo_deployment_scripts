#!/bin/bash
set -e

# --- Settings ---
ODOO_SERVICE="odoo"                 # systemd service name
ODOO_HOME="/opt/odoo"               # Odoo installation directory
SRC_DIR="/opt/odoo/src"             # custom modules root
VENV="$ODOO_HOME/venv/bin/pip"      # pip inside Odoo virtual environment

echo "========================================="
echo "        Odoo Deployment Script"
echo "========================================="

# Detect repo folder (expecting exactly one repo)
REPO=$(find "$SRC_DIR" -maxdepth 1 -mindepth 1 -type d | head -n 1)

if [ -z "$REPO" ]; then
    echo "❌ ERROR: No repositories found in $SRC_DIR"
    exit 1
fi

echo "✓ Using repo: $REPO"
cd "$REPO"

# -----------------------------------------------
# 1. Pull latest code
# -----------------------------------------------
echo "→ Pulling latest changes..."
git pull

# -----------------------------------------------
# 2. Install Python requirements (if exist)
# -----------------------------------------------
if [ -f "$REPO/requirements.txt" ]; then
    echo "→ Installing Python dependencies..."
    $VENV install -r "$REPO/requirements.txt"
else
    echo "→ No requirements.txt found, skipping Python deps."
fi

# -----------------------------------------------
# 3. Restart Odoo service
# -----------------------------------------------
echo "→ Restarting Odoo service..."
systemctl restart "$ODOO_SERVICE"

echo "========================================="
echo "   ✅ Deployment completed successfully!"
echo "========================================="

