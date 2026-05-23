# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Planned
- **TAKServer auto-install via `install.sh`** — currently `setup_tak.sh` must be run manually after the main install (see note below). Root cause: TAKServer's Apache Ignite grid takes 3–5 min to initialize after container start; blocking the main installer for that long is impractical. Planned fix: deferred async cert setup or a reliable readiness probe.
- **Jitsi Meet** — self-hosted video conferencing (jitsi-web, prosody, jicofo, jvb containers) behind nginx + Authelia
- **Modular installer** — service selection via `whiptail` at install time; Docker Compose profiles so unused services are never started
- **ARM64 TAKServer build** — auto-detection of architecture in `setup_tak.sh`; Dockerfile for building TAKServer on ARM64 (Raspberry Pi 4/5, cloud ARM instances)

---

## [0.0.8] – 2026-05-23

### Fixed

- **Mumble unreachable via domain for VPN clients** — `dnsmasq/entrypoint.sh` was missing DNAT rules for port 64738 (TCP + UDP). VPN clients resolve `mumble.DOMAIN` via dnsmasq to the VPN gateway, but without a DNAT rule the traffic never reached the nginx stream proxy. Direct IP access worked because it bypassed the VPN tunnel entirely. Fixed by adding `add_dnat tcp/udp 64738 → nginx:64738` to the dnsmasq entrypoint.
- **nginx fails to start on fresh install before `setup_tak.sh` runs** — `nginx.conf` references `proxy_ssl_certificate /etc/nginx/certs/tak-admin.crt`, which only exists after `setup_tak.sh` extracts it from `admin.p12`. On a fresh install nginx would refuse to start. Fixed by having `setup_server.sh` write placeholder `tak-admin.{crt,key}` (copy of the main TLS cert) so nginx can start immediately. `setup_tak.sh` overwrites them with the real admin cert and reloads nginx.

---

## [0.0.7] – 2026-05-23

### Added

- **Mumble TCP/UDP stream proxy via nginx** — Port 64738 (TCP + UDP) moved from the mumble container to the nginx container. nginx proxies Mumble at the stream layer, making the server reachable via domain name (`mumble.DOMAIN:64738`) and externally by IP. Previously Mumble was only reachable at `IP:64738` because the port was not routed through nginx.
- **QR code uploaded to Nextcloud** — `add_user.sh` now uploads `qr-credentials.png` to `KOMMS-Users/<username>/` in Nextcloud alongside `.ovpn`, `credentials.txt`, and TAK files. The operator can distribute the onboarding QR directly from the Nextcloud share without accessing the server filesystem.

### Changed

- **TAKServer nginx proxy — transparent mTLS** — nginx now proxies all paths on `tak.DOMAIN` to TAKServer port `8443` and automatically presents the admin certificate (`tak-admin.crt/key`, extracted from `admin.p12` by `setup_tak.sh`). Both WebTAK and the Marti Dashboard are accessible at `https://tak.DOMAIN/` without any browser certificate installation. `setup_tak.sh` extracts `tak-admin.{crt,key}` to the nginx certs directory automatically using `openssl pkcs12 -legacy` (required for Java 8/11 RC2-40-CBC PKCS12 files on OpenSSL 3.x).
- **Marti Dashboard access simplified** — The one-time browser certificate import step (previously: download `ca.pem` + `admin-browser.p12`, import into Firefox, then connect directly to port 8443) is no longer required. The dashboard is accessible at `https://tak.DOMAIN/Marti/` — the Authelia gate (lldap_admin group) protects access; nginx handles the admin certificate transparently.

---

## [0.0.6] – 2026-05-23

### Fixed

- **TAKServer WebTAK static files** — `setup_tak.sh` now extracts WAR-root content (`webtak/`, `Marti/`, `index.html`) to `$TAK_DIR/webcontent/` and patches `setenv.sh` with `-Dspring.web.resources.static-locations`. Spring Boot PropertiesLauncher does not add WAR-root to the classpath, so without this fix WebTAK returns HTTP 200 with Content-Length 0.
- **HikariPool size = 1** — Python post-patch now explicitly sets `connectionPoolAutoSize="false" numDbConnections="16"` on `<repository>`. When `enable="false"`, `DataSourceUtils` skips the `SHOW max_connections` query, `maxConnections` stays 0, and the auto-size formula computes pool = 1 — causing all DB calls (`isAdmin()`, etc.) to time out after 250 ms.
- **LDAP userstring placeholder** — Python post-patch now writes `uid={username},...` (TAKServer 5.7 format). Previously `uid=%s,...` caused TAKServer to authenticate the literal string `%s` against LLDAP → error 49 invalid credentials.
- **Server certificate hostname** — `setup_tak.sh` now generates the server certificate with `CN=tak.${DOMAIN}` and `SAN=tak.${DOMAIN}` instead of `CN=takserver`. The internal hostname `takserver` is not valid for the public domain; browsers blocked access to port 8443 with `SSL_ERROR_BAD_CERT_DOMAIN` and HSTS preventing exceptions.
- **nginx proxy target** — nginx now proxies `tak.DOMAIN` → TAKServer port `8446` (was `8443`). Port 8446 has `ROLE_NO_CLIENT_CERT` in `portRoleMap`, making `/login` and `/oauth/token` accessible without a client certificate. Port 8443 is reserved for certificate-based Marti Dashboard access (`clientAuth="WANT"`).

### Changed

- **Port 8443 `clientAuth`** — Changed from `NONE` to `WANT` in `CoreConfig.xml` template and Python post-patch. `WANT` lets the server request an optional client certificate: normal users log in via LDAP without a cert; the admin cert (`admin.p12`) grants `ROLE_ADMIN` via `UserAuthenticationFile.xml` fingerprint matching — which is required to access the Marti Dashboard.

### Added

- **Marti Dashboard access** — Full operator instructions for one-time browser setup: download `ca.pem` + `admin-browser.p12`, import both into Firefox, then navigate to `https://tak.DOMAIN:8443/Marti/metrics/index.html`.

---

## [0.0.5] – 2026-05-22

### Fixed
- `setup_tak.sh`: removed `keytool` re-encoding step that produced PBES2/AES-256-CBC PKCS12; replaced with OpenSSL `-legacy` conversion to create `admin-browser.p12` (SHA1/RC2) — compatible with all browsers

---

## [0.0.4] – 2026-05-22

### Changed
- `install.sh` no longer calls `setup_tak.sh` automatically — TAKServer ZIP is detected and reported, but setup must be run manually after the main install completes. This prevents the installer from blocking for 5+ minutes waiting on TAKServer's Ignite grid initialization.

### Fixed
- Nextcloud `trusted_domains` now explicitly set to `cloud.DOMAIN` during setup (was only `localhost`, causing "Untrusted domain" error on first login)

---

## [0.0.3] – 2026-05-22

### Added
- **TAKServer auto-detection** — installer scans `$DATA_DIR/tak-release/*.zip` at startup; no prompt needed. Place the ZIP there before running `install.sh` and TAKServer is set up fully automatically.

### Fixed
- TAK cert subject: added missing `ST=` prefix for state/province (was producing invalid subjects like `/C=DE/Bayern/L=...` instead of `/C=DE/ST=Bayern/L=...`)
- `setup_tak.sh` certmod: waits 60 s after port 8443 opens for Apache Ignite grid to finish initializing, then retries up to 3× — eliminates the manual `certmod` step on fresh installs

### Changed
- Nextcloud: `allow_multiple_user_backends=0` — local password login form is hidden; all authentication enforced through Authelia SSO

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
