#!/bin/bash
set -e

# Create a global odooctl command in /usr/local/bin
# Usage: sudo bash odooctl-link.sh [/path/to/odoo_deployment_scripts]

REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
TARGET="/usr/local/bin/odooctl"
SOURCE="${REPO_DIR}/odooctl.sh"

if [ ! -f "$SOURCE" ]; then
    echo "❌ odooctl.sh not found at: $SOURCE"
    exit 1
fi

chmod +x "$SOURCE"
ln -sf "$SOURCE" "$TARGET"

echo "✓ Linked: $TARGET -> $SOURCE"
echo "Try: odooctl --help"
