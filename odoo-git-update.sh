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
PROJECT_DIR="${REPO_DIR:-$OE_HOME/src}"
ODOO_BIN="$OE_HOME/odoo/odoo-bin"
VENV_PY="$OE_HOME/venv/bin/python3"
LOG_FILE="$OE_HOME/log/git-update_${INSTANCE_NAME}.log"
BACKUP_DIR="$OE_HOME/backups/${INSTANCE_NAME}/$(date +%Y%m%d_%H%M%S)"
FIX_REPO_PERMS="${FIX_REPO_PERMS:-true}"
BACKUP_METHOD="${BACKUP_METHOD:-pg}"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

run_repo_git() {
    if sudo -u "$OE_USER" -H git "$@"; then
        return 0
    fi

    if [ "$EUID" -eq 0 ]; then
        log "[WARN] Git access as $OE_USER failed, retrying with root git credentials"
        git "$@"
        chown -R "$OE_USER:$OE_USER" "$PROJECT_DIR" >>"$LOG_FILE" 2>&1
        return 0
    fi

    return 1
}

detect_odoo_config() {
    local service_file config_path

    service_file="/etc/systemd/system/${SERVICE}.service"
    if [ ! -f "$service_file" ]; then
        service_file="/lib/systemd/system/${SERVICE}.service"
        [ -f "$service_file" ] || service_file="/usr/lib/systemd/system/${SERVICE}.service"
        if [ ! -f "$service_file" ]; then
            echo "❌ Service file not found: /etc/systemd/system/${SERVICE}.service"
            exit 1
        fi
    fi

    config_path=$(awk '
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
    ' "$service_file" | tr -d "\"'")
    if [ ! -f "$config_path" ]; then
        for candidate in "/etc/${SERVICE}.conf" "/etc/odoo.conf"; do
            if [ -f "$candidate" ]; then
                config_path="$candidate"
                break
            fi
        done
    fi
    if [ ! -f "$config_path" ]; then
        echo "❌ Could not read Odoo config path: $config_path"
        exit 1
    fi

    echo "$config_path"
}

read_odoo_conf_value() {
    local key="$1"
    local config_path="$2"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$config_path" | head -n1
}

ODOO_CONF_DB_USER=""
ODOO_CONF_DB_HOST=""
ODOO_CONF_DB_PORT=""
ODOO_CONF_DB_PASSWORD=""

load_db_settings_from_odoo_config() {
    local config_path

    config_path=$(detect_odoo_config)

    ODOO_CONF_DB_USER=$(read_odoo_conf_value "db_user" "$config_path")
    ODOO_CONF_DB_HOST=$(read_odoo_conf_value "db_host" "$config_path")
    ODOO_CONF_DB_PORT=$(read_odoo_conf_value "db_port" "$config_path")
    ODOO_CONF_DB_PASSWORD=$(read_odoo_conf_value "db_password" "$config_path")

    [ "$ODOO_CONF_DB_HOST" = "False" ] && ODOO_CONF_DB_HOST=""
    [ "$ODOO_CONF_DB_PORT" = "False" ] && ODOO_CONF_DB_PORT=""
    [ "$ODOO_CONF_DB_PASSWORD" = "False" ] && ODOO_CONF_DB_PASSWORD=""

    [ -n "$DB_USER" ] || DB_USER=$(read_odoo_conf_value "db_user" "$config_path")
    [ -n "$DB_HOST" ] || DB_HOST=$(read_odoo_conf_value "db_host" "$config_path")
    [ -n "$DB_PORT" ] || DB_PORT=$(read_odoo_conf_value "db_port" "$config_path")
    if [ -z "${DB_PASSWORD:-${DB_PASS:-}}" ]; then
        DB_PASSWORD=$(read_odoo_conf_value "db_password" "$config_path")
    fi

    [ "$DB_HOST" = "False" ] && DB_HOST=""
    [ "$DB_PORT" = "False" ] && DB_PORT=""
    [ "$DB_PASSWORD" = "False" ] && DB_PASSWORD=""
}

CONFIG_PATH=$(detect_odoo_config)

if [ -z "$ODOO_PORT" ]; then
    CONF_PORT=$(sed -n 's/^[[:space:]]*http_port[[:space:]]*=[[:space:]]*\\([0-9]\\+\\).*/\\1/p' "$CONFIG_PATH" | head -n1)
    if [ -n "$CONF_PORT" ]; then
        ODOO_PORT="$CONF_PORT"
    else
        ODOO_PORT="8069"
    fi
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

# Ensure git can operate even if the repo is owned by root and SSH keys are only available for root.
# This mirrors the behavior of odoo_install.sh (fallback to root credentials when run as root).
run_repo_git config --global --add safe.directory "$PROJECT_DIR" >>"$LOG_FILE" 2>&1 || true
git config --global --add safe.directory "$PROJECT_DIR" >>"$LOG_FILE" 2>&1 || true

if ! sudo -u "$OE_USER" test -w "$PROJECT_DIR/.git" 2>/dev/null; then
    if [ "$FIX_REPO_PERMS" = "true" ]; then
        log "[WARN] Fixing repo permissions for $PROJECT_DIR (chown to $OE_USER)"
        chown -R "$OE_USER:$OE_USER" "$PROJECT_DIR" >>"$LOG_FILE" 2>&1 || {
            log "[ERROR] Cannot fix repo permissions"
            exit 1
        }
    else
        log "[ERROR] Repo not writable by $OE_USER (set FIX_REPO_PERMS=true to auto-fix)"
        exit 1
    fi
fi

log "[INFO] DB backup (method: $BACKUP_METHOD)..."

load_db_settings_from_odoo_config

PG_DUMP_ARGS=()
[ -n "$DB_USER" ] && PG_DUMP_ARGS+=("-U" "$DB_USER")
[ -n "$DB_HOST" ] && PG_DUMP_ARGS+=("-h" "$DB_HOST")
[ -n "$DB_PORT" ] && PG_DUMP_ARGS+=("-p" "$DB_PORT")

do_pg_dump() {
    PGPASSWORD="$1" pg_dump "${PG_DUMP_ARGS[@]}" \
        -F c -b -f "${BACKUP_DIR}/${DB_NAME}.dump" "$DB_NAME" \
        >> "$LOG_FILE" 2>&1
}

do_pg_dump_as_odoo_user() {
    local run_as args password

    run_as="${OE_USER:-${DB_USER:-odoo}}"
    password="${1:-$ODOO_CONF_DB_PASSWORD}"
    args=()
    [ -n "$ODOO_CONF_DB_USER" ] && args+=("-U" "$ODOO_CONF_DB_USER")
    [ -n "$ODOO_CONF_DB_HOST" ] && args+=("-h" "$ODOO_CONF_DB_HOST")
    [ -n "$ODOO_CONF_DB_PORT" ] && args+=("-p" "$ODOO_CONF_DB_PORT")

    sudo -u "$run_as" env PGPASSWORD="$password" pg_dump "${args[@]}" \
        -F c -b -f "${BACKUP_DIR}/${DB_NAME}.dump" "$DB_NAME" \
        >> "$LOG_FILE" 2>&1
}

do_odoo_http_backup() {
    ODOO_PORT_EFFECTIVE="${ODOO_PORT:-8069}"
    MASTER_PASS_EFFECTIVE="${MASTER_PASS:-${ODOO_MASTER_PASS:-}}"
    if [ -z "$MASTER_PASS_EFFECTIVE" ]; then
        read -s -p "Odoo master password: " MASTER_PASS_EFFECTIVE
        echo ""
    fi
    BACKUP_ZIP="${BACKUP_DIR}/${DB_NAME}.zip"
    HTTP_CODE=$(curl -sS -o "$BACKUP_ZIP" -w "%{http_code}" \
        -X POST "http://127.0.0.1:${ODOO_PORT_EFFECTIVE}/web/database/backup" \
        -F backup_format=zip \
        -F master_pwd="$MASTER_PASS_EFFECTIVE" \
        -F name="$DB_NAME" 2>>"$LOG_FILE")
    if ! [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
        log "[ERROR] Odoo HTTP backup failed (no HTTP code)"
        return 1
    fi
    if [ "$HTTP_CODE" -ge 400 ]; then
        log "[ERROR] Odoo HTTP backup failed (HTTP $HTTP_CODE)"
        return 1
    fi
    if [ ! -s "$BACKUP_ZIP" ]; then
        log "[ERROR] Odoo HTTP backup produced empty file"
        return 1
    fi
    if [ "$(head -c 2 "$BACKUP_ZIP")" != "PK" ]; then
        log "[ERROR] Odoo HTTP backup is not a ZIP file (see log for response)"
        head -c 200 "$BACKUP_ZIP" >>"$LOG_FILE" 2>&1 || true
        return 1
    fi
}

if [ "$BACKUP_METHOD" = "odoo" ]; then
    if ! do_odoo_http_backup; then
        log "[ERROR] Odoo HTTP backup failed"
        exit 1
    fi
elif [ "$BACKUP_METHOD" = "auto" ]; then
    if ! do_pg_dump "${DB_PASSWORD:-${DB_PASS:-}}"; then
        if do_pg_dump_as_odoo_user; then
            log "[INFO] pg_dump completed using Odoo config/local user"
        else
            log "[WARN] pg_dump failed — prompting for password"
            read -s -p "Postgres password for user ${DB_USER}: " DB_PASS_PROMPT
            echo ""
            if ! do_pg_dump "$DB_PASS_PROMPT"; then
                log "[WARN] pg_dump failed — trying Odoo HTTP backup"
                if ! do_odoo_http_backup; then
                    log "[ERROR] Odoo HTTP backup failed"
                    exit 1
                fi
            fi
        fi
    fi
else
    if ! do_pg_dump "${DB_PASSWORD:-${DB_PASS:-}}"; then
        if do_pg_dump_as_odoo_user; then
            log "[INFO] pg_dump completed using Odoo config/local user"
        else
            log "[WARN] pg_dump failed — prompting for password"
            read -s -p "Postgres password for user ${DB_USER}: " DB_PASS_PROMPT
            echo ""
            if ! do_pg_dump "$DB_PASS_PROMPT"; then
                log "[ERROR] DB backup failed"
                exit 1
            fi
        fi
    fi
fi

log "[INFO] Checking local changes..."
if ! run_repo_git diff --quiet; then
    log "[WARN] Local changes found — auto-stash..."
    run_repo_git stash push -m "auto-stash-before-update-$(date +%F-%H%M%S)" \
        >>"$LOG_FILE" 2>&1
    STASHED=1
else
    log "[INFO] No local changes."
    STASHED=0
fi

log "[INFO] Fetch + change check..."
if ! run_repo_git fetch --all >>"$LOG_FILE" 2>&1; then
    log "[ERROR] git fetch failed"
    exit 1
fi

CHANGED=$(run_repo_git diff --name-only HEAD "origin/$BRANCH" | wc -l)
if [ "$CHANGED" -eq 0 ]; then
    log "[INFO] No remote changes — nothing to do."
    if [ "$STASHED" -eq 1 ]; then
        log "[INFO] Restoring stash..."
        run_repo_git stash pop >>"$LOG_FILE" 2>&1 || log "[WARN] stash pop had conflicts."
    fi
    exit 0
fi

OLD_COMMIT=$(run_repo_git rev-parse HEAD)

log "[INFO] Pulling changes from origin/$BRANCH..."
if ! run_repo_git pull origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
    log "[ERROR] git pull failed — rollback to $OLD_COMMIT"
    run_repo_git reset --hard "$OLD_COMMIT" >>"$LOG_FILE" 2>&1
    exit 1
fi

if [ "$STASHED" -eq 1 ]; then
    log "[INFO] Restoring stash..."
    run_repo_git stash pop >>"$LOG_FILE" 2>&1 || log "[WARN] stash pop had conflicts."
fi

REQ_FILE="$PROJECT_DIR/requirements.txt"
if [ -f "$REQ_FILE" ]; then
    if run_repo_git diff --name-only "$OLD_COMMIT" HEAD | grep -q "requirements.txt"; then
        log "[INFO] requirements.txt changed — pip install..."
        sudo -u "$OE_USER" "$OE_HOME/venv/bin/pip" install -r "$REQ_FILE" \
            >>"$LOG_FILE" 2>&1 || {
                log "[ERROR] pip install failed — rollback to $OLD_COMMIT"
                run_repo_git reset --hard "$OLD_COMMIT" >>"$LOG_FILE" 2>&1
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
