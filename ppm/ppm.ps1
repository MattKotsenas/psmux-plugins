#!/usr/bin/env pwsh
# =============================================================================
# PPM - Psmux Plugin Manager
# The plugin manager for psmux (like tpm for tmux)
# https://github.com/psmux/psmux-plugins/tree/main/ppm
# =============================================================================
#
# Usage in ~/.psmux.conf:
#   set -g @plugin 'psmux-plugins/ppm'
#   set -g @plugin 'psmux-plugins/psmux-sensible'
#   run '~/.psmux/plugins/ppm/ppm.ps1'
#
# Key bindings (after loading):
#   Prefix + I    - Install plugins
#   Prefix + U    - Update plugins
#   Prefix + M    - Remove/clean unused plugins
# =============================================================================

$ErrorActionPreference = 'Continue'

# --- Monorepo mapping ---
# Maps GitHub "org" prefixes to actual monorepo owner/repo, as a maintainer-curated
# registry of well-known shorthands. When a plugin spec like 'psmux-plugins/<name>'
# is used, PPM first tries to clone it as an individual repo. If that fails (because
# psmux-plugins is not a real GitHub org), it falls back to cloning the monorepo and
# extracting the <name> subdirectory.
#
# Users who want to install from any other monorepo (e.g. a fork) can use the
# self-describing 3-segment form without touching this map:
#   set -g @plugin 'owner/monorepo/subdir'
# Optionally with a branch suffix (TPM-compatible):
#   set -g @plugin 'owner/monorepo/subdir#branch'
#   set -g @plugin 'owner/repo#branch'
$script:MONOREPO_MAP = @{
    'psmux-plugins' = 'psmux/psmux-plugins'
}

# --- Resolve paths ---
$PPM_ROOT = $PSScriptRoot
$PLUGIN_DIR = Split-Path -Parent $PPM_ROOT
$PSMUX_HOME = Split-Path -Parent $PLUGIN_DIR

# Detect the psmux binary (psmux, pmux, or tmux)
function Get-PsmuxBinary {
    foreach ($name in @('psmux', 'pmux', 'tmux')) {
        $bin = Get-Command $name -ErrorAction SilentlyContinue
        if ($bin) { return $bin.Source }
    }
    # Fallback: check common install locations
    foreach ($name in @('psmux.exe', 'pmux.exe', 'tmux.exe')) {
        $paths = @(
            "$env:LOCALAPPDATA\psmux\$name",
            "$env:USERPROFILE\.cargo\bin\$name",
            "$env:ProgramFiles\psmux\$name"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) { return $p }
        }
    }
    return 'psmux'
}

$script:PSMUX = Get-PsmuxBinary

function Invoke-Psmux {
    param([Parameter(ValueFromRemainingArguments)]$Args)
    & $script:PSMUX @Args 2>&1
}

# --- Status toast helpers ---
# Use a finite duration that outlasts each step; successive Show-PpmStatus
# calls refresh the toast as work progresses.
$script:PROGRESS_TOAST_MS = 60000

function Show-PpmStatus {
    param([string]$Message, [int]$DurationMs = $script:PROGRESS_TOAST_MS)
    & $script:PSMUX display-message -d $DurationMs $Message 2>&1 | Out-Null
}

# Overwrite any lingering progress toast with a near-instant blank so the
# result popup (from captured stdout) isn't sharing the screen with a stale
# "Installing ..." status. The blank toast expires within ~1ms, so by the
# time the popup renders the status bar is clear.
function Clear-PpmStatus {
    & $script:PSMUX display-message -d 1 ' ' 2>&1 | Out-Null
}

# --- Parse @plugin declarations from psmux options ---
function Get-DeclaredPlugins {
    param([string]$SessionTarget)
    $plugins = @()

    # Method 1: Query show-options for @plugin values
    $opts = if ($SessionTarget) {
        Invoke-Psmux show-options -t $SessionTarget -g 2>&1
    } else {
        Invoke-Psmux show-options -g 2>&1
    }

    $optsText = ($opts | Out-String)
    # Match lines like: @plugin "psmux-plugins/psmux-sensible"
    $matches = [regex]::Matches($optsText, '@plugin\s+[''"]?([^''"]+)[''"]?')
    foreach ($m in $matches) {
        $val = $m.Groups[1].Value.Trim()
        if ($val) {
            $plugins += $val
        }
    }

    # Method 2: Also scan config files for @plugin declarations
    $configPaths = @(
        "$env:USERPROFILE\.psmux.conf",
        "$env:USERPROFILE\.psmuxrc",
        "$env:USERPROFILE\.tmux.conf",
        "$env:USERPROFILE\.config\psmux\psmux.conf"
    )
    foreach ($cfg in $configPaths) {
        if (Test-Path $cfg) {
            $content = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $cfgMatches = [regex]::Matches($content, "set\s+-g\s+@plugin\s+['""]([^'""]+)['""]")
                foreach ($m in $cfgMatches) {
                    $val = $m.Groups[1].Value.Trim()
                    if ($val -and $val -notin $plugins) {
                        $plugins += $val
                    }
                }
            }
            break  # Only read the first found config file (psmux behavior)
        }
    }

    return $plugins
}

# --- Resolve plugin spec to git URL and local path ---
# Supported spec shapes (each may have an optional '#branch' suffix):
#   https://...                URL clone direct
#   git@...                    URL clone direct (SSH)
#   owner/monorepo/subdir      3-segment: clone owner/monorepo, extract subdir
#   owner/repo                 2-segment: clone owner/repo (with MONOREPO_MAP fallback)
#   name                       bare name: assumed under psmux-plugins org
function Resolve-PluginSpec {
    param([string]$Spec)

    # Parse optional '#branch' suffix (TPM-compatible: split on first '#').
    $branch = $null
    if ($Spec -match '^([^#]+)#(.+)$') {
        $Spec = $Matches[1]
        $branch = $Matches[2]
    }

    if ($Spec -match '^https?://' -or $Spec -match '^git@') {
        # Full URL: derive name from the final path segment, stripping .git
        $name = (($Spec -split '[/:]')[-1]) -replace '\.git$',''
        $localPath = Join-Path $PLUGIN_DIR $name
        return @{ Name = $name; Url = $Spec; Path = $localPath; Org = $null; Branch = $branch; MonorepoSource = $null; SubdirName = $null }
    }
    elseif ($Spec -match '^([^/]+)/([^/]+)/([^/]+)$') {
        # 3-segment: owner/monorepo/subdir - explicit monorepo extraction.
        $owner    = $Matches[1]
        $monorepo = $Matches[2]
        $subdir   = $Matches[3]
        $localPath = Join-Path $PLUGIN_DIR $subdir
        return @{ Name = $subdir; Url = "https://github.com/$owner/$monorepo.git"; Path = $localPath; Org = $owner; Branch = $branch; MonorepoSource = "$owner/$monorepo"; SubdirName = $subdir }
    }
    elseif ($Spec -match '^([^/]+)/([^/]+)$') {
        # 2-segment: GitHub owner/repo shorthand.
        $org = $Matches[1]
        $name = $Matches[2]
        $localPath = Join-Path $PLUGIN_DIR $name
        return @{ Name = $name; Url = "https://github.com/$Spec.git"; Path = $localPath; Org = $org; Branch = $branch; MonorepoSource = $null; SubdirName = $null }
    }
    else {
        # Bare name: assume psmux-plugins org.
        $localPath = Join-Path $PLUGIN_DIR $Spec
        return @{ Name = $Spec; Url = "https://github.com/psmux-plugins/$Spec.git"; Path = $localPath; Org = 'psmux-plugins'; Branch = $branch; MonorepoSource = $null; SubdirName = $null }
    }
}

# --- Derive a plugin's local directory name from its @plugin spec ---
# Strips any '#branch' suffix before taking the final path segment. Branch names
# may contain '/' (e.g. 'temp/integration'), so a naive ($spec -split '/')[-1]
# returns the branch tail ('integration') instead of the plugin name, which
# breaks the startup sourcing filter, the update name->spec lookup, and the
# unused-plugin clean pass. Mirrors Resolve-PluginSpec's own name derivation.
function Get-PluginName {
    param([string]$Spec)
    $base = ($Spec -split '#', 2)[0]
    return (($base -split '[/:]')[-1]) -replace '\.git$', ''
}

# --- Clone from monorepo fallback ---
# When the individual repo clone fails and the org is in MONOREPO_MAP,
# clone the full monorepo to a temp directory and extract just the
# subdirectory for the requested plugin.
#
# 3-segment specs (owner/monorepo/subdir) call into this function with
# $Source set explicitly, bypassing the MONOREPO_MAP lookup.
# $Branch (if set) is passed to git clone --branch.
function Install-FromMonorepo {
    param(
        [string]$Org,
        [string]$Name,
        [string]$TargetPath,
        [string]$Source,
        [string]$Branch
    )
    # Resolve monorepo source: explicit $Source takes precedence over the map.
    $monorepo = if ($Source) { $Source } else { $script:MONOREPO_MAP[$Org] }
    if (-not $monorepo) { return $false }

    $cloneUrl = "https://github.com/$monorepo.git"
    $tmpDir = Join-Path $env:TEMP "ppm-monorepo-$Org-$(Get-Random)"

    $branchNote = if ($Branch) { " branch '$Branch'" } else { "" }
    Write-Host "  Trying monorepo ($monorepo)$branchNote ..." -ForegroundColor DarkCyan
    $cloneArgs = @('clone', '--depth', '1')
    if ($Branch) { $cloneArgs += @('--branch', $Branch) }
    $cloneArgs += @($cloneUrl, $tmpDir)
    try {
        & git @cloneArgs 2>&1 | Out-Null
    } catch {
        if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
        return $false
    }

    $subDir = Join-Path $tmpDir $Name
    if (-not (Test-Path $subDir)) {
        Write-Host "  '$Name' not found in monorepo $monorepo" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        return $false
    }

    # Copy the subdirectory contents to the target location.
    # If target already exists (update scenario), clean old content first
    # but preserve the .monorepo.json marker.
    if (Test-Path $TargetPath) {
        Get-ChildItem -Path $TargetPath -Exclude '.monorepo.json' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    }
    # Copy the contents of $subDir (not the directory itself) into $TargetPath.
    # Using `Copy-Item -Path $subDir -Destination $TargetPath -Recurse` when
    # $TargetPath already exists nests $subDir as a child (~/.psmux/plugins/<name>/<name>/),
    # which breaks plugin loading. Enumerate children to merge instead.
    Get-ChildItem -Path $subDir -Force | Copy-Item -Destination $TargetPath -Recurse -Force

    # Create a .monorepo marker so Update-Plugin knows how to update this.
    # The optional 'branch' field is persisted only when a branch was specified
    # at install time, so subsequent updates pull from the same ref.
    $metaHash = @{
        monorepo = $monorepo
        org      = $Org
        name     = $Name
        url      = $cloneUrl
    }
    if ($Branch) { $metaHash.branch = $Branch }
    $metaHash | ConvertTo-Json | Set-Content (Join-Path $TargetPath '.monorepo.json') -Encoding UTF8

    # Clean up temp dir
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    return $true
}

# --- Find the active config file ---
function Get-PsmuxConfigFile {
    $configPaths = @(
        "$env:USERPROFILE\.psmux.conf",
        "$env:USERPROFILE\.psmuxrc",
        "$env:USERPROFILE\.tmux.conf",
        "$env:USERPROFILE\.config\psmux\psmux.conf"
    )
    foreach ($cfg in $configPaths) {
        if (Test-Path $cfg) { return $cfg }
    }
    return $null
}

# --- Persist plugin activation line to config file ---
# Writes a source-file or run-shell line so the plugin loads on next server start.
function Persist-PluginActivation {
    param([string]$Spec, [string]$PluginPath)
    $name = Split-Path -Leaf $PluginPath
    $configFile = Get-PsmuxConfigFile
    if (-not $configFile) { return }

    $content = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return }

    # Build a tilde-relative forward-slash path for the activation line
    $homeFwd = ($env:USERPROFILE -replace '\\', '/')

    # Determine the activation line based on what the plugin ships
    $pluginConf = Join-Path $PluginPath 'plugin.conf'
    $pluginPs1  = Join-Path $PluginPath "$name.ps1"
    if (Test-Path $pluginConf) {
        $relPath = ($pluginConf -replace '\\', '/') -replace [regex]::Escape($homeFwd), '~'
        $activationLine = "source-file '$relPath'"
    } elseif (Test-Path $pluginPs1) {
        $relPath = ($pluginPs1 -replace '\\', '/') -replace [regex]::Escape($homeFwd), '~'
        $activationLine = "run-shell '$relPath'"
    } else {
        return  # no known entry point
    }

    # Skip if this activation line (or one referencing the same plugin name) already exists
    if ($content -match [regex]::Escape($name)) { return }

    # Append inside managed section, or create one
    $lines = @(Get-Content $configFile -ErrorAction SilentlyContinue)
    $endIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '# -- End plugins') { $endIdx = $i; break }
    }

    $pluginLine = "set -g @plugin '$Spec'"
    if ($endIdx -ge 0) {
        # Insert before the end-marker
        $before = $lines[0..($endIdx - 1)]
        $after  = $lines[$endIdx..($lines.Count - 1)]
        $lines  = @($before) + @($pluginLine, $activationLine) + @($after)
    } else {
        # Create a managed section at the end
        $lines += @(
            '',
            '# -- Plugins (managed by ppm) --------------------------------',
            $pluginLine,
            $activationLine,
            '# -- End plugins ---------------------------------------------'
        )
    }

    $lines | Set-Content -Path $configFile -Encoding UTF8
    Write-Host "  Persisted: $name -> config" -ForegroundColor DarkCyan
}

# --- Remove plugin activation lines from config file ---
function Remove-PluginActivation {
    param([string]$PluginName)
    $configFile = Get-PsmuxConfigFile
    if (-not $configFile) { return }

    $lines = @(Get-Content $configFile -ErrorAction SilentlyContinue)
    $filtered = $lines | Where-Object {
        -not ($_ -match [regex]::Escape($PluginName) -and
              ($_ -match 'source-file' -or $_ -match 'run-shell' -or $_ -match '@plugin'))
    }

    # Clean up empty managed section
    $hasPlugins = $filtered | Where-Object { $_ -match '@plugin' -and $_ -notmatch 'ppm' }
    if (-not $hasPlugins) {
        $filtered = $filtered | Where-Object {
            $_ -notmatch '# -- Plugins \(managed by ppm\)' -and
            $_ -notmatch '# -- End plugins'
        }
    }

    $filtered | Set-Content -Path $configFile -Encoding UTF8
}

# --- Install a single plugin ---
function Install-Plugin {
    param([string]$Spec)
    $info = Resolve-PluginSpec $Spec

    if (Test-Path $info.Path) {
        Write-Host "  Already installed: $($info.Name)" -ForegroundColor DarkGray
        return $true
    }

    $branchNote = if ($info.Branch) { " (branch: $($info.Branch))" } else { "" }
    Write-Host "  Installing: $($info.Name)$branchNote ..." -ForegroundColor Cyan

    # 3-segment specs (owner/monorepo/subdir): route directly to monorepo extraction.
    # No probe, no MONOREPO_MAP lookup - the source is self-described in the spec.
    if ($info.MonorepoSource) {
        if (Install-FromMonorepo -Org $info.Org -Name $info.SubdirName -TargetPath $info.Path -Source $info.MonorepoSource -Branch $info.Branch) {
            Write-Host "  Installed: $($info.Name)" -ForegroundColor Green
            Initialize-Plugin $info.Path
            Persist-PluginActivation -Spec $Spec -PluginPath $info.Path
            return $true
        }
        Write-Host "  FAILED: $($info.Name) - could not install from $($info.MonorepoSource) subdir $($info.SubdirName)" -ForegroundColor Red
        return $false
    }

    # 2-segment / URL / bare name: try direct git clone first.
    $cloned = $false
    try {
        $cloneArgs = @('clone', '--depth', '1')
        if ($info.Branch) { $cloneArgs += @('--branch', $info.Branch) }
        $cloneArgs += @($info.Url, $info.Path)
        & git @cloneArgs 2>&1 | Out-Null
        if (Test-Path $info.Path) { $cloned = $true }
    } catch {}

    # Fallback: monorepo extraction if org is in MONOREPO_MAP
    if (-not $cloned -and $info.Org -and $script:MONOREPO_MAP.ContainsKey($info.Org)) {
        # Remove any partial clone artifacts
        if (Test-Path $info.Path) { Remove-Item -Recurse -Force $info.Path -ErrorAction SilentlyContinue }
        $cloned = Install-FromMonorepo -Org $info.Org -Name $info.Name -TargetPath $info.Path -Branch $info.Branch
    }

    if ($cloned -and (Test-Path $info.Path)) {
        Write-Host "  Installed: $($info.Name)" -ForegroundColor Green
        # Source the plugin into the running session
        Initialize-Plugin $info.Path
        # Persist activation to config file so it survives server restarts
        Persist-PluginActivation -Spec $Spec -PluginPath $info.Path
        return $true
    }

    # Last resort: check if it's a local/bundled plugin
    $bundledPath = Join-Path $PPM_ROOT "bundled\$($info.Name)"
    if (Test-Path $bundledPath) {
        Copy-Item -Path $bundledPath -Destination $info.Path -Recurse -Force
        Write-Host "  Installed (bundled): $($info.Name)" -ForegroundColor Green
        Initialize-Plugin $info.Path
        Persist-PluginActivation -Spec $Spec -PluginPath $info.Path
        return $true
    }

    Write-Host "  FAILED: $($info.Name) - could not clone from $($info.Url)" -ForegroundColor Red
    return $false
}

# --- Update a single plugin ---
function Update-Plugin {
    param([string]$PluginPath, [string]$Spec)
    $name = Split-Path -Leaf $PluginPath

    # Check for monorepo marker (extracted from monorepo, no .git)
    $monorepoJson = Join-Path $PluginPath '.monorepo.json'
    if (Test-Path $monorepoJson) {
        $meta = Get-Content $monorepoJson -Raw | ConvertFrom-Json
        $metaBranch = $meta.branch
        $branchNote = if ($metaBranch) { " branch '$metaBranch'" } else { "" }
        Write-Host "  Updating: $name (from monorepo $($meta.monorepo)$branchNote) ..." -ForegroundColor Cyan
        $tmpDir = Join-Path $env:TEMP "ppm-monorepo-$($meta.org)-$(Get-Random)"
        try {
            $cloneArgs = @('clone', '--depth', '1')
            if ($metaBranch) { $cloneArgs += @('--branch', $metaBranch) }
            $cloneArgs += @($meta.url, $tmpDir)
            & git @cloneArgs 2>&1 | Out-Null
            $subDir = Join-Path $tmpDir $meta.name
            if (Test-Path $subDir) {
                # Remove old contents (except .monorepo.json) and copy new
                Get-ChildItem -Path $PluginPath -Exclude '.monorepo.json' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path $subDir | Copy-Item -Destination $PluginPath -Recurse -Force
                Write-Host "  Updated: $name" -ForegroundColor Green
            } else {
                Write-Host "  FAILED: '$name' not found in monorepo" -ForegroundColor Red
            }
        } catch {
            Write-Host "  FAILED: $name - $($_.Exception.Message)" -ForegroundColor Red
        }
        if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
        return
    }

    if (Test-Path (Join-Path $PluginPath '.git')) {
        Write-Host "  Updating: $name ..." -ForegroundColor Cyan
        Push-Location $PluginPath
        try {
            git pull --rebase 2>&1 | Out-Null
            Write-Host "  Updated: $name" -ForegroundColor Green
        } catch {
            Write-Host "  FAILED: $name" -ForegroundColor Red
        }
        Pop-Location
        return
    }

    # No .git and no .monorepo.json — try to derive the source from $Spec.
    # Parse optional '#branch' suffix and the spec shape.
    $specBase = $Spec
    $specBranch = $null
    if ($specBase -and $specBase -match '^([^#]+)#(.+)$') {
        $specBase = $Matches[1]
        $specBranch = $Matches[2]
    }

    # 3-segment spec: explicit monorepo source, no MONOREPO_MAP needed.
    if ($specBase -and $specBase -match '^([^/]+)/([^/]+)/([^/]+)$') {
        $sOwner = $Matches[1]
        $sRepo  = $Matches[2]
        $sSubdir = $Matches[3]
        $branchNote = if ($specBranch) { " branch '$specBranch'" } else { "" }
        Write-Host "  Updating: $name (3-segment monorepo $sOwner/$sRepo$branchNote) ..." -ForegroundColor Cyan
        if (Install-FromMonorepo -Org $sOwner -Name $sSubdir -TargetPath $PluginPath -Source "$sOwner/$sRepo" -Branch $specBranch) {
            Write-Host "  Updated: $name" -ForegroundColor Green
        } else {
            Write-Host "  FAILED: $name - 3-segment update failed" -ForegroundColor Red
        }
        return
    }

    # 2-segment / bare-name fallback via MONOREPO_MAP
    $org = $null
    if ($specBase -and $specBase -match '^([^/]+)/') { $org = $Matches[1] }
    if (-not $org) {
        # Guess the org from known psmux plugin name patterns
        if ($name -match '^psmux-') { $org = 'psmux-plugins' }
    }
    if ($org -and $script:MONOREPO_MAP.ContainsKey($org)) {
        Write-Host "  Updating: $name (monorepo fallback) ..." -ForegroundColor Cyan
        if (Install-FromMonorepo -Org $org -Name $name -TargetPath $PluginPath -Branch $specBranch) {
            Write-Host "  Updated: $name" -ForegroundColor Green
        } else {
            Write-Host "  FAILED: $name - monorepo fallback failed" -ForegroundColor Red
        }
        return
    }

    Write-Host "  Skip (not git): $name" -ForegroundColor DarkGray
}

# --- Initialize/source a plugin ---
function Initialize-Plugin {
    param([string]$PluginPath)
    $name = Split-Path -Leaf $PluginPath

    # If the plugin ships a plugin.conf, psmux already sourced it natively
    # when processing the `set -g @plugin` declaration.  Skip re-sourcing
    # via the .ps1 entry point to avoid overriding user settings that were
    # set AFTER the @plugin line in the config file.
    $confFile = Join-Path $PluginPath 'plugin.conf'
    if (Test-Path $confFile) {
        return
    }

    # Look for the main plugin entry point (in priority order)
    $entryPoints = @(
        (Join-Path $PluginPath "$name.ps1"),
        (Join-Path $PluginPath "$($name -replace '^psmux-','').ps1"),
        (Join-Path $PluginPath 'plugin.ps1'),
        (Join-Path $PluginPath 'init.ps1')
    )

    foreach ($ep in $entryPoints) {
        if (Test-Path $ep) {
            try {
                & $ep
            } catch {
                Write-Host "  Warning: Error sourcing $name : $_" -ForegroundColor Yellow
            }
            return
        }
    }
}

# --- Main: Install all plugins ---
function Install-AllPlugins {
    $plugins = Get-DeclaredPlugins
    if ($plugins.Count -eq 0) {
        Write-Host "PPM: No plugins declared. Add 'set -g @plugin ""owner/repo""' to your config." -ForegroundColor Yellow
        return
    }

    Show-PpmStatus "PPM: Installing $($plugins.Count) plugin(s)..."
    Write-Host ""
    Write-Host "PPM - Installing plugins..." -ForegroundColor Magenta
    Write-Host ("=" * 50) -ForegroundColor Magenta

    $installed = 0
    foreach ($spec in $plugins) {
        $name = Get-PluginName $spec
        Show-PpmStatus "PPM: Installing $name..."
        if (Install-Plugin $spec) { $installed++ }
    }

    Clear-PpmStatus
    Write-Host ("=" * 50) -ForegroundColor Magenta
    Write-Host "PPM: $installed/$($plugins.Count) plugins installed." -ForegroundColor Magenta
    Write-Host ""
}

# --- Main: Update all plugins ---
function Update-AllPlugins {
    Write-Host ""
    Write-Host "PPM - Updating plugins..." -ForegroundColor Magenta
    Write-Host ("=" * 50) -ForegroundColor Magenta

    # Build a name→spec lookup from declared plugins
    $declaredPlugins = Get-DeclaredPlugins
    $specByName = @{}
    foreach ($spec in $declaredPlugins) {
        $pname = Get-PluginName $spec
        $specByName[$pname] = $spec
    }

    $dirs = Get-ChildItem -Path $PLUGIN_DIR -Directory -ErrorAction SilentlyContinue

    if ($dirs.Count -eq 0) {
        Write-Host "  No plugins to update." -ForegroundColor DarkGray
        return
    }

    Show-PpmStatus "PPM: Updating $($dirs.Count) plugin(s)..."

    foreach ($dir in $dirs) {
        Show-PpmStatus "PPM: Updating $($dir.Name)..."
        $spec = $specByName[$dir.Name]
        Update-Plugin -PluginPath $dir.FullName -Spec $spec
    }

    Clear-PpmStatus
    Write-Host ("=" * 50) -ForegroundColor Magenta
    Write-Host "PPM: Update complete." -ForegroundColor Magenta
    Write-Host ""
}

# --- Main: Clean unused plugins ---
function Remove-UnusedPlugins {
    $plugins = Get-DeclaredPlugins
    $declaredNames = $plugins | ForEach-Object { Get-PluginName $_ }

    Show-PpmStatus "PPM: Cleaning unused plugins..."
    Write-Host ""
    Write-Host "PPM - Cleaning unused plugins..." -ForegroundColor Magenta
    Write-Host ("=" * 50) -ForegroundColor Magenta

    # Skip the PPM directory itself when scanning for unused plugins. Matches
    # tpm's pattern in scripts/clean_plugins.sh (`[ "${plugin}" = "tpm" ] && continue`):
    # never remove the plugin manager regardless of whether the user has declared
    # `set -g @plugin 'psmux-plugins/ppm'` in their config. If they removed that
    # line, this guard prevents the clean pass from deleting the directory
    # containing the currently-running script.
    $dirs = Get-ChildItem -Path $PLUGIN_DIR -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'ppm' }

    $removed = 0
    foreach ($dir in $dirs) {
        if ($dir.Name -notin $declaredNames) {
            Show-PpmStatus "PPM: Removing $($dir.Name)..."
            Write-Host "  Removing: $($dir.Name)" -ForegroundColor Yellow
            Remove-Item -Recurse -Force $dir.FullName -ErrorAction SilentlyContinue
            # Also remove activation lines from config
            Remove-PluginActivation -PluginName $dir.Name
            $removed++
        }
    }

    Clear-PpmStatus
    if ($removed -eq 0) {
        Write-Host "  All plugins are in use." -ForegroundColor Green
    } else {
        Write-Host "  Removed $removed unused plugin(s)." -ForegroundColor Yellow
    }

    Write-Host ("=" * 50) -ForegroundColor Magenta
    Write-Host ""
}

# --- Register PPM keybindings ---
function Register-PPMBindings {
    # Convert to forward slashes to avoid psmux backslash stripping
    $ppmFwd = $PPM_ROOT -replace '\\', '/'
    $installPath = "$ppmFwd/scripts/install_plugins.ps1"
    $updatePath  = "$ppmFwd/scripts/update_plugins.ps1"
    $cleanPath   = "$ppmFwd/scripts/clean_plugins.ps1"

    Invoke-Psmux bind-key I "run-shell 'pwsh -NoProfile -File `"$installPath`"'" 2>&1 | Out-Null
    Invoke-Psmux bind-key U "run-shell 'pwsh -NoProfile -File `"$updatePath`"'" 2>&1 | Out-Null
    Invoke-Psmux bind-key M "run-shell 'pwsh -NoProfile -File `"$cleanPath`"'" 2>&1 | Out-Null
}

# =============================================================================
# ENTRY POINT
# =============================================================================
# When sourced via `run` in .psmux.conf, this:
# 1. Ensures the plugin directory exists
# 2. Registers PPM key bindings
# 3. Sources all installed plugins
# 4. Does NOT auto-install (user presses Prefix+I for that)

# Ensure plugin directory exists
if (-not (Test-Path $PLUGIN_DIR)) {
    New-Item -ItemType Directory -Path $PLUGIN_DIR -Force | Out-Null
}

# Register PPM key bindings
Register-PPMBindings

# Source only plugins that are declared in config (not every directory)
$declaredPlugins = Get-DeclaredPlugins
$declaredNames = $declaredPlugins | ForEach-Object { Get-PluginName $_ }

# Source only plugins that are declared in config (not every directory).
# The `$_.Name -ne 'ppm'` filter is a PPM-specific divergence from tpm: tpm
# has no analogous startup-source loop (its plugin sourcing is integrated
# into tpm.tmux's main script flow, so re-entry is impossible by design).
# PPM runs sourcing as a separate pass after bootstrap, so the guard prevents
# PPM from re-sourcing itself when the user has declared
# `set -g @plugin 'psmux-plugins/ppm'` in their config.
$installedPlugins = Get-ChildItem -Path $PLUGIN_DIR -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'ppm' -and $_.Name -in $declaredNames }

foreach ($pluginDir in $installedPlugins) {
    Initialize-Plugin $pluginDir.FullName
}

Write-Host "PPM: Loaded $($installedPlugins.Count) plugin(s). Press Prefix+I to install new plugins." -ForegroundColor DarkGray
