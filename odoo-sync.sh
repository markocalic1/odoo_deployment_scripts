#!/bin/bash
set -e

###########################################################################
# ODOO PRODUCTION → STAGING SYNC TOOL (WITH ODOO BACKUP OPTION)
###########################################################################

### DEFAULTS ###
PROD_SSH_USER="root"
RESTORE_METHOD="pg"     # restore method
BACKUP_METHOD="pg"      # backup method: pg | odoo | auto
BACKUP_DIR="/opt/odoo/backups"
STAGING_FS="/opt/odoo/.local/share/Odoo/filestore"

### PARSE ARGUMENTS ###
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --prod-host) PROD_HOST="$2"; shift ;;
        --prod-ssh) PROD_SSH_USER="$2"; shift ;;
        --prod-db) PROD_DB="$2"; shift ;;
        --staging-db) STAGING_DB="$2"; shift ;;
        --method) RESTORE_METHOD="$2"; shift ;;  # restore method
        --backup-method) BACKUP_METHOD="$2"; shift ;;  # NEW
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

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

    ssh $PROD_SSH "
        mkdir -p $BACKUP_DIR;
        pg_dump -Fc $PROD_DB > $BACKUP_DIR/${PROD_DB}.dump;
        tar -czf $BACKUP_DIR/${PROD_DB}_filestore.tar.gz $STAGING_FS/$PROD_DB;
    " || return 1

    echo "✓ PostgreSQL backup completed"
    return 0
}

###########################################
# OPTION B — Odoo endpoint backup
###########################################
perform_odoo_backup() {
    echo "→ Running Odoo endpoint backup..."

    read -p "Enter Odoo master password (production): " MASTER_PASS

    curl -o "$BACKUP_DIR/${PROD_DB}.zip" \
        -X POST "http://${PROD_HOST}:8069/web/database/backup" \
        -F backup_format=zip \
        -F master_pwd="$MASTER_PASS" \
        -F name="$PROD_DB"

    if [[ ! -f "$BACKUP_DIR/${PROD_DB}.zip" ]]; then
        echo "❌ Odoo backup failed"
        return 1
    fi

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
    scp $PROD_SSH:$BACKUP_DIR/${PROD_DB}.zip $BACKUP_DIR/
else
    scp $PROD_SSH:$BACKUP_DIR/${PROD_DB}.dump $BACKUP_DIR/
    scp $PROD_SSH:$BACKUP_DIR/${PROD_DB}_filestore.tar.gz $BACKUP_DIR/
fi


###########################################################################
# STEP 3 — RESTORE (PG or Odoo)
###########################################################################

if [[ "$RESTORE_METHOD" == "pg" ]]; then
    echo "→ Performing PostgreSQL restore..."

    systemctl stop odoo || true

    sudo -u postgres dropdb --if-exists "$STAGING_DB"
    sudo -u postgres createdb "$STAGING_DB"

    sudo -u postgres pg_restore -d "$STAGING_DB" $BACKUP_DIR/${PROD_DB}.dump

else
    echo "→ Performing Odoo restore via endpoint..."

    read -p "Enter Staging master password: " STAGING_PASS

    curl -X POST "http://localhost:8069/web/database/restore" \
        -F master_pwd="$STAGING_PASS" \
        -F name="$STAGING_DB" \
        -F backup_file=@$BACKUP_DIR/${PROD_DB}.zip \
        -F copy=true
fi


###########################################################################
# STEP 4 — RESTORE FILESTORE (PG METHOD ONLY)
###########################################################################

if [[ "$BACKUP_METHOD" != "odoo" ]]; then
    echo "→ Restoring filestore..."

    rm -rf $STAGING_FS/$STAGING_DB
    mkdir -p $STAGING_FS/$STAGING_DB

    tar -xzf $BACKUP_DIR/${PROD_DB}_filestore.tar.gz -C $STAGING_FS/

    chown -R odoo:odoo $STAGING_FS/$STAGING_DB
fi


###########################################################################
# STEP 5 — RESTART ODOO
###########################################################################

echo "→ Restarting Odoo..."
systemctl start odoo

echo "========================================="
echo "  ✅ Sync Completed Successfully!"
echo "========================================="

