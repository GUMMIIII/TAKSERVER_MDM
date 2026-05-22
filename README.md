# TAKSERVER_MDM – Communications & MDM Platform

Self-hosted secure communications platform with mobile device management for Android and Windows.

**Services:** Authelia SSO · LLDAP · Nextcloud · Matrix/Synapse · Element · Headwind MDM · OpenVPN · TAKServer · Mumble  
**Access model:** One login (LLDAP) → all services via Authelia SSO · VPN required for most services  
**Scale:** Designed for small teams (< 50 devices)

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  Nginx (443)                                                │
│                                                             │
│  auth.domain     → Authelia SSO portal (login once)        │
│  cloud.domain    → Nextcloud           [Authelia, no VPN]  │
│  element.domain  → Element Web         [VPN + Authelia]    │
│  matrix.domain   → Matrix/Synapse      [VPN only]          │
│  mdm.domain      → Headwind MDM        [VPN + Authelia*]   │
│  ldap.domain     → LLDAP Web UI        [VPN + Authelia*]   │
│  tak.domain      → TAKServer WebTAK    [VPN + Authelia*]   │
│                                                             │
│  OpenVPN :1194/UDP   Mumble :64738   TAKServer :8089/8443  │
└─────────────────────────────────────────────────────────────┘
         ▲                         ▲
         │ HTTPS (no VPN)          │ VPN tunnel (10.8.0.0/24)
    ─────┴────               ──────┴──────
   Nextcloud login         All other services
```

`* lldap_admin group required`

> **ARM64 / Raspberry Pi:** TAKServer is x86-only and is automatically skipped.  
> All other services run on RPi 4/5 (64-bit OS).

---

## Installation

### Prerequisites

1. Fresh **Ubuntu 22.04/24.04**, **Debian 12**, or **Raspberry Pi OS (64-bit)**
2. Root SSH access
3. DNS A-records pointing to your server (`*.domain.com` + `domain.com`)
4. Optional: TAKServer Docker zip from [tak.gov](https://tak.gov/products/tak-server)

### One-command install

```bash
# Public repo:
curl -fsSL https://raw.githubusercontent.com/GUMMIIII/TAKSERVER_MDM/main/install.sh | bash

# Private repo (GitHub PAT required):
curl -H "Authorization: token $GITHUB_PAT" \
     -fsSL https://raw.githubusercontent.com/GUMMIIII/TAKSERVER_MDM/main/install.sh \
  | GITHUB_PAT=$GITHUB_PAT bash
```

The installer prompts for all settings interactively, then:
- Configures UFW firewall
- Generates TLS certificates (Let's Encrypt on VPS, self-signed on LAN)
- Starts all Docker services
- Sets up LDAP integration for Nextcloud and Matrix
- Creates your operator account (`.ovpn` + TAK cert + Nextcloud upload)

At the end it prints the SCP command to download your operator `.ovpn`.

### TAKServer (optional)

TAKServer's Docker image requires a free account at [tak.gov](https://tak.gov):

1. Download **TAKSERVER-DOCKER-\*.zip**
2. Place it on the server before running the installer:
   ```bash
   scp TAKSERVER-DOCKER-*.zip root@your.server:/opt/komms-data/tak-release/
   ```
3. Answer `y` when the installer asks

To add TAKServer after initial install:
```bash
sudo bash /opt/komms/server/setup_tak.sh
```

---

## Service URLs

| Service | URL | VPN required | Auth |
|---------|-----|:---:|------|
| Authelia portal | `https://auth.domain.com` | No | — |
| Nextcloud | `https://cloud.domain.com` | No | Authelia (any user) |
| Element Web | `https://element.domain.com` | **Yes** | Authelia (any user) |
| Matrix | `https://matrix.domain.com` | **Yes** | Synapse native |
| Headwind MDM | `https://mdm.domain.com` | **Yes** | Authelia (lldap_admin) |
| LLDAP Web UI | `https://ldap.domain.com` | **Yes** | Authelia (lldap_admin) |
| TAKServer WebTAK | `https://tak.domain.com` | **Yes** | Authelia (lldap_admin) |
| TAKServer clients | `tak.domain.com:8089` TLS | **Yes** | x509 certificate |
| Mumble | `domain.com:64738` | **Yes** | Server join password |
| OpenVPN | `domain.com:1194` UDP | — | x509 + LDAP |

---

## User Management

### Add a regular user

```bash
sudo bash /opt/komms/server/add_user.sh <username> "Display Name"
# Example:
sudo bash /opt/komms/server/add_user.sh soldier01 "Max Mustermann"
```

### Add an admin/operator user

```bash
sudo bash /opt/komms/server/add_user.sh --admin <username> "Display Name"
```

`--admin` additionally adds the user to the `lldap_admin` group, granting access to MDM, LLDAP Web UI, and TAKServer WebTAK.

### What `add_user.sh` creates

```
/opt/komms-data/users/<username>/
├── <username>.ovpn         ← OpenVPN profile (import in OpenVPN app)
├── <username>-tak.p12      ← TAK client cert (import in ATAK/WinTAK)
├── <username>-tak.zip      ← TAK data package (auto-connect, recommended)
├── qr-credentials.png      ← QR with login credentials for Nextcloud
├── qr-info.png             ← QR with all connection details
└── credentials.txt         ← Plain-text summary (delete after distributing!)
```

Files are automatically uploaded to `cloud.domain.com → KOMMS-Users/<username>/` and shared with the user.

### Onboarding flow

1. User opens `https://cloud.domain.com` (no VPN needed)
2. Logs in with credentials from `qr-credentials.png`
3. Downloads `.ovpn` from the shared folder
4. Imports `.ovpn` in OpenVPN app → connects VPN
5. All other services become accessible

### Delete a user

```bash
sudo bash /opt/komms/server/delete_user.sh <username>
```

Removes the account from: LLDAP → Nextcloud → OpenVPN (cert revoked) → TAKServer → local files.

---

## Updates

```bash
sudo bash /opt/komms/server/update.sh            # latest release tag (recommended)
sudo bash /opt/komms/server/update.sh main       # current main branch
sudo bash /opt/komms/server/update.sh v0.2.0     # specific tag
```

The update script:
- Backs up `/opt/komms-data/.env` before touching anything
- Never modifies data in `/opt/komms-data/`
- Detects new `.env` variables and warns if your config is missing them
- Shows migration notes (if any) and asks for confirmation before proceeding
- Stops the stack, updates the code, pulls new images, restarts

---

## File Structure

```
TAKSERVER_MDM/
├── install.sh                     ← One-shot installer (entry point)
│
├── server/
│   ├── setup_server.sh            ← Server setup (called by install.sh)
│   ├── setup_tak.sh               ← TAKServer setup (optional)
│   ├── add_user.sh                ← Add user (SSO + VPN + TAK + Nextcloud + QR)
│   ├── delete_user.sh             ← Remove user from all systems
│   ├── docker-compose.yml         ← All services
│   ├── .env.example               ← Config template
│   ├── authelia/
│   │   └── configuration.yml      ← Authelia SSO + access_control rules
│   ├── nginx/
│   │   └── nginx.conf.vps.template← Reverse proxy template (envsubst)
│   ├── matrix/homeserver.yaml     ← Synapse config
│   ├── mumble/murmur.ini          ← Mumble config
│   └── takserver/CoreConfig.xml   ← TAKServer config
│
├── android/
│   ├── provisioner.sh             ← MDM post-enrollment script
│   └── debloat.sh                 ← Android debloat
│
└── windows/
    └── setup.ps1                  ← Windows device provisioner
```

---

## Security Notes

- Change **all** passwords in `.env` before going live
- VPN enforcement is handled by nginx (`geo $vpn_ip` module) — services listed as "VPN required" return 403 for non-VPN IPs even after Authelia login
- Authelia access_control requires `lldap_admin` group membership for admin services
- Matrix federation is disabled by default (closed deployment)
- TAKServer cert passphrase (`TAK_CERT_PASS` in `.env`) should be changed from the default `atakatak`
- Let's Encrypt renewal runs automatically via Certbot cronjob (VPS only)
- Restrict firewall to ports: 80, 443, 1194/UDP, 8089, 8443, 64738
