#!/bin/bash
set -e

###############################################################################
# SMART NGINX + SSL INSTALLER FOR ODOO
# • Auto-detect Odoo service, config, port, longpolling port
# • Supports IPv4, IPv6 or dual-stack
# • Auto or manual DNS mode (with instructions)
# • Cloudflare DNS integration
# • Two-phase: ACME HTTP -> Final HTTPS config
###############################################################################

echo "============== SMART NGINX + SSL INSTALLER =============="

###############################################################################
# STEP 1 – DETECT ODOO SYSTEMD SERVICE
###############################################################################
echo "Finding installed Odoo systemd services..."

SERVICES_FOUND=($(ls /etc/systemd/system/ | grep -E '^odoo.*\.service$' | sed 's/.service//'))

if [ ${#SERVICES_FOUND[@]} -eq 0 ]; then
    echo "❌ No Odoo services detected. Enter manually:"
    read -p "Systemd Odoo service name: " SERVICE_NAME
else
    echo "Detected Odoo services:"
    printf ' - %s\n' "${SERVICES_FOUND[@]}"
    read -p "Select service [${SERVICES_FOUND[0]}]: " SERVICE_NAME
    SERVICE_NAME=${SERVICE_NAME:-${SERVICES_FOUND[0]}}
fi

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "❌ ERROR: systemd service not found: $SERVICE_NAME"
    exit 1
fi

echo "✓ Using service: $SERVICE_NAME"

###############################################################################
# STEP 2 – DETECT ODOO CONFIG
###############################################################################
ODOO_CONFIG=$(sed -n 's/.*-c[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$SERVICE_FILE" | head -n1)

if [ ! -f "$ODOO_CONFIG" ]; then
    echo "❌ Could not detect Odoo config automatically."
    read -p "Enter config file path: " ODOO_CONFIG
fi
if [ ! -f "$ODOO_CONFIG" ]; then
    echo "❌ ERROR: Config file missing: $ODOO_CONFIG"
    exit 1
fi

echo "✓ Odoo config detected: $ODOO_CONFIG"

###############################################################################
# STEP 3 – DETECT PORTS
###############################################################################
ODOO_PORT=$(sed -n 's/^[[:space:]]*http_port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$ODOO_CONFIG" | head -n1)
ODOO_PORT=${ODOO_PORT:-8069}
echo "✓ Odoo port: $ODOO_PORT"

LONGPOLLING_PORT=$(sed -n 's/^[[:space:]]*longpolling_port[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$ODOO_CONFIG" | head -n1)
LONGPOLLING_PORT=${LONGPOLLING_PORT:-8072}
echo "✓ Longpolling port: $LONGPOLLING_PORT"

###############################################################################
# STEP 4 – ASK FOR DOMAIN
###############################################################################
read -p "Domain for this Odoo instance (example: erp.company.com): " DOMAIN
if [ -z "$DOMAIN" ]; then echo "❌ Domain required"; exit 1; fi

###############################################################################
# STEP 5 – CHOOSE IP MODE (IPv4/IPv6)
###############################################################################
echo ""
echo "---------------------------------------"
echo "   DNS Configuration Mode"
echo "---------------------------------------"
echo "1) IPv4 only (A)"
echo "2) IPv6 only (AAAA)"
echo "3) Dual stack (A + AAAA)"
read -p "Choose [1/2/3] (default 1): " IP_MODE
IP_MODE=${IP_MODE:-1}

SERVER_IPV4=$(curl -4 -s ifconfig.me || true)
SERVER_IPV6=$(curl -6 -s ifconfig.me || true)

[[ "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || SERVER_IPV4=""
[[ "$SERVER_IPV6" =~ : ]] || SERVER_IPV6=""

manual_dns_instructions() {
    echo ""
    echo "================ MANUAL DNS MODE ================"
    echo "Create these DNS records:"
    echo ""

    if [[ "$IP_MODE" == "1" || "$IP_MODE" == "3" ]] && [[ -n "$SERVER_IPV4" ]]; then
        echo " A record:"
        echo "   Name: $DOMAIN"
        echo "   Value: $SERVER_IPV4"
    fi

    if [[ "$IP_MODE" == "2" || "$IP_MODE" == "3" ]] && [[ -n "$SERVER_IPV6" ]]; then
        echo ""
        echo " AAAA record:"
        echo "   Name: $DOMAIN"
        echo "   Value: $SERVER_IPV6"
    fi

    echo ""
    echo "After creating DNS records, wait 1–3 minutes,"
    echo "then continue installation."
    echo "================================================="
}

###############################################################################
# STEP 6 – CLOUDFLARE DNS AUTO MODE
###############################################################################
read -p "Automatically create Cloudflare DNS records? [Y/n]: " CF_AUTO
CF_AUTO=${CF_AUTO:-Y}

if [[ "$CF_AUTO" =~ ^[Yy]$ ]]; then
    echo "→ Running Cloudflare DNS script..."
    if ! bash cloudflare_dns.sh "$DOMAIN" "$IP_MODE"; then
        echo "⚠ Cloudflare failed. Switching to manual DNS."
        manual_dns_instructions
        read -p "Press ENTER when DNS is configured..."
    fi
else
    echo "→ You selected manual DNS mode."
    manual_dns_instructions
    read -p "Press ENTER when DNS is configured..."
fi

###############################################################################
# STEP 7 – INSTALL NGINX
###############################################################################
echo "[1/7] Installing Nginx..."
apt update
apt install -y nginx
systemctl enable nginx
systemctl start nginx

mkdir -p /var/www/$DOMAIN
mkdir -p /var/log/nginx/odoo

NGINX_FILE="/etc/nginx/sites-available/$DOMAIN"

###############################################################################
# STEP 8 – TEMPORARY ACME CONFIG
###############################################################################
echo "[2/7] Creating ACME temporary config..."

cat <<EOF > "$NGINX_FILE"
server {
    listen 80;
    listen [::]:80;
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

###############################################################################
# STEP 9 – LET'S ENCRYPT (CERTONLY)
###############################################################################
echo "[3/7] Generating SSL certificate..."
apt install -y certbot python3-certbot-nginx

certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@$DOMAIN

###############################################################################
# STEP 10 – FULL HTTPS CONFIG
###############################################################################
echo "[4/7] Creating full HTTPS config..."

UPSTREAM_PREFIX=$(echo "$DOMAIN" | tr '.-' '_')

cat <<EOF > "$NGINX_FILE"

upstream ${UPSTREAM_PREFIX}_backend {
    server 127.0.0.1:$ODOO_PORT;
}

upstream ${UPSTREAM_PREFIX}_longpolling {
    server 127.0.0.1:$LONGPOLLING_PORT;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 500M;

    access_log /var/log/nginx/odoo/${DOMAIN}_access.log;
    error_log  /var/log/nginx/odoo/${DOMAIN}_error.log;

    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    location / {
        proxy_pass http://${UPSTREAM_PREFIX}_backend;
        proxy_redirect off;
    }

    location /longpolling {
        proxy_pass http://${UPSTREAM_PREFIX}_longpolling;
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        expires 864000;
        proxy_pass http://${UPSTREAM_PREFIX}_backend;
    }

    gzip on;
    gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript;
}
EOF

nginx -t
systemctl reload nginx

###############################################################################
# STEP 11 – ENABLE PROXY MODE IN ODOO
###############################################################################
echo "[5/7] Ensuring proxy_mode is enabled..."

if ! grep -q "^proxy_mode *= *True" "$ODOO_CONFIG"; then
    echo "proxy_mode = True" >> "$ODOO_CONFIG"
fi


###############################################################################
# STEP X – FIREWALL CONFIGURATION (UFW)
###############################################################################
echo "[7/7] Configuring firewall..."
# Install UFW if missing
if ! command -v ufw >/dev/null 2>&1; then
    sudo apt install -y ufw
fi

# Prevent firewall from locking SSH
sudo ufw allow 22/tcp >/dev/null || true

# Allow HTTP/HTTPS (Nginx profiles)
sudo ufw allow 'Nginx Full'   >/dev/null || true
sudo ufw allow 'Nginx HTTP'   >/dev/null || true
sudo ufw allow 'Nginx HTTPS'  >/dev/null || true



# Allow Odoo backend port only if user wants
read -p "Allow direct access to Odoo port $ODOO_PORT (useful for debugging)? [y/N]: " ALLOW_ODOO
ALLOW_ODOO=${ALLOW_ODOO:-N}

if [[ "$ALLOW_ODOO" =~ ^[Yy]$ ]]; then
    ufw allow $ODOO_PORT/tcp >/dev/null || true
    echo "✓ Allowed Odoo port $ODOO_PORT"
else
    echo "✓ Skipped opening Odoo backend port"
fi

# Allow longpolling port only if needed
read -p "Allow direct longpolling port $LONGPOLLING_PORT (rarely needed)? [y/N]: " ALLOW_LP
ALLOW_LP=${ALLOW_LP:-N}

if [[ "$ALLOW_LP" =~ ^[Yy]$ ]]; then
    ufw allow $LONGPOLLING_PORT/tcp >/dev/null || true
    echo "✓ Allowed longpolling port $LONGPOLLING_PORT"
else
    echo "✓ Skipped longpolling port"
fi

# Enable firewall without asking for confirmation
sudo ufw --force enable

echo "✓ Firewall configured successfully"
echo "--------------------------------------"
sudo ufw status verbose
echo "--------------------------------------"


###############################################################################
# STEP 12 – RESTART SERVICES
###############################################################################
echo "[7/7] Restarting services..."

systemctl restart "$SERVICE_NAME"
systemctl reload nginx

###############################################################################
# DONE
###############################################################################
echo "================== DONE =================="
echo "Domain:        https://$DOMAIN"
echo "Odoo port:     $ODOO_PORT"
echo "Longpolling:   $LONGPOLLING_PORT"
echo "Config file:   $ODOO_CONFIG"
echo "Service name:  $SERVICE_NAME"
echo "SSL:           ENABLED"
echo "proxy_mode:    VERIFIED"
echo "=========================================="

