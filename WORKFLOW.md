# KOMMS – Operator Workflow

> **Audience:** Administrators deploying KOMMS on a fresh server.  
> **Deutsche Version:** [WORKFLOW.de.md](WORKFLOW.de.md)

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [DNS Setup (VPS only)](#2-dns-setup-vps-only)
3. [Installation](#3-installation)
4. [First Login Overview](#4-first-login-overview)
5. [Adding Users](#5-adding-users)
6. [Removing Users](#6-removing-users)
7. [Handing Over Credentials](#7-handing-over-credentials)
8. [Android Device Setup (User Side)](#8-android-device-setup-user-side)
9. [Windows Client Setup (User Side)](#9-windows-client-setup-user-side)
10. [Day-to-Day Operations](#10-day-to-day-operations)
11. [Maintenance & Backups](#11-maintenance--backups)
12. [Adding TAKServer](#12-adding-takserver)
13. [Updates](#13-updates)

---

## 1. Prerequisites

### Server

| Requirement | VPS / Cloud | LAN / Homelab |
|-------------|-------------|---------------|
| OS | Ubuntu 22.04 / 24.04 or Debian 12 (64-bit) | same |
| Architecture | x86_64 | x86_64 or ARM64 (RPi — TAKServer excluded) |
| RAM | 4 GB min · **8 GB min with TAKServer** | 2 GB min |
| Disk | 40 GB min | 20 GB min |
| Root access | required | required |
| Open ports | 80, 443, 1194/UDP, 8089, 8443, 64738 | same |

### Admin Machine

- SSH access to the server
- GitHub account with access to this repository

---

## 2. DNS Setup (VPS only)

All DNS A-records must point to the server IP **before** running the installer. A wildcard record `*.domain.com` + `domain.com` is sufficient.

| Record | Target |
|--------|--------|
| `domain.com` | Server IP |
| `auth.domain.com` | Server IP |
| `cloud.domain.com` | Server IP |
| `collabora.domain.com` | Server IP |
| `element.domain.com` | Server IP |
| `matrix.domain.com` | Server IP |
| `mdm.domain.com` | Server IP |
| `ldap.domain.com` | Server IP |
| `tak.domain.com` | Server IP |

Wait for DNS propagation (5–60 min), then verify:

```bash
dig +short auth.domain.com    # must return the server IP
```

---

## 3. Installation

### 3.1 Clone and configure

If using a forked/private repo, edit `install.sh` to point to your repository:

```bash
REPO_OWNER="your-github-username"    # line ~21
```

### 3.2 Run the installer on the server (as root)

```bash
# Public repository:
curl -fsSL https://raw.githubusercontent.com/GUMMIIII/TAKSERVER_MDM/main/install.sh | bash

# Private repository (GitHub PAT required):
curl -H "Authorization: token YOUR_GITHUB_PAT" \
     -fsSL https://raw.githubusercontent.com/GUMMIIII/TAKSERVER_MDM/main/install.sh \
  | GITHUB_PAT=YOUR_GITHUB_PAT bash
```

### 3.3 TAKServer (optional — before running the installer)

TAKServer is **auto-detected** — no prompt during install. If you want it set up automatically, place the ZIP in the data directory first:

```bash
mkdir -p /opt/komms-data/tak-release
scp TAKSERVER-DOCKER-*.zip root@YOUR_SERVER:/opt/komms-data/tak-release/
```

If the directory or ZIP is not present, TAKServer is skipped and can be added later (see [Section 12](#12-adding-takserver-later)).

### 3.4 What the installer asks

The installer prompts interactively for:

- Domain name, deployment mode (VPS / LAN)
- Passwords: database, Nextcloud admin, MDM admin, LDAP admin
- Mumble SuperUser password + join password
- VPN hostname/port, certificate fields
- Operator username and display name (prompted after health check)

### 3.5 What happens automatically

```
[1/8]  System update
[2/8]  Package installation (Docker, certbot, jq, qrencode, …)
[3/8]  Docker installation
[4/8]  Clone KOMMS repository to /opt/komms
[5/8]  Write /opt/komms-data/.env
[6/8]  setup_server.sh:
         · UFW firewall rules
         · TLS certificate (Let's Encrypt on VPS, self-signed on LAN)
         · nginx.conf, homeserver.yaml, element/config.json generated
         · OpenVPN PKI initialized
         · Docker services started
         · Nextcloud LDAP + Authelia SSO integration configured
         · Mumble server name and join password set
[7/8]  TAKServer — ZIP detected → prints instructions to run setup_tak.sh
       (full auto-install not yet supported — see note below)
[8/8]  Health check + login overview printed
       → Operator account created (add_user.sh --admin)
       → .ovpn + TAK certificate + Nextcloud upload
       → SCP command printed for downloading the .ovpn
```

> **TAKServer requires a manual post-install step** — run `setup_tak.sh` after `install.sh` completes (see [Section 12](#12-adding-takserver-later)).  
> All other services are fully configured automatically without any manual steps.

### 3.6 Installation time

Approximately **15–25 minutes** (10 min Docker image downloads). TAKServer adds another 5–10 min when run manually via `setup_tak.sh`.

### 3.7 Retrieve the operator .ovpn

The installer prints the SCP command at the end:

```bash
scp root@SERVER_IP:/opt/komms-data/users/operator/operator.ovpn .
```

Alternatively: after logging into `https://cloud.domain.com`, the file is in the shared folder `KOMMS-Users/operator/`.

---

## 4. First Login Overview

### Access model

```
Without VPN:
  auth.domain.com        → Authelia SSO portal (login for all services)
  cloud.domain.com       → Nextcloud (Authelia-gated)
  collabora.domain.com   → Collabora Online (WOPI token auth via Nextcloud)

VPN required:
  element.domain.com → Element Web   (Authelia: any user)
  matrix.domain.com  → Matrix/Synapse (no Authelia gate — native clients)
  mdm.domain.com     → Headwind MDM  (Authelia: lldap_admin)
  ldap.domain.com    → LLDAP Web UI  (Authelia: lldap_admin)
  tak.domain.com     → TAKServer     (Authelia: lldap_admin)
```

### Service login table

| Service | URL | Credentials |
|---------|-----|-------------|
| **Authelia** | `https://auth.domain.com` | LLDAP username + password |
| **Nextcloud** | `https://cloud.domain.com` | Authelia SSO — redirects automatically (no password form) |
| **Collabora** | `https://collabora.domain.com` | Automatic via Nextcloud (WOPI) |
| **Element** | `https://element.domain.com` | Authelia SSO |
| **Headwind MDM** | `https://mdm.domain.com` | Authelia SSO (lldap_admin) |
| **LLDAP Admin** | `https://ldap.domain.com` | Authelia SSO (lldap_admin) |
| **TAKServer** | `https://tak.domain.com` | Authelia SSO (lldap_admin) |
| **Mumble** | `domain.com:64738` | Join password from `.env` |

> Element, MDM, LLDAP and TAKServer are **only reachable with an active VPN** — nginx returns 403 even for authenticated Authelia sessions from non-VPN IPs.

---

## 5. Adding Users

### Regular user

```bash
sudo bash /opt/komms/server/add_user.sh <username> "Display Name"

# Example:
sudo bash /opt/komms/server/add_user.sh soldier01 "John Smith"
```

Access granted: Nextcloud, Element, Matrix, Mumble, OpenVPN.

### Admin/operator user

```bash
sudo bash /opt/komms/server/add_user.sh --admin <username> "Display Name"
```

Additional access: Headwind MDM, LLDAP Web UI, TAKServer WebTAK.  
(`lldap_admin` group membership is set automatically.)

### Special case: built-in `admin` account

```bash
sudo bash /opt/komms/server/add_user.sh admin "Admin"
```

LLDAP account creation and password reset are skipped (the account already exists and its password is used by Authelia/Synapse for LDAP bind). OpenVPN cert, TAK certificate, and Nextcloud upload run normally.

### What gets created

```
/opt/komms-data/users/<username>/
├── <username>.ovpn         ← OpenVPN profile (Android + Windows)
├── <username>-tak.p12      ← ATAK/WinTAK certificate (passphrase: TAK_CERT_PASS from .env)
├── <username>-tak.zip      ← TAK data package (recommended — auto-connects)
├── qr-credentials.png      ← QR code with LLDAP login credentials
└── credentials.txt         ← Plain-text summary (delete after handover!)
```

All files are automatically uploaded to Nextcloud (`KOMMS-Users/<username>/`) and shared with the user.

### User onboarding flow

1. User opens `https://cloud.domain.com` (no VPN needed)
2. Logs in via Authelia SSO with the LLDAP credentials from `qr-credentials.png` — Nextcloud redirects automatically (no password form on Nextcloud itself)
3. Downloads `.ovpn` from the shared folder
4. Imports `.ovpn` into the OpenVPN app → connects VPN
5. All other services are now reachable

---

## 6. Removing Users

```bash
sudo bash /opt/komms/server/delete_user.sh <username>
```

Removes the account from (in order):

1. LLDAP
2. Nextcloud + WebDAV folder
3. OpenVPN (certificate revoked, PKI files deleted)
4. TAKServer certificates (`.p12`, `.crt`, `.key`, `.jks`)
5. Local files under `/opt/komms-data/users/<username>/`

---

## 7. Handing Over Credentials

### Secure handover process

1. Open the user's Nextcloud folder (`KOMMS-Users/<username>/`) and send `qr-credentials.png` via a secure channel — or show it in person
2. User scans the QR, logs into Nextcloud, and downloads `.ovpn`
3. **Delete files from `/opt/komms-data/users/<username>/` after handover**

### Per-device checklist

- [ ] VPN profile imported and connection tested
- [ ] Authelia login at `auth.domain.com` works
- [ ] Nextcloud logged in (`cloud.domain.com`)
- [ ] Element Web logged in (`element.domain.com`, VPN required)
- [ ] Mumble client connected (`domain.com:64738`, VPN + join password)
- [ ] ATAK: TAK data package imported (`.zip`), server connection tested
- [ ] MDM enrollment completed (admin devices only)

---

## 8. Android Device Setup (User Side)

### 8.1 VPN (OpenVPN)

1. Install: **OpenVPN for Android**
2. Transfer `.ovpn` to the device (download from Nextcloud)
3. In the app: `+` → Import file → Connect
4. Enter LLDAP username + password when prompted

### 8.2 Matrix / Element

1. Install: **Element**
2. Connect VPN
3. Open `https://element.domain.com` in a browser → Authelia login  
   *or* in Element app: "Other server" → `https://matrix.domain.com`

### 8.3 Nextcloud

1. Install: **Nextcloud**
2. Server URL: `https://cloud.domain.com` (no VPN needed)
3. Log in with LLDAP credentials

### 8.4 ATAK (TAKServer)

**Recommended: TAK data package (`.zip`)**

1. Transfer `.zip` to the device (from Nextcloud)
2. ATAK → Settings → Network → Import data package
3. Connection is configured automatically

**Manual:**

1. Transfer `.p12` to the device
2. ATAK → Settings → Network → Connections → `+`
3. Server: `tak.domain.com`, Port: `8089`, Protocol: `TLS`
4. Import `.p12` certificate (passphrase from `credentials.txt`)

### 8.5 Mumble

1. Install: **Mumla**
2. Connect VPN
3. Add server: `domain.com:64738`
4. Enter the join password (from `credentials.txt`)

### 8.6 Headwind MDM (admin devices only)

1. Connect VPN
2. Open `https://mdm.domain.com` → Authelia login
3. Generate an enrollment QR for the device
4. On the target device: install the Headwind APK → scan QR

---

## 9. Windows Client Setup (User Side)

```powershell
# Run as Administrator:
.\windows\setup.ps1
```

Installs and configures: OpenVPN, WinTAK, Element Desktop.

---

## 10. Day-to-Day Operations

### Check service status

```bash
cd /opt/komms/server
docker compose ps
```

### View logs

```bash
docker compose logs -f nginx        # reverse proxy + access log
docker compose logs -f authelia     # SSO / auth errors
docker compose logs -f lldap        # LDAP / user management
docker compose logs -f nextcloud
docker compose logs -f collabora    # Collabora Online / document editor
docker compose logs -f synapse      # Matrix
docker compose logs -f headwind     # MDM
docker compose logs -f openvpn
docker compose logs -f mumble
```

### Restart a service

```bash
docker compose restart <service>    # single service
docker compose restart nginx        # after nginx config changes
```

> **Note:** After changes to `nginx.conf`, restart the nginx container rather than just reloading (`nginx -s reload`). If the config file was regenerated from the template, the running container still has the old inode-cached version until it is restarted.

### Reset a user's password

```bash
NEW_PASS=$(openssl rand -base64 18 | tr -d '=+/' | head -c 20)
cd /opt/komms/server
source /opt/komms-data/.env
docker compose exec lldap /app/lldap_set_password \
    --base-url http://127.0.0.1:17170 \
    --admin-password "$LDAP_ADMIN_PASS" \
    --username "<username>" \
    --password "$NEW_PASS"
echo "New password: $NEW_PASS"
```

### Stop / start the stack

```bash
docker compose down        # stop all (data volumes preserved)
docker compose up -d       # start all
```

---

## 11. Maintenance & Backups

### Platform update

```bash
sudo bash /opt/komms/server/update.sh            # latest release tag (recommended)
sudo bash /opt/komms/server/update.sh main       # current main branch
sudo bash /opt/komms/server/update.sh v0.0.5     # specific tag
```

The update script backs up `.env`, warns about new required variables, stops the stack, updates code + images, and restarts.

### Nextcloud major version upgrade

Nextcloud only supports single-step major upgrades (e.g. 33 → 34). Run once per major version:

```bash
sudo bash /opt/komms/server/update_nextcloud.sh        # auto: current + 1
sudo bash /opt/komms/server/update_nextcloud.sh 34     # explicit target
```

After upgrading, commit the updated image tag:

```bash
git add server/docker-compose.yml
git commit -m "chore: update Nextcloud 33 to 34"
git push
```

### Backup important volumes

```bash
for vol in server_postgres_data server_synapse_data server_nextcloud_data \
           server_openvpn_data server_lldap_data server_headwind_files; do
    docker run --rm \
        -v ${vol}:/data:ro \
        -v /backup:/backup \
        alpine tar czf /backup/${vol}-$(date +%Y%m%d).tar.gz -C /data .
done

# Back up .env separately (keep encrypted!)
cp /opt/komms-data/.env /backup/komms-env-$(date +%Y%m%d).env
```

### Let's Encrypt certificate (VPS)

Renewal runs automatically via Certbot cron job.  
Manual renewal:

```bash
certbot renew
certbot certificates    # check status
```

### Server reboot

```bash
reboot
# Stack starts automatically (restart: unless-stopped)
cd /opt/komms/server && docker compose ps
```

---

## 12. Adding TAKServer

> **This is a required manual step after every fresh install.** Fully automated TAKServer setup inside `install.sh` is on the roadmap but not yet implemented — see [CHANGELOG](CHANGELOG.md) for details.

TAKServer requires a free account at [tak.gov](https://tak.gov).

```bash
# 1. Place the ZIP in the release directory (if not already done before install):
scp TAKSERVER-DOCKER-*.zip root@YOUR_SERVER:/opt/komms-data/tak-release/

# 2. Run setup:
sudo bash /opt/komms/server/setup_tak.sh

# 3. Generate TAK certificates for existing users:
sudo bash /opt/komms/server/add_user.sh <username> "Display Name"
# (detects existing VPN cert → only creates TAK cert + uploads to Nextcloud)
```

### What setup_tak.sh does

1. Extracts the ZIP and builds the TAKServer Docker image (~5 min)
2. Extracts WebTAK static files from the WAR to `$TAK_DIR/webcontent/`; patches `setenv.sh` with the static-locations property
3. Generates the CA, server certificate (`CN=tak.DOMAIN`), and admin client certificate
4. Initializes the TAKServer PostgreSQL database schema
5. Re-patches `CoreConfig.xml` after TAKServer rewrites it on first boot (LDAP `{username}`, `clientAuth=WANT`, pool size, DB URL)
6. Restarts the container and waits for port 8443 to open
7. Waits **60 seconds** for TAKServer's Apache Ignite grid to fully initialize
8. Runs `certmod` to grant `ROLE_ADMIN` to the admin certificate (retries up to 3×)

### Why does it take so long?

The wait after container start is **expected**. TAKServer uses Apache Ignite as its internal service mesh. Port 8443 opens quickly, but the Ignite grid takes several more minutes to become ready for certificate management commands. Do not interrupt the script.

If `certmod` fails despite the wait, run it manually:

```bash
docker exec komms_tak bash -c \
  'cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/admin.pem'
```

### Marti Dashboard (admin only)

The Marti Dashboard is accessible at `https://tak.DOMAIN/Marti/` — **no browser certificate required**.

nginx proxies all traffic on `tak.DOMAIN` (port 443) to TAKServer port 8443 and automatically presents the admin certificate (extracted from `admin.p12` during `setup_tak.sh`). Any user with `lldap_admin` group membership gets `ROLE_ADMIN` via the forwarded cert.

**Access:**

1. Connect VPN
2. Navigate to `https://tak.DOMAIN/` or `https://tak.DOMAIN/Marti/`
3. Log in via Authelia (lldap_admin group required)

> **Direct port 8443 access (troubleshooting / ATAK TCP):**  
> Port 8443 is exposed directly by Docker with `clientAuth=WANT`. If needed, import `ca.pem` and `admin-browser.p12` into Firefox for direct cert-auth access at `https://tak.DOMAIN:8443/Marti/`.  
> Download from server:
> ```bash
> scp root@YOUR_SERVER:/opt/komms-data/tak/certs/files/ca.pem            ~/Downloads/tak-ca.pem
> scp root@YOUR_SERVER:/opt/komms-data/tak/certs/files/admin-browser.p12 ~/Downloads/admin-browser.p12
> ```

---

## 13. Updates

See [Section 11 – Maintenance & Backups](#11-maintenance--backups) for full update instructions.

| Update type | Command |
|-------------|---------|
| Platform (code + Docker images) | `sudo bash /opt/komms/server/update.sh` |
| Nextcloud major version | `sudo bash /opt/komms/server/update_nextcloud.sh` |

---

*When in doubt: `docker compose logs -f <service>` is your best friend.*
