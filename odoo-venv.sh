#!/bin/bash
set -e

ODOO_HOME="/opt/odoo"
VENV="$ODOO_HOME/venv"

if [ ! -d "$VENV" ]; then
    echo "❌ Virtual environment not found at $VENV"
    exit 1
fi

echo "Activating Odoo virtual environment..."
echo "Run 'deactivate' to exit the environment."

source "$VENV/bin/activate"

