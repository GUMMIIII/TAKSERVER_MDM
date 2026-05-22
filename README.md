# KOMMS – Self-Hosted Communications & MDM Platform

A fully self-hosted, secure communications platform with mobile device management for Android and Windows.  
One installation gives your team encrypted chat, voice, file sharing, VPN, TAK situational awareness, and MDM — all behind a single SSO.

> **Operator guide (step-by-step):** [WORKFLOW.md](WORKFLOW.md)  
> **Deutsche Dokumentation:** [WORKFLOW.de.md](WORKFLOW.de.md)

---

## What's Included

| Service | Role | VPN required |
|---------|------|:---:|
| [Authelia](https://www.authelia.com) | SSO portal — log in once for all services | No |
| [LLDAP](https://github.com/lldap/lldap) | Lightweight LDAP — single user directory | — |
| [Nextcloud](https://nextcloud.com) | File sharing, onboarding, CalDAV/CardDAV | No |
| [Collabora Online](https://www.collaboraoffice.com) | In-browser document editing (Nextcloud integration) | No |
| [Matrix / Synapse](https://matrix.org) | Encrypted team messaging | **Yes** |
| [Element Web](https://element.io) | Matrix web client | **Yes** |
| [OpenVPN](https://openvpn.net) | VPN — required for all internal services | — |
| [Headwind MDM](https://h-mdm.com) | Android MDM — app + config management | **Yes** |
| [TAKServer](https://tak.gov) | Situational awareness (ATAK / WinTAK) | **Yes** |
| [Mumble](https://www.mumble.info) | Low-latency encrypted voice | **Yes** |
| nginx | Reverse proxy — TLS termination, Authelia gate, VPN enforcement | — |
| PostgreSQL | Shared database for Headwind, Synapse, Authelia, Nextcloud | — |

**Scale:** Designed for small teams (< 50 devices).  
**ARM64 / Raspberry Pi:** TAKServer is x86-only and is automatically skipped on ARM; all other services run on RPi 4/5 (64-bit OS).

---

## Architecture

```
Internet
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│  nginx :443                                                  │
│                                                              │
│  auth.domain       → Authelia SSO portal  [no VPN]          │
│  cloud.domain      → Nextcloud            [no VPN, Authelia] │
│  collabora.domain  → Collabora Online     [no VPN, WOPI]     │
│  element.domain    → Element Web          [VPN + Authelia]   │
│  matrix.domain     → Matrix / Synapse     [VPN only]         │
│  mdm.domain        → Headwind MDM         [VPN + Authelia*]  │
│  ldap.domain       → LLDAP Web UI         [VPN + Authelia*]  │
│  tak.domain        → TAKServer WebTAK     [VPN + Authelia*]  │
│                                                              │
│  OpenVPN :1194/UDP    Mumble :64738    TAKServer :8089/8443  │
└──────────────────────────────────────────────────────────────┘
         ▲                           ▲
         │ HTTPS (no VPN needed)     │ HTTPS (VPN tunnel 10.8.0.0/24)
    ─────┴────                 ──────┴──────
   Nextcloud / Authelia       All other services
```

`* lldap_admin group membership required`

VPN enforcement is handled by nginx (`geo $vpn_ip`) — VPN-required services return **403** for non-VPN IPs regardless of Authelia session state.

---

## Quick Start

### Prerequisites

1. Fresh **Ubuntu 22.04/24.04**, **Debian 12**, or **Raspberry Pi OS 64-bit**
2. Root SSH access — minimum **4 GB RAM** (8 GB if using TAKServer)
3. DNS A-records pointing to your server (`*.domain.com` + `domain.com`) — VPS only
4. Optional: TAKServer Docker ZIP from [tak.gov](https://tak.gov/products/tak-server)

### One-command install

```bash
# Public repository:
curl -fsSL https://raw.githubusercontent.com/GUMMIIII/TAKSERVER_MDM/main/install.sh | bash

# Private repository (GitHub PAT required):
curl -H "Authorization: token $GITHUB_PAT" \
     -fsSL https://raw.githubusercontent.com/GUMMIIII/TAKSERVER_MDM/main/install.sh \
  | GITHUB_PAT=$GITHUB_PAT bash
```

The installer prompts for all settings interactively, then runs fully automatically (~15–25 min).  
At the end it prints an SCP command to download your operator `.ovpn`.

For a full walkthrough see **[WORKFLOW.md](WORKFLOW.md)**.

### TAKServer (optional)

TAKServer requires a free registration at [tak.gov](https://tak.gov).

> **Note:** TAKServer setup via `install.sh` is not yet fully automated. The installer detects the ZIP and reports it, but `setup_tak.sh` must be run **manually after the main install completes**. See [roadmap](#unreleased) for details.

```bash
# 1. Place the ZIP on the server before or after install.sh:
scp TAKSERVER-DOCKER-*.zip root@your.server:/opt/komms-data/tak-release/

# 2. After install.sh finishes, run setup manually:
sudo bash /opt/komms/server/setup_tak.sh
```

`setup_tak.sh` takes **5–10 minutes** — most of this is waiting for TAKServer's internal grid to initialize before the admin certificate can be registered. This is expected; do not interrupt the script.

---

## User Management

```bash
# Add a regular user (Nextcloud + Element + VPN + TAK cert)
sudo bash /opt/komms/server/add_user.sh <username> "Display Name"

# Add an admin/operator user (+ MDM, LLDAP, TAKServer WebTAK access)
sudo bash /opt/komms/server/add_user.sh --admin <username> "Display Name"

# Remove a user from all systems
sudo bash /opt/komms/server/delete_user.sh <username>
```

Each `add_user.sh` run creates:

```
/opt/komms-data/users/<username>/
├── <username>.ovpn         ← OpenVPN profile
├── <username>-tak.p12      ← TAK client certificate
├── <username>-tak.zip      ← TAK data package (recommended)
├── qr-credentials.png      ← QR code with LLDAP login credentials
└── credentials.txt         ← Plain-text summary (delete after handover!)
```

Files are automatically uploaded to Nextcloud (`KOMMS-Users/<username>/`) and shared with the user.

### Onboarding in 4 steps

1. User opens `https://cloud.domain.com` — no VPN needed
2. Logs in via Authelia SSO with the LLDAP credentials from `qr-credentials.png` (Nextcloud redirects automatically — no password form on Nextcloud itself)
3. Downloads `.ovpn` → imports into OpenVPN app → connects
4. All other services are now accessible

---

## Updates

### Platform update (code + Docker images)

```bash
sudo bash /opt/komms/server/update.sh            # latest release tag (recommended)
sudo bash /opt/komms/server/update.sh main       # current main branch
sudo bash /opt/komms/server/update.sh v0.0.5     # specific tag
```

- Backs up `/opt/komms-data/.env` before touching anything
- Never modifies data in `/opt/komms-data/`
- Warns if new `.env` variables are missing from your config
- Stops stack → updates code → pulls images → restarts

### Nextcloud major version upgrade

Nextcloud only supports single-step major upgrades. Run once per major version:

```bash
sudo bash /opt/komms/server/update_nextcloud.sh        # auto: current + 1
sudo bash /opt/komms/server/update_nextcloud.sh 34     # explicit target
```

Then commit the updated image tag to keep the repo in sync:

```bash
git add server/docker-compose.yml
git commit -m "chore: update Nextcloud 33 to 34"
git push
```

---

## File Structure

```
TAKSERVER_MDM/
├── install.sh                        ← One-shot installer (entry point)
│
├── server/
│   ├── docker-compose.yml            ← All services
│   ├── .env.example                  ← Configuration template
│   ├── setup_server.sh               ← Server configuration (called by install.sh)
│   ├── setup_tak.sh                  ← TAKServer setup (optional)
│   ├── add_user.sh                   ← User provisioning
│   ├── delete_user.sh                ← User removal
│   ├── update.sh                     ← Platform update
│   ├── update_nextcloud.sh           ← Nextcloud major version upgrade
│   ├── migrate-data-dir.sh           ← Migration helper for existing installs
│   ├── authelia/
│   │   └── configuration.yml.template← Authelia SSO + access_control rules
│   ├── nginx/
│   │   └── nginx.conf.vps.template   ← Reverse proxy config template (envsubst)
│   ├── matrix/
│   │   └── homeserver.yaml           ← Synapse configuration
│   ├── mumble/
│   │   └── murmur.ini                ← Mumble configuration
│   └── takserver/
│       └── CoreConfig.xml            ← TAKServer configuration template
│
├── android/
│   ├── provisioner.sh                ← MDM post-enrollment provisioner
│   └── debloat.sh                    ← Android debloat script
│
├── windows/
│   └── setup.ps1                     ← Windows device provisioner
│
├── README.md                         ← This file (English)
├── WORKFLOW.md                       ← Full operator guide (English)
└── WORKFLOW.de.md                    ← Vollständige Betriebsanleitung (Deutsch)
```

### Data separation

| Path | Purpose | Touched by git? |
|------|---------|:---:|
| `/opt/komms/` | Code, scripts, Docker Compose | Yes — `git pull` updates this |
| `/opt/komms-data/` | Live configs, secrets, certificates, user files | **Never** |

`git pull` can never overwrite your `.env`, certificates, or user credentials.

---

## Security Notes

- Change **all** passwords in `.env` before going live — see `.env.example` for all variables
- TAKServer cert passphrase (`TAK_CERT_PASS`) defaults to `atakatak` — change it
- Matrix federation is disabled by default (closed deployment)
- Let's Encrypt renewal runs automatically via Certbot cron job (VPS only)
- Firewall: allow only ports `80`, `443`, `1194/UDP`, `8089`, `8443`, `64738`
- VPN enforcement cannot be bypassed via Authelia — it is enforced at the nginx IP layer
- All secrets and configs live in `/opt/komms-data/` which is outside the git repository

---

## License

[AGPL-3.0](LICENSE)
