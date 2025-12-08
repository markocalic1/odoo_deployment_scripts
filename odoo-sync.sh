#!/bin/bash
set -e

###########################################################################
# ODOO PRODUCTION → STAGING SYNC TOOL
#
# Usage examples:
#   ./odoo-sync.sh --prod-host 1.2.3.4 --prod-db mydb --method pg
#   ./odoo-sync.sh (interactive mode)
#
# Options:
#   --prod-host       Production server IP or hostname
#   --prod-ssh        SSH user for production (default: root)
#   --prod-db         Production database name
#   --staging-db      Staging database name (default: <prod_db>_staging)
#   --method          restore method: "pg" or "odoo"
###########################################################################

### DEFAULTS ###
PROD_SSH_USER="root"
RESTORE_METHOD="pg"  # default restore method
BACKUP_DIR="/opt/odoo/backups"
STAGING_FS="/opt/odoo/.local/share/Odoo/filestore"

### PARSE ARGUMENTS ###
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --prod-host) PROD_HOST="$2"; shift ;;
        --prod-ssh) PROD_SSH_USER="$2"; shift ;;
        --prod-db) PROD_DB="$2"; shift ;;
        --staging-db) STAGING_DB="$2"; shift ;;
        --method) RESTORE_METHOD="$2"; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

### INTERACTIVE MODE IF MISSING ARGUMENTS ###

if [ -z "$PROD_HOST" ]; then
    read -p "Production host/IP: " PROD_HOST
fi

if [ -z "$PROD_DB" ]; then
    read -p "Production DB name: " PROD_DB
fi

if [ -z "$STAGING_DB" ]; then
    DEFAULT_STAGING="${PROD_DB}_staging"
    read -p "Staging DB name [$DEFAULT_STAGING]: " STAGING_DB
    STAGING_DB=${STAGING_DB:-$DEFAULT_STAGING}
fi

if [[ "$RESTORE_METHOD" != "pg" && "$RESTORE_METHOD" != "odoo" ]]; then
    echo "Choose restore method:"
    echo " 1) PostgreSQL direct restore (fastest)"
    echo " 2) Odoo /web/database/restore endpoint"
    read -p "Method [1/2] (default 1): " M
    RESTORE_METHOD=$([[ "$M" == "2" ]] && echo "odoo" || echo "pg")
fi

### SSH CONNECTION STRING ###
PROD_SSH="${PROD_SSH_USER}@${PROD_HOST}"

echo "========================================="
echo "   Odoo Sync: Production → Staging"
echo "========================================="
echo "Production Host:     $PROD_HOST"
echo "Production DB:       $PROD_DB"
echo "Staging DB:          $STAGING_DB"
echo "Restore Method:      $RESTORE_METHOD"
echo "========================================="

mkdir -p "$BACKUP_DIR"

### STEP 1: RUN BACKUP ON PRODUCTION ###
echo "→ Creating backup on production..."

ssh $PROD_SSH "
    mkdir -p $BACKUP_DIR;
    pg_dump -Fc $PROD_DB > $BACKUP_DIR/${PROD_DB}.dump;
    tar -czf $BACKUP_DIR/${PROD_DB}_filestore.tar.gz $STAGING_FS/$PROD_DB;
"

### STEP 2: COPY BACKUP TO STAGING ###
echo "→ Downloading backup files..."

scp $PROD_SSH:$BACKUP_DIR/${PROD_DB}.dump $BACKUP_DIR/
scp $PROD_SSH:$BACKUP_DIR/${PROD_DB}_filestore.tar.gz $BACKUP_DIR/

### STEP 3: DB RESTORE (TWO METHODS) ###

if [[ "$RESTORE_METHOD" == "pg" ]]; then
    echo "→ Using PostgreSQL direct restore method"

    systemctl stop odoo || true

    sudo -u postgres dropdb --if-exists "$STAGING_DB"
    sudo -u postgres createdb "$STAGING_DB"

    echo "→ Restoring DB..."
    sudo -u postgres pg_restore -d "$STAGING_DB" $BACKUP_DIR/${PROD_DB}.dump

else
    echo "→ Using Odoo restore endpoint method"

    read -p "Odoo admin password on staging: " ADMIN_PASS

    curl -X POST "http://localhost:8069/web/database/restore" \
        -F "master_pwd=$ADMIN_PASS" \
        -F "name=$STAGING_DB" \
        -F "backup_file=@$BACKUP_DIR/${PROD_DB}.dump" \
        -F "copy=true"

fi

### STEP 4: RESTORE FILESTORE ###
echo "→ Restoring filestore..."

rm -rf $STAGING_FS/$STAGING_DB
mkdir -p $STAGING_FS/$STAGING_DB

tar -xzf $BACKUP_DIR/${PROD_DB}_filestore.tar.gz -C $STAGING_FS/

chown -R odoo:odoo $STAGING_FS/$STAGING_DB

### STEP 5: RESTART ODOO ###
echo "→ Restarting Odoo..."
systemctl start odoo

echo "========================================="
echo "  ✅ Sync Completed Successfully!"
echo "========================================="

