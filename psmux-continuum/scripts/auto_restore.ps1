#!/usr/bin/env pwsh
# psmux-continuum: Auto-restore on server start
$ErrorActionPreference = 'Continue'

function Get-PsmuxBin {
    # Test-mode override: env var pointing to a wrapper script/exe to use
    # instead of the discovered binary. Lets isolation tests redirect every
    # psmux invocation to a wrapper that adds -L <test-socket>.
    if ($env:PSMUX_BIN_OVERRIDE) { return $env:PSMUX_BIN_OVERRIDE }
    foreach ($n in @('psmux','pmux','tmux')) {
        $b = Get-Command $n -ErrorAction SilentlyContinue
        if ($b) { return $b.Source }
    }
    return 'psmux'
}

# Opt-in via @continuum-restore 'on'. The plugin.conf hook is registered
# unconditionally; this script is the option gate, evaluated at exec time.
$PSMUX = Get-PsmuxBin
$restoreOpt = (& $PSMUX show-options -gv '@continuum-restore' 2>&1 | Out-String).Trim()
if ($restoreOpt -ne 'on') { exit 0 }

# Fire at most once per psmux server lifetime. The hook is on session-created
# and restore.ps1 itself calls new-session for each saved session, so without
# this guard the hook would re-enter for every restored session.
#
# We use a file-based atomic claim (FileMode.CreateNew) for the singleton,
# NOT psmux's set-option/show-options. The latter has a TOCTOU window
# between show-options (read) and set-option (write): two near-simultaneous
# session-created events can both observe an unset flag, both proceed, and
# both spawn restore.ps1. restore.ps1 has its own PID-file singleton as a
# safety net, but cleaning the race up here avoids wasted pwsh spawns.
#
# The marker file lives alongside auto_save.pid in LOCALAPPDATA. We tie it
# to the psmux server's PID so a fresh server boot reclaims the slot:
# if the recorded PID matches the current server PID, we've already fired
# for this lifetime; if it doesn't match (server restarted), we delete the
# stale marker and re-claim.
$pidDir = Join-Path $env:LOCALAPPDATA 'psmux-continuum'
if (-not (Test-Path $pidDir)) {
    New-Item -ItemType Directory -Path $pidDir -Force | Out-Null
}
$firedMarker = Join-Path $pidDir 'restore-fired.marker'

# Determine current psmux server's PID to use as the "lifetime token."
# If the marker file's recorded PID matches the current server PID, we've
# already fired for this server lifetime; exit.
$serverPid = $null
try {
    $serverPid = (& $PSMUX display-message -p '#{pid}' 2>&1 | Out-String).Trim()
} catch {}

if ((Test-Path $firedMarker) -and $serverPid) {
    $recordedPid = $null
    try { $recordedPid = (Get-Content $firedMarker -Raw -EA SilentlyContinue).Trim() } catch {}
    if ($recordedPid -eq $serverPid) {
        # Already fired for this server lifetime.
        exit 0
    }
    # Server PID changed — server restarted. Remove the stale marker before
    # we re-claim.
    Remove-Item $firedMarker -Force -ErrorAction SilentlyContinue
}

# Atomic claim of the marker file. CreateNew fails if it already exists,
# making this race-safe even if two auto_restore.ps1 invocations call into
# this block simultaneously.
try {
    $fs = [System.IO.File]::Open(
        $firedMarker,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    try {
        if ($serverPid) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($serverPid)
            $fs.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $fs.Dispose()
    }
} catch [System.IO.IOException] {
    # Another auto_restore.ps1 won the race; exit.
    exit 0
}

$restoreScript = Join-Path $PSScriptRoot '..\..\psmux-resurrect\scripts\restore.ps1'
if (-not (Test-Path $restoreScript)) {
    $restoreScript = Join-Path $env:USERPROFILE '.psmux\plugins\psmux-resurrect\scripts\restore.ps1'
}

$resurrectDir = Join-Path $env:USERPROFILE '.psmux\resurrect'
$lastFile = Join-Path $resurrectDir 'last'

if ((Test-Path $restoreScript) -and (Test-Path $lastFile)) {
    & pwsh -NoProfile -File $restoreScript
}
