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
NO_DB_BACKUP="false"

if [ "$2" = "--no-db-backup" ] || [ "$2" = "no-db-backup" ]; then
    NO_DB_BACKUP="true"
fi

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
BACKUP_METHOD="${BACKUP_METHOD:-pg}"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$DEPLOY_LOG")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DEPLOY_LOG"
}

step() {
    LAST_STEP="$*"
    log "==== $* ===="
}

LAST_STEP="INIT"
trap 'log "❌ DEPLOY FAILED (step: ${LAST_STEP})"; log "============== END DEPLOY [$INSTANCE_NAME] (FAILED) =============="; exit 1' ERR

log "============== START DEPLOY [$INSTANCE_NAME] =============="
log "→ Config: $CONFIG_FILE"
log "→ Repo dir: ${REPO_DIR:-$OE_HOME/src}"
log "→ Backup method: ${BACKUP_METHOD}"
log "→ Service: ${SERVICE_NAME}"

#########################################################################
# BACKUP
#########################################################################

step "BACKUP"
log "→ Creating backup directory: $BACKUP_DIR"

# 1. Database backup (optional)
if [ -n "$DB_NAME" ] && [ "$NO_DB_BACKUP" != "true" ]; then
    log "→ Dumping database: $DB_NAME (method: ${BACKUP_METHOD})"

    PG_DUMP_ARGS=()
    [ -n "$DB_USER" ] && PG_DUMP_ARGS+=("-U" "$DB_USER")
    [ -n "$DB_HOST" ] && PG_DUMP_ARGS+=("-h" "$DB_HOST")
    [ -n "$DB_PORT" ] && PG_DUMP_ARGS+=("-p" "$DB_PORT")

    do_pg_dump() {
        PGPASSWORD="$1" pg_dump "${PG_DUMP_ARGS[@]}" \
            -F c -b -f "${BACKUP_DIR}/${DB_NAME}.dump" "$DB_NAME" \
            >> "$DEPLOY_LOG" 2>&1
    }

    detect_odoo_config() {
        SERVICE="${SERVICE_NAME:-odoo}"
        SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
        if [ ! -f "$SERVICE_FILE" ]; then
            return 1
        fi
        CONFIG_PATH=$(grep -oP '(?<=-c ).+' "$SERVICE_FILE" | tr -d ' ')
        [ -f "$CONFIG_PATH" ] || return 1
        echo "$CONFIG_PATH"
        return 0
    }

    do_odoo_backup() {
        ODOO_PORT_EFFECTIVE="${ODOO_PORT:-8069}"
        MASTER_PASS_EFFECTIVE="${MASTER_PASS:-${ODOO_MASTER_PASS:-}}"
        if [ -z "$MASTER_PASS_EFFECTIVE" ]; then
            read -s -p "Odoo master password: " MASTER_PASS_EFFECTIVE
            echo ""
        fi
        curl -o "${BACKUP_DIR}/${DB_NAME}.zip" \
            -X POST "http://127.0.0.1:${ODOO_PORT_EFFECTIVE}/web/database/backup" \
            -F backup_format=zip \
            -F master_pwd="$MASTER_PASS_EFFECTIVE" \
            -F name="$DB_NAME" >>"$DEPLOY_LOG" 2>&1
    }

    if [ "$BACKUP_METHOD" = "odoo" ]; then
        if ! do_odoo_backup; then
            log "❌ Odoo backup failed"
            exit 1
        fi
        log "✓ Odoo backup completed"
    elif [ "$BACKUP_METHOD" = "auto" ]; then
        if ! do_pg_dump "${DB_PASSWORD:-${DB_PASS:-}}"; then
            log "⚠ pg_dump failed — prompting for password"
            read -s -p "Postgres password for user ${DB_USER}: " DB_PASS_PROMPT
            echo ""
            if ! do_pg_dump "$DB_PASS_PROMPT"; then
                log "⚠ pg_dump failed — trying Odoo backup"
                if ! do_odoo_backup; then
                    log "❌ Odoo backup failed"
                    exit 1
                fi
                log "✓ Odoo backup completed"
            fi
        else
            log "✓ pg_dump completed"
        fi
    else
        if ! do_pg_dump "${DB_PASSWORD:-${DB_PASS:-}}"; then
            log "⚠ DB backup failed — prompting for password"
            read -s -p "Postgres password for user ${DB_USER}: " DB_PASS_PROMPT
            echo ""
            if ! do_pg_dump "$DB_PASS_PROMPT"; then
                log "❌ DB backup failed"
                exit 1
            fi
            log "✓ pg_dump completed (after prompt)"
        else
            log "✓ pg_dump completed"
        fi
    fi
else
    if [ "$NO_DB_BACKUP" = "true" ]; then
        log "ℹ DB backup skipped (no-db-backup)"
    else
        log "ℹ No DB_NAME specified — DB backup skipped"
    fi
fi

# 2. Code backup
if [ -n "$REPO_DIR" ]; then
    log "→ Backing up code (odoo + repo: $REPO_DIR)"
    tar czf "${BACKUP_DIR}/code.tar.gz" \
        -C "$OE_HOME" odoo \
        -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")" \
        >> "$DEPLOY_LOG" 2>&1 || {
            log "❌ Repo backup failed (see log: $DEPLOY_LOG)"
            exit 1
        }
else
    log "→ Backing up code (odoo + src)"
    tar czf "${BACKUP_DIR}/code.tar.gz" -C "$OE_HOME" odoo src \
        >> "$DEPLOY_LOG" 2>&1 || {
            log "❌ Code backup failed (odoo + src)"
            exit 1
        }
fi


#########################################################################
# GIT UPDATE
#########################################################################

step "GIT UPDATE"
REPO_PATH="${REPO_DIR:-$OE_HOME/src}"
cd "$REPO_PATH"

sudo -u "$OE_USER" git config --global --add safe.directory "$REPO_PATH" >>"$DEPLOY_LOG" 2>&1 || true

CURRENT_COMMIT=$(sudo -u "$OE_USER" git rev-parse HEAD)
log "→ Current commit: $CURRENT_COMMIT"

log "→ Fetching Git updates (origin/$BRANCH)"
sudo -u "$OE_USER" git fetch --all >>"$DEPLOY_LOG" 2>&1

log "→ Resetting to origin/$BRANCH"
sudo -u "$OE_USER" git reset --hard "origin/$BRANCH" >>"$DEPLOY_LOG" 2>&1

NEW_COMMIT=$(sudo -u "$OE_USER" git rev-parse HEAD)
log "→ New commit: $NEW_COMMIT"


#########################################################################
# PIP INSTALL
#########################################################################

step "PIP INSTALL"
REQ_FILE="${REPO_DIR:-$OE_HOME/src}/requirements.txt"

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

step "RESTART SERVICE"
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

step "HEALTH CHECK"
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
