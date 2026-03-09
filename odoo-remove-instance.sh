#!/bin/bash
set -e

# Remove an Odoo instance created with odoo_install.sh
# Safe defaults: remove service + config + deploy env
# Destructive actions are opt-in flags.

usage() {
    cat <<EOF
Usage: sudo bash $0 <instance_name> [options]

Options:
  --drop-db            Drop database from env (DB_NAME)
  --delete-home        Delete OE_HOME directory
  --delete-user        Delete Linux user (OE_USER)
  --delete-pg-user     Delete PostgreSQL user (DB_USER)
  --dry-run            Print actions without changing anything
  --yes                Skip interactive confirmation
  -h, --help           Show this help

Examples:
  sudo bash $0 staging19
  sudo bash $0 staging19 --drop-db --delete-home --yes
EOF
}

INSTANCE_NAME="$1"
if [ -z "$INSTANCE_NAME" ] || [ "$INSTANCE_NAME" = "-h" ] || [ "$INSTANCE_NAME" = "--help" ]; then
    usage
    exit 0
fi
shift

DROP_DB="false"
DELETE_HOME="false"
DELETE_USER="false"
DELETE_PG_USER="false"
DRY_RUN="false"
ASSUME_YES="false"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --drop-db) DROP_DB="true" ;;
        --delete-home) DELETE_HOME="true" ;;
        --delete-user) DELETE_USER="true" ;;
        --delete-pg-user) DELETE_PG_USER="true" ;;
        --dry-run) DRY_RUN="true" ;;
        --yes) ASSUME_YES="true" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
done

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (use sudo)."
    exit 1
fi

ENV_FILE="/etc/odoo_deploy/${INSTANCE_NAME}.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Instance env not found: $ENV_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

SERVICE_NAME="${SERVICE_NAME:-odoo}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_PATH=""
if [ -f "$SERVICE_FILE" ]; then
    CONFIG_PATH=$(grep -oP '(?<=-c ).+' "$SERVICE_FILE" | tr -d ' ' || true)
fi

LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
DB_USER_EFFECTIVE="${DB_USER:-$OE_USER}"
DB_HOST_EFFECTIVE="${DB_HOST:-localhost}"
DB_PORT_EFFECTIVE="${DB_PORT:-5432}"

print_action() {
    echo "  - $1"
}

run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

echo "Instance:        $INSTANCE_NAME"
echo "Env file:        $ENV_FILE"
echo "Service:         $SERVICE_NAME"
echo "Service file:    $SERVICE_FILE"
echo "Config file:     ${CONFIG_PATH:-<not detected>}"
echo "OE_HOME:         ${OE_HOME:-<empty>}"
echo "OE_USER:         ${OE_USER:-<empty>}"
echo "DB_NAME:         ${DB_NAME:-<empty>}"
echo "DB_USER:         ${DB_USER_EFFECTIVE:-<empty>}"
echo ""
echo "Planned actions:"
print_action "Stop and disable systemd service (if exists)"
print_action "Remove service file"
print_action "Remove Odoo config file (if detected)"
print_action "Remove deploy env file"
print_action "Remove logrotate file /etc/logrotate.d/${SERVICE_NAME} (if exists)"

if [ "$DROP_DB" = "true" ]; then
    print_action "Drop database: ${DB_NAME:-<empty>}"
fi
if [ "$DELETE_HOME" = "true" ]; then
    print_action "Delete OE_HOME: ${OE_HOME:-<empty>}"
fi
if [ "$DELETE_USER" = "true" ]; then
    print_action "Delete Linux user: ${OE_USER:-<empty>}"
fi
if [ "$DELETE_PG_USER" = "true" ]; then
    print_action "Delete PostgreSQL user: ${DB_USER_EFFECTIVE:-<empty>}"
fi

if [ "$ASSUME_YES" != "true" ]; then
    echo ""
    read -r -p "Type instance name '${INSTANCE_NAME}' to confirm: " CONFIRM
    if [ "$CONFIRM" != "$INSTANCE_NAME" ]; then
        echo "❌ Confirmation mismatch. Aborted."
        exit 1
    fi
fi

echo ""
echo "=== Removing instance: ${INSTANCE_NAME} ==="

if systemctl list-unit-files | awk '{print $1}' | grep -qx "${SERVICE_NAME}.service"; then
    run_cmd "systemctl disable --now \"$SERVICE_NAME\" || true"
else
    echo "ℹ Service unit not registered: ${SERVICE_NAME}.service"
fi

if [ -f "$SERVICE_FILE" ]; then
    run_cmd "rm -f \"$SERVICE_FILE\""
fi

if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    run_cmd "rm -f \"$CONFIG_PATH\""
fi

if [ -f "$LOGROTATE_FILE" ]; then
    run_cmd "rm -f \"$LOGROTATE_FILE\""
fi

if [ -f "$ENV_FILE" ]; then
    run_cmd "rm -f \"$ENV_FILE\""
fi

run_cmd "systemctl daemon-reload"

if [ "$DROP_DB" = "true" ]; then
    if [ -z "$DB_NAME" ]; then
        echo "⚠ DB_NAME is empty in env; skip drop-db."
    else
        run_cmd "sudo -u postgres psql -Atqc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" | grep -q 1 && sudo -u postgres dropdb -h \"${DB_HOST_EFFECTIVE}\" -p \"${DB_PORT_EFFECTIVE}\" \"${DB_NAME}\" || true"
    fi
fi

if [ "$DELETE_HOME" = "true" ]; then
    if [ -n "$OE_HOME" ] && [ "$OE_HOME" != "/" ]; then
        run_cmd "rm -rf \"$OE_HOME\""
    else
        echo "⚠ OE_HOME is empty or invalid; skip delete-home."
    fi
fi

if [ "$DELETE_USER" = "true" ]; then
    if [ -n "$OE_USER" ] && id "$OE_USER" >/dev/null 2>&1; then
        run_cmd "deluser --remove-home \"$OE_USER\" || true"
    else
        echo "ℹ Linux user not found: ${OE_USER}"
    fi
fi

if [ "$DELETE_PG_USER" = "true" ]; then
    if [ -n "$DB_USER_EFFECTIVE" ]; then
        run_cmd "sudo -u postgres psql -Atqc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER_EFFECTIVE}'\" | grep -q 1 && sudo -u postgres dropuser \"${DB_USER_EFFECTIVE}\" || true"
    else
        echo "⚠ DB user is empty; skip delete-pg-user."
    fi
fi

echo "✓ Removal completed for ${INSTANCE_NAME}"
