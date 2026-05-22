# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Planned
- **SSO-only login for Element + Nextcloud** — disable password login, enforce Authelia SSO as the only auth path
- **Jitsi Meet** — self-hosted video conferencing (jitsi-web, prosody, jicofo, jvb containers) behind nginx + Authelia
- **Modular installer** — service selection via `whiptail` at install time; Docker Compose profiles so unused services are never started
- **ARM64 TAKServer build** — auto-detection of architecture in `setup_tak.sh`; Dockerfile for building TAKServer on ARM64 (Raspberry Pi 4/5, cloud ARM instances)

---

## [0.0.1] – 2026-05-22

### Added
- **Collabora Online (CODE)** — integrated document editing inside Nextcloud; `collabora/code:latest` container, nginx reverse proxy with WebSocket support, richdocuments auto-configured via `occ`
- **`update_nextcloud.sh`** — single-step Nextcloud major version upgrade script; reads version from running container, updates image tag, pulls, restarts, runs `occ upgrade` + DB tasks
- **English documentation** — `README.md` rewritten as primary English reference; `WORKFLOW.md` full English operator guide; German guide retained as `WORKFLOW.de.md`
- **Nextcloud 33** — upgraded from 30 through 31, 32, to 33 (current latest)

### Fixed
- nginx: suppress Nextcloud's own `X-Frame-Options: DENY` via `proxy_hide_header`; global `SAMEORIGIN` from http block now applies cleanly
- nginx: added missing `X-Robots-Tag` and `X-Permitted-Cross-Domain-Policies` security headers
- WOPI: Collabora callback path (`/index.php/apps/richdocuments/wopi/`) bypasses Authelia gate so document editing works without VPN
- `update_nextcloud.sh`: `occ upgrade` now manages its own maintenance mode; removed pre-enabling that caused "upgrade already in process" error; added 30s post-upgrade stabilization wait

### Security
- `.gitignore`: TAKServer ZIP files (`*.zip`) explicitly excluded to prevent accidental commit

---

## [0.0.0] – 2026-05-22

### Added
- Initial public release of TAKSERVER_MDM (formerly KOMMS)
- Full self-hosted communications stack: TAKServer, OpenVPN, Headwind MDM, LLDAP, Authelia SSO, Nextcloud, Matrix/Synapse, Element Web, Mumble, nginx reverse proxy, PostgreSQL
- `install.sh` – single-command installer (VPS + LAN modes)
- `server/setup_server.sh` – non-interactive server configuration (TLS, OpenVPN PKI, service configs)
- `server/setup_tak.sh` – TAKServer image loading, CoreConfig generation, cert setup
- `server/add_user.sh` – user provisioning (LLDAP + OpenVPN cert + TAK cert + Nextcloud upload + QR)
- `server/delete_user.sh` – full user removal across all services
- `server/migrate-data-dir.sh` – migration script for existing installations
- Data separation architecture: code in `/opt/komms/`, persistent data in `/opt/komms-data/`
- AGPL-3.0 license

### Security
- All generated configs, secrets, and user files stored outside the git repository (`/opt/komms-data/`)
- `git pull` can never overwrite live configs or credentials
- Real domain and install token removed from repository history
