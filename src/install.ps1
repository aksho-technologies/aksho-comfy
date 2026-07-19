# Aksho ComfyUI installer / updater / repairer.
#
# One idempotent script, three roles:
#   - Fresh install:  downloads ComfyUI portable + extensions + models per manifest.json
#   - Update:         same run; only components whose hash/size changed are downloaded
#   - Repair:         same run; missing or corrupted files are re-fetched
#
# Modes:
#   install.ps1                          full install/update/repair, then launch
#   install.ps1 -NoLaunch                full install/update/repair, no launch (Update bat)
#   install.ps1 -UpdateCheck             fast launch-time check (~2s); prompts only when a
#                                        newer bundleVersion exists, else returns immediately
#
# State: <install root>\installed.json tracks bundleVersion + per-component sha256.
# PowerShell 5.1 compatible. Downloads via curl.exe (resume-capable), extraction via tar.exe.

param(
    [string]$InstallPath = '',
    [switch]$UpdateCheck,
    [switch]$NoLaunch,
    [switch]$SkipSelfUpdate
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:InstallerVersion = '1.0.0'
$Script:BaseUrl = 'https://dl.akshoai.com'
$Script:ManifestUrl = "$Script:BaseUrl/manifest.json"
$Script:ComfyPort = 8188
$Script:AtelierUrl = 'https://akshoai.com/atelier'

function Write-Info($msg) { Write-Host "[AKSHO COMFY] $msg" }
function Write-Err($msg) { Write-Host "[AKSHO COMFY] ERROR: $msg" -ForegroundColor Red }

function Resolve-InstallRoot {
    # Priority: explicit param > script living at <root>\installer\install.ps1 > prompt.
    if ($InstallPath) { return $InstallPath }
    $scriptDir = Split-Path -Parent $PSCommandPath
    if ((Split-Path -Leaf $scriptDir) -eq 'installer') {
        $root = Split-Path -Parent $scriptDir
        if (Test-Path (Join-Path $root 'installed.json')) { return $root }
    }
    $default = 'C:\AkshoComfy'
    $answer = Read-Host "Install folder [$default]"
    if (-not $answer) { $answer = $default }
    return $answer
}

function Get-Manifest([int]$timeoutSec) {
    $tmp = Join-Path $env:TEMP 'aksho-comfy-manifest.json'
    & curl.exe -fsS -m $timeoutSec $Script:ManifestUrl -o $tmp 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return (Get-Content $tmp -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-InstalledState([string]$root) {
    $path = Join-Path $root 'installed.json'
    if (Test-Path $path) {
        try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ bundleVersion = ''; components = [pscustomobject]@{} }
}

function Save-InstalledState([string]$root, $state) {
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $root 'installed.json') -Encoding UTF8
}

function Get-ComponentsToInstall([string]$root, $manifest, $state) {
    $needed = @()
    foreach ($c in $manifest.components) {
        $recorded = $state.components.PSObject.Properties[$c.id]
        if (-not $recorded -or $recorded.Value.sha256 -ne $c.sha256) { $needed += $c; continue }
        if ($c.kind -eq 'file') {
            $target = Join-Path $root $c.targetPath
            if (-not (Test-Path $target)) { $needed += $c; continue }
            if ((Get-Item $target).Length -ne [long]$c.sizeBytes) { $needed += $c; continue }
        } else {
            # Archives: trust the recorded hash; presence of the target folder is the cheap sanity check.
            if (-not (Test-Path (Join-Path $root $c.targetPath))) { $needed += $c }
        }
    }
    return $needed
}

function Invoke-Download([string]$url, [string]$dest, [string]$sha256) {
    $part = "$dest.part"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & curl.exe -fL -C - --retry 3 --retry-delay 5 --progress-bar $url -o $part
        if ($LASTEXITCODE -ne 0) {
            if ($attempt -eq 3) { throw "Download failed: $url" }
            continue
        }
        $actual = (Get-FileHash -Algorithm SHA256 $part).Hash.ToLowerInvariant()
        if ($actual -eq $sha256.ToLowerInvariant()) {
            Move-Item -Force $part $dest
            return
        }
        Write-Info "Hash mismatch (attempt $attempt), redownloading..."
        Remove-Item -Force $part
    }
    throw "Hash verification failed after retries: $url"
}

function Install-Component([string]$root, $c) {
    $downloads = Join-Path $root '_downloads'
    if ($c.kind -eq 'file') {
        $target = Join-Path $root $c.targetPath
        $staged = Join-Path $downloads ($c.id)
        Invoke-Download $c.url $staged $c.sha256
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Move-Item -Force $staged $target
    } elseif ($c.kind -eq 'archive-extract') {
        $staged = Join-Path $downloads ("$($c.id).zip")
        Invoke-Download $c.url $staged $c.sha256
        $target = Join-Path $root $c.targetPath
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        # Archives are packed so their root IS the target content (no wrapper folder).
        & tar.exe -xf $staged -C $target
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $($c.id)" }
        Remove-Item -Force $staged
    } else {
        throw "Unknown component kind '$($c.kind)' for $($c.id)"
    }
}

function Invoke-PostInstall([string]$root, $components) {
    $python = Join-Path $root 'python_embeded\python.exe'
    if (-not (Test-Path $python)) {
        Write-Err "Embedded python not found at $python; extension setup skipped."
        return
    }
    foreach ($c in $components) {
        if (-not $c.postInstall) { continue }
        $extDir = Join-Path $root $c.targetPath
        if ($c.postInstall.pipRequirements) {
            $req = Join-Path $extDir $c.postInstall.pipRequirements
            if (Test-Path $req) {
                Write-Info "Installing python packages for $($c.id)..."
                & $python -m pip install -q -r $req
            }
        }
        if ($c.postInstall.runScript) {
            $script = Join-Path $extDir $c.postInstall.runScript
            if (Test-Path $script) {
                Write-Info "Running setup script for $($c.id)..."
                & $python $script
            }
        }
    }
}

function Write-Launchers([string]$root) {
    $launcher = @'
@echo off
setlocal
cd /d "%~dp0"
title Aksho ComfyUI
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\install.ps1" -UpdateCheck
echo [AKSHO COMFY] Starting ComfyUI on port 8188...
.\python_embeded\python.exe -s ComfyUI\main.py --port 8188 --enable-cors-header --disable-auto-launch
pause
'@
    $updater = @'
@echo off
setlocal
cd /d "%~dp0"
title Aksho ComfyUI Updater
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\install.ps1" -NoLaunch
pause
'@
    Set-Content -Path (Join-Path $root 'Run Aksho ComfyUI.bat') -Value $launcher -Encoding ASCII
    Set-Content -Path (Join-Path $root 'Update Aksho ComfyUI.bat') -Value $updater -Encoding ASCII
    $installerDir = Join-Path $root 'installer'
    New-Item -ItemType Directory -Force -Path $installerDir | Out-Null
    Copy-Item -Force $PSCommandPath (Join-Path $installerDir 'install.ps1')
}

function Invoke-SelfUpdate([string]$root, $manifest) {
    if ($SkipSelfUpdate) { return $false }
    if (-not $manifest.installerVersion -or $manifest.installerVersion -eq $Script:InstallerVersion) { return $false }
    Write-Info "Installer update $Script:InstallerVersion -> $($manifest.installerVersion), fetching..."
    $newPath = Join-Path $env:TEMP 'aksho-comfy-install-new.ps1'
    & curl.exe -fsSL -m 60 $manifest.installerUrl -o $newPath
    if ($LASTEXITCODE -ne 0) { Write-Info 'Installer self-update failed, continuing with current version.'; return $false }
    $flags = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newPath, '-InstallPath', $root, '-SkipSelfUpdate')
    if ($UpdateCheck) { $flags += '-UpdateCheck' }
    if ($NoLaunch) { $flags += '-NoLaunch' }
    & powershell @flags
    exit $LASTEXITCODE
}

function Test-DiskSpace([string]$root, $needed) {
    $bytes = 0
    foreach ($c in $needed) { $bytes += [long]$c.sizeBytes }
    $bytes = [long]($bytes * 1.2)
    $qualifier = (Split-Path -Qualifier ([IO.Path]::GetFullPath($root))).TrimEnd(':')
    $free = (Get-PSDrive $qualifier).Free
    if ($free -lt $bytes) {
        $needGB = [math]::Round($bytes / 1GB, 1)
        $freeGB = [math]::Round($free / 1GB, 1)
        throw "Not enough disk space on ${qualifier}: - need about ${needGB} GB, ${freeGB} GB free."
    }
}

function Wait-ForComfy {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$Script:ComfyPort/system_stats"
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$root = Resolve-InstallRoot
New-Item -ItemType Directory -Force -Path $root | Out-Null
$state = Get-InstalledState $root

if ($UpdateCheck) {
    # Fast path for the launcher: never block a launch on network problems.
    $manifest = Get-Manifest 2
    if (-not $manifest) { Write-Info 'Offline - skipping update check.'; exit 0 }
    if ($manifest.bundleVersion -eq $state.bundleVersion) { exit 0 }
    $answer = Read-Host "Update available ($($state.bundleVersion) -> $($manifest.bundleVersion)). Update now? [Y/n]"
    if ($answer -and $answer.Trim().ToLowerInvariant() -eq 'n') { exit 0 }
    # Fall through into the full flow below with the fetched manifest.
} else {
    $manifest = Get-Manifest 30
    if (-not $manifest) { Write-Err 'Could not fetch the update manifest. Check your connection and try again.'; exit 1 }
}

Invoke-SelfUpdate $root $manifest

$needed = Get-ComponentsToInstall $root $manifest $state
if ($needed.Count -eq 0) {
    Write-Info "Everything is up to date (bundle $($manifest.bundleVersion))."
} else {
    $totalGB = [math]::Round(($needed | ForEach-Object { [long]$_.sizeBytes } | Measure-Object -Sum).Sum / 1GB, 2)
    Write-Info "$($needed.Count) component(s) to download (about $totalGB GB)."
    Test-DiskSpace $root $needed

    foreach ($c in $needed) {
        Write-Info "Downloading $($c.id)..."
        Install-Component $root $c
        if (-not $state.components.PSObject.Properties[$c.id]) {
            $state.components | Add-Member -NotePropertyName $c.id -NotePropertyValue $null -Force
        }
        $state.components.$($c.id) = [pscustomobject]@{
            sha256 = $c.sha256
            sizeBytes = [long]$c.sizeBytes
            installedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-InstalledState $root $state
    }

    Invoke-PostInstall $root ($needed | Where-Object { $_.postInstall })
}

$state.bundleVersion = $manifest.bundleVersion
Save-InstalledState $root $state
Write-Launchers $root
$downloadsDir = Join-Path $root '_downloads'
if (Test-Path $downloadsDir) { Remove-Item -Recurse -Force $downloadsDir -ErrorAction SilentlyContinue }

if ($UpdateCheck -or $NoLaunch) {
    Write-Info "Done (bundle $($manifest.bundleVersion))."
    exit 0
}

Write-Info 'Starting ComfyUI for a first health check...'
Start-Process -FilePath (Join-Path $root 'Run Aksho ComfyUI.bat') -WorkingDirectory $root
if (Wait-ForComfy) {
    Write-Info 'ComfyUI is ready on http://127.0.0.1:8188'
    Write-Info 'Opening Atelier - pick the Local provider and connect.'
    Start-Process $Script:AtelierUrl
} else {
    Write-Err 'ComfyUI did not respond within 2 minutes. Check the ComfyUI console window for details.'
    exit 1
}
exit 0
