
# Odoo Deployment Scripts (Professional CI/CD)

This repository contains production‑grade deployment automation for Odoo 19+ servers without Docker.
It provides fully automated SSH‑based deployments triggered via GitHub Actions, with backup, rollback,
health‑checks, Cloudflare DNS helper scripts, Nginx SSL automation, and environment‑based multi‑instance support.

---

## 🚀 Features

### ✅ Full Odoo Deploy Pipeline
- Git pull via SSH
- Automatic requirements installation
- Database & code backup before every deploy
- Auto rollback on failure
- Health check on `/web/login`
- Instance‑based `.env` configs
- Detailed deploy logs per instance

### ✅ CI/CD Ready (GitHub Actions)
- Branch‑based deployment:
  - `19.0-staging` → staging server
  - `19.0` → production server
- Secure deploy via SSH private key stored in GitHub secrets
- Zero open ports — **no webhook listener needed**

### ✅ Server‑Side Utilities
- Cloudflare DNS auto‑creator (`cloudflare_dns.sh`)
- Nginx + SSL installer (`install_nginx_ssl.sh`)
- Odoo installation scripts (`odoo_install.sh`)
- SSH key generator helper (`ssh_key_create.sh`)

---

## 📁 Directory Structure

```
odoo_deployment_scripts/
│
├── odoo_install.sh
├── install_nginx_ssl.sh
├── cloudflare_dns.sh
├── deploy_odoo.sh
├── ssh_key_create.sh
└── README.md
```

---

## ⚙️ Deploy Setup

### 1. Create instance config

Create file:

```
/etc/odoo_deploy/staging19.env
```

Example:

```
INSTANCE_NAME="staging19"

OE_USER="odoo"
OE_HOME="/opt/odoo"
SERVICE_NAME="odoo"

BRANCH="19.0-staging"

DB_NAME="staging19"
DB_USER="odoo"
DB_HOST="localhost"
DB_PORT="5432"

ODOO_PORT="8069"
```

Production uses `BRANCH="19.0"`.

---

## 🚀 Deploy Script

Use:

```
bash /opt/odoo/deploy_odoo.sh staging19
```

This will:
- Backup DB + code
- Pull updates
- Install Python deps
- Restart Odoo
- Health check
- Rollback on failure

All logs stored in:

```
/opt/odoo/log/deploy_staging19.log
```

---

## 🔐 GitHub CI/CD Integration

Create GitHub secrets:

| Secret | Description |
|--------|-------------|
| `SSH_PRIVATE_KEY` | Private key for SSH deploy |
| `SSH_USER` | Usually `root` |
| `SSH_HOST_STAGING` | Staging server IP |
| `SSH_HOST_PROD` | Production server IP |

Example workflow:

```
.github/workflows/deploy.yml
```

```yaml
name: Odoo CI/CD Deploy

on:
  push:
    branches:
      - "19.0-staging"
      - "19.0"

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup SSH
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Determine target environment
        id: env
        run: |
          if [[ "${GITHUB_REF##*/}" == "19.0-staging" ]]; then
            echo "target=staging" >> $GITHUB_OUTPUT
          else
            echo "target=prod" >> $GITHUB_OUTPUT
          fi

      - name: Deploy to Staging
        if: steps.env.outputs.target == 'staging'
        run: |
          ssh -o StrictHostKeyChecking=no ${{ secrets.SSH_USER }}@${{ secrets.SSH_HOST_STAGING }}           "bash /opt/odoo/deploy_odoo.sh staging19"

      - name: Deploy to Production
        if: steps.env.outputs.target == 'prod'
        run: |
          ssh -o StrictHostKeyChecking=no ${{ secrets.SSH_USER }}@${{ secrets.SSH_HOST_PROD }}           "bash /opt/odoo/deploy_odoo.sh prod19"
```

---

## 🌐 Cloudflare DNS Helper

Use:

```
./cloudflare_dns.sh sub.domain.com
```

Automatically:
- Validates token
- Loads/saves `/etc/cloudflare/api_token`
- Detects zone
- Creates A‑record only if missing

---

## 🔒 SSH Deploy Key Setup

Generate key:

```
ssh-keygen -t ed25519 -f github_ci_key
```

Add `github_ci_key.pub` to GitHub → Deploy Keys.

Add private key to GitHub Secrets:

```
SSH_PRIVATE_KEY
```

---

## 💬 Support

For improvements, ideas, or additional automation (Zero‑Downtime, multi‑repo deploy, asset builds, DB migrations), open an issue or contact the maintainer.

---

## 📄 License

MIT
