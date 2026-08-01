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
# Downloads are scoped to the feature packs the user picked. The picker appears on a
# fresh install and on Update runs (so features can be added or dropped later); the
# launch-time check reuses the saved selection. Dropping a pack stops updating it, it
# never deletes anything already on disk.
#
# State: <install root>\installed.json tracks bundleVersion + chosen packs + per-component sha256.
# PowerShell 5.1 compatible. Downloads via curl.exe (resume-capable), extraction via tar.exe.

param(
    [string]$InstallPath = '',
    [switch]$UpdateCheck,
    [switch]$NoLaunch,
    [switch]$SkipSelfUpdate
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:InstallerVersion = '1.1.0'
$Script:BaseUrl = 'https://dl.akshoai.com'
$Script:ManifestUrl = "$Script:BaseUrl/manifest.json"
$Script:ComfyPort = 8188
$Script:AtelierUrl = 'https://akshoai.com/atelier'
$Script:DefaultRoot = 'C:\AkshoComfy'

function Write-Info($msg) { Write-Host "[AKSHO COMFY] $msg" }
function Write-Err($msg) { Write-Host "[AKSHO COMFY] ERROR: $msg" -ForegroundColor Red }

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return "$([math]::Round($bytes / 1GB, 2)) GB" }
    if ($bytes -ge 1MB) { return "$([math]::Round($bytes / 1MB, 0)) MB" }
    return "$bytes B"
}

function Resolve-ExistingRoot {
    # An install that already exists is never relocated: explicit param wins, then
    # the copy of this script living inside <root>\installer.
    if ($InstallPath) { return $InstallPath }
    $scriptDir = Split-Path -Parent $PSCommandPath
    if ((Split-Path -Leaf $scriptDir) -eq 'installer') {
        $root = Split-Path -Parent $scriptDir
        if (Test-Path (Join-Path $root 'installed.json')) { return $root }
    }
    return ''
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
    return [pscustomobject]@{ bundleVersion = ''; packs = @(); components = [pscustomobject]@{} }
}

function Save-InstalledState([string]$root, $state) {
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $root 'installed.json') -Encoding UTF8
}

function Get-PackSize($manifest, $pack) {
    $bytes = 0L
    foreach ($id in $pack.components) {
        $c = $manifest.components | Where-Object { $_.id -eq $id }
        if ($c) { $bytes += [long]$c.sizeBytes }
    }
    return $bytes
}

function Get-SelectedComponents($manifest, $packIds) {
    # A component can belong to more than one pack; ticking either pulls it in once.
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pack in $manifest.packs) {
        if ($pack.required -or ($packIds -contains $pack.id)) {
            foreach ($id in $pack.components) { [void]$wanted.Add($id) }
        }
    }
    return @($manifest.components | Where-Object { $wanted.Contains($_.id) })
}

# ---------------------------------------------------------------------------
# Feature picker
# ---------------------------------------------------------------------------

function Show-FeaturePickerGui($manifest, [string]$root, $selectedIds, [bool]$allowFolder) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Aksho ComfyUI - choose what to install'
    $form.Size = New-Object System.Drawing.Size(560, 700)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Every Atelier feature is optional except the core. Untick anything you will not use; you can add it later from Update Aksho ComfyUI.'
    $intro.Location = New-Object System.Drawing.Point(16, 12)
    $intro.Size = New-Object System.Drawing.Size(510, 40)
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 180)
    $form.Controls.Add($intro)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(12, 56)
    $panel.Size = New-Object System.Drawing.Size(518, 462)
    $panel.AutoScroll = $true
    $panel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($panel)

    $boxes = @{}
    $y = 8
    foreach ($pack in $manifest.packs) {
        $size = Get-PackSize $manifest $pack
        $box = New-Object System.Windows.Forms.CheckBox
        $label = if ($pack.required) { "$($pack.label)   ($(Format-Size $size))   -   always installed" }
                 else { "$($pack.label)   ($(Format-Size $size))" }
        $box.Text = $label
        $box.Location = New-Object System.Drawing.Point(10, $y)
        $box.Size = New-Object System.Drawing.Size(470, 20)
        $box.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $box.ForeColor = [System.Drawing.Color]::White
        $box.Checked = $pack.required -or ($selectedIds -contains $pack.id)
        # AutoCheck rather than Enabled: a disabled checkbox is painted grey and
        # reads as unavailable, when the core is simply not up for debate.
        if ($pack.required) { $box.AutoCheck = $false }
        $box.Tag = $pack.id
        $panel.Controls.Add($box)
        $boxes[$pack.id] = $box
        $y += 21

        $desc = New-Object System.Windows.Forms.Label
        $desc.Text = $pack.description
        $desc.Location = New-Object System.Drawing.Point(30, $y)
        $desc.Size = New-Object System.Drawing.Size(460, 17)
        $desc.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 160)
        $panel.Controls.Add($desc)
        $y += 25
    }

    # Fit the list to its content so a short pack list leaves no dead space and a
    # long one scrolls, then hang everything below off wherever it ended up.
    $panel.Height = [Math]::Min(462, $y + 6)
    $below = $panel.Bottom + 12

    $total = New-Object System.Windows.Forms.Label
    $total.Location = New-Object System.Drawing.Point(16, $below)
    $total.Size = New-Object System.Drawing.Size(510, 20)
    $total.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 210)
    $form.Controls.Add($total)

    $refreshTotal = {
        $bytes = 0L
        foreach ($pack in $manifest.packs) {
            $box = $boxes[$pack.id]
            if ($box.Checked) { $bytes += Get-PackSize $manifest $pack }
        }
        $total.Text = "Selected: $(Format-Size $bytes) of models and extensions."
    }
    foreach ($box in $boxes.Values) { $box.Add_CheckedChanged($refreshTotal) }
    & $refreshTotal

    $folderLabel = New-Object System.Windows.Forms.Label
    $folderLabel.Text = 'Install folder'
    $folderLabel.Location = New-Object System.Drawing.Point(16, ($below + 28))
    $folderLabel.Size = New-Object System.Drawing.Size(120, 20)
    $form.Controls.Add($folderLabel)

    $folderBox = New-Object System.Windows.Forms.TextBox
    $folderBox.Text = $root
    $folderBox.Location = New-Object System.Drawing.Point(16, ($below + 50))
    $folderBox.Size = New-Object System.Drawing.Size(410, 24)
    $folderBox.BackColor = [System.Drawing.Color]::FromArgb(36, 36, 44)
    $folderBox.ForeColor = [System.Drawing.Color]::White
    $folderBox.BorderStyle = 'FixedSingle'
    $folderBox.Enabled = $allowFolder
    $form.Controls.Add($folderBox)

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'
    $browse.Location = New-Object System.Drawing.Point(434, ($below + 49))
    $browse.Size = New-Object System.Drawing.Size(94, 26)
    $browse.FlatStyle = 'Flat'
    $browse.Enabled = $allowFolder
    $browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Where should Aksho ComfyUI live?'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $folderBox.Text = Join-Path $dialog.SelectedPath 'AkshoComfy'
        }
    })
    $form.Controls.Add($browse)

    if (-not $allowFolder) {
        $note = New-Object System.Windows.Forms.Label
        $note.Text = 'Existing install - move the folder yourself to relocate it.'
        $note.Location = New-Object System.Drawing.Point(16, ($below + 78))
        $note.Size = New-Object System.Drawing.Size(510, 18)
        $note.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 160)
        $form.Controls.Add($note)
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Install'
    $ok.Location = New-Object System.Drawing.Point(330, ($below + 100))
    $ok.Size = New-Object System.Drawing.Size(96, 30)
    $ok.FlatStyle = 'Flat'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(432, ($below + 100))
    $cancel.Size = New-Object System.Drawing.Size(96, 30)
    $cancel.FlatStyle = 'Flat'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    $form.ClientSize = New-Object System.Drawing.Size(542, ($below + 142))
    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $chosen = @()
    foreach ($pack in $manifest.packs) {
        if ($boxes[$pack.id].Checked) { $chosen += $pack.id }
    }
    $picked = $folderBox.Text.Trim()
    if (-not $picked) { $picked = $root }
    return @{ Root = $picked; Packs = $chosen }
}

function Show-FeaturePickerConsole($manifest, [string]$root, $selectedIds, [bool]$allowFolder) {
    Write-Host ''
    Write-Info 'Choose what to install (Enter keeps the shown answer):'
    $chosen = @()
    foreach ($pack in $manifest.packs) {
        $size = Format-Size (Get-PackSize $manifest $pack)
        if ($pack.required) {
            Write-Host "  [x] $($pack.label) ($size) - required"
            $chosen += $pack.id
            continue
        }
        $default = if ($selectedIds -contains $pack.id) { 'Y' } else { 'N' }
        Write-Host "      $($pack.description)"
        $answer = Read-Host "  $($pack.label) ($size)? [$default]"
        if (-not $answer) { $answer = $default }
        if ($answer.Trim().ToLowerInvariant().StartsWith('y')) { $chosen += $pack.id }
    }
    if ($allowFolder) {
        $answer = Read-Host "Install folder [$root]"
        if ($answer) { $root = $answer.Trim() }
    }
    return @{ Root = $root; Packs = $chosen }
}

function Show-FeaturePicker($manifest, [string]$root, $selectedIds, [bool]$allowFolder) {
    try {
        return Show-FeaturePickerGui $manifest $root $selectedIds $allowFolder
    } catch {
        # No desktop (Server Core, remote session without a window station).
        Write-Info 'Graphical picker unavailable, falling back to prompts.'
        return Show-FeaturePickerConsole $manifest $root $selectedIds $allowFolder
    }
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Invoke-RenameMigrations([string]$root, $components) {
    # A component whose filename changed between bundles is moved rather than
    # re-downloaded: the bytes are identical, only the name is not.
    foreach ($c in $components) {
        if (-not $c.renameFrom) { continue }
        $target = Join-Path $root $c.targetPath
        $old = Join-Path $root $c.renameFrom
        if ((Test-Path $target) -or -not (Test-Path $old)) { continue }
        Write-Info "Renaming $($c.renameFrom) -> $($c.targetPath)"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Move-Item -Force $old $target
    }
}

function Get-ComponentsToInstall([string]$root, $components, $state) {
    $needed = @()
    foreach ($c in $components) {
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
                # -s mirrors the launcher: no user site-packages, so pip can neither
                # install to nor satisfy requirements from a location ComfyUI won't see.
                & $python -s -m pip install -q -r $req
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

function Install-BasePipPackages([string]$root, $manifest) {
    # Packages the bundle needs beyond the extensions' own requirements files
    # (e.g. imports an extension's dependency pulls in only at runtime).
    if (-not $manifest.basePipPackages) { return }
    $python = Join-Path $root 'python_embeded\python.exe'
    if (-not (Test-Path $python)) { return }
    Write-Info 'Ensuring base python packages...'
    & $python -s -m pip install -q @($manifest.basePipPackages)
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

$root = Resolve-ExistingRoot
$isFresh = -not $root
if ($isFresh) { $root = $Script:DefaultRoot }
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

# Everything is ticked on a first run; afterwards the saved selection is the default.
# A single-element array survives a JSON round trip as a bare string, hence the @().
$selected = @($state.packs)
if ($isFresh -or $selected.Count -eq 0) {
    $selected = @($manifest.packs | ForEach-Object { $_.id })
}

if (-not $UpdateCheck) {
    $choice = Show-FeaturePicker $manifest $root $selected (-not (Test-Path (Join-Path $root 'installed.json')))
    if (-not $choice) { Write-Info 'Cancelled.'; exit 0 }
    $selected = @($choice.Packs)
    if ($choice.Root -ne $root) {
        $root = $choice.Root
        $state = Get-InstalledState $root
    }
}

New-Item -ItemType Directory -Force -Path $root | Out-Null
$components = Get-SelectedComponents $manifest $selected
Invoke-RenameMigrations $root $components

$needed = Get-ComponentsToInstall $root $components $state
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

Install-BasePipPackages $root $manifest

$state.bundleVersion = $manifest.bundleVersion
if (-not $state.PSObject.Properties['packs']) {
    $state | Add-Member -NotePropertyName packs -NotePropertyValue @() -Force
}
$state.packs = $selected
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


