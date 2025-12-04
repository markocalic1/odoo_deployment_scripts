#!/bin/bash
set -e

###############################################################################
# NGINX + SSL INSTALLER FOR ANY ODOO INSTANCE
# Adds:
# - Auto detect Odoo config file from systemd service
# - Ensures proxy_mode = True
# - Cloudflare-friendly
###############################################################################

echo "============== NGINX + SSL INSTALLER =============="

# -------------------------------
# Interactive settings
# -------------------------------

read -p "Domain for this Odoo instance (example: erp.mycompany.com): " DOMAIN
read -p "Odoo port (example: 8069, 8071, 8090...): " ODOO_PORT
read -p "Systemd Odoo service name (example: odoo19, odoo-staging): " SERVICE_NAME

echo "---------------------------------------------------------"
echo "Domain:        $DOMAIN"
echo "Odoo port:     $ODOO_PORT"
echo "Service name:  $SERVICE_NAME"
echo "---------------------------------------------------------"
sleep 2

# -------------------------------
# Install Nginx
# -------------------------------

echo "[1/6] Installing NGINX..."
apt update
apt install -y nginx

systemctl enable nginx
systemctl start nginx

# -------------------------------
# Nginx config for Odoo
# -------------------------------

echo "[2/6] Creating Nginx config..."

NGINX_FILE="/etc/nginx/sites-available/$DOMAIN"

cat <<EOF > $NGINX_FILE
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    proxy_set_header X-Forwarded-Host  \$host;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP         \$remote_addr;

    location / {
        proxy_pass http://127.0.0.1:$ODOO_PORT;
    }

    location /websocket {
        proxy_pass http://127.0.0.1:$ODOO_PORT;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        expires 864000;
        proxy_pass http://127.0.0.1:$ODOO_PORT;
    }
}
EOF

# -------------------------------
# Enable nginx config
# -------------------------------

echo "[3/6] Enabling Nginx site..."

mkdir -p /var/www/$DOMAIN
chmod -R 755 /var/www/$DOMAIN

ln -s $NGINX_FILE /etc/nginx/sites-enabled/$DOMAIN || true

rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl reload nginx

# -------------------------------
# SSL via Certbot
# -------------------------------

echo "[4/6] Installing Certbot + generating SSL..."

apt install -y certbot python3-certbot-nginx

certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN --redirect

systemctl reload nginx

# -------------------------------
# Find Odoo config file
# -------------------------------

echo "[5/6] Detecting Odoo config file..."

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

if [ ! -f $SERVICE_FILE ]; then
    echo "❌ ERROR: Systemd service $SERVICE_NAME not found!"
    exit 1
fi

ODOO_CONFIG=$(grep -oP "(?<=-c ).+" $SERVICE_FILE | tr -d ' ')

if [ ! -f "$ODOO_CONFIG" ]; then
    echo "❌ ERROR: Could not find Odoo config file: $ODOO_CONFIG"
    exit 1
fi

echo "✓ Odoo config detected: $ODOO_CONFIG"

# -------------------------------
# Ensure proxy_mode = True
# -------------------------------

echo "[6/6] Ensuring 'proxy_mode = True' is set..."

if grep -q "^proxy_mode *= *True" "$ODOO_CONFIG"; then
    echo "✓ proxy_mode already enabled"
else
    echo "proxy_mode = True" >> "$ODOO_CONFIG"
    echo "✓ proxy_mode added to config"
fi

systemctl restart $SERVICE_NAME
systemctl reload nginx

echo "================== DONE =================="
echo "Domain:          https://$DOMAIN"
echo "Odoo port:       $ODOO_PORT"
echo "Service name:    $SERVICE_NAME"
echo "Config file:     $ODOO_CONFIG"
echo "SSL:             ENABLED (Let's Encrypt)"
echo "proxy_mode:      VERIFIED"
echo "=========================================="

