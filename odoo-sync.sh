#!/bin/bash
set -e

###########################################################################
# ODOO PRODUCTION → STAGING SYNC TOOL (WITH ODOO BACKUP OPTION)
###########################################################################

### DEFAULTS ###
PROD_SSH_USER="root"
RESTORE_METHOD="pg"     # restore method
BACKUP_METHOD="pg"      # backup method: pg | odoo | auto
BACKUP_DIR=""
STAGING_FS=""
PROD_BACKUP_DIR=""
PROD_FS=""
STAGING_SERVICE="odoo"
SKIP_FILESTORE="false"
PROD_MASTER_PASS=""
STAGING_MASTER_PASS=""
DROP_METHOD="auto" # auto | odoo | pg
SERVICE_WAS_STOPPED="false"
PROD_MASTER_PASS_ENV="${PROD_MASTER_PASS:-${ODOO_PROD_MASTER_PASS:-}}"
STAGING_MASTER_PASS_ENV="${STAGING_MASTER_PASS:-${ODOO_STAGING_MASTER_PASS:-}}"

PROD_DB_HOST=""
PROD_DB_PORT=""
PROD_DB_USER=""

### CONFIG FILES ###
PROD_ENV=""
STAGING_ENV=""

### PARSE ARGUMENTS ###
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --prod-env) PROD_ENV="$2"; shift ;;
        --staging-env) STAGING_ENV="$2"; shift ;;
        --prod-host) PROD_HOST="$2"; shift ;;
        --prod-ssh) PROD_SSH_USER="$2"; shift ;;
        --prod-db) PROD_DB="$2"; shift ;;
        --staging-db) STAGING_DB="$2"; shift ;;
        --prod-fs) PROD_FS="$2"; shift ;;
        --staging-fs) STAGING_FS="$2"; shift ;;
        --backup-dir) BACKUP_DIR="$2"; shift ;;
        --prod-backup-dir) PROD_BACKUP_DIR="$2"; shift ;;
        --staging-service) STAGING_SERVICE="$2"; shift ;;
        --prod-db-host) PROD_DB_HOST="$2"; shift ;;
        --prod-db-port) PROD_DB_PORT="$2"; shift ;;
        --prod-db-user) PROD_DB_USER="$2"; shift ;;
        --no-filestore) SKIP_FILESTORE="true" ;;
        --prod-master-pass) PROD_MASTER_PASS="$2"; shift ;;
        --staging-master-pass) STAGING_MASTER_PASS="$2"; shift ;;
        --drop-method) DROP_METHOD="$2"; shift ;;
        --method) RESTORE_METHOD="$2"; shift ;;  # restore method
        --backup-method) BACKUP_METHOD="$2"; shift ;;  # NEW
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

### LOAD ENV FILES (if provided) ###
if [ -n "$PROD_ENV" ]; then
    if [ ! -f "$PROD_ENV" ]; then
        echo "❌ Production env not found: $PROD_ENV"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$PROD_ENV"
    PROD_DB_ENV="$DB_NAME"
    PROD_OE_HOME_ENV="$OE_HOME"
    PROD_DB_USER_ENV="$DB_USER"
    PROD_DB_HOST_ENV="$DB_HOST"
    PROD_DB_PORT_ENV="$DB_PORT"
    PROD_ODOO_PORT_ENV="$ODOO_PORT"
    PROD_MASTER_PASS_ENV="${PROD_MASTER_PASS_ENV:-${MASTER_PASS:-${ODOO_MASTER_PASS:-}}}"
    PROD_FS_ENV="${OE_HOME}/.local/share/Odoo/filestore"
fi

if [ -n "$STAGING_ENV" ]; then
    if [ ! -f "$STAGING_ENV" ]; then
        echo "❌ Staging env not found: $STAGING_ENV"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$STAGING_ENV"
    STAGING_DB_ENV="$DB_NAME"
    STAGING_OE_HOME_ENV="$OE_HOME"
    STAGING_SERVICE_ENV="$SERVICE_NAME"
    STAGING_ODOO_PORT_ENV="$ODOO_PORT"
    STAGING_MASTER_PASS_ENV="${STAGING_MASTER_PASS_ENV:-${MASTER_PASS:-${ODOO_MASTER_PASS:-}}}"
    STAGING_FS_ENV="${OE_HOME}/.local/share/Odoo/filestore"
fi

### APPLY ENV VALUES WHEN NOT EXPLICITLY SET ###
PROD_DB="${PROD_DB:-$PROD_DB_ENV}"
STAGING_DB="${STAGING_DB:-$STAGING_DB_ENV}"

PROD_DB_USER="${PROD_DB_USER:-$PROD_DB_USER_ENV}"
PROD_DB_HOST="${PROD_DB_HOST:-$PROD_DB_HOST_ENV}"
PROD_DB_PORT="${PROD_DB_PORT:-$PROD_DB_PORT_ENV}"
PROD_ODOO_PORT="${PROD_ODOO_PORT:-$PROD_ODOO_PORT_ENV}"

STAGING_SERVICE="${STAGING_SERVICE:-$STAGING_SERVICE_ENV}"
STAGING_ODOO_PORT="${STAGING_ODOO_PORT:-$STAGING_ODOO_PORT_ENV}"

if [ -z "$BACKUP_DIR" ]; then
    if [ -n "$STAGING_OE_HOME_ENV" ]; then
        BACKUP_DIR="$STAGING_OE_HOME_ENV/backups"
    else
        BACKUP_DIR="/opt/odoo/backups"
    fi
fi

if [ -z "$PROD_BACKUP_DIR" ]; then
    PROD_BACKUP_DIR="${BACKUP_DIR:-/opt/odoo/backups}"
fi

if [ -z "$STAGING_FS" ] && [ -n "$STAGING_FS_ENV" ]; then
    STAGING_FS="$STAGING_FS_ENV"
fi
if [ -z "$STAGING_FS" ]; then
    STAGING_FS="/opt/odoo/.local/share/Odoo/filestore"
fi

if [ -z "$PROD_FS" ]; then
    PROD_FS="${PROD_FS_ENV:-$STAGING_FS}"
fi

### INTERACTIVE ###
if [ -z "$PROD_HOST" ]; then read -p "Production host/IP: " PROD_HOST; fi
if [ -z "$PROD_DB" ]; then read -p "Production DB name: " PROD_DB; fi

if [ -z "$STAGING_DB" ]; then
    DEFAULT_STAGING="${PROD_DB}_staging"
    read -p "Staging DB name [$DEFAULT_STAGING]: " STAGING_DB
    STAGING_DB=${STAGING_DB:-$DEFAULT_STAGING}
fi

if [[ "$BACKUP_METHOD" != "pg" && "$BACKUP_METHOD" != "odoo" && "$BACKUP_METHOD" != "auto" ]]; then
    echo "Choose backup method:"
    echo " 1) PostgreSQL pg_dump (fastest)"
    echo " 2) Odoo Web Backup (full zip including filestore)"
    echo " 3) Auto fallback (try pg_dump then Odoo)"
    read -p "Method [1/2/3] (default 1): " BM
    BACKUP_METHOD=$([[ "$BM" == "2" ]] && echo "odoo" || ([[ "$BM" == "3" ]] && echo "auto" || echo "pg"))
fi

PROD_SSH="${PROD_SSH_USER}@${PROD_HOST}"

echo "========================================="
echo "Odoo Sync: Production → Staging"
echo "-----------------------------------------"
echo "Production Host:   $PROD_HOST"
echo "Production DB:     $PROD_DB"
echo "Staging DB:        $STAGING_DB"
echo "Backup Method:     $BACKUP_METHOD"
echo "Restore Method:    $RESTORE_METHOD"
echo "========================================="


mkdir -p "$BACKUP_DIR"

###########################################################################
# STEP 1 — BACKUP ON PRODUCTION (pg_dump OR Odoo endpoint)
###########################################################################

echo "→ Starting backup process..."

###########################################
# OPTION A — pg_dump backup
###########################################
perform_pg_backup() {
    echo "→ Running pg_dump backup on production..."

    PG_DUMP_ARGS=""
    if [ -n "$PROD_DB_USER" ]; then
        PG_DUMP_ARGS+=" -U '$PROD_DB_USER'"
    fi
    if [ -n "$PROD_DB_HOST" ]; then
        PG_DUMP_ARGS+=" -h '$PROD_DB_HOST'"
    fi
    if [ -n "$PROD_DB_PORT" ]; then
        PG_DUMP_ARGS+=" -p '$PROD_DB_PORT'"
    fi

    if [[ "$SKIP_FILESTORE" == "true" ]]; then
        ssh "$PROD_SSH" "
            mkdir -p '$PROD_BACKUP_DIR';
            pg_dump$PG_DUMP_ARGS -Fc '$PROD_DB' > '$PROD_BACKUP_DIR/${PROD_DB}.dump';
        " || return 1
    else
        ssh "$PROD_SSH" "
            mkdir -p '$PROD_BACKUP_DIR';
            pg_dump$PG_DUMP_ARGS -Fc '$PROD_DB' > '$PROD_BACKUP_DIR/${PROD_DB}.dump';
            tar -czf '$PROD_BACKUP_DIR/${PROD_DB}_filestore.tar.gz' -C '$PROD_FS' '$PROD_DB';
        " || return 1
    fi

    echo "✓ PostgreSQL backup completed"
    return 0
}

###########################################
# OPTION B — Odoo endpoint backup
###########################################
perform_odoo_backup() {
    echo "→ Running Odoo endpoint backup..."

    if [ -z "$PROD_MASTER_PASS" ]; then
        PROD_MASTER_PASS="$PROD_MASTER_PASS_ENV"
    fi
    if [ -z "$PROD_MASTER_PASS" ]; then
        read -p "Enter Odoo master password (production): " PROD_MASTER_PASS
    fi

    PROD_PORT=${PROD_ODOO_PORT:-8069}
    ssh "$PROD_SSH" "
        mkdir -p '$PROD_BACKUP_DIR';
        curl -o '$PROD_BACKUP_DIR/${PROD_DB}.zip' \
            -X POST 'http://127.0.0.1:${PROD_PORT}/web/database/backup' \
            -F backup_format=zip \
            -F master_pwd='$PROD_MASTER_PASS' \
            -F name='$PROD_DB';
    " || return 1

    echo "✓ Odoo backup (ZIP) completed"
    return 0
}

###########################################
# AUTO MODE (try pg then fallback to odoo)
###########################################
if [[ "$BACKUP_METHOD" == "pg" ]]; then
    perform_pg_backup || exit 1
elif [[ "$BACKUP_METHOD" == "odoo" ]]; then
    perform_odoo_backup || exit 1
else
    echo "→ AUTO mode: trying pg_dump first..."
    if ! perform_pg_backup; then
        echo "→ pg_dump failed. Falling back to Odoo backup..."
        perform_odoo_backup || exit 1
    fi
fi


###########################################################################
# STEP 2 — DOWNLOAD BACKUPS TO STAGING
###########################################################################

echo "→ Downloading files..."

if [[ "$BACKUP_METHOD" == "odoo" ]]; then
    scp "$PROD_SSH:$PROD_BACKUP_DIR/${PROD_DB}.zip" "$BACKUP_DIR/"
else
    scp "$PROD_SSH:$PROD_BACKUP_DIR/${PROD_DB}.dump" "$BACKUP_DIR/"
    if [[ "$SKIP_FILESTORE" != "true" ]]; then
        scp "$PROD_SSH:$PROD_BACKUP_DIR/${PROD_DB}_filestore.tar.gz" "$BACKUP_DIR/"
    fi
fi


###########################################################################
# STEP 3 — RESTORE (PG or Odoo)
###########################################################################

if [[ "$RESTORE_METHOD" == "pg" ]]; then
    echo "→ Performing PostgreSQL restore..."

    systemctl stop "$STAGING_SERVICE" || true

    sudo -u postgres dropdb --if-exists "$STAGING_DB"
    sudo -u postgres createdb "$STAGING_DB"

    sudo -u postgres pg_restore -d "$STAGING_DB" $BACKUP_DIR/${PROD_DB}.dump

else
    echo "→ Performing Odoo restore via endpoint..."

    if [ -z "$STAGING_MASTER_PASS" ]; then
        STAGING_MASTER_PASS="$STAGING_MASTER_PASS_ENV"
    fi
    if [ -z "$STAGING_MASTER_PASS" ]; then
        read -p "Enter Staging master password: " STAGING_MASTER_PASS
    fi

    drop_via_odoo() {
        local drop_resp drop_code
        drop_resp="$(mktemp)"
    STAGING_PORT=${STAGING_ODOO_PORT:-8069}
    drop_code=$(curl -s -o "$drop_resp" -w "%{http_code}" -X POST "http://localhost:${STAGING_PORT}/web/database/drop" \
        -F master_pwd="$STAGING_MASTER_PASS" \
        -F name="$STAGING_DB")
        if [ "$drop_code" -ge 400 ]; then
            echo "⚠ Odoo drop failed (HTTP $drop_code)"
            rm -f "$drop_resp"
            return 1
        fi
        if grep -qi "Database deleted" "$drop_resp"; then
            rm -f "$drop_resp"
            return 0
        fi
        rm -f "$drop_resp"
        return 1
    }

    drop_via_pg() {
        systemctl stop "$STAGING_SERVICE" || true
        SERVICE_WAS_STOPPED="true"
        sudo -u postgres psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STAGING_DB}' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
        sudo -u postgres dropdb --if-exists "$STAGING_DB"
    }

    if [ "$DROP_METHOD" == "odoo" ]; then
        echo "→ Dropping existing staging DB via Odoo endpoint..."
        drop_via_odoo || {
            echo "❌ Odoo drop failed"
            exit 1
        }
    elif [ "$DROP_METHOD" == "pg" ]; then
        echo "→ Dropping existing staging DB via PostgreSQL..."
        drop_via_pg || exit 1
    else
        echo "→ Dropping existing staging DB (auto: Odoo → PostgreSQL)..."
        if ! drop_via_odoo; then
            echo "→ Odoo drop failed, trying PostgreSQL drop..."
            drop_via_pg || exit 1
        fi
    fi

    if [ "$SERVICE_WAS_STOPPED" == "true" ]; then
        echo "→ Starting Odoo service before restore..."
        systemctl start "$STAGING_SERVICE"
        sleep 2
    fi

    restore_resp="$(mktemp)"
    restore_code=$(curl -s -o "$restore_resp" -w "%{http_code}" -X POST "http://localhost:${STAGING_PORT}/web/database/restore" \
        -F master_pwd="$STAGING_MASTER_PASS" \
        -F name="$STAGING_DB" \
        -F backup_file=@$BACKUP_DIR/${PROD_DB}.zip \
        -F copy=true)
    if [ "$restore_code" -ge 400 ]; then
        echo "❌ Odoo restore failed (HTTP $restore_code)"
        echo "---- Response ----"
        sed -n '1,200p' "$restore_resp"
        rm -f "$restore_resp"
        exit 1
    fi
    if grep -qi "Database restore error" "$restore_resp"; then
        echo "❌ Odoo restore failed (see response from /web/database/restore)"
        echo "---- Response ----"
        sed -n '1,200p' "$restore_resp"
        rm -f "$restore_resp"
        exit 1
    fi
    rm -f "$restore_resp"
fi


###########################################################################
# STEP 4 — RESTORE FILESTORE (PG METHOD ONLY)
###########################################################################

if [[ "$BACKUP_METHOD" != "odoo" && "$SKIP_FILESTORE" != "true" ]]; then
    echo "→ Restoring filestore..."

    rm -rf "$STAGING_FS/$STAGING_DB"
    mkdir -p "$STAGING_FS"

    tar -xzf "$BACKUP_DIR/${PROD_DB}_filestore.tar.gz" -C "$STAGING_FS/"

    if [ -d "$STAGING_FS/$PROD_DB" ] && [ "$PROD_DB" != "$STAGING_DB" ]; then
        mv "$STAGING_FS/$PROD_DB" "$STAGING_FS/$STAGING_DB"
    fi

    chown -R odoo:odoo "$STAGING_FS/$STAGING_DB"
fi


###########################################################################
# STEP 5 — RESTART ODOO
###########################################################################

echo "→ Restarting Odoo..."
systemctl start "$STAGING_SERVICE"

echo "========================================="
echo "  ✅ Sync Completed Successfully!"
echo "========================================="
