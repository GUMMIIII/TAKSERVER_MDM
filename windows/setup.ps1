#Requires -Version 5.1
<#
.SYNOPSIS
    KOMMS – Windows Device Provisioner
.DESCRIPTION
    Sets up a Windows device for use with the KOMMS platform.
    Installs: OpenVPN client, Element (Matrix), Mumble, WinTAK (if available)
    Configures: OpenVPN profile, removes unnecessary software
    Run from PowerShell as Administrator: .\setup.ps1 -ServerIP 10.0.0.1
.PARAMETER ServerIP
    IP or hostname of the KOMMS server
.PARAMETER VpnProfile
    Path to the .ovpn profile file (optional, downloaded from server if omitted)
#>
param(
    [Parameter(Mandatory)]
    [string]$ServerIP,
    [string]$VpnProfile = ""
)

$ErrorActionPreference = "Stop"

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Header {
    Clear-Host
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║        KOMMS – Windows Device Provisioner               ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function OK   { param($m) Write-Host "  ✔  $m" -ForegroundColor Green }
function WARN { param($m) Write-Host "  ⚠  $m" -ForegroundColor Yellow }
function ERR  { param($m) Write-Host "  ✗  $m" -ForegroundColor Red }
function INFO { param($m) Write-Host "  →  $m" -ForegroundColor Cyan }
function STEP { param($m) Write-Host "`n$m" -ForegroundColor White }

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [System.Security.Principal.WindowsPrincipal]$id
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-Winget {
    param([string]$Id, [string]$Name)
    # Check via winget list (handles apps not in PATH, e.g. GUI-only installers)
    $installed = winget list --id $Id --exact 2>$null | Select-String $Id
    if ($installed) { OK "$Name already installed"; return }
    INFO "Installing $Name via winget..."
    winget install --id $Id -e --silent `
        --accept-source-agreements --accept-package-agreements
    OK "$Name installed"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
Write-Header

if (-not (Test-Admin)) {
    ERR "Run this script as Administrator."
    Write-Host "  Right-click PowerShell → 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    ERR "winget not available. Install App Installer from the Microsoft Store."
    exit 1
}

Write-Host "  Server: $ServerIP" -ForegroundColor White
Write-Host ""

# ── [1/5] Install apps ────────────────────────────────────────────────────────
STEP "[1/5] Installing KOMMS applications"

# OpenVPN client
Install-Winget "OpenVPNTechnologies.OpenVPN"  "openvpn"

# Element (Matrix client)
Install-Winget "Element.Element" "element-desktop"

# Mumble (voice client)
Install-Winget "Mumble.Mumble" "mumble"

# Nextcloud Desktop client
Install-Winget "Nextcloud.NextcloudDesktop" "nextcloudcmd"

# ── [2/5] OpenVPN profile ────────────────────────────────────────────────────
STEP "[2/5] Configuring OpenVPN"

$ovpnDir    = "C:\Program Files\OpenVPN\config"
$ovpnTarget = "$ovpnDir\komms.ovpn"

if ($VpnProfile -and (Test-Path $VpnProfile)) {
    Copy-Item $VpnProfile $ovpnTarget -Force
    OK "OpenVPN profile installed from: $VpnProfile"
} elseif (Test-Path $ovpnTarget) {
    OK "OpenVPN profile already present"
} else {
    WARN "No .ovpn profile provided."
    INFO "Get it from your admin, place it at:"
    INFO "  $ovpnTarget"
    INFO "Then connect via the OpenVPN GUI in the system tray."
}

# ── [3/5] Debloat Windows ────────────────────────────────────────────────────
STEP "[3/5] Removing unnecessary Windows apps"

$bloat = @(
    "Microsoft.BingWeather",
    "Microsoft.GetHelp",
    "Microsoft.Getstarted",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.People",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.Xbox.TCUI",
    "Microsoft.XboxApp",
    "Microsoft.XboxGameOverlay",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Microsoft.YourPhone",
    "MicrosoftTeams"   # consumer Teams, not enterprise
)

foreach ($app in $bloat) {
    try {
        Get-AppxPackage -Name $app -AllUsers | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    } catch {
        # Not installed — that's fine
    }
}
OK "Windows bloat removed"

# ── [4/5] System settings ─────────────────────────────────────────────────────
STEP "[4/5] Applying system settings"

# Disable telemetry
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" `
    -Name "AllowTelemetry" -Value 0 -Type DWord -Force

# Disable Cortana
$cortanaPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
if (-not (Test-Path $cortanaPath)) { New-Item -Path $cortanaPath -Force | Out-Null }
Set-ItemProperty -Path $cortanaPath -Name "AllowCortana" -Value 0 -Type DWord -Force

# Disable consumer experiences (app suggestions)
$cloudPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
if (-not (Test-Path $cloudPath)) { New-Item -Path $cloudPath -Force | Out-Null }
Set-ItemProperty -Path $cloudPath -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force

OK "System settings applied"

# ── [5/5] Firewall ────────────────────────────────────────────────────────────
STEP "[5/5] Firewall rules"

# Allow Mumble
New-NetFirewallRule -DisplayName "KOMMS Mumble" `
    -Direction Inbound -Protocol UDP -LocalPort 64738 `
    -Action Allow -ErrorAction SilentlyContinue | Out-Null

OK "Firewall rules added"

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✔  Windows provisioning complete!" -ForegroundColor Green
Write-Host "  ════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "  1. Connect OpenVPN: system tray → OpenVPN GUI → komms" -ForegroundColor White
Write-Host "  2. Element:  https://$ServerIP/_matrix/" -ForegroundColor White
Write-Host "  3. Mumble:   server=$ServerIP  port=64738" -ForegroundColor White
Write-Host "  4. Nextcloud: https://$ServerIP/nextcloud/" -ForegroundColor White
Write-Host ""
