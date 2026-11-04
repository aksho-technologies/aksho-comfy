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
# Packs come in tiers: the required core, the base checkpoints (pick one or more, or
# none to bring your own), the model support packs a checkpoint or tool runs on
# (named in its worksWith, and ticked with it), and the tools.
#
# State: <install root>\installed.json tracks bundleVersion + chosen packs + per-component
# sha256 of the components those packs hold.
# PowerShell 5.1 compatible. Downloads via curl.exe (resume-capable), extraction via tar.exe.

param(
    [string]$InstallPath = '',
    [switch]$UpdateCheck,
    [switch]$NoLaunch,
    [switch]$SkipSelfUpdate,
    [string]$BaseUrl = 'https://dl.akshoai.com'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:InstallerVersion = '1.2.0'
$Script:BaseUrl = $BaseUrl.TrimEnd('/')
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

function Get-PacksOnDisk([string]$root, $manifest) {
    # The packs an existing install evidently chose: every one whose files are
    # all present. Used when the state file names none, so a repaired record
    # follows what is on disk instead of downloading every pack there is.
    $found = @()
    foreach ($pack in $manifest.packs) {
        # A pack with nothing in it yet (a checkpoint still to come) is never on disk.
        if (-not @($pack.components).Count) { continue }
        $complete = $true
        foreach ($id in $pack.components) {
            $c = $manifest.components | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $c -or -not (Test-Path -LiteralPath (Join-Path $root $c.targetPath))) { $complete = $false; break }
        }
        if ($complete) { $found += $pack.id }
    }
    return $found
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

function Get-MigratedSelection($manifest, $state, $packIds) {
    # Selections saved before the base checkpoints (installer 1.2.0) carry onto
    # the new packs. Dreamhex and the Illustrious pieces moved out of Core and the
    # MOSS packs were split; the files never moved on disk, so nothing downloads
    # again. A record exists only for components a chosen pack holds (see the
    # end of Main), so a pack dropped on a later run is never brought back here.
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $packIds) {
        switch ($id) {
            'moss-image' { $out.Add('base-aio'); $out.Add('moss') }
            'moss-image-lite' { $out.Add('base-aio-lite'); $out.Add('moss-lite') }
            default { $out.Add($id) }
        }
    }
    $recorded = $state.components.PSObject.Properties
    if (-not $out.Contains('base-2-5d') -and $recorded['model-checkpoint-dreamhex-v5']) { $out.Add('base-2-5d') }
    if (-not $out.Contains('illustrious') -and $recorded['model-ipadapter-noob']) { $out.Add('illustrious') }
    $known = @($manifest.packs | ForEach-Object { $_.id })
    return @($out | Where-Object { $known -contains $_ } | Select-Object -Unique)
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
    $form.Size = New-Object System.Drawing.Size(560, 780)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Core is always installed. Pick at least one base checkpoint, or None to bring your own; each brings the model support it runs on. You can change all of this later from Update Aksho ComfyUI.'
    $intro.Font = $form.Font
    $intro.Location = New-Object System.Drawing.Point(16, 12)
    $intro.Size = New-Object System.Drawing.Size(510, ($intro.GetPreferredSize((New-Object System.Drawing.Size(510, 0))).Height))
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 180)
    $form.Controls.Add($intro)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(12, ($intro.Bottom + 8))
    $panel.Size = New-Object System.Drawing.Size(518, 540)
    $panel.AutoScroll = $true
    $panel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($panel)

    # A first install has no folder yet; an existing one keeps where it is.
    $firstRun = $allowFolder
    $packsById = @{}
    foreach ($pack in $manifest.packs) { $packsById[$pack.id] = $pack }
    $groups = @(
        @{ Tiers = @('core'); Title = 'Core' },
        @{ Tiers = @('base'); Title = 'Base checkpoint: pick one or more' },
        @{ Tiers = @('family'); Title = 'Model support' },
        @{ Tiers = @('recommended', 'optional'); Title = 'Tools' }
    )
    $boxes = @{}
    $none = $null
    $y = 8
    foreach ($group in $groups) {
        $members = @($manifest.packs | Where-Object { $group.Tiers -contains $_.tier })
        if (-not $members.Count) { continue }
        $head = New-Object System.Windows.Forms.Label
        $head.Text = $group.Title
        $head.Location = New-Object System.Drawing.Point(10, $y)
        $head.Size = New-Object System.Drawing.Size(470, 20)
        $head.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $head.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 210)
        $panel.Controls.Add($head)
        $y += 26

        foreach ($pack in $members) {
            $size = Get-PackSize $manifest $pack
            if (-not @($pack.components).Count) {
                # A checkpoint with nothing in it yet is shown, not offered: a
                # plain line where its box would be. (A disabled checkbox paints
                # its label embossed on this dark form, hard to read.)
                $soon = New-Object System.Windows.Forms.Label
                $soon.Text = "$($pack.label)   -   coming soon"
                $soon.Location = New-Object System.Drawing.Point(27, ($y + 2))
                $soon.Size = New-Object System.Drawing.Size(453, 18)
                $soon.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
                $soon.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 160)
                $panel.Controls.Add($soon)
            } else {
                $box = New-Object System.Windows.Forms.CheckBox
                $box.Text = if ($pack.required) { "$($pack.label)   ($(Format-Size $size))   -   always installed" }
                            else { "$($pack.label)   ($(Format-Size $size))" }
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
            }
            $y += 21

            # A tool names the models it works with.
            $text = $pack.description
            if ($pack.worksWith -and $pack.tier -ne 'base') {
                $models = @($pack.worksWith | ForEach-Object { $packsById[$_].label -replace '\s+support\b', '' })
                $text = "$text Works with $($models -join ' or ')."
            }
            $desc = New-Object System.Windows.Forms.Label
            $desc.Text = $text
            # Measured in the form's font before it joins the panel, so a long
            # description wraps onto its own lines instead of being cut off.
            $desc.Font = $form.Font
            $desc.Location = New-Object System.Drawing.Point(30, $y)
            $desc.Size = New-Object System.Drawing.Size(460, ($desc.GetPreferredSize((New-Object System.Drawing.Size(460, 0))).Height))
            $desc.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 160)
            $panel.Controls.Add($desc)
            $y += $desc.Height + 8
        }

        if ($group.Tiers -contains 'base') {
            $none = New-Object System.Windows.Forms.CheckBox
            $none.Text = 'None, I will pick my own image checkpoint'
            $none.Location = New-Object System.Drawing.Point(10, $y)
            $none.Size = New-Object System.Drawing.Size(470, 20)
            $none.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $none.ForeColor = [System.Drawing.Color]::White
            # An install that already chose its packs and holds no checkpoint chose None.
            $none.Checked = -not $firstRun -and -not @($members | Where-Object { $boxes[$_.id].Checked }).Count
            $panel.Controls.Add($none)
            $y += 29
        }
        $y += 6
    }

    # Fit the list to its content so a short pack list leaves no dead space and a
    # long one scrolls, then hang everything below off wherever it ended up.
    $panel.Height = [Math]::Min(540, $y + 6)
    $below = $panel.Bottom + 12

    $total = New-Object System.Windows.Forms.Label
    $total.Location = New-Object System.Drawing.Point(16, $below)
    $total.Size = New-Object System.Drawing.Size(510, 20)
    $total.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 210)
    $form.Controls.Add($total)

    $refreshTotal = {
        # A component two packs share downloads once, so it counts once.
        $held = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($pack in $manifest.packs) {
            if ($boxes[$pack.id].Checked) { foreach ($id in $pack.components) { [void]$held.Add($id) } }
        }
        $bytes = 0L
        foreach ($c in $manifest.components) { if ($held.Contains($c.id)) { $bytes += [long]$c.sizeBytes } }
        $total.Text = "Selected: $(Format-Size $bytes) of models and extensions."
        # Install waits for a checkpoint pick or an explicit None.
        $ok.Enabled = (-not $none) -or $none.Checked -or [bool]@($manifest.packs | Where-Object { $_.tier -eq 'base' -and $boxes[$_.id].Checked }).Count
    }

    # Ticking a checkpoint or a tool ticks the model support it runs on; unticking a
    # model support unticks what can no longer run. On a first install a checkpoint
    # also brings the recommended tools made for its model.
    $ui = @{ busy = $false }
    $onTick = {
        param($source)
        if ($ui.busy) { return }
        $ui.busy = $true
        try {
            $pack = $packsById[$source.Tag]
            if ($source.Checked) {
                $supports = @($pack.worksWith | Where-Object { $_ })
                if ($supports.Count -and -not @($supports | Where-Object { $boxes[$_].Checked }).Count) { $boxes[$supports[0]].Checked = $true }
                if ($pack.tier -eq 'base') {
                    $none.Checked = $false
                    if ($firstRun) {
                        foreach ($tool in @($manifest.packs | Where-Object { $_.tier -eq 'recommended' -and $_.worksWith })) {
                            if (@($tool.worksWith | Where-Object { $supports -contains $_ }).Count) { $boxes[$tool.id].Checked = $true }
                        }
                    }
                }
            } elseif ($pack.tier -eq 'family') {
                foreach ($other in $manifest.packs) {
                    if (-not $other.worksWith -or -not $boxes[$other.id].Checked) { continue }
                    if (-not @($other.worksWith | Where-Object { $boxes[$_].Checked }).Count) { $boxes[$other.id].Checked = $false }
                }
            }
        } finally { $ui.busy = $false }
        & $refreshTotal
    }
    foreach ($box in $boxes.Values) { $box.Add_CheckedChanged($onTick) }
    if ($none) {
        $none.Add_CheckedChanged({
            if ($none.Checked) {
                foreach ($pack in @($manifest.packs | Where-Object { $_.tier -eq 'base' -and $boxes[$_.id] })) { $boxes[$pack.id].Checked = $false }
            }
            & $refreshTotal
        })
    }

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
    & $refreshTotal

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
    $firstRun = $allowFolder
    $packsById = @{}
    foreach ($pack in $manifest.packs) { $packsById[$pack.id] = $pack }
    $chosen = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pack in @($manifest.packs | Where-Object { $_.required })) {
        Write-Host "  [x] $($pack.label) ($(Format-Size (Get-PackSize $manifest $pack))) - required"
        $chosen.Add($pack.id)
    }

    # Base checkpoints: one or more by number, or 0 to bring your own.
    $bases = @($manifest.packs | Where-Object { $_.tier -eq 'base' -and @($_.components).Count })
    if ($bases.Count) {
        Write-Host '  Base checkpoints (pick one or more, or 0 for none and bring your own):'
        for ($i = 0; $i -lt $bases.Count; $i++) {
            Write-Host "    $($i + 1)) $($bases[$i].label) ($(Format-Size (Get-PackSize $manifest $bases[$i]))) - $($bases[$i].description)"
        }
        $picked = @(for ($i = 0; $i -lt $bases.Count; $i++) { if ($selectedIds -contains $bases[$i].id) { $i + 1 } })
        $default = if ($picked.Count) { $picked -join ',' } elseif ($firstRun) { '' } else { '0' }
        while ($true) {
            $answer = Read-Host "  Base checkpoints [$default]"
            if (-not $answer) { $answer = $default }
            $numbers = @($answer -split '[,\s]+' | Where-Object { $_ })
            if ($numbers.Count -eq 1 -and $numbers[0] -eq '0') { break }
            $valid = @($numbers | Where-Object { $_ -match '^\d+$' -and [int]$_ -ge 1 -and [int]$_ -le $bases.Count })
            if ($valid.Count -and $valid.Count -eq $numbers.Count) {
                foreach ($n in $valid) { $chosen.Add($bases[[int]$n - 1].id) }
                break
            }
            Write-Host '  Type the numbers of the checkpoints you want, separated by commas, or 0 for none.'
        }
    }
    # Each checkpoint brings the model support it runs on.
    $supports = @($chosen | ForEach-Object { $packsById[$_].worksWith } | Where-Object { $_ } | Select-Object -Unique)

    foreach ($pack in $manifest.packs) {
        if ($pack.required -or $pack.tier -eq 'base' -or -not @($pack.components).Count) { continue }
        $size = Format-Size (Get-PackSize $manifest $pack)
        if ($supports -contains $pack.id) {
            Write-Host "  [x] $($pack.label) ($size) - your checkpoint runs on it"
            $chosen.Add($pack.id)
            continue
        }
        # On a first install the recommended tools made for a picked model come along.
        $forPicked = $firstRun -and $pack.tier -eq 'recommended' -and @($pack.worksWith | Where-Object { $chosen.Contains($_) }).Count
        $default = if (($selectedIds -contains $pack.id) -or $forPicked) { 'Y' } else { 'N' }
        $text = $pack.description
        if ($pack.worksWith) {
            $models = @($pack.worksWith | ForEach-Object { $packsById[$_].label -replace '\s+support\b', '' })
            $text = "$text Works with $($models -join ' or ')."
        }
        Write-Host "      $text"
        $answer = Read-Host "  $($pack.label) ($size)? [$default]"
        if (-not $answer) { $answer = $default }
        if (-not $answer.Trim().ToLowerInvariant().StartsWith('y')) { continue }
        $chosen.Add($pack.id)
        # A tool brings the model support it runs on, when none of its own is in yet.
        $needs = @($pack.worksWith | Where-Object { $_ })
        if ($needs.Count -and -not @($needs | Where-Object { $chosen.Contains($_) }).Count) {
            Write-Host "  [x] $($packsById[$needs[0]].label) - $($pack.label) runs on it"
            $chosen.Add($needs[0])
        }
    }
    if ($allowFolder) {
        $answer = Read-Host "Install folder [$root]"
        if ($answer) { $root = $answer.Trim() }
    }
    return @{ Root = $root; Packs = @($chosen | Select-Object -Unique) }
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
        if (-not $recorded -and $c.kind -eq 'file') {
            # A file that is already on disk at the right size and hash (placed
            # by hand, or by an installer that never recorded it) is adopted
            # into the state instead of being downloaded again.
            $target = Join-Path $root $c.targetPath
            if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -eq [long]$c.sizeBytes)) {
                Write-Info "Checking $($c.id) already on disk..."
                $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
                if ($actual -eq $c.sha256.ToLowerInvariant()) {
                    $state.components | Add-Member -NotePropertyName $c.id -NotePropertyValue ([pscustomobject]@{
                        sha256 = $c.sha256; sizeBytes = [long]$c.sizeBytes; installedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }) -Force
                    Save-InstalledState $root $state
                    continue
                }
            }
        }
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

function Clear-DirectoryExcept([string]$dir, [string[]]$keeps) {
    # Empties $dir except the subtrees listed in $keeps (absolute paths). A kept
    # subtree deeper inside a child means descending into that child rather
    # than deleting it whole.
    foreach ($child in Get-ChildItem -LiteralPath $dir -Force) {
        $childFull = $child.FullName.TrimEnd('\')
        if ($keeps -contains $childFull) { continue }
        $prefix = $childFull + '\'
        $holdsKept = $child.PSIsContainer -and @($keeps | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($holdsKept) { Clear-DirectoryExcept $childFull $keeps; continue }
        Remove-Item -LiteralPath $childFull -Recurse -Force
    }
}

function Clear-ReplacedPaths([string]$root, $c) {
    # An archive that REPLACES a runtime (the embedded Python, ComfyUI's own
    # code) must not land on top of the old one: extraction never deletes, so
    # two torch versions' files would sit side by side after a ComfyUI bump.
    # Each path in 'replaces' is emptied first, except the subtrees in 'keeps',
    # which hold what the user owns (models, custom nodes, outputs, history).
    if (-not $c.replaces) { return }
    $keeps = @()
    if ($c.keeps) { $keeps = @($c.keeps | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $root $_)).TrimEnd('\') }) }
    foreach ($rel in $c.replaces) {
        $dir = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Write-Info "Clearing $rel before the new runtime lands (keeping what you own)..."
        Clear-DirectoryExcept ([IO.Path]::GetFullPath($dir).TrimEnd('\')) $keeps
    }
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
        Clear-ReplacedPaths $root $c
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
.\python_embeded\python.exe -s ComfyUI\main.py --port 8188 --enable-cors-header --enable-assets --enable-asset-hashing --disable-auto-launch --preview-method auto
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
    # After the first install this script IS <root>\installer\install.ps1 (see
    # Resolve-ExistingRoot, which expects exactly that), so copying it over
    # itself threw a red IOException on every update run. Nothing was broken,
    # but it reads like a crash.
    $stashed = Join-Path $installerDir 'install.ps1'
    $sourcePath = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $targetPath = if (Test-Path -LiteralPath $stashed) { (Resolve-Path -LiteralPath $stashed).Path } else { $stashed }
    if ($sourcePath -ne $targetPath) {
        Copy-Item -Force -LiteralPath $sourcePath -Destination $stashed
    }
}

function Invoke-SelfUpdate([string]$root, $manifest) {
    if ($SkipSelfUpdate) { return $false }
    if (-not $manifest.installerVersion -or $manifest.installerVersion -eq $Script:InstallerVersion) { return $false }
    Write-Info "Installer update $Script:InstallerVersion -> $($manifest.installerVersion), fetching..."
    $newPath = Join-Path $env:TEMP 'aksho-comfy-install-new.ps1'
    & curl.exe -fsSL -m 60 $manifest.installerUrl -o $newPath
    if ($LASTEXITCODE -ne 0) { Write-Info 'Installer self-update failed, continuing with current version.'; return $false }
    $flags = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newPath, '-InstallPath', $root, '-SkipSelfUpdate', '-BaseUrl', $Script:BaseUrl)
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

# Every run is logged next to the installer, so a failed update can be read
# back instead of retold. The log is overwritten per run; it is not history.
if (Test-Path -LiteralPath $root) {
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'installer') | Out-Null
        Start-Transcript -Path (Join-Path $root 'installer\last-run.log') -Force | Out-Null
    } catch { }
}

if ($UpdateCheck) {
    # Fast path for the launcher: never block a launch on network problems.
    $manifest = Get-Manifest 2
    if (-not $manifest) { Write-Info 'Offline - skipping update check.'; exit 0 }
    if ($manifest.bundleVersion -eq $state.bundleVersion) { exit 0 }
    # A self-update relaunches this script with -SkipSelfUpdate after the user
    # already answered the question once; asking again read as an update loop.
    if (-not $SkipSelfUpdate) {
        $answer = Read-Host "Update available ($($state.bundleVersion) -> $($manifest.bundleVersion)). Update now? [Y/n]"
        if ($answer -and $answer.Trim().ToLowerInvariant() -eq 'n') { exit 0 }
    }
    # Fall through into the full flow below with the fetched manifest.
} else {
    $manifest = Get-Manifest 30
    if (-not $manifest) { Write-Err 'Could not fetch the update manifest. Check your connection and try again.'; exit 1 }
}

# $null = ... because the function returns $false when no installer update is
# needed, and a bare call drops that boolean on the output stream: users saw a
# stray "False" printed in the middle of the run.
$null = Invoke-SelfUpdate $root $manifest

# A first run ticks the tools that work with every model; the checkpoint picked in
# the picker brings its model support and the tools made for it. Afterwards the
# saved selection is the default.
# A single-element array survives a JSON round trip as a bare string, hence the @().
# Nulls are dropped: a state file written as "packs": [ null ] read as one chosen
# pack that matched nothing, so every optional pack silently stopped updating.
$firstRunPacks = @($manifest.packs | Where-Object { $_.tier -eq 'recommended' -and -not $_.worksWith } | ForEach-Object { $_.id })
$selected = @($state.packs | Where-Object { $_ })
if ($isFresh) {
    $selected = $firstRunPacks
} elseif ($selected.Count -eq 0) {
    $selected = @(Get-PacksOnDisk $root $manifest)
    if ($selected.Count -eq 0) { $selected = $firstRunPacks }
    Write-Info "No pack selection on record; keeping the packs found on disk: $($selected -join ', ')"
}
$selected = @(Get-MigratedSelection $manifest $state $selected)

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

# @() keeps a single component an array, so its count reads right.
$needed = @(Get-ComponentsToInstall $root $components $state)
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

    # A replaced runtime is a fresh Python: every extension's packages have to
    # go back in, not only the ones whose own component changed this run.
    $runtimeReplaced = @($needed | Where-Object { $_.replaces }).Count -gt 0
    $postInstallSet = if ($runtimeReplaced) { $components } else { $needed }
    Invoke-PostInstall $root ($postInstallSet | Where-Object { $_.postInstall })
}

Install-BasePipPackages $root $manifest

$state.bundleVersion = $manifest.bundleVersion
if (-not $state.PSObject.Properties['packs']) {
    $state | Add-Member -NotePropertyName packs -NotePropertyValue @() -Force
}
$state.packs = $selected
# Only the components the chosen packs hold stay on record. A dropped pack's
# files stay on disk, untracked, so a later run never reads them as a choice;
# picking the pack again adopts them by hash instead of downloading them.
$held = @{}
foreach ($c in $components) { $held[$c.id] = $true }
foreach ($name in @($state.components.PSObject.Properties | ForEach-Object { $_.Name })) {
    if (-not $held[$name]) { $state.components.PSObject.Properties.Remove($name) }
}
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


