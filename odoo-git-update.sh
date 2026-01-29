#!/bin/bash
set -e

# Git update + optional module update for Odoo instance
# Usage:
#   sudo bash odoo-git-update.sh <instance_name> [update [-all|module1,module2]]

INSTANCE_NAME="$1"
ACTION="$2"

if [ -z "$INSTANCE_NAME" ]; then
    echo "Usage: $0 <instance_name> [update [-all|module1,module2]]"
    exit 1
fi

CONFIG_FILE="/etc/odoo_deploy/${INSTANCE_NAME}.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [ -z "$OE_HOME" ]; then
    echo "❌ OE_HOME not set in $CONFIG_FILE"
    exit 1
fi
if [ -z "$OE_USER" ]; then
    echo "❌ OE_USER not set in $CONFIG_FILE"
    exit 1
fi
if [ -z "$BRANCH" ]; then
    echo "❌ BRANCH not set in $CONFIG_FILE"
    exit 1
fi
if [ -z "$DB_NAME" ]; then
    echo "❌ DB_NAME not set in $CONFIG_FILE"
    exit 1
fi

SERVICE="${SERVICE_NAME:-odoo}"
PROJECT_DIR="$OE_HOME/src"
ODOO_BIN="$OE_HOME/odoo/odoo-bin"
VENV_PY="$OE_HOME/venv/bin/python3"
LOG_FILE="$OE_HOME/log/git-update_${INSTANCE_NAME}.log"
BACKUP_DIR="$OE_HOME/backups/${INSTANCE_NAME}/$(date +%Y%m%d_%H%M%S)"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

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

if [ ! -x "$VENV_PY" ]; then
    echo "❌ Python venv not found: $VENV_PY"
    exit 1
fi
if [ ! -f "$ODOO_BIN" ]; then
    echo "❌ Odoo binary not found: $ODOO_BIN"
    exit 1
fi

log "----------------------------------------"
log " ODOO GIT UPDATE START [$INSTANCE_NAME]"
log "----------------------------------------"

cd "$PROJECT_DIR"

log "[INFO] DB backup..."
sudo -u "$OE_USER" "$VENV_PY" "$ODOO_BIN" -c "$CONFIG_PATH" -d "$DB_NAME" \
    --save --stop-after-init --backup-dir "$BACKUP_DIR" \
    >>"$LOG_FILE" 2>&1 || log "[WARN] DB backup failed (continuing)"

log "[INFO] Checking local changes..."
if ! sudo -u "$OE_USER" git diff --quiet; then
    log "[WARN] Local changes found — auto-stash..."
    sudo -u "$OE_USER" git stash push -m "auto-stash-before-update-$(date +%F-%H%M%S)" \
        >>"$LOG_FILE" 2>&1
    STASHED=1
else
    log "[INFO] No local changes."
    STASHED=0
fi

log "[INFO] Fetch + change check..."
sudo -u "$OE_USER" git fetch --all >>"$LOG_FILE" 2>&1

CHANGED=$(sudo -u "$OE_USER" git diff --name-only HEAD "origin/$BRANCH" | wc -l)
if [ "$CHANGED" -eq 0 ]; then
    log "[INFO] No remote changes — nothing to do."
    if [ "$STASHED" -eq 1 ]; then
        log "[INFO] Restoring stash..."
        sudo -u "$OE_USER" git stash pop >>"$LOG_FILE" 2>&1 || log "[WARN] stash pop had conflicts."
    fi
    exit 0
fi

OLD_COMMIT=$(sudo -u "$OE_USER" git rev-parse HEAD)

log "[INFO] Pulling changes from origin/$BRANCH..."
if ! sudo -u "$OE_USER" git pull origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
    log "[ERROR] git pull failed — rollback to $OLD_COMMIT"
    sudo -u "$OE_USER" git reset --hard "$OLD_COMMIT" >>"$LOG_FILE" 2>&1
    exit 1
fi

if [ "$STASHED" -eq 1 ]; then
    log "[INFO] Restoring stash..."
    sudo -u "$OE_USER" git stash pop >>"$LOG_FILE" 2>&1 || log "[WARN] stash pop had conflicts."
fi

REQ_FILE="$PROJECT_DIR/requirements.txt"
if [ -f "$REQ_FILE" ]; then
    if sudo -u "$OE_USER" git diff --name-only "$OLD_COMMIT" HEAD | grep -q "requirements.txt"; then
        log "[INFO] requirements.txt changed — pip install..."
        sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install -r "$REQ_FILE" \
            >>"$LOG_FILE" 2>&1 || {
                log "[ERROR] pip install failed — rollback to $OLD_COMMIT"
                sudo -u "$OE_USER" git reset --hard "$OLD_COMMIT" >>"$LOG_FILE" 2>&1
                exit 1
            }
    else
        log "[INFO] requirements.txt unchanged."
    fi
else
    log "[INFO] requirements.txt not found."
fi

log "[INFO] Python syntax check..."
if ! sudo -u "$OE_USER" bash -c \
    "find '$PROJECT_DIR' -name '*.py' -print0 | xargs -0 '$VENV_PY' -m py_compile" \
    >>"$LOG_FILE" 2>&1; then
    log "[ERROR] Python syntax check failed — rollback to $OLD_COMMIT"
    sudo -u "$OE_USER" git reset --hard "$OLD_COMMIT" >>"$LOG_FILE" 2>&1
    exit 1
fi

if [ "$ACTION" = "update" ]; then
    shift 2
    if [ "$1" = "-all" ]; then
        log "[INFO] Updating all modules..."
        systemctl stop "$SERVICE" || true
        sudo -u "$OE_USER" "$VENV_PY" "$ODOO_BIN" -c "$CONFIG_PATH" -d "$DB_NAME" \
            -u all --stop-after-init >>"$LOG_FILE" 2>&1
        systemctl start "$SERVICE"
    else
        MODULES_RAW="$*"
        MODULES="${MODULES_RAW// /,}"
        if [ -z "$MODULES" ]; then
            echo "Usage: $0 <instance_name> update [-all|module1,module2]"
            exit 1
        fi
        log "[INFO] Updating modules: $MODULES"
        systemctl stop "$SERVICE" || true
        sudo -u "$OE_USER" "$VENV_PY" "$ODOO_BIN" -c "$CONFIG_PATH" -d "$DB_NAME" \
            -u "$MODULES" --stop-after-init >>"$LOG_FILE" 2>&1
        systemctl start "$SERVICE"
    fi
fi

log "[INFO] Restarting service: $SERVICE"
systemctl restart "$SERVICE"

log "----------------------------------------"
log " ODOO GIT UPDATE DONE [$INSTANCE_NAME]"
log "----------------------------------------"
