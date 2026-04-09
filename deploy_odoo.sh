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

INSTANCE_NAME=""
NO_DB_BACKUP="false"
VERBOSE="${VERBOSE:-false}"

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose)
            VERBOSE="true"
            ;;
        --no-db-backup|no-db-backup)
            NO_DB_BACKUP="true"
            ;;
        *)
            if [ -z "$INSTANCE_NAME" ]; then
                INSTANCE_NAME="$1"
            else
                echo "Usage: $0 <instance_name> [--no-db-backup] [--verbose]"
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$INSTANCE_NAME" ]; then
    echo "Usage: $0 <instance_name> [--no-db-backup] [--verbose]"
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
FIX_REPO_PERMS="${FIX_REPO_PERMS:-true}"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$DEPLOY_LOG")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DEPLOY_LOG"
}

step() {
    LAST_STEP="$*"
    log "==== $* ===="
}

verbose_log() {
    if [ "$VERBOSE" = "true" ]; then
        log "ℹ $*"
    fi
}

log_http_response_preview() {
    local response_file="$1"
    local header_file="$2"

    if [ -s "$header_file" ]; then
        verbose_log "Odoo HTTP response headers:"
        sed 's/\r$//' "$header_file" >>"$DEPLOY_LOG" 2>&1 || true
    fi

    log "❌ Odoo HTTP response preview:"
    LC_ALL=C tr -d '\000' <"$response_file" | head -c 600 >>"$DEPLOY_LOG" 2>&1 || true
}

LAST_STEP="INIT"
trap 'log "❌ DEPLOY FAILED (step: ${LAST_STEP})"; log "============== END DEPLOY [$INSTANCE_NAME] (FAILED) =============="; exit 1' ERR

log "============== START DEPLOY [$INSTANCE_NAME] =============="
log "→ Config: $CONFIG_FILE"
log "→ Repo dir: ${REPO_DIR:-$OE_HOME/src}"
log "→ Backup method: ${BACKUP_METHOD}"
log "→ Service: ${SERVICE_NAME}"
log "→ Verbose mode: ${VERBOSE}"

run_repo_git() {
    if sudo -u "$OE_USER" -H git "$@"; then
        return 0
    fi

    if [ "$EUID" -eq 0 ]; then
        log "⚠ Git access as $OE_USER failed, retrying with root git credentials"
        git "$@"
        chown -R "$OE_USER:$OE_USER" "$REPO_PATH" >>"$DEPLOY_LOG" 2>&1
        return 0
    fi

    return 1
}

detect_odoo_config() {
    local service service_file config_path

    service="${SERVICE_NAME:-odoo}"
    service_file="/etc/systemd/system/${service}.service"
    if [ ! -f "$service_file" ]; then
        service_file="/lib/systemd/system/${service}.service"
        [ -f "$service_file" ] || service_file="/usr/lib/systemd/system/${service}.service"
        [ -f "$service_file" ] || service_file=""
    fi

    if [ -n "$service_file" ]; then
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
    fi

    if [ ! -f "$config_path" ]; then
        for candidate in "/etc/${service}.conf" "/etc/odoo.conf"; do
            if [ -f "$candidate" ]; then
                config_path="$candidate"
                break
            fi
        done
    fi

    [ -f "$config_path" ] || return 1

    echo "$config_path"
    return 0
}

ODOO_CONF_DB_USER=""
ODOO_CONF_DB_HOST=""
ODOO_CONF_DB_PORT=""
ODOO_CONF_DB_PASSWORD=""

read_odoo_conf_value() {
    local key="$1"
    local config_path="$2"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$config_path" | head -n1
}

load_db_settings_from_odoo_config() {
    local config_path

    config_path=$(detect_odoo_config) || return 0

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

#########################################################################
# BACKUP
#########################################################################

step "BACKUP"
log "→ Creating backup directory: $BACKUP_DIR"

# 1. Database backup (optional)
if [ -n "$DB_NAME" ] && [ "$NO_DB_BACKUP" != "true" ]; then
    log "→ Dumping database: $DB_NAME (method: ${BACKUP_METHOD})"
    load_db_settings_from_odoo_config

    PG_DUMP_ARGS=()
    [ -n "$DB_USER" ] && PG_DUMP_ARGS+=("-U" "$DB_USER")
    [ -n "$DB_HOST" ] && PG_DUMP_ARGS+=("-h" "$DB_HOST")
    [ -n "$DB_PORT" ] && PG_DUMP_ARGS+=("-p" "$DB_PORT")

    do_pg_dump() {
        PGPASSWORD="$1" pg_dump "${PG_DUMP_ARGS[@]}" \
            -F c -b -f "${BACKUP_DIR}/${DB_NAME}.dump" "$DB_NAME" \
            >> "$DEPLOY_LOG" 2>&1
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
            >> "$DEPLOY_LOG" 2>&1
    }

    do_odoo_backup() {
        local ODOO_PORT_EFFECTIVE MASTER_PASS_EFFECTIVE BACKUP_ZIP HTTP_CODE HEADER_FILE CONTENT_TYPE

        ODOO_PORT_EFFECTIVE="${ODOO_PORT:-8069}"
        MASTER_PASS_EFFECTIVE="${MASTER_PASS:-${ODOO_MASTER_PASS:-}}"
        if [ -z "$MASTER_PASS_EFFECTIVE" ]; then
            read -s -p "Odoo master password: " MASTER_PASS_EFFECTIVE
            echo ""
        fi
        BACKUP_ZIP="${BACKUP_DIR}/${DB_NAME}.zip"
        HEADER_FILE="${BACKUP_DIR}/${DB_NAME}.headers"
        verbose_log "Requesting Odoo HTTP backup from http://127.0.0.1:${ODOO_PORT_EFFECTIVE}/web/database/backup for database ${DB_NAME}"
        HTTP_CODE=$(curl -sS -o "$BACKUP_ZIP" -w "%{http_code}" \
            -D "$HEADER_FILE" \
            -X POST "http://127.0.0.1:${ODOO_PORT_EFFECTIVE}/web/database/backup" \
            -F backup_format=zip \
            -F master_pwd="$MASTER_PASS_EFFECTIVE" \
            -F name="$DB_NAME" 2>>"$DEPLOY_LOG")
        CONTENT_TYPE=$(awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ {sub(/\r$/, "", $0); sub(/^Content-Type:[[:space:]]*/, "", $0); print; exit}' "$HEADER_FILE")
        [ -n "$CONTENT_TYPE" ] && verbose_log "Odoo HTTP response content type: $CONTENT_TYPE"
        if ! [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
            log "❌ Odoo HTTP backup failed (no HTTP code) — check service/port/db_manager"
            [ -s "$HEADER_FILE" ] && log_http_response_preview "$BACKUP_ZIP" "$HEADER_FILE"
            return 1
        fi
        if [ "$HTTP_CODE" -ge 400 ]; then
            log "❌ Odoo HTTP backup failed (HTTP $HTTP_CODE)"
            log_http_response_preview "$BACKUP_ZIP" "$HEADER_FILE"
            return 1
        fi
        if [ ! -s "$BACKUP_ZIP" ]; then
            log "❌ Odoo HTTP backup produced empty file"
            [ -s "$HEADER_FILE" ] && log_http_response_preview "$BACKUP_ZIP" "$HEADER_FILE"
            return 1
        fi
        if [ "$(head -c 2 "$BACKUP_ZIP")" != "PK" ]; then
            log "❌ Odoo HTTP backup is not a ZIP file (see log for response)"
            log_http_response_preview "$BACKUP_ZIP" "$HEADER_FILE"
            return 1
        fi
        verbose_log "Odoo HTTP backup saved to $BACKUP_ZIP"
    }

    if [ "$BACKUP_METHOD" = "odoo" ]; then
        if ! do_odoo_backup; then
            log "❌ Odoo backup failed"
            exit 1
        fi
        log "✓ Odoo backup completed"
    elif [ "$BACKUP_METHOD" = "auto" ]; then
        if ! do_pg_dump "${DB_PASSWORD:-${DB_PASS:-}}"; then
            if do_pg_dump_as_odoo_user; then
                log "✓ pg_dump completed using Odoo config/local user"
            else
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
            fi
        else
            log "✓ pg_dump completed"
        fi
    else
        if ! do_pg_dump "${DB_PASSWORD:-${DB_PASS:-}}"; then
            if do_pg_dump_as_odoo_user; then
                log "✓ pg_dump completed using Odoo config/local user"
            else
                log "⚠ DB backup failed — prompting for password"
                read -s -p "Postgres password for user ${DB_USER}: " DB_PASS_PROMPT
                echo ""
                if ! do_pg_dump "$DB_PASS_PROMPT"; then
                    log "❌ DB backup failed"
                    exit 1
                fi
                log "✓ pg_dump completed (after prompt)"
            fi
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
git config --global --add safe.directory "$REPO_PATH" >>"$DEPLOY_LOG" 2>&1 || true

if ! sudo -u "$OE_USER" test -w "$REPO_PATH/.git" 2>/dev/null; then
    if [ "$FIX_REPO_PERMS" = "true" ]; then
        log "⚠ Fixing repo permissions for $REPO_PATH (chown to $OE_USER)"
        chown -R "$OE_USER:$OE_USER" "$REPO_PATH" >>"$DEPLOY_LOG" 2>&1 || {
            log "❌ Cannot fix repo permissions (see log: $DEPLOY_LOG)"
            exit 1
        }
    else
        log "❌ Repo not writable by $OE_USER (set FIX_REPO_PERMS=true to auto-fix)"
        exit 1
    fi
fi

CURRENT_COMMIT=$(sudo -u "$OE_USER" git rev-parse HEAD)
log "→ Current commit: $CURRENT_COMMIT"

log "→ Fetching Git updates (origin/$BRANCH)"
if ! run_repo_git fetch --all >>"$DEPLOY_LOG" 2>&1; then
    log "❌ Git fetch failed (see log: $DEPLOY_LOG)"
    exit 1
fi

log "→ Resetting to origin/$BRANCH"
if ! run_repo_git reset --hard "origin/$BRANCH" >>"$DEPLOY_LOG" 2>&1; then
    log "❌ Git reset failed (see log: $DEPLOY_LOG)"
    exit 1
fi

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
if [ -z "$ODOO_PORT" ]; then
    CONFIG_PATH=$(detect_odoo_config || true)
    if [ -f "$CONFIG_PATH" ]; then
        CONF_PORT=$(sed -n 's/^[[:space:]]*http_port[[:space:]]*=[[:space:]]*\\([0-9]\\+\\).*/\\1/p' "$CONFIG_PATH" | head -n1)
        if [ -n "$CONF_PORT" ]; then
            ODOO_PORT="$CONF_PORT"
            log "ℹ ODOO_PORT not set — using http_port from $CONFIG_PATH: $ODOO_PORT"
        fi
    fi
fi
ODOO_PORT="${ODOO_PORT:-8069}"
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
