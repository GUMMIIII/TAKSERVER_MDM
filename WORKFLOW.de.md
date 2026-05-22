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
| RAM | min. 4 GB · **min. 8 GB mit TAKServer** | min. 2 GB |
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
| `collabora.domain.de` | VPS-IP |

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

### 3.3 TAKServer (optional — vor dem Installer)

TAKServer wird **automatisch erkannt** — kein Prompt während der Installation. ZIP einfach vorher auf den Server legen:

```bash
mkdir -p /opt/komms-data/tak-release
scp TAKSERVER-DOCKER-*.zip root@DEIN_SERVER:/opt/komms-data/tak-release/
```

Liegt kein ZIP vor, wird TAKServer übersprungen und kann später nachgerüstet werden (siehe [Abschnitt 12](#12-takserver-nachrüsten)).

### 3.4 Abgefragte Einstellungen

Der Installer fragt interaktiv:
- Domain, Betriebsmodus (VPS / LAN)
- Passwörter (DB, Nextcloud-Admin, MDM-Admin, LDAP-Admin)
- Mumble SuperUser-Passwort + Join-Passwort
- VPN-Hostname/Port, Zertifikatsfelder
- Operator-Username + Anzeigename (nach dem Health-Check abgefragt)

### 3.5 Automatischer Ablauf

```
[1/8]  System-Update
[2/8]  Pakete installieren (Docker, certbot, jq, qrencode, …)
[3/8]  Docker installieren
[4/8]  KOMMS-Repository nach /opt/komms klonen
[5/8]  .env schreiben
[6/8]  setup_server.sh:
         · UFW Firewall konfigurieren
         · TLS-Zertifikat (Let's Encrypt VPS / selbstsigniert LAN)
         · nginx.conf, homeserver.yaml, element/config.json generieren
         · OpenVPN PKI initialisieren
         · Docker-Dienste starten (inkl. Authelia, LLDAP, Nextcloud, Matrix …)
         · Nextcloud LDAP + OIDC Integration einrichten
         · Mumble Server-Name und Join-Passwort setzen
[7/8]  TAKServer — ZIP erkannt → gibt Hinweis zur manuellen Ausführung von setup_tak.sh
       (vollautomatisches Setup noch nicht implementiert, siehe Hinweis unten)
[8/8]  Health-Check aller Dienste + Login-Übersicht
       → Operator-Account anlegen (add_user.sh --admin)
       → .ovpn, TAK-Zertifikat, Nextcloud-Upload
       → SCP-Befehl zum Herunterladen der .ovpn ausgeben
```

> **TAKServer erfordert einen manuellen Schritt nach der Installation** — `setup_tak.sh` muss nach Abschluss von `install.sh` ausgeführt werden (siehe [Abschnitt 12](#12-takserver-nachrüsten)).  
> Alle anderen Dienste laufen vollständig automatisch ohne manuelle Nacharbeiten.

### 3.6 Laufzeit

Erstinstallation: ca. **15–25 Minuten** (davon ~10 Min Image-Downloads). TAKServer kommt mit weiteren 5–10 Min hinzu wenn `setup_tak.sh` manuell ausgeführt wird.

### 3.7 Operator .ovpn abholen

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
  auth.domain.de        → Authelia SSO-Portal (Login für alle Dienste)
  cloud.domain.de       → Nextcloud (Authelia-Gated)
  collabora.domain.de   → Collabora Online (WOPI-Token-Auth via Nextcloud)

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
| **Nextcloud** | `https://cloud.domain.de` | Authelia SSO — automatische Weiterleitung (kein Passwort-Formular) |
| **Collabora** | `https://collabora.domain.de` | automatisch via Nextcloud (WOPI) |
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
├── qr-credentials.png      ← QR mit LLDAP-Zugangsdaten
└── credentials.txt         ← Klartext-Übersicht (nach Übergabe löschen!)
```

Alle Dateien werden automatisch nach Nextcloud (`KOMMS-Users/<username>/`) hochgeladen und mit dem Nutzer geteilt.

### Onboarding-Ablauf (Nutzer-Seite)

1. `https://cloud.domain.de` im Browser öffnen (kein VPN nötig)
2. Über Authelia SSO mit den LLDAP-Zugangsdaten aus `qr-credentials.png` anmelden — Nextcloud leitet automatisch weiter (kein eigenes Passwort-Formular bei Nextcloud)
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
docker compose logs -f collabora    # Collabora Online / Dokumenten-Editor
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

### Plattform aktualisieren (Code + Docker-Images)

```bash
sudo bash /opt/komms/server/update.sh            # aktueller Release-Tag (empfohlen)
sudo bash /opt/komms/server/update.sh main       # aktueller main-Branch
sudo bash /opt/komms/server/update.sh v0.0.5     # bestimmter Tag
```

Das Update-Script sichert `.env`, warnt bei fehlenden neuen Variablen, stoppt den Stack, aktualisiert Code + Images und startet neu.

### Nextcloud Major-Version upgraden

Nextcloud unterstützt nur einzelne Major-Version-Sprünge (z. B. 33 → 34). Pro Major-Version einmal ausführen:

```bash
sudo bash /opt/komms/server/update_nextcloud.sh        # automatisch: aktuell + 1
sudo bash /opt/komms/server/update_nextcloud.sh 34     # explizites Ziel
```

Danach den aktualisierten Image-Tag committen:

```bash
git add server/docker-compose.yml
git commit -m "chore: Nextcloud 33 auf 34 aktualisiert"
git push
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

> **Dieser Schritt ist nach jeder Frischinstallation manuell erforderlich.** Das vollautomatische TAKServer-Setup innerhalb von `install.sh` ist in Planung, aber noch nicht implementiert — siehe [CHANGELOG](CHANGELOG.md).

TAKServer erfordert eine kostenlose Registrierung auf [tak.gov](https://tak.gov).

```bash
# 1. ZIP in das Release-Verzeichnis legen (falls nicht bereits vor install.sh geschehen):
scp TAKSERVER-DOCKER-*.zip root@DEIN_SERVER:/opt/komms-data/tak-release/

# 2. Setup ausführen:
sudo bash /opt/komms/server/setup_tak.sh

# 3. TAK-Zertifikate für bestehende Nutzer nachholen:
sudo bash /opt/komms/server/add_user.sh <username> "Anzeigename"
# (erkennt vorhandenes VPN-Cert → erstellt nur TAK-Cert + lädt in Nextcloud hoch)
```

### Was setup_tak.sh macht

1. ZIP entpacken + Docker-Image bauen (~5 Min)
2. CA, Server-Zertifikat und Admin-Client-Zertifikat generieren
3. PostgreSQL-Datenbankschema initialisieren
4. Container neu starten, auf Port 8443 warten
5. **60 Sekunden** warten bis Apaches Ignite-Grid vollständig initialisiert ist
6. `certmod` ausführen um `ROLE_ADMIN` für das Admin-Zertifikat zu setzen (bis zu 3 Versuche)

### Warum dauert das so lange?

Die Wartezeit nach dem Container-Start ist **gewollt und notwendig**. TAKServer nutzt Apache Ignite als internen Service-Mesh. Port 8443 öffnet sich schnell — aber das Ignite-Grid braucht noch mehrere Minuten bis es Zertifikatsverwaltungs-Kommandos verarbeiten kann. Das Script **nicht unterbrechen**.

Falls `certmod` trotzdem fehlschlägt, manuell nachführen:

```bash
docker exec komms_tak bash -c \
  'cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/admin.pem'
```

---

*Bei Problemen: `docker compose logs -f <dienst>` ist dein bester Freund.*
