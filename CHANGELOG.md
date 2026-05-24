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

## [0.0.19] – 2026-05-24

### Fixed

- **UFW: Port `8443/tcp` is exposed again** (was closed in v0.0.9). ATAK clients have their own internal trust-store containing only the TAKServer-internal `KOMMSca` CA (via `user.p12` / `truststore-tak.p12`), so the nginx Let's Encrypt cert on `443` is rejected by ATAK during the TLS handshake (manifested as "socket is closed" client-side, with `0` HTTP requests visible in nginx logs). ATAK OTA must talk directly to TAKServer's KOMMSca-signed cert on port `8443`. The `/update/` Authelia bypass on nginx:443 stays in place for `curl`/browser verification, but ATAK itself must use `https://tak.DOMAIN:8443/update` for the Update Server setting.
- **Nextcloud MIME mapping for `.ovpn` + `.p12`** — Nextcloud was serving these files as `text/plain` (because no MIME mapping for `.ovpn` is registered by default and the dist mapping falls back to `text/plain`). Result: when an Android phone downloaded the `.ovpn` from Nextcloud, the OS appended `.txt` to the filename (`admin.ovpn.txt`), breaking the auto-import flow in the OpenVPN app. `setup_server.sh` now writes `/var/www/html/config/mimetypemapping.json` with explicit mappings: `.ovpn → application/x-openvpn-profile`, `.p12 → application/x-pkcs12`. Verified live: `Content-Type: application/x-openvpn-profile` is now sent on download.

### Documented

- **README: ATAK OTA URL clarified** — explicit warning to use `https://tak.DOMAIN:8443/update` (port 8443), not the nginx `:443` path, because of the trust-store mismatch above. The previously-documented nginx-proxied URL works for `curl`/browser tests but not for ATAK itself.

### Notes on fresh-install parity

After this release a fresh `install.sh` run produces a deployment that matches the current state on the live test server, end-to-end:
- nginx with `/update/` Authelia bypass (v0.0.15) **and** UFW 8443 open for ATAK direct (v0.0.19)
- `webcontent/update/` drop folder auto-created with operator README (v0.0.16)
- OpenVPN `duplicate-cn` + `mssfix 1400` + `tun-mtu 1500` for stable multi-device + mobile (v0.0.17)
- postgres healthcheck no longer floods FATAL log (v0.0.18)
- Nextcloud MIME types so `.ovpn` and `.p12` downloads keep their extensions on Android (v0.0.19)

---

## [0.0.18] – 2026-05-24

### Fixed

- **postgres healthcheck log spam** — `pg_isready -U ${DB_USER}` had no `-d` so it defaulted to a database named after the user (`komms`), which does not exist. Every healthcheck interval (10s) printed `FATAL: database "komms" does not exist` to the postgres log, adding ~360 noise lines per hour and obscuring real issues. Fixed by adding `-d postgres` (the always-present default DB). The healthcheck still confirms the server is accepting connections.

---

## [0.0.17] – 2026-05-24

### Fixed

- **ATAK CoT stream randomly disconnected with "Zeitüberschreitung beim Datenempfang"** when the same user certificate was connected from multiple devices (phone + laptop + tablet) simultaneously. OpenVPN default behaviour was to terminate the previous session whenever a new client with the same CN connected, causing endless reconnect loops. Fixed by enabling `duplicate-cn` in `openvpn.conf` so the same identity can hold multiple concurrent tunnels (each device gets its own VPN IP from the pool).
- **Sporadic VPN reconnects on mobile / WLAN clients** caused by oversized packets being fragmented by the carrier or AP. Added `mssfix 1400` (clamps TCP MSS for traffic through the tunnel) and `tun-mtu 1500` (explicit MTU so both sides agree, avoiding the IV_MTU=1600 announcement from some Android clients).

### Notes

ATAK identity is tied to the **TAK x509 client cert** (`<user>-tak.p12`), not the OpenVPN cert — so even with `duplicate-cn` enabled, if you want multiple ATAK devices to appear as distinct users on the situational awareness layer, each device still needs its own TAK cert from `add_user.sh`. The OpenVPN cert is purely transport.

### Upgrade

Live patch:
```bash
docker exec komms_openvpn bash -c '
  grep -q "^duplicate-cn" /etc/openvpn/openvpn.conf || echo "duplicate-cn"  >> /etc/openvpn/openvpn.conf
  grep -q "^mssfix"       /etc/openvpn/openvpn.conf || echo "mssfix 1400"   >> /etc/openvpn/openvpn.conf
  grep -q "^tun-mtu"      /etc/openvpn/openvpn.conf || echo "tun-mtu 1500"  >> /etc/openvpn/openvpn.conf
'
docker compose -f /opt/komms/server/docker-compose.yml restart openvpn
```

---

## [0.0.16] – 2026-05-24

### Added

- **`setup_tak.sh` auto-creates `webcontent/update/`** — fresh installs now have the OTA drop folder ready out of the box, with a `README.txt` inside that explains what to drop there and the matching ATAK update URL. No manual `mkdir` needed before the first `product.infz` upload. Pairs with the v0.0.15 nginx bypass to make ATAK OTA work end-to-end on a fresh install with zero manual steps on the TAKSERVER_MDM side.

### Documented

- Companion repo [takserver_ota](https://github.com/GUMMIIII/takserver_ota) v0.1.1 now ships a dedicated "Variante B / Option B" section in its EN_README / DEU_README that points operators of TAKSERVER_MDM at the `/opt/komms-data/tak/webcontent/update/` host path and the `https://tak.DOMAIN/update/` ATAK URL — so the cross-repo workflow is now documented from both sides.

---

## [0.0.15] – 2026-05-24

### Added

- **nginx bypass for `/update/`** — ATAK clients fetching OTA APK + plugin manifests have no Authelia cookie session, so the default `location /` Authelia gate redirected them to the login page (HTTP 302). Added a dedicated `location /update/` block on `tak.${DOMAIN}` that bypasses the gate, still presents the admin client cert to TAKServer:8443 (so `clientAuth=WANT` does not reject), and raises `client_max_body_size` to 500 MB so APK uploads don't truncate. The manifest + APKs are by design public artifacts; actual CoT access control still happens at the 8089 TLS input via per-user x509 certs.
- **README: OTA file drop path** — documented that generated `product.inf`/`product.infz`/APKs go to `/opt/komms-data/tak/webcontent/update/` on the host (bind-mount to `/opt/tak/webcontent/update/` in the container), reachable for ATAK at `https://tak.${DOMAIN}/update/product.infz`. Pairs with the [takserver_ota](https://github.com/GUMMIIII/takserver_ota) companion.

### Verified

Behavior empirically confirmed on a live deployment: before the fix, `curl https://tak.DOMAIN/update/...` returned `302` (Authelia redirect) while `docker exec komms_tak curl https://localhost:8443/update/...` returned `200`. After the fix, both paths return `200`.

---

## [0.0.14] – 2026-05-24

### Added

- **README badges** — license (AGPL v3), latest release, last commit, open issues, GitHub stars. Quick-glance project health at the top of the README.

### Notes

This release coincides with the repository going public. Repo hardening applied alongside:

- Secret Scanning + Push Protection enabled (blocks accidental token commits before they leave the developer machine)
- Dependabot alerts + automated security fixes enabled
- Issues + Discussions enabled, squash-merge as the only merge style, auto-delete of merged branches

No code changes — documentation + repo settings only.

---

## [0.0.13] – 2026-05-24

### Added

- **`SECURITY.md`** — private vulnerability reporting policy. Points reporters to the GitHub Security Advisory form rather than public issues; documents scope and out-of-scope items, expected response time, and credit.
- **Issue templates** under `.github/ISSUE_TEMPLATE/`:
  - Structured bug report form (affected component dropdown, repro steps, logs block, OS/architecture)
  - Feature request form (problem, proposal, scope estimate, contribution willingness)
  - Issue template config exposing quick-links to the Security Advisory form and to "test environment access" requests
- **README maintainer note: test-deployment offer** — read-only access to a running test environment available on request, so prospective operators can poke at the platform before installing.

### Notes

Documentation + repo hygiene only — no functional changes.

---

## [0.0.12] – 2026-05-24

### Changed

- **README: added "A note from the maintainer" section** — sets expectations: solo-maintained hobby project, bugs likely, feedback/issues welcome, response within a few days (longer for bigger changes).
- **README: added Companion section for [GUMMIIII/takserver_ota](https://github.com/GUMMIIII/takserver_ota)** — self-hosted OTA APK + plugin update channel for ATAK that plugs into the TAKServer set up here. Useful for keeping field-device fleets in sync without manual updates.
- **CHANGELOG: anonymized live deployment reference** in the v0.0.10 entry (removed the operator's real domain).

### Notes

No functional changes — documentation only. Skipping straight from v0.0.10 → v0.0.12 to keep the README maintainer-note (released as v0.0.11) on its own version line.

---

## [0.0.11] – 2026-05-24

### Changed

- **README: maintainer note** — see v0.0.12 entry above for the consolidated description.

---

## [0.0.10] – 2026-05-24

### Fixed

- **Collabora editor opened empty (no toolbar / no editing)** — `richdocuments` created the `.docx` but the Collabora iframe could not load template presets or userconfig settings. Root cause: Collabora's server-side preset fetch calls `https://cloud.DOMAIN/apps/richdocuments/settings/userconfig/...` (without the `/index.php/` prefix), which fell into nginx's default `location /` block and hit the Authelia gate → HTTP 302 → all 12 template fetches failed → `DocumentBroker: Failed to load all settings`, Kit process killed. Existing bypass only matched `/index.php/apps/richdocuments/wopi/`. Widened the regex to `^/(index\.php/)?apps/richdocuments/` so both URL forms bypass Authelia (Nextcloud still validates the access token internally). Verified on a live deployment.

---

## [0.0.9] – 2026-05-24

### Removed

- **LAN / Homelab deployment mode** — entire mode was incomplete (`setup_server.sh` never generated an `nginx.conf` for the LAN data dir → nginx container would not start on first install) and untested in production. `install.sh` no longer prompts for a mode; the only supported deployment is VPS / public domain with Let's Encrypt subdomains. All `DEPLOY_MODE` branches removed from `install.sh` and `setup_server.sh`.
- **`server/nginx/nginx.conf`** — orphaned LAN-mode template with `YOUR_DOMAIN` placeholders. Not mounted by `docker-compose.yml` (mount path is `${DATA_DIR}/config/nginx/nginx.conf`) and not generated by any current script. Deleted.
- **`update.sh` `--profile tak` flag** — no-op because `docker-compose.yml` does not declare any profiles. Removed to avoid implying a feature that does not exist.

### Fixed

- **Stale TAK_IMAGE default `takserver/takserver:5.3-RELEASE-35`** — the entire setup is built for TAKServer 5.7 (CoreConfig.xml template, Python post-patch in `setup_tak.sh`). `install.sh` wrote 5.3 into `.env` on fresh installs; first `docker compose up takserver` would fail before `setup_tak.sh` overwrote the value. Cleared `TAK_IMAGE=` on fresh installs and changed the `docker-compose.yml` default to `no-tak-image-loaded` (intentional fail-fast sentinel).
- **`install.sh` health-check + final login table pointed at `https://${DOMAIN}:8443`** — TAKServer no longer requires direct port 8443 access since v0.0.7 (nginx proxies all TAK paths through `tak.${DOMAIN}:443` with the admin cert). Updated to `https://tak.${DOMAIN}` for both health-check and the printed access table.
- **`install.sh` Mumble health-check used base `${DOMAIN}:64738`** — Mumble is now reachable via `mumble.${DOMAIN}:64738` (nginx stream proxy, v0.0.7). Health-check updated.
- **`setup_tak.sh` final banner** — instructed users to download `ca.pem` + `admin-browser.p12` and import them into Firefox; this hasn't been required since v0.0.7. Replaced with concise access table that reflects the nginx-mTLS-proxy setup.
- **`setup_server.sh` UFW exposed `8443/tcp` externally** — unnecessary since v0.0.7 nginx proxy. Removed from VPS firewall rules to reduce attack surface.
- **`add_user.sh` step numbering inconsistent** — first three steps printed `[1/5]`–`[3/5]`, later three printed `[4/6]`–`[6/6]`. Unified to `[1/6]`–`[6/6]`.
- **`.env.example` missing variables** — `LETSENCRYPT_EMAIL`, `MUMBLE_SERVER_PASS`, `TAK_DOMAIN`, `DATA_DIR` were written by `install.sh` but not declared in the template, causing `update.sh` to print misleading "new variables" warnings.

### Changed

- **`install.sh` banner** — bumped from "Installer v1.0" to drop the misleading version number; renamed `KOMMS` to `TAKSERVER_MDM` to match the repo name.
- **`install.sh` curl example URLs** — replaced `YOUR_GITHUB_USERNAME` placeholder with `GUMMIIII`.
- **README.md firewall list** — explicit, accurate port list (was missing `8444`, had stale `8443`).

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
