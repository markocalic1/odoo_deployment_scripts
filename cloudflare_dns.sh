#!/bin/bash
set -e

###############################################
# CLOUDLFare DNS Auto Creator (Pro Version)
###############################################

DOMAIN=$1

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 sub.domain.com"
    exit 1
fi

CF_TOKEN_FILE="/etc/cloudflare/api_token"
SERVER_IP=$(curl -s ifconfig.me)

# ----------------------------------------------
# Detect root domain (handles nested subdomains)
# ----------------------------------------------
get_root_domain() {
    local d="$1"
    local root=""
    # Try longest TLD first (co.uk, com.au, etc.)
    for i in {1..5}; do
        root=$(echo "$d" | awk -F. '{print $(NF-1)"."$NF}')
        if dig +short NS "$root" >/dev/null 2>&1; then
            echo "$root"
            return
        fi
        d="${d#*.}"
    done
    echo "$root"
}

ROOT_DOMAIN=$(get_root_domain "$DOMAIN")

if [ -z "$ROOT_DOMAIN" ]; then
    echo "❌ Could not determine root domain for: $DOMAIN"
    exit 1
fi

echo "----------------------------------------------"
echo " Cloudflare DNS Auto Creator"
echo "----------------------------------------------"
echo "Domain:        $DOMAIN"
echo "Root domain:   $ROOT_DOMAIN"
echo "Server IP:     $SERVER_IP"
echo "----------------------------------------------"

# ----------------------------------------------
# Load token or ask user
# ----------------------------------------------
if [ ! -f "$CF_TOKEN_FILE" ]; then
    echo "⚠ No Cloudflare token found at $CF_TOKEN_FILE"
    read -p "Enter Cloudflare API Token: " CF_TOKEN_INPUT

    if [ -z "$CF_TOKEN_INPUT" ]; then
        echo "❌ Token cannot be empty."
        exit 1
    fi

    sudo mkdir -p /etc/cloudflare
    echo "$CF_TOKEN_INPUT" | sudo tee "$CF_TOKEN_FILE" >/dev/null
    sudo chmod 600 "$CF_TOKEN_FILE"
fi

CF_TOKEN=$(cat "$CF_TOKEN_FILE")

# ----------------------------------------------
# Verify Token Permissions
# ----------------------------------------------
echo "Verifying Cloudflare API Token..."

VERIFY=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

echo "Token verify response: $VERIFY"

if ! echo "$VERIFY" | grep -q '"success":true'; then
    echo "❌ Invalid token — authentication failed."
    exit 1
fi

echo "✓ Token verified successfully"

# ----------------------------------------------
# Fetch available zones (debug)
# ----------------------------------------------
echo "Fetching zones available for this token..."

ZONES_LIST=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CF_TOKEN")

echo "$ZONES_LIST" | jq '.result[].name' 2>/dev/null || true

# ----------------------------------------------
# Get Zone ID
# ----------------------------------------------
echo "Checking Cloudflare zone access..."

ZONE_RESPONSE=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')

if [ "$ZONE_ID" = "null" ] || [ -z "$ZONE_ID" ]; then
    echo "❌ Token does NOT have access to zone: $ROOT_DOMAIN"
    echo "Make sure token includes:"
    echo "   Zone → DNS: Read"
    echo "   Zone → DNS: Edit"
    echo "   Zone → Zone: Read"
    exit 1
fi

echo "✓ Zone ID: $ZONE_ID"

# ----------------------------------------------
# Check if record already exists
# ----------------------------------------------
echo "Checking if DNS record exists..."

RECORD_RESPONSE=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN")

if echo "$RECORD_RESPONSE" | grep -q "\"name\":\"$DOMAIN\""; then
    echo "❌ DNS record already exists for $DOMAIN"
    echo "→ Please handle manually in Cloudflare dashboard."
    exit 1
fi

echo "✓ No existing record found. Creating A record..."

# ----------------------------------------------
# CREATE DNS RECORD
# ----------------------------------------------
CREATE_RESPONSE=$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":true}")

echo "Create response: $CREATE_RESPONSE"

if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
    echo "======================================"
    echo "  ✅ DNS record successfully created  "
    echo "    $DOMAIN → $SERVER_IP"
    echo "======================================"
else
    echo "❌ ERROR: DNS record creation failed"
    echo "Cloudflare response:"
    echo "$CREATE_RESPONSE"

    echo ""
    echo "Would you like to continue installer WITHOUT Cloudflare DNS? (manual DNS mode)"
    read -p "Continue without using Cloudflare? [y/N]: " CHOICE
    if [[ "$CHOICE" =~ ^[Yy]$ ]]; then
        echo "✓ Continuing in MANUAL DNS mode"
        exit 0
    fi

    exit 1
fi

