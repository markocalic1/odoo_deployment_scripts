#!/bin/bash
set -e

STAGING_ENV=""
DB_NAME=""
DB_USER=""
DB_HOST=""
DB_PORT=""
BASE_URL=""
SERVICE_NAME=""
OE_HOME=""
OE_USER=""
ODOO_BIN=""
CONFIG_PATH=""
DRY_RUN="false"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --env) STAGING_ENV="$2"; shift ;;
        --db) DB_NAME="$2"; shift ;;
        --db-user) DB_USER="$2"; shift ;;
        --db-host) DB_HOST="$2"; shift ;;
        --db-port) DB_PORT="$2"; shift ;;
        --base-url) BASE_URL="$2"; shift ;;
        --service) SERVICE_NAME="$2"; shift ;;
        --oe-home) OE_HOME="$2"; shift ;;
        --oe-user) OE_USER="$2"; shift ;;
        --odoo-bin) ODOO_BIN="$2"; shift ;;
        --config) CONFIG_PATH="$2"; shift ;;
        --dry-run) DRY_RUN="true" ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
    shift
done

if [ -n "$STAGING_ENV" ]; then
    if [ ! -f "$STAGING_ENV" ]; then
        echo "❌ Staging env not found: $STAGING_ENV"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$STAGING_ENV"
    ENV_DB_NAME="$DB_NAME"
    ENV_DB_USER="$DB_USER"
    ENV_DB_HOST="$DB_HOST"
    ENV_DB_PORT="$DB_PORT"
    ENV_BASE_URL="${STAGING_BASE_URL:-${BASE_URL:-}}"
    ENV_SERVICE_NAME="${SERVICE_NAME:-odoo}"
    ENV_OE_HOME="$OE_HOME"
    ENV_OE_USER="$OE_USER"
fi

DB_NAME="${DB_NAME:-$ENV_DB_NAME}"
DB_USER="${DB_USER:-$ENV_DB_USER}"
DB_HOST="${DB_HOST:-$ENV_DB_HOST}"
DB_PORT="${DB_PORT:-$ENV_DB_PORT}"
BASE_URL="${BASE_URL:-$ENV_BASE_URL}"
SERVICE_NAME="${SERVICE_NAME:-$ENV_SERVICE_NAME}"
OE_HOME="${OE_HOME:-$ENV_OE_HOME}"
OE_USER="${OE_USER:-$ENV_OE_USER}"

if [ -z "$DB_NAME" ]; then
    echo "❌ DB name is required (--db or via env file)"
    exit 1
fi

if [ -z "$DB_HOST" ]; then DB_HOST="localhost"; fi
if [ -z "$DB_PORT" ]; then DB_PORT="5432"; fi
if [ -z "$DB_USER" ]; then DB_USER="odoo"; fi
if [ -z "$SERVICE_NAME" ]; then SERVICE_NAME="odoo"; fi

detect_odoo_config() {
    local service_file config_path
    for service_file in \
        "/etc/systemd/system/${SERVICE_NAME}.service" \
        "/lib/systemd/system/${SERVICE_NAME}.service" \
        "/usr/lib/systemd/system/${SERVICE_NAME}.service"; do
        [ -f "$service_file" ] || continue
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
        if [ -n "$config_path" ] && [ -f "$config_path" ]; then
            echo "$config_path"
            return 0
        fi
    done

    for config_path in "/etc/${SERVICE_NAME}.conf" "/etc/odoo.conf"; do
        if [ -f "$config_path" ]; then
            echo "$config_path"
            return 0
        fi
    done
    return 1
}

detect_odoo_bin() {
    local service_file odoo_path
    for service_file in \
        "/etc/systemd/system/${SERVICE_NAME}.service" \
        "/lib/systemd/system/${SERVICE_NAME}.service" \
        "/usr/lib/systemd/system/${SERVICE_NAME}.service"; do
        [ -f "$service_file" ] || continue
        odoo_path=$(awk '
            /^ExecStart=/ {
                line = substr($0, index($0, "=") + 1)
                n = split(line, args, /[[:space:]]+/)
                for (i = 1; i <= n; i++) {
                    gsub(/^"|"$/, "", args[i])
                    if (args[i] ~ /odoo-bin$/ || args[i] ~ /\/odoo$/) {
                        print args[i]
                        exit
                    }
                }
            }
        ' "$service_file")
        if [ -n "$odoo_path" ] && [ -x "$odoo_path" ]; then
            echo "$odoo_path"
            return 0
        fi
    done
    return 1
}

if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH=$(detect_odoo_config || true)
fi
if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ]; then
    echo "❌ Could not detect Odoo config path. Use --config or provide a service/env with a valid config."
    exit 1
fi

if [ -z "$ODOO_BIN" ]; then
    if [ -n "$OE_HOME" ] && [ -x "$OE_HOME/odoo/odoo-bin" ]; then
        ODOO_BIN="$OE_HOME/odoo/odoo-bin"
    elif ODOO_BIN_DETECTED=$(detect_odoo_bin || true) && [ -n "$ODOO_BIN_DETECTED" ]; then
        ODOO_BIN="$ODOO_BIN_DETECTED"
    elif command -v odoo >/dev/null 2>&1; then
        ODOO_BIN="$(command -v odoo)"
    else
        echo "❌ Could not detect odoo-bin. Use --odoo-bin or provide OE_HOME in env."
        exit 1
    fi
fi

run_odoo() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "---- COMMAND ----"
        if [ -n "$OE_USER" ]; then
            echo "sudo -u $OE_USER $ODOO_BIN neutralize -c $CONFIG_PATH -d $DB_NAME"
        else
            echo "$ODOO_BIN neutralize -c $CONFIG_PATH -d $DB_NAME"
        fi
        return 0
    fi

    if [ -n "$OE_USER" ]; then
        sudo -u "$OE_USER" "$ODOO_BIN" neutralize -c "$CONFIG_PATH" -d "$DB_NAME"
    else
        "$ODOO_BIN" neutralize -c "$CONFIG_PATH" -d "$DB_NAME"
    fi
}

run_sql() {
    local sql="$1"
    if [ "$DRY_RUN" = "true" ]; then
        echo "---- SQL ----"
        echo "$sql"
        return 0
    fi
    if PGPASSWORD="${DB_PASSWORD:-${DB_PASS:-}}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -qc "$sql" >/dev/null 2>&1; then
        return 0
    fi
    sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -qc "$sql"
}

echo "========================================="
echo "Odoo Neutralize"
echo "-----------------------------------------"
echo "Database:          $DB_NAME"
echo "Config:            $CONFIG_PATH"
echo "Odoo bin:          $ODOO_BIN"
echo "Odoo user:         ${OE_USER:-<current user>}"
echo "Base URL:          ${BASE_URL:-<unchanged>}"
echo "Dry run:           $DRY_RUN"
echo "========================================="

run_odoo
echo "✓ Odoo CLI neutralize completed"

if [ -n "$BASE_URL" ]; then
    run_sql "
        INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
        VALUES ('web.base.url', '${BASE_URL}', 1, 1, now(), now())
        ON CONFLICT (key)
        DO UPDATE SET value = EXCLUDED.value, write_uid = 1, write_date = now();
    "
    echo "✓ web.base.url updated"
fi

echo "✅ Neutralization completed"
