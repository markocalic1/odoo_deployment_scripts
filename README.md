# Odoo Server Setup Scripts

Automated scripts for installing and configuring Odoo instances on Ubuntu servers (20.04 / 22.04 / 24.04).  
These scripts allow quick, consistent, and repeatable setup of:

- Odoo Community (19.0, 20.0, master…)
- PostgreSQL users and databases
- Python virtual environments
- Systemd services
- Nginx reverse proxy
- Let's Encrypt SSL certificates
- Cloudflare‑friendly configurations

One installer can create production, staging, and development instances with zero modifications.

---

## 📦 Repository Contents

| Script | Description |
|--------|-------------|
| **install_odoo.sh** | Installs an Odoo instance (version of your choice), PostgreSQL user, virtualenv, systemd service |
| **install_nginx_ssl.sh** | Sets up Nginx reverse proxy, applies SSL via Let’s Encrypt, auto‑enables `proxy_mode` |
| **deploy.sh** *(optional)* | Pulls latest code and restarts services |
| **backup.sh** *(optional)* | Backup script for PostgreSQL databases |

---

## ⚙️ Requirements

- Ubuntu 20.04 / 22.04 / 24.04  
- Root or sudo access  
- GitHub SSH key (for private repos)  
- Cloudflare DNS A‑record pointing to the server IP (for SSL)  

---

## 🚀 Installing an Odoo Instance

### 1. Clone the scripts

```bash
git clone git@github.com:username/your-repo.git
cd your-repo
chmod +x install_odoo.sh
chmod +x install_nginx_ssl.sh
```

### 2. Run the Odoo installer

```bash
sudo bash install_odoo.sh
```

You will be prompted for:

- Odoo system user (e.g., `odoo19`)
- Installation directory (e.g., `/opt/odoo19`)
- Your custom modules repo URL
- Git branch (`main`, `staging`, `dev`)
- PostgreSQL username
- Odoo version (`19.0`, `20.0`, `master`, ...)
- Config file name (e.g., `odoo19.conf`)
- Systemd service name (e.g., `odoo19`)
- Port (default `8069`)

---

## 🌍 Domain + SSL Setup (Nginx)

### 1. Cloudflare DNS

Create an A record:

| Type | Name | Value | Proxy |
|------|------|--------|--------|
| A | erp | SERVER_IP | Proxied (orange) |

### 2. Run SSL + Nginx setup

```bash
sudo bash install_nginx_ssl.sh
```

You will be prompted for:

- Domain (e.g., `erp.example.com`)
- Odoo port
- Systemd service name

The script will:

- Install nginx  
- Create reverse proxy config  
- Generate Let’s Encrypt SSL  
- Detect the Odoo config file  
- Ensure `proxy_mode = True`  
- Restart all services  

Your instance will be available at:

```
https://erp.example.com
```

---

## 🧪 Example Production Installation

```bash
sudo bash install_odoo.sh
# User: odoo19
# Directory: /opt/odoo19
# Repo: git@github.com:username/custom-addons.git
# Branch: main
# PostgreSQL user: odoo19
# Odoo version: 19.0
# Config: odoo19.conf
# Service: odoo19
# Port: 8069
```

## 🧪 Example Staging Installation

```bash
sudo bash install_odoo.sh
# User: odoo19s
# Directory: /opt/odoo19-staging
# Branch: staging
# Port: 8071
```

### SSL setup:

```bash
sudo bash install_nginx_ssl.sh
# Domain: staging.example.com
# Port: 8071
# Service: odoo19s
```

---

## ☁️ Recommended Cloudflare Settings

| Option | Value |
|--------|--------|
| SSL/TLS Mode | **Full (strict)** |
| Always Use HTTPS | ON |
| Auto Minify | ON |
| Rocket Loader | OFF (for Odoo) |
| Proxy | ON |

---

## 🛠 Optional: Deployment Script (deploy.sh)

Typical workflow:

```bash
sudo bash deploy.sh odoo19
```

Tasks performed:

- Pull latest commit from repo
- Install new Python dependencies (if any)
- Restart Odoo systemd service

---

## 🗄 Backup Script (backup.sh)

If included, it supports:

- Automatic PostgreSQL dumps
- Optional upload to remote storage
- Cron automation

---

## 📜 License

MIT License (recommended for scripts).  
Update as needed.

---

## 💬 Support

For improvements or issues, feel free to open a GitHub issue or PR.
