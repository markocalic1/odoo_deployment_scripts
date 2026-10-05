#!/bin/bash
# Independent Odoo ZIP backup and local restore. No SSH transfer or deployment.
set -euo pipefail
umask 077

usage() {
    echo "Usage: odooctl backup <instance|env-file> [output-directory]"
    echo "       odooctl restore <instance|env-file> <backup.zip> [--replace]"
}
fail() { echo "Error: $*" >&2; exit 1; }
ACTION="${1:-}"
ENV_ARG="${2:-}"
[[ "$ACTION" == backup || "$ACTION" == restore ]] || { usage; exit 1; }
[[ -n "$ENV_ARG" ]] || { usage; exit 1; }
if [[ "$ENV_ARG" == */* || "$ENV_ARG" == *.env ]]; then
    ENV_FILE="$ENV_ARG"
else
    ENV_FILE="/etc/odoo_deploy/$ENV_ARG.env"
fi
[[ -f "$ENV_FILE" ]] || fail "Missing env: $ENV_FILE"
TARGET="${3:-}"
REPLACE="${4:-}"
[[ $# -le 4 ]] || fail "Too many arguments"
[[ -z "$REPLACE" || ( "$ACTION" == restore && "$REPLACE" == --replace ) ]] || fail "Unknown option: $REPLACE"
# Repository Docker envs are parsed by Compose, not executed as shell code.
DOCKER_REPO_ENV=false
if [[ "$(basename "$ENV_FILE")" == env || "$(basename "$ENV_FILE")" == .env ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DOCKER_TARGET="$(python3 "$SCRIPT_DIR/odoo-docker-target.py" "$ENV_FILE")"
    IFS=$'\t' read -r COMPOSE_FILE COMPOSE_SERVICE ODOO_BIN CONFIG_PATH DATA_DIR DB_NAME <<< "$DOCKER_TARGET"
    RUNTIME=docker
    ENVIRONMENT=local
    DOCKER_REPO_ENV=true
else
    # Deployment env files are trusted local shell configuration.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
: "${DB_NAME:?DB_NAME is required in env}"
RUNTIME="${RUNTIME:-systemd}"
OE_USER="${OE_USER:-odoo}"
SERVICE_NAME="${SERVICE_NAME:-odoo}"

if [[ "$RUNTIME" == docker ]]; then
    [[ "$ACTION" == restore ]] || fail "Docker backup is not supported by this command"
    : "${COMPOSE_FILE:?COMPOSE_FILE is required}"
    : "${COMPOSE_SERVICE:?COMPOSE_SERVICE is required}"
    : "${ODOO_BIN:?ODOO_BIN is required}"
    : "${CONFIG_PATH:?CONFIG_PATH is required}"
    : "${DATA_DIR:?DATA_DIR is required}"
    [[ -f "$COMPOSE_FILE" ]] || fail "Missing Compose file: $COMPOSE_FILE"
    COMPOSE=(docker compose -f "$COMPOSE_FILE")
    if [[ "$DOCKER_REPO_ENV" == true ]]; then
        COMPOSE=(docker compose --env-file "$(realpath "$ENV_FILE")" -f "$COMPOSE_FILE")
    fi
elif [[ "$RUNTIME" == systemd ]]; then
    : "${OE_HOME:?OE_HOME is required}"
    CONFIG_PATH="${CONFIG_PATH:-/etc/${SERVICE_NAME%.service}.conf}"
    DATA_DIR="${DATA_DIR:-$OE_HOME/.local/share/Odoo}"
    [[ -r "$CONFIG_PATH" ]] || fail "Missing config: $CONFIG_PATH"
    if [[ -n "${ODOO_BIN:-}" ]]; then
        ODOO=("$ODOO_BIN")
    elif [[ -x "$OE_HOME/venv/bin/odoo" ]]; then
        ODOO=("$OE_HOME/venv/bin/odoo")
    else
        ODOO=("$OE_HOME/venv/bin/python3" "$OE_HOME/odoo/odoo-bin")
    fi
    [[ -x "${ODOO[0]}" ]] || fail "Odoo executable missing: ${ODOO[0]}"
else
    fail "RUNTIME must be systemd or docker"
fi

validate_zip() {
    python3 - "$1" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None, 'Corrupt ZIP member'
    assert z.getinfo('dump.sql').file_size > 0, 'Missing or empty SQL dump'
    assert 'manifest.json' in z.namelist(), 'Missing Odoo manifest'
    # A database with no attachments may legitimately have an empty filestore.
print('Odoo ZIP integrity: OK')
PY
}

if [[ "$ACTION" == backup ]]; then
    [[ -z "$REPLACE" ]] || fail "Backup does not accept --replace"
    OUTPUT_DIR="${TARGET:-${BACKUP_DIR:-$OE_HOME/backups}}"
    install -d -m 0700 -o "$OE_USER" -g "$OE_USER" "$OUTPUT_DIR"
    OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
    ARCHIVE="$OUTPUT_DIR/${DB_NAME}-$(date -u +%Y%m%dT%H%M%SZ)-$$.zip"
    systemctl is-active --quiet "$SERVICE_NAME" || fail "Service is not active: $SERVICE_NAME"
    # Resume the initially active service even if stop or dump fails.
    trap 'systemctl start "$SERVICE_NAME"' EXIT
    systemctl stop "$SERVICE_NAME"
    sudo -u "$OE_USER" "${ODOO[@]}" db -c "$CONFIG_PATH" -D "$DATA_DIR" \
        dump "$DB_NAME" "$ARCHIVE"
    validate_zip "$ARCHIVE"
    chmod 600 "$ARCHIVE"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
    chown "$OE_USER:$OE_USER" "$ARCHIVE.sha256"
    systemctl start "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME"
    trap - EXIT
    printf 'Backup: %s\nChecksum: %s.sha256\n' "$ARCHIVE" "$ARCHIVE"
    exit 0
fi

[[ "${ENVIRONMENT:-}" == local || "${ENVIRONMENT:-}" == staging ]] || \
    fail "Restore requires ENVIRONMENT=local or staging in the target env"
[[ -n "$TARGET" && -f "$TARGET" ]] || fail "Backup ZIP is required"
ARCHIVE="$(realpath "$TARGET")"
validate_zip "$ARCHIVE"
if [[ -f "$ARCHIVE.sha256" ]]; then
    (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256")
fi
LOAD=(load --neutralize)
[[ "$REPLACE" != --replace ]] || LOAD+=(--force)
LOAD+=("$DB_NAME")
echo "Restore target: $DB_NAME ($RUNTIME); replace: ${REPLACE:-(no)}"
STOPPED=false
restore_failure() {
    local result=$?
    [[ -z "${TEMP_ARCHIVE:-}" ]] || rm -f "$TEMP_ARCHIVE"
    [[ -z "${TEMP_DIR:-}" ]] || rmdir "$TEMP_DIR"
    if [[ "$result" != 0 && "$STOPPED" == true ]]; then
        echo "Restore failed. Target service remains stopped; review before starting it." >&2
    fi
}
trap restore_failure EXIT
if [[ "$RUNTIME" == docker ]]; then
    # Bind only this readable file; the private host directory remains mode 0700.
    TEMP_DIR="$(mktemp -d /tmp/odoo-restore-XXXXXXXX)"
    TEMP_ARCHIVE="$TEMP_DIR/input.zip"
    install -m 0644 "$ARCHIVE" "$TEMP_ARCHIVE"
    "${COMPOSE[@]}" stop "$COMPOSE_SERVICE"
    STOPPED=true
    "${COMPOSE[@]}" run --rm --no-deps --user "$OE_USER" \
        --volume "$TEMP_ARCHIVE:/backup/input.zip:ro" \
        --entrypoint "$ODOO_BIN" "$COMPOSE_SERVICE" \
        db -c "$CONFIG_PATH" -D "$DATA_DIR" "${LOAD[@]}" /backup/input.zip
    "${COMPOSE[@]}" start "$COMPOSE_SERVICE"
else
    # sudo -u odoo must be able to read the ZIP regardless of its original owner.
    TEMP_ARCHIVE="$(mktemp /tmp/odoo-restore-XXXXXXXX.zip)"
    install -m 0600 -o "$OE_USER" -g "$OE_USER" "$ARCHIVE" "$TEMP_ARCHIVE"
    systemctl stop "$SERVICE_NAME"
    STOPPED=true
    sudo -u "$OE_USER" "${ODOO[@]}" db -c "$CONFIG_PATH" -D "$DATA_DIR" \
        "${LOAD[@]}" "$TEMP_ARCHIVE"
    systemctl start "$SERVICE_NAME"
fi
rm -f "$TEMP_ARCHIVE"
[[ -z "${TEMP_DIR:-}" ]] || rmdir "$TEMP_DIR"
STOPPED=false
trap - EXIT
echo "Restore complete: $DB_NAME (neutralized)"
