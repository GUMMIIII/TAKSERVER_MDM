# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [0.1.0] – 2026-05-22

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
