#!/bin/bash
set -e

#########################################################################
# UNIVERSAL ODOO DEPLOY SCRIPT
# - Backup database (optional)
# - Backup code
# - Git fetch + reset --hard origin/<branch>
# - Install requirements
# - Restart Odoo
# - Health check
# - Auto rollback if failure
#
# Usage:
#   sudo bash deploy_odoo.sh instance_name
#
# Expected config file:
#   /etc/odoo_deploy/<instance_name>.env
#########################################################################

INSTANCE_NAME="$1"

if [ -z "$INSTANCE_NAME" ]; then
    echo "Usage: $0 <instance_name>"
    exit 1
fi

CONFIG_FILE="/etc/odoo_deploy/${INSTANCE_NAME}.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="$OE_HOME/backups/${INSTANCE_NAME}/${TIMESTAMP}"
DEPLOY_LOG="$OE_HOME/log/deploy_${INSTANCE_NAME}.log"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$DEPLOY_LOG")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DEPLOY_LOG"
}

log "============== START DEPLOY [$INSTANCE_NAME] =============="

#########################################################################
# BACKUP
#########################################################################

log "→ Creating backup directory: $BACKUP_DIR"

# 1. Database backup (optional)
if [ -n "$DB_NAME" ]; then
    log "→ Dumping database: $DB_NAME"
    PGPASSWORD="${DB_PASSWORD:-${DB_PASS:-}}" \
    pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" \
        -F c -b -f "${BACKUP_DIR}/${DB_NAME}.dump" "$DB_NAME" \
        >> "$DEPLOY_LOG" 2>&1 || log "⚠ DB backup failed (continuing)"
else
    log "ℹ No DB_NAME specified — DB backup skipped"
fi

# 2. Code backup
log "→ Backing up code (odoo + src)"
tar czf "${BACKUP_DIR}/code.tar.gz" -C "$OE_HOME" odoo src \
    >> "$DEPLOY_LOG" 2>&1 || log "⚠ Code backup failed"


#########################################################################
# GIT UPDATE
#########################################################################

cd "$OE_HOME/src"

CURRENT_COMMIT=$(sudo -u "$OE_USER" git rev-parse HEAD)
log "→ Current commit: $CURRENT_COMMIT"

log "→ Fetching Git updates"
sudo -u "$OE_USER" git fetch --all >>"$DEPLOY_LOG" 2>&1

log "→ Resetting to origin/$BRANCH"
sudo -u "$OE_USER" git reset --hard "origin/$BRANCH" >>"$DEPLOY_LOG" 2>&1

NEW_COMMIT=$(sudo -u "$OE_USER" git rev-parse HEAD)
log "→ New commit: $NEW_COMMIT"


#########################################################################
# PIP INSTALL
#########################################################################

REQ_FILE="$OE_HOME/src/requirements.txt"

if [ -f "$REQ_FILE" ]; then
    log "→ Installing Python dependencies"
    "$OE_HOME/venv/bin/pip" install -r "$REQ_FILE" \
        >> "$DEPLOY_LOG" 2>&1 || {
            log "❌ Pip install failed → rolling back"
            sudo -u "$OE_USER" git reset --hard "$CURRENT_COMMIT"
            "$OE_HOME/venv/bin/pip" install -r "$REQ_FILE" >>"$DEPLOY_LOG" 2>&1 || true
            log "❌ DEPLOY FAILED"
            exit 1
        }
else
    log "ℹ No requirements.txt found"
fi


#########################################################################
# RESTART ODOO
#########################################################################

log "→ Restarting Odoo service: $SERVICE_NAME"

systemctl restart "$SERVICE_NAME" || {
    log "❌ Service failed to restart → rolling back"
    sudo -u "$OE_USER" git reset --hard "$CURRENT_COMMIT"
    systemctl restart "$SERVICE_NAME" || true
    exit 1
}

sleep 2

#########################################################################
# HEALTH CHECK
#########################################################################

HEALTH_URL="http://127.0.0.1:${ODOO_PORT}/web/login"

log "→ Performing health check on: $HEALTH_URL"

SUCCESS=0
for i in {1..10}; do
    if curl -s "$HEALTH_URL" | grep -qi "odoo"; then
        SUCCESS=1
        break
    fi
    log "  - Attempt $i failed, retrying..."
    sleep 3
done

if [ "$SUCCESS" -ne 1 ]; then
    log "❌ HEALTH CHECK FAILED → Rolling back"
    cd "$OE_HOME/src"
    sudo -u "$OE_USER" git reset --hard "$CURRENT_COMMIT" >>"$DEPLOY_LOG" 2>&1
    systemctl restart "$SERVICE_NAME"
    exit 1
fi

#########################################################################
# DONE
#########################################################################

log "✓ DEPLOY SUCCESSFUL"
log "============== END DEPLOY [$INSTANCE_NAME] =============="

exit 0
