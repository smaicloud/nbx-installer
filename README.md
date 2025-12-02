# NetBox Installer Script (Ubuntu 24.04 LTS, NetBox 4.4+)

This repository contains a fully automated installation and update script for **NetBox 4.4+** running on **Ubuntu 24.04 LTS** — completely without containers. Optionally, the script can also install the **NetBox Device Discovery Backend**.

---

## 🚀 Features

* ✓ Supports **Ubuntu 24.04 LTS only** (clean, modern environment)
* ✓ Supports **NetBox 4.4 and newer only**
* ✓ Fully automated installation (PostgreSQL, Redis, Gunicorn, nginx)
* ✓ Fully automated updates
* ✓ Optional installation of **NetBox Discovery (Device Discovery Backend)**
* ✓ Generated passwords stored securely in `/root/netbox-install-credentials.txt`
* ✓ No housekeeping script required (NetBox 4.4+ uses built‑in scheduled jobs)
* ✓ ALLOWED_HOSTS remains as in original script: `['*']`
* ✓ Better error handling via `set -euo pipefail`

---

## 📦 Requirements

* Ubuntu **24.04 LTS** (mandatory!)
* Root privileges
* Internet connectivity (to install packages and download NetBox)

Optional for NetBox Discovery:

* A working **Diode deployment** reachable via gRPC
* OAuth client credentials for Diode

---

## 📥 Installation

Make the script executable:

```bash
chmod +x netbox-installer.sh
```

Run the installer:

```bash
sudo ./netbox-installer.sh
```

The script will ask:

1. “Install” or “Update”
2. Your desired NetBox version (e.g. `4.4.7`)
3. Whether to install NetBox Discovery

---

## 🛠️ What the script installs and configures

### System components

* PostgreSQL (db + user `netbox`)
* Redis (as cache/queue)
* Python virtual environment for NetBox
* Gunicorn + systemd units
* nginx reverse proxy

### NetBox configuration

* Auto‑generated `SECRET_KEY`
* Auto‑generated PostgreSQL password
* `ALLOWED_HOSTS = ['*']`
* `configuration.py` created automatically

### Files

* NetBox stored under `/opt/netbox-VERSION/`
* Symlink `/opt/netbox` points to the active version
* Systemd units created:

  * `netbox.service`
  * `netbox-rq.service`

---

## 🔍 Optional: NetBox Discovery Backend

If you select **Yes** during installation, the script will:

1. Create a Python venv at `/opt/netbox-discovery-venv`
2. Install:

   * `netboxlabs-device-discovery`
3. Create a systemd service:

   * `netbox-device-discovery.service`
4. Create an environment file:

   * `/etc/netbox-discovery.env`

Example content:

```ini
DIODE_TARGET=grpc://CHANGE-ME:8080/diode
DIODE_CLIENT_ID=CHANGE-ME
DIODE_CLIENT_SECRET=CHANGE-ME
LISTEN_HOST=0.0.0.0
LISTEN_PORT=9000
```

➡ **You must edit this file** to match your Diode environment.

You also need to install and configure the Diode NetBox plugin inside NetBox.

---

## 🔐 Credentials

Sensitive values (passwords, secrets) are **not shown in the terminal**.
Instead, they are stored securely here:

```
/root/netbox-install-credentials.txt
```

Contains:

* NetBox version
* PostgreSQL password
* Secret Key

File permissions are set to `600`.

---

## 🌐 Accessing NetBox

After installation, open NetBox in your browser:

```
http://SERVER-IP
```

---

## 🔄 Updating NetBox

The script also supports updates.

It preserves:

* `configuration.py`
* `ldap_config.py`
* `media/`
* `scripts/`
* `reports/`
* `gunicorn.py`

The old version must exist under `/opt/netbox-<version>/`.

---

## 🧹 No housekeeping needed

NetBox 4.4+ uses internal scheduled jobs.
The legacy `netbox-housekeeping.sh` script is **removed by design**.

---

## ⚠️ Notes

* ALLOWED_HOSTS remains `['*']` as requested
* SSL/HTTPS is **not configured automatically** (can be added later)
* The installer is designed for **bare‑metal/VM installations**, not Docker
