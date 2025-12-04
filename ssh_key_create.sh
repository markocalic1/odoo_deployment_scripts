#!/bin/bash
set -e

#########################################################
# SSH KEY CREATOR
#########################################################
# Creates a new SSH key pair for GitHub/GitLab/Bitbucket
# Options:
#  ✓ Choose email for key
#  ✓ Choose key name
#  ✓ Choose type (ed25519 or rsa4096)
#  ✓ Secure permissions
#  ✓ Auto-print public key for copy/paste
#########################################################

echo "============== SSH KEY CREATOR =============="

# -------------------------------------------------------
# Ask for email
# -------------------------------------------------------
read -p "Email for SSH key (example: john@example.com): " KEY_EMAIL
if [ -z "$KEY_EMAIL" ]; then
    echo "❌ Email cannot be empty"
    exit 1
fi

# -------------------------------------------------------
# Ask for key name
# -------------------------------------------------------
read -p "Key name [id_ed25519]: " KEY_NAME
KEY_NAME=${KEY_NAME:-id_ed25519}

KEY_PATH="$HOME/.ssh/$KEY_NAME"

# -------------------------------------------------------
# Choose key type
# -------------------------------------------------------
echo "Choose SSH key type:"
echo "1) ed25519 (recommended, modern)"
echo "2) rsa4096 (legacy compatibility)"

read -p "Choice [1]: " KEY_TYPE
KEY_TYPE=${KEY_TYPE:-1}

if [ "$KEY_TYPE" == "2" ]; then
    KEY_TYPE_CMD="rsa -b 4096"
    echo "✓ Using RSA 4096"
else
    KEY_TYPE_CMD="ed25519"
    echo "✓ Using ED25519"
fi

# -------------------------------------------------------
# Prevent overwriting existing keys
# -------------------------------------------------------
if [ -f "$KEY_PATH" ]; then
    echo "❌ SSH key already exists at: $KEY_PATH"
    echo "Move or rename it before creating a new one."
    exit 1
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh

# -------------------------------------------------------
# Create SSH key
# -------------------------------------------------------
echo "Generating SSH key..."
ssh-keygen -t $KEY_TYPE_CMD -f "$KEY_PATH" -C "$KEY_EMAIL" -N ""

chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

echo ""
echo "=========================================="
echo "   ✅ SSH KEY CREATED SUCCESSFULLY"
echo "=========================================="
echo "Private key: $KEY_PATH"
echo "Public key:  $KEY_PATH.pub"
echo ""
echo "---------- PUBLIC KEY (copy to GitHub/GitLab) ----------"
cat "$KEY_PATH.pub"
echo "--------------------------------------------------------"

# -------------------------------------------------------
# Optional: Copy to clipboard (if installed)
# -------------------------------------------------------
if command -v xclip >/dev/null; then
    echo "$(<$KEY_PATH.pub)" | xclip -selection clipboard
    echo "✓ Public key copied to clipboard!"
elif command -v pbcopy >/dev/null; then
    echo "$(<$KEY_PATH.pub)" | pbcopy
    echo "✓ Public key copied to clipboard!"
else
    echo "ℹ Install xclip to enable auto copy: sudo apt install xclip"
fi

echo ""
echo "Now add this public key to:"
echo "GitHub → https://github.com/settings/keys"
echo "GitLab → https://gitlab.com/-/profile/keys"
echo "Bitbucket → https://bitbucket.org/account/settings/ssh-keys/"
echo ""
echo "========================================================="

