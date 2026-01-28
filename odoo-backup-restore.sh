#!/bin/bash
set -e

# Simple wrapper for odoo-sync.sh with minimal arguments.
# Usage: sudo bash odoo-sync-run.sh <instance_suffix>
# Example: sudo bash odoo-sync-run.sh 19

INSTANCE_SUFFIX="$1"
if [ -z "$INSTANCE_SUFFIX" ]; then
    echo "Usage: $0 <instance_suffix>"
    echo "Example: $0 19"
    exit 1
fi

PROD_ENV="/etc/odoo_deploy/prod${INSTANCE_SUFFIX}.env"
STAGING_ENV="/etc/odoo_deploy/staging${INSTANCE_SUFFIX}.env"
SECRET_ENV="/etc/odoo_deploy/odoo-sync.env"

if [ ! -f "$PROD_ENV" ]; then
    echo "❌ Missing prod env: $PROD_ENV"
    exit 1
fi
if [ ! -f "$STAGING_ENV" ]; then
    echo "❌ Missing staging env: $STAGING_ENV"
    exit 1
fi

# Optional secrets file for master passwords
if [ -f "$SECRET_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SECRET_ENV"
fi

if [ -z "$PROD_HOST" ]; then
    read -p "Production host/IP: " PROD_HOST
fi

ARGS=(
    --prod-env "$PROD_ENV"
    --staging-env "$STAGING_ENV"
    --prod-host "$PROD_HOST"
    --prod-ssh "${PROD_SSH_USER:-root}"
)

if [ -n "$PROD_MASTER_PASS" ]; then
    ARGS+=(--prod-master-pass "$PROD_MASTER_PASS")
fi
if [ -n "$STAGING_MASTER_PASS" ]; then
    ARGS+=(--staging-master-pass "$STAGING_MASTER_PASS")
fi

if [ -n "$BACKUP_METHOD" ]; then
    ARGS+=(--backup-method "$BACKUP_METHOD")
fi
if [ -n "$RESTORE_METHOD" ]; then
    ARGS+=(--method "$RESTORE_METHOD")
fi
if [ -n "$DROP_METHOD" ]; then
    ARGS+=(--drop-method "$DROP_METHOD")
fi
if [ "$NO_FILESTORE" == "true" ]; then
    ARGS+=(--no-filestore)
fi

bash "$(dirname "$0")/odoo-sync.sh" "${ARGS[@]}"
