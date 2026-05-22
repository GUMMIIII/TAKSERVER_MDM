# KOMMS – Workflow: Von der Installation bis zur Nutzung

> **Zielgruppe:** Administratoren, die KOMMS auf einem frischen Server aufsetzen.

---

## Inhaltsverzeichnis

1. [Voraussetzungen](#1-voraussetzungen)
2. [DNS einrichten (nur VPS)](#2-dns-einrichten-nur-vps)
3. [Installation](#3-installation)
4. [Erster Login – Übersicht](#4-erster-login--übersicht)
5. [Nutzer anlegen](#5-nutzer-anlegen)
6. [Nutzer löschen](#6-nutzer-löschen)
7. [Geräteübergabe an den Nutzer](#7-geräteübergabe-an-den-nutzer)
8. [Android-Gerät einrichten (Nutzer-Seite)](#8-android-gerät-einrichten-nutzer-seite)
9. [Windows-Client einrichten (Nutzer-Seite)](#9-windows-client-einrichten-nutzer-seite)
10. [Laufender Betrieb](#10-laufender-betrieb)
11. [Wartung & Backups](#11-wartung--backups)
12. [TAKServer nachrüsten](#12-takserver-nachrüsten)

---

## 1. Voraussetzungen

### Server

| Anforderung | VPS / Cloud | LAN / Homelab |
|-------------|-------------|---------------|
| Betriebssystem | Ubuntu 22.04 / 24.04 oder Debian 12 (64-bit) | gleich |
| Architektur | x86_64 | x86_64 oder ARM64 (RPi, ohne TAKServer) |
| RAM | min. 4 GB (8 GB empfohlen) | min. 2 GB |
| Speicher | min. 40 GB | min. 20 GB |
| Root-Zugang | erforderlich | gleich |
| Offene Ports | 80, 443, 1194/udp, 8089, 8443, 64738 | gleich |

### Admin-Maschine

- SSH-Zugang zum Server
- GitHub-Account mit Zugriff auf das TAKSERVER_MDM-Repository

---

## 2. DNS einrichten (nur VPS)

**Vor der Installation** müssen folgende DNS-A-Records auf die VPS-IP zeigen.  
Ein Wildcard-Record `*.domain.de` + `domain.de` reicht aus.

| Record | Ziel |
|--------|------|
| `domain.de` | VPS-IP |
| `auth.domain.de` | VPS-IP |
| `cloud.domain.de` | VPS-IP |
| `element.domain.de` | VPS-IP |
| `matrix.domain.de` | VPS-IP |
| `mdm.domain.de` | VPS-IP |
| `ldap.domain.de` | VPS-IP |
| `tak.domain.de` | VPS-IP |
| `office.domain.de` | VPS-IP |

DNS-Propagation abwarten (kann 5–60 Min dauern):

```bash
dig +short auth.domain.de      # muss die VPS-IP zurückgeben
```

---

## 3. Installation

### 3.1 Repository vorbereiten

In `install.sh` bei Bedarf anpassen:

```bash
REPO_OWNER="dein-github-username"     # Zeile ~21
```

### 3.2 Installer ausführen (auf dem Server als root)

```bash
# Öffentliches Repository:
curl -fsSL https://raw.githubusercontent.com/DEIN_USERNAME/TAKSERVER_MDM/main/install.sh | bash

# Privates Repository (GitHub PAT erforderlich):
curl -H "Authorization: token DEIN_GITHUB_PAT" \
     -fsSL https://raw.githubusercontent.com/DEIN_USERNAME/TAKSERVER_MDM/main/install.sh \
  | GITHUB_PAT=DEIN_GITHUB_PAT bash
```

### 3.3 Installationsablauf

Der Installer fragt interaktiv alle Einstellungen ab:
- Domain, Passwörter (DB, Nextcloud-Admin, MDM-Admin, LDAP-Admin)
- Mumble SuperUser-Passwort + Join-Passwort (für Verbindung zum Voice-Server)
- VPN-Hostname/Port, Zertifikatsfelder
- TAKServer (optional, falls ZIP bereitgestellt)
- Operator-Username + Anzeigename

Danach läuft alles automatisch:

```
[1/8]  System-Update + Pakete installieren
[2/8]  Docker installieren & starten
[3/8]  KOMMS-Repository nach /opt/komms klonen
[4/8]  .env schreiben
[5/8]  setup_server.sh:
         · UFW Firewall konfigurieren
         · TLS-Zertifikat (Let's Encrypt VPS / selbstsigniert LAN)
         · nginx.conf, homeserver.yaml, element/config.json generieren
         · OpenVPN PKI initialisieren
         · Docker-Dienste starten (inkl. Authelia, LLDAP, Nextcloud, Matrix …)
         · Nextcloud LDAP + OIDC Integration einrichten
         · Mumble Server-Name und Join-Passwort setzen
[6/8]  TAKServer einrichten (optional)
[7/8]  Health-Check aller Dienste + Login-Übersicht
[8/8]  Operator-Account anlegen (add_user.sh --admin)
         → .ovpn, TAK-Zertifikat, Nextcloud-Upload
         → SCP-Befehl zum Herunterladen der .ovpn ausgeben
```

### 3.4 Laufzeit

Erstinstallation: ca. **15–25 Minuten** (davon ~10 Min Image-Downloads)

### 3.5 Operator .ovpn abholen

Am Ende der Installation wird ein SCP-Befehl angezeigt:

```bash
scp root@SERVER_IP:/opt/komms-data/users/operator/operator.ovpn .
```

Alternativ: Nach dem Login auf `https://cloud.domain.de` liegt die Datei im Ordner `KOMMS-Users/operator/`.

---

## 4. Erster Login – Übersicht

### Zugangsmodell

```
Ohne VPN erreichbar:
  auth.domain.de    → Authelia SSO-Portal (Login für alle Dienste)
  cloud.domain.de   → Nextcloud (Authelia-Gated)

Nur mit VPN erreichbar:
  element.domain.de → Element Web    (Authelia: beliebiger Nutzer)
  matrix.domain.de  → Matrix/Synapse (kein Authelia, native Clients)
  mdm.domain.de     → Headwind MDM   (Authelia: lldap_admin)
  ldap.domain.de    → LLDAP Web UI   (Authelia: lldap_admin)
  tak.domain.de     → TAKServer      (Authelia: lldap_admin)
```

### Login-Übersicht (VPS)

| Dienst | URL | Zugangsdaten |
|--------|-----|--------------|
| **Authelia** | `https://auth.domain.de` | LLDAP-Nutzername + Passwort |
| **Nextcloud** | `https://cloud.domain.de` | Nextcloud-Admin / nc-passwort (lokaler Admin) |
| **Element** | `https://element.domain.de` | via Authelia SSO |
| **Headwind MDM** | `https://mdm.domain.de` | via Authelia SSO (lldap_admin) |
| **LLDAP Admin** | `https://ldap.domain.de` | via Authelia SSO (lldap_admin) |
| **TAKServer** | `https://tak.domain.de` | via Authelia SSO (lldap_admin) |
| **Mumble** | `domain.de:64738` | Join-Passwort aus .env |

> Element, MDM, LLDAP und TAKServer sind **nur mit aktivem VPN** erreichbar — nginx gibt 403 zurück, auch bei bestehender Authelia-Session.

---

## 5. Nutzer anlegen

### Regulärer Nutzer

```bash
sudo bash /opt/komms/server/add_user.sh <username> "Anzeigename"

# Beispiel:
sudo bash /opt/komms/server/add_user.sh soldier01 "Max Mustermann"
```

Zugang: Nextcloud, Element, Matrix, Mumble

### Admin-Nutzer (Operator)

```bash
sudo bash /opt/komms/server/add_user.sh --admin <username> "Anzeigename"
```

Zusätzlicher Zugang: MDM, LLDAP Web UI, TAKServer WebTAK  
(Mitgliedschaft in `lldap_admin` Gruppe wird automatisch gesetzt)

### Sonderfall: built-in `admin` Account

```bash
sudo bash /opt/komms/server/add_user.sh admin "Admin"
```

LLDAP-Erstellung und Passwort-Reset werden übersprungen (der Account existiert bereits und dessen Passwort wird von Authelia/Synapse für LDAP-Bind genutzt). OpenVPN, TAK-Zertifikat und Nextcloud-Upload laufen normal durch.

### Was wird erstellt?

```
/opt/komms-data/users/<username>/
├── <username>.ovpn         ← OpenVPN-Profil (Android + Windows)
├── <username>-tak.p12      ← ATAK/WinTAK-Zertifikat (Passphrase: TAK_CERT_PASS aus .env)
├── <username>-tak.zip      ← TAK-Datenpaket (empfohlen, auto-connect)
├── qr-credentials.png      ← QR mit Login-Zugangsdaten für Nextcloud
├── qr-info.png             ← QR mit allen Verbindungsdetails
└── credentials.txt         ← Klartext-Übersicht (nach Übergabe löschen!)
```

Alle Dateien werden automatisch nach Nextcloud (`KOMMS-Users/<username>/`) hochgeladen und mit dem Nutzer geteilt.

### Onboarding-Ablauf (Nutzer-Seite)

1. `https://cloud.domain.de` im Browser öffnen (kein VPN nötig)
2. Mit Zugangsdaten aus `qr-credentials.png` einloggen
3. `.ovpn` aus dem geteilten Ordner herunterladen
4. `.ovpn` in OpenVPN-App importieren → VPN verbinden
5. Ab jetzt sind alle anderen Dienste erreichbar

---

## 6. Nutzer löschen

```bash
sudo bash /opt/komms/server/delete_user.sh <username>
```

Löscht in dieser Reihenfolge:
1. LLDAP-Account
2. Nextcloud-Account + WebDAV-Ordner
3. OpenVPN-Zertifikat (widerrufen + PKI-Dateien gelöscht)
4. TAKServer-Zertifikate (.p12, .crt, .key, .jks)
5. Lokale Dateien unter `/opt/komms-data/users/<username>/`

---

## 7. Geräteübergabe an den Nutzer

### Sicherer Übergabeprozess

1. `qr-credentials.png` zeigen (persönlich oder über sicheren Kanal)
2. Nutzer loggt sich in Nextcloud ein, lädt `.ovpn` herunter
3. **Dateien aus `/opt/komms-data/users/<username>/` nach Übergabe löschen**

### Checkliste pro Gerät

- [ ] VPN-Profil importiert und Verbindung getestet
- [ ] Authelia-Login auf `auth.domain.de` funktioniert
- [ ] Nextcloud eingeloggt (`cloud.domain.de`)
- [ ] Element Web eingeloggt (`element.domain.de`, VPN erforderlich)
- [ ] Mumble-Client verbunden (`domain.de:64738`, VPN + Join-Passwort)
- [ ] ATAK: TAK-Datenpaket importiert (`.zip`), Server-Verbindung getestet
- [ ] MDM-Enrollment abgeschlossen (nur Admin-Geräte)

---

## 8. Android-Gerät einrichten (Nutzer-Seite)

### 8.1 VPN (OpenVPN)

1. App installieren: **OpenVPN for Android**
2. `.ovpn` auf das Gerät übertragen (aus Nextcloud herunterladen)
3. In der App: `+` → Datei importieren → verbinden
4. Beim Verbinden: LLDAP-Nutzername + Passwort eingeben

### 8.2 Matrix / Element

1. App installieren: **Element**
2. VPN verbinden
3. `https://element.domain.de` im Browser öffnen → Authelia-Login
4. Oder Element-App: „Andere Server" → `https://matrix.domain.de`

### 8.3 Nextcloud

1. App installieren: **Nextcloud**
2. Server-URL: `https://cloud.domain.de` (kein VPN nötig)
3. Mit LLDAP-Zugangsdaten anmelden

### 8.4 ATAK (TAKServer)

**Empfohlen: TAK-Datenpaket (`.zip`)**

1. `.zip`-Datei auf das Gerät übertragen (aus Nextcloud)
2. ATAK öffnen → Einstellungen → Netzwerk → Datenpaket importieren
3. Verbindung wird automatisch eingerichtet

**Alternativ (manuell):**

1. `.p12`-Datei übertragen
2. ATAK → Einstellungen → Netzwerk → Verbindungen → `+`
3. Server: `tak.domain.de`, Port: `8089`, Protokoll: `TLS`
4. Zertifikat `.p12` importieren (Passphrase aus `credentials.txt`)

### 8.5 Mumble

1. App installieren: **Mumla**
2. VPN verbinden
3. Server hinzufügen: `domain.de:64738`
4. Join-Passwort eingeben (aus `credentials.txt`)

### 8.6 Headwind MDM (nur Admin)

1. VPN verbinden
2. `https://mdm.domain.de` im Browser öffnen → Authelia-Login
3. Enrollment-QR für das Gerät generieren
4. Auf dem Zielgerät: Headwind APK installieren → QR scannen

---

## 9. Windows-Client einrichten (Nutzer-Seite)

```powershell
# Als Administrator ausführen:
.\windows\setup.ps1
```

Installiert und konfiguriert: OpenVPN, WinTAK, Element Desktop

---

## 10. Laufender Betrieb

### Service-Status prüfen

```bash
cd /opt/komms/server
docker compose ps
```

### Logs anzeigen

```bash
docker compose logs -f nginx        # Reverse Proxy + Zugriffslog
docker compose logs -f authelia     # SSO / Auth-Fehler
docker compose logs -f lldap        # LDAP / Nutzer-Verwaltung
docker compose logs -f nextcloud
docker compose logs -f synapse      # Matrix
docker compose logs -f headwind     # MDM
docker compose logs -f openvpn
docker compose logs -f mumble
```

### Dienste neu starten

```bash
docker compose restart <dienst>     # einzelner Dienst
docker compose restart nginx        # nginx nach Config-Änderungen
```

> **Wichtig:** Nach Änderungen an `nginx.conf` muss der nginx-Container **neu gestartet** werden (`restart`, nicht nur `nginx -s reload`), falls die Konfigurationsdatei neu generiert wurde — andernfalls liest der Container die alte Datei (inode-Bindung).

### Nutzer-Passwort zurücksetzen

```bash
NEW_PASS=$(openssl rand -base64 18 | tr -d '=+/' | head -c 20)
cd /opt/komms/server
docker compose exec lldap /app/lldap_set_password \
    --base-url http://127.0.0.1:17170 \
    --admin-password "$LDAP_ADMIN_PASS" \
    --username "<username>" \
    --password "$NEW_PASS"
echo "Neues Passwort: $NEW_PASS"
```

### Stack stoppen / starten

```bash
docker compose down                 # stoppen (Daten bleiben in Volumes)
docker compose up -d                # starten
```

---

## 11. Wartung & Backups

### Docker-Images aktualisieren

```bash
cd /opt/komms/server
docker compose pull
docker compose up -d
```

### Backup (wichtige Volumes)

```bash
for vol in server_postgres_data server_synapse_data server_nextcloud_data \
           server_openvpn_data server_lldap_data server_headwind_files; do
    docker run --rm \
        -v ${vol}:/data:ro \
        -v /backup:/backup \
        alpine tar czf /backup/${vol}-$(date +%Y%m%d).tar.gz -C /data .
done

# .env getrennt und verschlüsselt sichern!
cp /opt/komms-data/.env /backup/komms-env-$(date +%Y%m%d).env
```

### Let's Encrypt Zertifikat (VPS)

Erneuerung läuft automatisch via Certbot-Cronjob.  
Manuell erneuern:

```bash
certbot renew
certbot certificates   # Status prüfen
```

### Server-Neustart

```bash
reboot
# Stack startet automatisch (restart: unless-stopped)
cd /opt/komms/server && docker compose ps
```

---

## 12. TAKServer nachrüsten

TAKServer erfordert eine kostenlose Registrierung auf [tak.gov](https://tak.gov).

```bash
# 1. Docker-ZIP von tak.gov herunterladen:
#    TAKSERVER-DOCKER-<version>.zip → nach /opt/komms-data/tak-release/

# 2. Setup ausführen:
sudo bash /opt/komms/server/setup_tak.sh

# 3. TAK-Zertifikate für bestehende Nutzer nachholen:
sudo bash /opt/komms/server/add_user.sh <username> "Anzeigename"
# (erkennt vorhandenes VPN-Cert → erstellt nur TAK-Cert + lädt in Nextcloud hoch)
```

---

*Bei Problemen: `docker compose logs -f <dienst>` ist dein bester Freund.*
