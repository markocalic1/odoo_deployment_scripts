#!/bin/bash
set -e

###############################################################################
# SMART NGINX + SSL INSTALLER FOR ODOO
# - Auto-detect Odoo service, config, port, longpolling
# - DNS Mode: Cloudflare / Manual / Skip
# - ACME HTTP challenge, then HTTPS config
# - Cloudflare-friendly, idempotent
###############################################################################

echo "============== SMART NGINX + SSL INSTALLER =============="

# ---------------------------------------------------------
#  AUTO-DETECT SYSTEMD SERVICES
# ---------------------------------------------------------

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

# ---------------------------------------------------------
#  AUTO-DETECT ODOO CONFIG FILE
# ---------------------------------------------------------

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

# ---------------------------------------------------------
#  AUTO-DETECT HTTP PORT
# ---------------------------------------------------------

ODOO_PORT=$(sed -n 's/^[[:space:]]*http_port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$ODOO_CONFIG" | head -n1)

if [ -z "$ODOO_PORT" ]; then
    read -p "Odoo port not found in config. Enter manually [8069]: " ODOO_PORT
    ODOO_PORT=${ODOO_PORT:-8069}
fi

echo "✓ Odoo port: $ODOO_PORT"

# ---------------------------------------------------------
#  LONGPOLLING PORT
# ---------------------------------------------------------

LONGPOLLING_PORT=$(sed -n 's/^[[:space:]]*longpolling_port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$ODOO_CONFIG")

if [ -z "$LONGPOLLING_PORT" ]; then
    LONGPOLLING_PORT=8072
    echo "⚠ longpolling_port missing → using default 8072"
else
    echo "✓ Longpolling port: $LONGPOLLING_PORT"
fi

# ---------------------------------------------------------
#  ASK FOR DOMAIN
# ---------------------------------------------------------

read -p "Domain for this Odoo instance (example: erp.example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo "❌ Domain is required."
    exit 1
fi

# ---------------------------------------------------------
#  DNS MODE SELECTION
# ---------------------------------------------------------

echo ""
echo "DNS Handling Options:"
echo "1) Auto-manage DNS via Cloudflare"
echo "2) Manual DNS (you create A-record yourself)"
echo "3) Skip DNS (no SSL)"
read -p "Choose DNS mode [1/2/3]: " DNS_MODE
DNS_MODE=${DNS_MODE:-2}

echo ""

SKIP_SSL=false

case $DNS_MODE in
    1)
        echo "→ Using Cloudflare DNS automation"
        bash cloudflare_dns.sh "$DOMAIN"
        ;;
    2)
        echo "--------------------------------------------"
        echo "🔧 MANUAL DNS MODE SELECTED"
        echo "Create this DNS A-record:"
        echo ""
        echo "Host: $DOMAIN"
        echo "Type: A"
        echo "Value: $(curl -s ifconfig.me)"
        echo ""
        echo "Press ENTER when DNS is created..."
        echo "--------------------------------------------"
        read
        ;;
    3)
        echo "⚠ Skipping DNS + SSL setup"
        SKIP_SSL=true
        ;;
    *)
        echo "❌ Invalid selection"
        exit 1
        ;;
esac

echo ""
echo "---------------------------------------------------------"
echo "Domain:        $DOMAIN"
echo "Service name:  $SERVICE_NAME"
echo "Config file:   $ODOO_CONFIG"
echo "Odoo port:     $ODOO_PORT"
echo "Longpolling:   $LONGPOLLING_PORT"
echo "DNS Mode:      $DNS_MODE"
echo "---------------------------------------------------------"
sleep 2

UPSTREAM_PREFIX=$(echo "$DOMAIN" | tr '.-' '_')

# ---------------------------------------------------------
#  INSTALL NGINX
# ---------------------------------------------------------

echo "[1/7] Installing NGINX..."
apt update
apt install -y nginx
systemctl enable nginx
systemctl start nginx

mkdir -p /var/log/nginx/odoo
mkdir -p /var/www/$DOMAIN

NGINX_FILE="/etc/nginx/sites-available/$DOMAIN"

# ---------------------------------------------------------
#  IF SKIPPING SSL → CREATE SIMPLE HTTP CONFIG ONLY
# ---------------------------------------------------------

if [ "$SKIP_SSL" = true ]; then

cat <<EOF > "$NGINX_FILE"
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$ODOO_PORT;
    }

    location /longpolling {
        proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
    }
}
EOF

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/$DOMAIN
nginx -t && systemctl reload nginx

echo "✔ HTTP-only mode enabled"
exit 0
fi

# ---------------------------------------------------------
#  PHASE 1: TEMP HTTP CONFIG FOR CERTBOT
# ---------------------------------------------------------

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

nginx -t && systemctl reload nginx
echo "✓ Temporary HTTP config loaded"

# ---------------------------------------------------------
#  SSL CERT GENERATION
# ---------------------------------------------------------

echo "[3/7] Installing Certbot..."
apt install -y certbot python3-certbot-nginx

echo "Requesting certificate..."
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@$DOMAIN
echo "✓ SSL certificate generated"

# ---------------------------------------------------------
#  PHASE 2: FULL HTTPS CONFIG
# ---------------------------------------------------------

cat <<EOF > "$NGINX_FILE"

# Odoo upstreams
upstream ${UPSTREAM_PREFIX}_backend {
    server 127.0.0.1:$ODOO_PORT;
}
upstream ${UPSTREAM_PREFIX}_longpolling {
    server 127.0.0.1:$LONGPOLLING_PORT;
}

# HTTP → HTTPS
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

# HTTPS
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    client_max_body_size 500M;

    location / {
        proxy_pass http://${UPSTREAM_PREFIX}_backend;
    }

    location /longpolling {
        proxy_pass http://${UPSTREAM_PREFIX}_longpolling;
    }

    location ~* /web/static/ {
        expires 864000;
        proxy_pass http://${UPSTREAM_PREFIX}_backend;
    }

    gzip on;
    gzip_types text/css application/json application/javascript;
}
EOF

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/$DOMAIN
nginx -t && systemctl reload nginx

# ---------------------------------------------------------
#  ENSURE ODOO proxy_mode = True
# ---------------------------------------------------------

if ! grep -q "^proxy_mode *= *True" "$ODOO_CONFIG"; then
    echo "proxy_mode = True" >> "$ODOO_CONFIG"
fi

systemctl restart "$SERVICE_NAME"

echo "================== DONE =================="
echo "Domain:        https://$DOMAIN"
echo "Odoo port:     $ODOO_PORT"
echo "Longpolling:   $LONGPOLLING_PORT"
echo "Config file:   $ODOO_CONFIG"
echo "Service name:  $SERVICE_NAME"
echo "SSL:           ENABLED"
echo "proxy_mode:    VERIFIED"
echo "=========================================="

