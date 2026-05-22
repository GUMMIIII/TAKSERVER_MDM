#Requires -Version 5.1
<#
.SYNOPSIS
    KOMMS – Local Test Setup for Docker Desktop (Windows)
.DESCRIPTION
    Richtet KOMMS für lokalen Test ein:
      • Erstellt server/.env mit Test-Defaults (oder bestehende wird genutzt)
      • Ersetzt Template-Platzhalter in homeserver.yaml und CoreConfig.xml
      • Generiert selbst-signiertes TLS-Zertifikat
      • Baut das Synapse-Custom-Image (matrix-synapse-ldap3)
      • Startet alle Services außer TAKServer
.EXAMPLE
    .\local-setup.ps1
    .\local-setup.ps1 -Reset    # löscht bestehende .env und startet neu
#>
param(
    [switch]$Reset
)

$ErrorActionPreference = "Stop"

# Immer vom KOMMS-Repo-Root ausführen
$RepoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerDir = Join-Path $RepoRoot "server"
Set-Location $RepoRoot

function OK($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function WARN($m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function INFO($m) { Write-Host "   ->  $m" -ForegroundColor Cyan }
function STEP($m) { Write-Host "`n  -- $m" -ForegroundColor White }
function ERR($m)  { Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║       KOMMS – Lokaler Docker Desktop Test               ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Docker prüfen ─────────────────────────────────────────────────────────────
STEP "Docker Desktop prüfen"
try {
    $null = docker info 2>&1
    OK "Docker läuft"
} catch {
    ERR "Docker läuft nicht. Docker Desktop starten und erneut versuchen."
}

# ── .env erstellen ────────────────────────────────────────────────────────────
STEP "Umgebungsvariablen (.env)"
$envFile = Join-Path $ServerDir ".env"

if ($Reset -and (Test-Path $envFile)) {
    Remove-Item $envFile -Force
    WARN ".env wurde zurückgesetzt."
}

if (-not (Test-Path $envFile)) {
    # Lokale IP ermitteln (nicht Loopback, nicht Docker-VEthernet)
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.InterfaceAlias -notmatch 'Loopback|Tunnel' -and
            $_.IPAddress -ne '127.0.0.1' -and
            $_.PrefixOrigin -ne 'WellKnown'
        } | Select-Object -First 1).IPAddress
    if (-not $localIP) { $localIP = "127.0.0.1" }

    Write-Host ""
    Write-Host "  Domain/IP fuer lokalen Test [$localIP]: " -ForegroundColor Cyan -NoNewline
    $input = Read-Host
    $DOMAIN = if ([string]::IsNullOrWhiteSpace($input)) { $localIP } else { $input.Trim() }

    # Zufällige Secrets generieren
    function RandHex($n) {
        $bytes = New-Object byte[] $n
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    }

    $DB_PASS     = "komms_$(RandHex 6)"
    $LDAP_PASS   = "lldap_$(RandHex 6)"
    $MAT_MAC     = RandHex 32
    $MAT_FORM    = RandHex 32
    $MAT_REG     = RandHex 32
    $JWT_SECRET  = RandHex 32

    @"
# KOMMS Lokale Testumgebung – generiert von local-setup.ps1
DOMAIN=$DOMAIN

DB_USER=komms
DB_PASS=$DB_PASS

HMDM_URL=https://$DOMAIN/mdm
HMDM_ADMIN_EMAIL=admin@komms.local
HMDM_ADMIN_PASS=komms_mdm_local

NC_ADMIN=admin
NC_PASS=komms_nc_local

MATRIX_DOMAIN=$DOMAIN
MATRIX_MACAROON_SECRET=$MAT_MAC
MATRIX_FORM_SECRET=$MAT_FORM
MATRIX_REGISTRATION_SHARED_SECRET=$MAT_REG

LDAP_BASE_DN=dc=komms,dc=local
LDAP_ADMIN_PASS=$LDAP_PASS
LLDAP_JWT_SECRET=$JWT_SECRET

MUMBLE_SERVER_NAME=KOMMS Voice (Lokal)
MUMBLE_SUPERUSER_PASS=komms_mumble_local

VPN_HOST=$DOMAIN
VPN_PORT=1194
VPN_PROTO=udp
VPN_SUBNET=10.8.0.0
VPN_MASK=255.255.255.0

TAK_CERT_PASS=atakatak
TAK_IMAGE=takserver/takserver:5.3-RELEASE-35

CERT_COUNTRY=DE
CERT_STATE=Bayern
CERT_CITY=Berlin
CERT_ORG=KOMMS
CERT_UNIT=Ops
"@ | Set-Content $envFile -Encoding utf8

    OK ".env erstellt"
    Write-Host ""
    Write-Host "  Gespeicherte Test-Zugangsdaten:" -ForegroundColor Yellow
    Write-Host "    DB:   komms / $DB_PASS" -ForegroundColor White
    Write-Host "    LLDAP: admin / $LDAP_PASS" -ForegroundColor White
    Write-Host "    Domain: $DOMAIN" -ForegroundColor White

} else {
    OK ".env bereits vorhanden (nutze bestehende Werte)"
}

# ── .env laden ────────────────────────────────────────────────────────────────
$cfg = @{}
Get-Content $envFile | Where-Object { $_ -match '^[A-Z_]+=.' -and $_ -notmatch '^#' } | ForEach-Object {
    $parts = $_ -split '=', 2
    if ($parts.Count -eq 2) { $cfg[$parts[0].Trim()] = $parts[1].Trim() }
}
function E($k) { if ($cfg.ContainsKey($k)) { $cfg[$k] } else { "" } }

$DOMAIN = E 'DOMAIN'

# ── homeserver.yaml generieren ────────────────────────────────────────────────
STEP "Matrix homeserver.yaml generieren"
$matrixYaml = Join-Path $ServerDir "matrix\homeserver.yaml"
$content = Get-Content $matrixYaml -Raw -Encoding utf8

if ($content -match '\$\{[A-Z_]+\}') {
    foreach ($key in $cfg.Keys) {
        $content = $content -replace [regex]::Escape("`${$key}"), $cfg[$key]
    }
    # Sicherstellen dass keine Platzhalter übrig bleiben
    if ($content -match '\$\{[A-Z_]+\}') {
        $missing = [regex]::Matches($content, '\$\{([A-Z_]+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        WARN "Unaufgelöste Variablen in homeserver.yaml: $($missing -join ', ')"
    }
    [System.IO.File]::WriteAllText($matrixYaml, $content, [System.Text.Encoding]::UTF8)
    OK "homeserver.yaml fertig"
} else {
    OK "homeserver.yaml bereits verarbeitet"
}

# ── CoreConfig.xml generieren ─────────────────────────────────────────────────
STEP "TAKServer CoreConfig.xml generieren"
$coreXml = Join-Path $ServerDir "takserver\CoreConfig.xml"
if (Test-Path $coreXml) {
    $content = Get-Content $coreXml -Raw -Encoding utf8
    if ($content -match 'KOMMS_TAK_DB_USER') {
        $content = $content `
            -replace 'KOMMS_TAK_DB_USER',     (E 'DB_USER') `
            -replace 'KOMMS_TAK_DB_PASS',     (E 'DB_PASS') `
            -replace 'KOMMS_CERT_PASS',        (E 'TAK_CERT_PASS') `
            -replace 'KOMMS_SERVER_HOST',      (E 'DOMAIN') `
            -replace 'KOMMS_LDAP_ADMIN_PASS', (E 'LDAP_ADMIN_PASS') `
            -replace 'KOMMS_LDAP_BASE_DN',    (E 'LDAP_BASE_DN')
        [System.IO.File]::WriteAllText($coreXml, $content, [System.Text.Encoding]::UTF8)
        OK "CoreConfig.xml fertig"
    } else {
        OK "CoreConfig.xml bereits verarbeitet"
    }
}

# ── TLS-Zertifikat generieren ─────────────────────────────────────────────────
STEP "TLS-Zertifikat generieren"
$certsDir = Join-Path $ServerDir "nginx\certs"
New-Item -ItemType Directory -Force -Path $certsDir | Out-Null

$certFile = Join-Path $certsDir "komms.crt"
if (-not (Test-Path $certFile)) {
    # Versuche lokales openssl (kommt mit Git for Windows)
    $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($opensslCmd) {
        INFO "Generiere Zertifikat mit lokalem openssl..."
        $keyFile  = Join-Path $certsDir "komms.key"
        openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes `
            -keyout $keyFile `
            -out    $certFile `
            -subj   "/CN=$DOMAIN/O=KOMMS/C=DE" 2>&1 | Out-Null
    } else {
        INFO "Kein lokales openssl – nutze Docker Alpine..."
        # Docker-Pfad braucht Forward Slashes
        $mountSrc = ($certsDir -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
        docker run --rm `
            -v "${mountSrc}:/certs" `
            alpine sh -c "apk add --no-cache openssl -q 2>/dev/null && openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout /certs/komms.key -out /certs/komms.crt -subj '/CN=$DOMAIN/O=KOMMS/C=DE' 2>/dev/null && echo OK"
    }
    OK "Zertifikat generiert (selbst-signiert, 365 Tage)"
} else {
    OK "Zertifikat bereits vorhanden"
}

# ── Synapse-Image bauen ────────────────────────────────────────────────────────
STEP "Synapse Custom-Image bauen (matrix-synapse-ldap3)"
INFO "Beim ersten Mal dauert das ~2-3 Minuten..."
Set-Location $ServerDir
docker compose build synapse
OK "Synapse-Image gebaut"

# ── Services starten ──────────────────────────────────────────────────────────
STEP "KOMMS Services starten (ohne TAKServer)"
docker compose up -d nginx postgres redis lldap headwind openvpn synapse mumble nextcloud
OK "Services gestartet"

# ── Status anzeigen ───────────────────────────────────────────────────────────
Write-Host ""
Start-Sleep -Seconds 3
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

# ── Nextcloud LDAP konfigurieren ──────────────────────────────────────────────
STEP "Nextcloud LDAP-Integration konfigurieren"
$bashCmd = Get-Command bash -ErrorAction SilentlyContinue
if ($bashCmd) {
    INFO "Starte setup_nextcloud_ldap.sh (wartet auf Nextcloud)..."
    bash (Join-Path $ServerDir "setup_nextcloud_ldap.sh")
    OK "LDAP-Setup abgeschlossen"
} else {
    WARN "bash nicht gefunden (Git Bash / WSL installieren)."
    WARN "LDAP-Setup manuell ausfuehren:"
    INFO "  bash server/setup_nextcloud_ldap.sh"
}

Set-Location $RepoRoot

# ── Fertig ────────────────────────────────────────────────────────────────────
$LDAP_PASS = E 'LDAP_ADMIN_PASS'
$NC_PASS_VAL = E 'NC_PASS'
$MDM_PASS = E 'HMDM_ADMIN_PASS'

Write-Host ""
Write-Host "  ==================================================" -ForegroundColor Green
Write-Host "  KOMMS laeuft lokal!" -ForegroundColor Green
Write-Host "  ==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  URLs (Browser-Zertifikat-Warnung akzeptieren):" -ForegroundColor Yellow
Write-Host "    MDM Dashboard:  https://$DOMAIN/mdm" -ForegroundColor Cyan
Write-Host "                    admin@komms.local / $MDM_PASS" -ForegroundColor White
Write-Host "    Nextcloud:      https://$DOMAIN/nextcloud" -ForegroundColor Cyan
Write-Host "                    admin / $NC_PASS_VAL" -ForegroundColor White
Write-Host "    Matrix:         https://$DOMAIN/_matrix" -ForegroundColor Cyan
Write-Host "    LLDAP Web-UI:   http://127.0.0.1:17170" -ForegroundColor Cyan
Write-Host "                    admin / $LDAP_PASS" -ForegroundColor White
Write-Host "    Mumble:         $DOMAIN`:64738" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Befehle:" -ForegroundColor Yellow
Write-Host "    Status:  cd server ; docker compose ps" -ForegroundColor White
Write-Host "    Logs:    cd server ; docker compose logs -f <service>" -ForegroundColor White
Write-Host "    Stop:    cd server ; docker compose down" -ForegroundColor White
Write-Host "    Reset:   .\local-setup.ps1 -Reset" -ForegroundColor White
Write-Host ""
Write-Host "  Tipp: LLDAP-UI direkt auf http://127.0.0.1:17170 oeffnen" -ForegroundColor Yellow
Write-Host "        (nginx-Zugangsschutz gilt nur fuer /ldap/ Route)" -ForegroundColor Yellow
Write-Host ""
