#!/bin/bash
set -e

###############################################################################
# SMART NGINX + SSL INSTALLER FOR ODOO
# - Auto-detect Odoo service, config, port, longpolling port
# - Advanced Nginx upstream + longpolling + caching + gzip
# - Two-phase: HTTP for certbot, then HTTPS with certs
# - Cloudflare-friendly, idempotent
###############################################################################

echo "============== SMART NGINX + SSL INSTALLER =============="

# -------------------------------
# Auto-detect Odoo services
# -------------------------------

echo "Finding installed Odoo systemd services..."

SERVICES_FOUND=($(ls /etc/systemd/system/ | grep -E '^odoo.*\.service$' | sed 's/.service//'))

if [ ${#SERVICES_FOUND[@]} -eq 0 ]; then
    echo "❌ No Odoo services detected. Please enter manually."
    read -p "Systemd Odoo service name: " SERVICE_NAME
else
    echo "Detected Odoo services:"
    printf ' - %s\n' "${SERVICES_FOUND[@]}"

    read -p "Select service [${SERVICES_FOUND[0]}]: " SERVICE_NAME
    SERVICE_NAME=${SERVICE_NAME:-${SERVICES_FOUND[0]}}
fi

echo "✓ Using service: $SERVICE_NAME"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "❌ ERROR: systemd service not found: $SERVICE_NAME"
    exit 1
fi

# -------------------------------
# Auto-detect config file from service
# -------------------------------

ODOO_CONFIG=$(sed -n 's/.*-c[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$SERVICE_FILE" | head -n1)

if [ -z "$ODOO_CONFIG" ] || [ ! -f "$ODOO_CONFIG" ]; then
    echo "❌ Could not detect Odoo config file from service."
    read -p "Enter config file path manually: " ODOO_CONFIG
fi

if [ ! -f "$ODOO_CONFIG" ]; then
    echo "❌ ERROR: Config file does not exist: $ODOO_CONFIG"
    exit 1
fi

echo "✓ Odoo config detected: $ODOO_CONFIG"

# -------------------------------
# Auto-detect Odoo port
# -------------------------------

ODOO_PORT=$(sed -n 's/^[[:space:]]*http_port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$ODOO_CONFIG" | head -n1)

if [ -z "$ODOO_PORT" ]; then
    read -p "Odoo port not found in config. Enter manually [8069]: " ODOO_PORT
    ODOO_PORT=${ODOO_PORT:-8069}
fi

echo "✓ Odoo port: $ODOO_PORT"

# -------------------------------
# Auto-detect longpolling port
# -------------------------------

LONGPOLLING_PORT=$(sed -n 's/^[[:space:]]*longpolling_port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$ODOO_CONFIG" | head -n1)

if [ -z "$LONGPOLLING_PORT" ]; then
    LONGPOLLING_PORT=8072
    echo "⚠ longpolling_port missing in config → using default 8072"
else
    echo "✓ Longpolling port: $LONGPOLLING_PORT"
fi

# -------------------------------
# Ask for domain
# -------------------------------

read -p "Domain for this Odoo instance (example: erp.mycompany.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo "❌ Domain is required."
    exit 1
fi

echo "---------------------------------------------------------"
echo "Domain:        $DOMAIN"
echo "Service name:  $SERVICE_NAME"
echo "Config file:   $ODOO_CONFIG"
echo "Odoo port:     $ODOO_PORT"
echo "Longpolling:   $LONGPOLLING_PORT"
echo "---------------------------------------------------------"
sleep 2

# Sanitize domain for upstream names
UPSTREAM_PREFIX=$(echo "$DOMAIN" | tr '.-' '_')

# -------------------------------
# Install Nginx
# -------------------------------

echo "[1/7] Installing NGINX..."
apt update
apt install -y nginx
systemctl enable nginx
systemctl start nginx

mkdir -p /var/log/nginx/odoo
mkdir -p /var/www/$DOMAIN

NGINX_FILE="/etc/nginx/sites-available/$DOMAIN"

# -----------------------------------------------
# Phase 1: HTTP-only config (for Certbot)
# -----------------------------------------------
echo "[2/7] Creating temporary HTTP config for ACME..."

cat <<EOF > "$NGINX_FILE"
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 500M;

    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }

    location / {
        return 301 http://\$host\$request_uri;
    }
}
EOF

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
echo "✓ HTTP config loaded (ACME-ready)"

# -------------------------------
# SSL via Certbot (certonly)
# -------------------------------

echo "[3/7] Installing Certbot + generating SSL certificate..."

apt install -y certbot python3-certbot-nginx

certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@$DOMAIN

echo "✓ SSL certificate generated"

# -----------------------------------------------
# Phase 2: Full HTTP + HTTPS advanced config
# -----------------------------------------------

echo "[4/7] Creating full HTTP+HTTPS Nginx config..."

cat <<EOF > "$NGINX_FILE"

# --------------------------
# ODOO UPSTREAM BLOCKS
# --------------------------
upstream ${UPSTREAM_PREFIX}_odoo_backend {
    server 127.0.0.1:$ODOO_PORT;
}

upstream ${UPSTREAM_PREFIX}_odoo_longpolling {
    server 127.0.0.1:$LONGPOLLING_PORT;
}

# --------------------------
# HTTP → HTTPS REDIRECT
# --------------------------
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 500M;

    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# --------------------------
# HTTPS SERVER
# --------------------------
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    client_max_body_size 500M;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    access_log /var/log/nginx/odoo/${DOMAIN}_access.log;
    error_log  /var/log/nginx/odoo/${DOMAIN}_error.log;

    # Proxy headers
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    # Performance tuning
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Main Odoo backend
    location / {
        proxy_pass http://${UPSTREAM_PREFIX}_odoo_backend;
        proxy_redirect off;
    }

    # Longpolling
    location /longpolling {
        proxy_pass http://${UPSTREAM_PREFIX}_odoo_longpolling;
    }

    # Static assets caching
    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://${UPSTREAM_PREFIX}_odoo_backend;
    }

    # Gzip compression
    gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
EOF

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
echo "✓ Full HTTPS config active"

# -------------------------------
# Ensure proxy_mode = True
# -------------------------------

echo "[5/7] Ensuring 'proxy_mode = True' in Odoo config..."

if grep -q "^proxy_mode *= *True" "$ODOO_CONFIG"; then
    echo "✓ proxy_mode already enabled"
else
    echo "proxy_mode = True" >> "$ODOO_CONFIG"
    echo "✓ proxy_mode added"
fi

# -------------------------------
# Restart services
# -------------------------------

echo "[6/7] Restarting Odoo and Nginx..."

systemctl restart "$SERVICE_NAME"
systemctl reload nginx

echo "================== DONE =================="
echo "Domain:        https://$DOMAIN"
echo "Odoo port:     $ODOO_PORT"
echo "Longpolling:   $LONGPOLLING_PORT"
echo "Config file:   $ODOO_CONFIG"
echo "Service name:  $SERVICE_NAME"
echo "SSL:           ENABLED"
echo "proxy_mode:    VERIFIED"
echo "=========================================="

