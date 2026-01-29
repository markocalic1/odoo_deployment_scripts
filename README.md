
# Odoo Deployment & Installation Scripts (Professional CI/CD)

This repository provides a complete automation system for installing, configuring, and deploying Odoo 19+ on Linux servers **without Docker**, including:

- Production-ready installation scripts  
- Automated Nginx + SSL setup  
- Cloudflare DNS integration  
- Full CI/CD deploy pipeline via GitHub Actions  
- Backup & rollback mechanisms  
- Multi-instance environment support  

Everything is built for professional Odoo consultants and teams who want **clean, repeatable, and safe deployments**.

---

# 📦 Included Scripts

| Script | Purpose |
|--------|---------|
| `odoo_install.sh` | Full automated installation of Odoo 19+ on a fresh server |
| `install_nginx_ssl.sh` | Nginx reverse proxy + SSL certificate installer |
| `cloudflare_dns.sh` | Auto-create DNS A-records via Cloudflare API |
| `deploy_odoo.sh` | Zero-downtime deploy script with backup & rollback |
| `ssh_key_create.sh` | Generates SSH keys used for GitHub Actions deployment |
| `odoo-sync.sh` | Sync prod → staging (DB + filestore) |
| `odoo-backup-restore.sh` | Simple wrapper to run `odoo-sync.sh` with minimal args |
| `odoo-update-modules.sh` | Update modules on local DB via odoo-bin |
| `odoo-git-update.sh` | Git update with backup, stash, checks, and optional module update |
| `odoo-sync-env-create.sh` | Create prod/staging env files for backup-restore sync |
| `odooctl.sh` | Unified CLI entrypoint for daily operations |
| `README.md` | Documentation |

---

# 🟥 1. Odoo Installation Script (`odoo_install.sh`)

The installer handles:

### ✅ Full Odoo installation
- Python3, pip, venv, build tools  
- PostgreSQL user autoconfiguration  
- Virtual environment creation  
- Installation of Odoo + custom addons  
- Requirements installation  
- System user creation  
- Systemd service creation  
- Log directory creation  

### ✅ Optional components
- `wkhtmltopdf` installation (patched Qt version)  
- Custom modules repository cloning  
- Environment validation  
- Safe re-run protections  
- Log rotation setup  

### 🧠 Instance-Agnostic Design
You can install multiple independent Odoo instances on the same server:

```
/opt/odoo19
/opt/odoo19-staging
/opt/odoo20
```

Each instance gets its own:
- user  
- virtualenv  
- config  
- service  
- logs  

### ▶️ Installation Example

```
sudo bash odoo_install.sh
```

The script will interactively ask:

- Odoo user  
- installation path  
- git repo URL (optional)  
- branch  
- PostgreSQL user  
- Odoo version  
- Systemd service name  
- Port  
- Whether to install wkhtmltopdf  

### 🔧 Log Rotation

Automatically creates:

```
/etc/logrotate.d/odoo
```

Contents:

```
/opt/odoo/log/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
```

---

# 🟦 2. Nginx + SSL Installer (`install_nginx_ssl.sh`)

This script:

### ✅ Auto-detects:
- Odoo systemd service  
- Odoo config file  
- http_port  
- longpolling_port  

### ✅ Creates:
- Nginx reverse proxy configuration  
- HTTP → HTTPS redirect  
- Longpolling upstream  
- Static assets caching  
- gzip support  

### ✅ Automatically installs SSL using Let's Encrypt

```
bash install_nginx_ssl.sh
```

---

# 🟧 3. Cloudflare DNS Auto-Creator (`cloudflare_dns.sh`)

Automatically:

- Loads Cloudflare API token  
- Saves token to `/etc/cloudflare/api_token`  
- Validates zone  
- Checks if DNS record exists  
- Creates A-record if missing  

Usage:

```
./cloudflare_dns.sh staging.example.com
```

---

# 🟩 4. Zero-Downtime Deploy Script (`deploy_odoo.sh`)

This is the core deployment engine.

### 🚀 Features
- Pull latest code from Git  
- Backup database  
- Backup current code  
- Install updated Python dependencies  
- Restart Odoo  
- Health check `/web/login`  
- Auto rollback on failure  
- Instance-based `.env` configs  
- Deploy logs stored per environment  

### ▶️ Usage

```
bash deploy_odoo.sh staging19
bash deploy_odoo.sh prod19
```

---

# 🟫 4.1 Unified CLI (`odooctl.sh`)

Use this as the **single entrypoint** for daily operations.

### ▶️ Examples

```
./odooctl.sh deploy staging19
./odooctl.sh git-update staging19 update -all
./odooctl.sh modules staging19 sale,stock,account
./odooctl.sh backup-restore 19
./odooctl.sh backup-restore-env 19
./odooctl.sh describe deploy
```

### 🔎 What does a command do?
Use `describe` to see what a command does and which config/env files it reads:

```
./odooctl.sh describe git-update
```

---

# 🟩 Daily Usage (Quick Guide)

### 1) Safe deploy (recommended)
```
./odooctl.sh deploy <instance>
```
Does: DB + code backup → git reset to origin/<branch> → pip install → restart → health check → auto‑rollback on failure.

### 2) Git update + optional module update
```
./odooctl.sh git-update <instance>
./odooctl.sh git-update <instance> update -all
./odooctl.sh git-update <instance> update sale,stock,account
```

### 3) Update modules only
```
./odooctl.sh modules <instance> sale,stock,account
```

### 4) Backup/restore prod -> staging
```
./odooctl.sh backup-restore <suffix>
```

### 5) Need help fast
```
./odooctl.sh --help
./odooctl.sh describe deploy
```

---

# 🟦 Run Without `./odooctl.sh`

Use a PATH shortcut so you can run `odooctl` directly.

### ▶️ System-wide (recommended)
```
sudo ln -sf /path/to/odoo_deployment_scripts/odooctl.sh /usr/local/bin/odooctl
```

### ▶️ User-only
```
mkdir -p ~/bin
ln -sf /path/to/odoo_deployment_scripts/odooctl.sh ~/bin/odooctl
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Then run:
```
odooctl deploy <instance>
```

---

# 🟦 7. Bash Autocomplete (`odooctl-completion.bash`)

Enable tab-completion for `odooctl` commands and instance names.

### ▶️ Install (per-user)

```
echo 'source /path/to/odoo_deployment_scripts/odooctl-completion.bash' >> ~/.bashrc
source ~/.bashrc
```

### ▶️ Install (system-wide)

```
sudo cp /path/to/odoo_deployment_scripts/odooctl-completion.bash /etc/bash_completion.d/odooctl
```

---

# 🟨 6. Backup/Restore Env Helper (`odoo-sync-env-create.sh`)

Generate the `prod<suffix>.env` and `staging<suffix>.env` files used by
`odoo-backup-restore.sh` (and `./odooctl.sh backup-restore`).

### ▶️ Usage

```
sudo bash odoo-sync-env-create.sh 19
sudo bash odoo-sync-env-create.sh 19 --with-sync-env
```

### Master Passwords
You can set master passwords in:
- `/etc/odoo_deploy/odoo-sync.env` (recommended), or
- `prod*.env` / `staging*.env` using `MASTER_PASS` or `ODOO_MASTER_PASS`

### Database Passwords (non-interactive pg_dump)
If your DB user requires a password, add one of these keys to the instance env:
- `DB_PASSWORD`, or
- `DB_PASS`

Then `deploy_odoo.sh` will use it for `pg_dump` without prompting.

---

# 🟪 5. SSH Key Generator (`ssh_key_create.sh`)

Creates an SSH deploy key pair:

```
ssh_key_create.sh
```

Output:

```
id_ed25519
id_ed25519.pub
```

You upload `id_ed25519.pub` into GitHub Deploy Keys  
and store private key in GitHub Actions Secret:

```
SSH_PRIVATE_KEY
```

---

# 🔥 6. GitHub Actions CI/CD Setup

---

# 🟫 7. Production → Staging Sync (`odoo-sync.sh`)

This script can sync production DB + filestore to staging using:
- `pg_dump` (fast, default), or
- Odoo Web Backup endpoint (zip).

### ✅ Recommended simple usage (no long args)

Use the wrapper `odoo-backup-restore.sh` and store secrets in a separate file:

Create `/etc/odoo_deploy/odoo-sync.env` (chmod 600):
```
PROD_HOST="23.88.117.155"
PROD_SSH_USER="root"
BACKUP_METHOD="odoo"   # or "pg"
RESTORE_METHOD="odoo"  # or "pg"
DROP_METHOD="auto"     # auto | odoo | pg
NO_FILESTORE="false"

# Master passwords (optional, avoids prompt)
PROD_MASTER_PASS="your_production_master_password"
STAGING_MASTER_PASS="your_staging_master_password"
```

Then run:
```
sudo bash odoo-backup-restore.sh 19
```

### ✅ Direct usage (full control)
```
sudo bash odoo-sync.sh \
  --prod-env /etc/odoo_deploy/prod19.env \
  --staging-env /etc/odoo_deploy/staging19.env \
  --prod-host 23.88.117.155 \
  --prod-ssh root \
  --backup-method odoo \
  --method odoo \
  --drop-method auto
```

### ⚠ Notes
- If `--method odoo` is used, Odoo service on staging must be running.
- If DB is locked, the script will stop the service and terminate sessions before drop.
- If restore fails, check Odoo logs: `journalctl -u odoo -n 200`.

---

# 🟦 8. Update Modules (`odoo-update-modules.sh`)

Update modules on a local instance database using `odoo-bin`.

Usage:
```
sudo bash odoo-update-modules.sh <instance_name> <module1,module2>
```

Example:
```
sudo bash odoo-update-modules.sh staging19 sale,stock,account
```

Notes:
- The script reads `/etc/odoo_deploy/<instance>.env` for `DB_NAME` and `OE_HOME`.
- It stops the Odoo service, runs update, then starts the service.

Triggers deployment:

- When pushing to `19.0-staging` → deploy to staging  
- When pushing to `19.0` → deploy to production  

### `.github/workflows/deploy.yml`

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

      - name: Determine Environment
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

# 📁 Environment Configs

Located in:

```
/etc/odoo_deploy/*.env
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

ODOO_PORT="8069"
LONGPOLLING_PORT="8072"
```

---

# 📌 Final Notes

This repository gives you:

- A fully reusable, multi-environment Odoo deployment system  
- Safe rollback on error  
- Cloudflare DNS automation  
- SSL + reverse proxy automation  
- GitHub CI/CD for push-to-deploy  

Everything follows modern DevOps & Odoo best practices.

---

# 📄 License

MIT License  
Feel free to use, modify, and improve!
