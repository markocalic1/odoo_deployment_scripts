#!/bin/bash
set -e

###############################################
# CLOUDFLARE DNS AUTO-CREATOR
###############################################
# Usage:
#   ./cloudflare_dns.sh sub.domain.com
#
# Automatically:
#  ✓ Loads/saves Cloudflare token
#  ✓ Detects zone
#  ✓ Checks if A-record exists
#  ✓ Creates DNS A record if not present
#  ✓ Uses server public IP
###############################################

DOMAIN=$1

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 sub.domain.com"
    exit 1
fi

CF_TOKEN_FILE="/etc/cloudflare/api_token"
SERVER_IP=$(curl -s ifconfig.me)
ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

echo "----------------------------------------------"
echo " Cloudflare DNS Auto Creator"
echo "----------------------------------------------"
echo "Domain:        $DOMAIN"
echo "Root domain:   $ROOT_DOMAIN"
echo "Server IP:     $SERVER_IP"
echo "----------------------------------------------"

# ---------------------------------------------------------
# 1. Check token or ask user
# ---------------------------------------------------------
if [ ! -f "$CF_TOKEN_FILE" ]; then
    echo "⚠ No Cloudflare token found at $CF_TOKEN_FILE"

    read -p "Enter Cloudflare API Token: " CF_TOKEN_INPUT

    if [ -z "$CF_TOKEN_INPUT" ]; then
        echo "❌ ERROR: Token cannot be empty."
        exit 1
    fi

    sudo mkdir -p /etc/cloudflare
    echo "$CF_TOKEN_INPUT" | sudo tee "$CF_TOKEN_FILE" >/dev/null
    sudo chmod 600 "$CF_TOKEN_FILE"

    echo "✓ Token saved to $CF_TOKEN_FILE"
fi

CF_TOKEN=$(cat "$CF_TOKEN_FILE")

# ---------------------------------------------------------
# 2. GET ZONE ID
# ---------------------------------------------------------
echo "Checking Cloudflare zone..."

ZONE_RESPONSE=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RESPONSE" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' | head -n1)

if [ -z "$ZONE_ID" ]; then
    echo "❌ ERROR: Could not find Cloudflare zone: $ROOT_DOMAIN"
    echo "$ZONE_RESPONSE"
    exit 1
fi

echo "✓ Zone ID: $ZONE_ID"

# ---------------------------------------------------------
# 3. CHECK IF RECORD ALREADY EXISTS
# ---------------------------------------------------------
echo "Checking if DNS record already exists..."

RECORD_RESPONSE=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

if [[ "$RECORD_RESPONSE" == *"\"name\":\"$DOMAIN\""* ]]; then
    echo "❌ ERROR: DNS record already exists for $DOMAIN"
    echo "Please handle this manually in Cloudflare Dashboard."
    exit 1
fi

echo "✓ No existing record found. Creating..."

# ---------------------------------------------------------
# 4. CREATE DNS RECORD
# ---------------------------------------------------------
CREATE_RESPONSE=$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":true}")

if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
    echo "======================================"
    echo "  ✅ DNS record successfully created  "
    echo "    $DOMAIN → $SERVER_IP"
    echo "======================================"
else
    echo "❌ ERROR: Failed to create DNS record"
    echo "$CREATE_RESPONSE"
    exit 1
fi

