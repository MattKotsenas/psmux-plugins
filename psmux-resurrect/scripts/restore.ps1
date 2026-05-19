#!/usr/bin/env pwsh
# psmux-resurrect: Restore saved environment
# Restores: sessions, windows, panes, layouts, active pane per window,
#           zoomed panes, pane titles, running processes (configurable),
#           window flags, active window selection
$ErrorActionPreference = 'Continue'

# psmux refuses `new-session` when PSMUX_SESSION/PSMUX_ACTIVE is set
# (psmux/src/main.rs:627), even with -d which cannot nest a UI. This
# script only issues detached new-session calls, so opt out of the guard
# via the documented override (psmux/src/main.rs:3120). Preserves
# PSMUX_TARGET_SESSION (server routing) and tool-detection signals.
$env:PSMUX_ALLOW_NESTING = '1'

function Get-PsmuxBin {
    # Test-mode override: env var pointing to a wrapper script/exe to use
    # instead of the discovered binary. Lets isolation tests redirect every
    # psmux invocation to a wrapper that adds -L <test-socket>.
    if ($env:PSMUX_BIN_OVERRIDE) { return $env:PSMUX_BIN_OVERRIDE }
    foreach ($n in @('psmux','pmux','tmux')) {
        $b = Get-Command $n -ErrorAction SilentlyContinue
        if ($b -and $b.Source) { return $b.Source }
    }
    return 'psmux'
}

$PSMUX = Get-PsmuxBin

# --- Singleton guard -------------------------------------------------------
# Restore is a long-running, NON-idempotent operation: it issues new-window
# calls for each saved window. Concurrent invocations interleave their
# new-window calls and double (or worse) the resulting window count.
#
# This is observable in the wild because:
#   * psmux-continuum's session-created hook fires for every new-session,
#     including the ones THIS script issues. Its option-based TOCTOU
#     singleton (@continuum-restore-fired) can let two auto_restore.ps1
#     invocations through under tight timing at server boot.
#   * Future user hooks / manual bindings can also re-enter.
#
# Process-level PID-file singleton matches the auto_save.ps1 approach
# (psmux-plugins#13 / Cosmin's fix). Atomic CreateNew on the PID file
# guarantees that exactly one restore loop ever proceeds at a time; any
# concurrent invocations exit cleanly without touching state.
#
# Test override: PSMUX_RESTORE_PID_FILE_OVERRIDE lets the Pester test suite
# point at a tempdir-local PID file so we don't collide with a real plugin
# install on the same machine.
$RESTORE_PID_FILE = if ($env:PSMUX_RESTORE_PID_FILE_OVERRIDE) {
    $env:PSMUX_RESTORE_PID_FILE_OVERRIDE
} else {
    Join-Path $env:LOCALAPPDATA 'psmux-continuum\restore.pid'
}
$pidDir = Split-Path $RESTORE_PID_FILE -Parent
if (-not (Test-Path $pidDir)) {
    New-Item -ItemType Directory -Path $pidDir -Force | Out-Null
}

# Atomic claim: try to create the file with CreateNew. If it exists and
# the recorded PID is still alive, another restore is in progress; exit.
# If it exists but the recorded PID is dead, the slot is stale (previous
# restore crashed) — reclaim atomically by deleting + retrying CreateNew.
# Bounded retries so we don't spin if two processes are both trying to
# reclaim the same dead slot (the second one will see the first's live PID
# on its second pass and exit cleanly).
$claimedSlot = $false
$ownPid = $PID
$MaxClaimAttempts = 3
for ($attempt = 0; $attempt -lt $MaxClaimAttempts; $attempt++) {
    try {
        $fs = [System.IO.File]::Open(
            $RESTORE_PID_FILE,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($ownPid.ToString())
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            $fs.Dispose()
        }
        $claimedSlot = $true
        break
    } catch [System.IO.IOException] {
        # File already exists. Inspect the recorded PID.
        $stalePid = $null
        try { $stalePid = [int]((Get-Content $RESTORE_PID_FILE -Raw).Trim()) } catch {}

        # Verify the recorded PID belongs to a pwsh process (the only thing
        # that should be running restore.ps1). PIDs are reused on Windows;
        # a bare Get-Process check can false-positive when the kernel has
        # recycled the PID to a different process. Checking the image name
        # narrows the window dramatically.
        $aliveOwner = $null
        if ($stalePid) {
            $proc = Get-Process -Id $stalePid -EA SilentlyContinue
            if ($proc -and ($proc.Name -in @('pwsh', 'powershell'))) {
                $aliveOwner = $proc
            }
        }
        if ($aliveOwner) {
            Write-Host "psmux-resurrect: another restore is already running (PID $stalePid); exiting." -ForegroundColor DarkGray
            exit 0
        }
        # Stale slot — delete and retry CreateNew. The delete + retry pattern
        # avoids the TOCTOU race on Set-Content: if another process is also
        # reclaiming, only one will succeed at CreateNew; the other will see
        # the first's live PID on the next iteration and exit.
        try {
            Remove-Item $RESTORE_PID_FILE -Force -ErrorAction Stop
        } catch {
            # Someone else may have just deleted it; loop will retry CreateNew.
        }
        Start-Sleep -Milliseconds 25
    }
}
if (-not $claimedSlot) {
    Write-Host "psmux-resurrect: could not claim singleton slot after $MaxClaimAttempts attempts; exiting." -ForegroundColor DarkGray
    exit 0
}

# Ensure we release the slot on any exit path (success, error, ctrl-C).
$releaseSlot = {
    if ($claimedSlot -and (Test-Path $RESTORE_PID_FILE)) {
        # Only delete if we're still the owner (PID matches). If someone
        # else claimed it after we set up but before we got here, leave
        # their claim alone.
        try {
            $currentOwner = [int]((Get-Content $RESTORE_PID_FILE -Raw).Trim())
            if ($currentOwner -eq $ownPid) {
                Remove-Item $RESTORE_PID_FILE -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Remove-Item $RESTORE_PID_FILE -Force -ErrorAction SilentlyContinue
        }
    }
}
# --- End singleton guard ---------------------------------------------------

# --- Progress indicator helpers ---
# A persistent message is exposed via the @resurrect-status user option so
# users can render it in status-right with #{@resurrect-status}. We also
# push the same string via display-message so users without that integration
# still see it as a toast.
#
# NOTE: psmux interprets `display-message -d 0` as "0ms = never show" (the
# guard in server/mod.rs reads `if elapsed < display_time`, so 0 always
# fails). tmux treats 0 as "indefinite"; psmux does not. We use a large
# duration (60s) instead so the toast stays put long enough to outlast a
# normal restore loop; each successive Show-Progress call refreshes it.
$BAR_WIDTH = 14
$PROGRESS_TOAST_MS = 60000
$SUMMARY_TOAST_MS = 5000

function Set-ResurrectStatus([string]$msg) {
    & $PSMUX set-option -g '@resurrect-status' $msg 2>&1 | Out-Null
}

function Clear-ResurrectStatus {
    & $PSMUX set-option -gu '@resurrect-status' 2>&1 | Out-Null
}

function Format-ProgressBar([int]$current, [int]$total) {
    if ($total -le 0) { $total = 1 }
    $filled = [int]([math]::Floor(($current / $total) * $BAR_WIDTH))
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $BAR_WIDTH) { $filled = $BAR_WIDTH }
    $empty = $BAR_WIDTH - $filled
    return ('[' + ('#' * $filled) + ('-' * $empty) + ']')
}

function Show-Progress([int]$current, [int]$total, [string]$sessionName) {
    $bar = Format-ProgressBar -current $current -total $total
    $msg = "psmux-resurrect: restoring $bar $current/$total  $sessionName"
    Set-ResurrectStatus $msg
    & $PSMUX display-message -d $PROGRESS_TOAST_MS $msg 2>&1 | Out-Null
}

# Resolve save directory (support @resurrect-dir option)
$RESURRECT_DIR = Join-Path $env:USERPROFILE '.psmux\resurrect'
try {
    $customDir = (& $PSMUX show-options -gv '@resurrect-dir' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $customDir -and $customDir -ne '' -and $customDir -notmatch 'unknown option|error|no server|not found|refused') {
        $customDir = $customDir -replace '^~', $env:USERPROFILE
        $customDir = $customDir -replace '\$HOME', $env:USERPROFILE
        $RESURRECT_DIR = $customDir
    }
} catch {}
$lastFile = Join-Path $RESURRECT_DIR 'last'

if (-not (Test-Path $lastFile)) {
    & $PSMUX display-message "No saved environment found!" 2>&1 | Out-Null
    Write-Host "psmux-resurrect: No save file found" -ForegroundColor Red
    exit 1
}

$saveFile = (Get-Content $lastFile -Raw).Trim()
if (-not (Test-Path $saveFile)) {
    & $PSMUX display-message "Save file not found: $saveFile" 2>&1 | Out-Null
    exit 1
}

try {
    $env_data = Get-Content $saveFile -Raw | ConvertFrom-Json

    # --- Build process restore list ---
    # Default processes to restore (Windows equivalents of tmux defaults)
    $defaultProcesses = @('python','python3','node','npm','ssh','wsl','htop','vim','nvim','less','more','tail')

    # Check user configured process list
    $userProcs = ''
    try {
        $userProcs = (& $PSMUX show-options -gv '@resurrect-processes' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $userProcs = '' }
    } catch { $userProcs = '' }
    $restoreProcesses = $true
    $restoreAllProcesses = $false
    $processList = @()

    if ($userProcs -eq 'false') {
        $restoreProcesses = $false
    } elseif ($userProcs -eq ':all:') {
        $restoreAllProcesses = $true
    } elseif ($userProcs -and $userProcs -notmatch 'unknown option|error|no server|not found|refused') {
        # Combine default + user processes
        $processList = $defaultProcesses + ($userProcs -split '\s+' | Where-Object { $_ })
    } else {
        $processList = $defaultProcesses
    }

    function Should-RestoreProcess {
        param([string]$Command)
        if (-not $restoreProcesses) { return $false }
        if ($restoreAllProcesses) { return $true }
        if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
        $cmdBase = ($Command -split '[\\/]' | Select-Object -Last 1) -replace '\.exe$',''
        foreach ($proc in $processList) {
            $procClean = $proc.Trim().Trim('"').Trim("'")
            if ($procClean.StartsWith('~')) {
                # Tilde match: command contains the string anywhere
                $match = $procClean.Substring(1)
                if ($Command -match [regex]::Escape($match)) { return $true }
            } else {
                # Exact base name match
                if ($cmdBase -eq $procClean) { return $true }
            }
        }
        return $false
    }

    $totalSessions = $env_data.sessions.Count
    $startTime = Get-Date
    $restoredCount = 0
    $skipped = @()
    $failed = @()
    $totalWindows = 0

    for ($si = 0; $si -lt $totalSessions; $si++) {
        $session = $env_data.sessions[$si]
        $sessionName = $session.name

        Show-Progress -current ($si + 1) -total $totalSessions -sessionName $sessionName

        # Check if session already exists. The original behavior was to skip
        # entirely, which lost data on psmux server startup: the server
        # creates a default empty session, this script saw it existed, and
        # `continue`'d past all the saved windows. Refactor to pane-level
        # reconciliation: when the existing session is the empty default
        # (exactly 1 window with 1 pane — no user state to preserve), reuse
        # it as the target for the saved content. Only when the session has
        # actual user state (multiple windows OR multiple panes) do we skip.
        $reuseExisting = $false
        $null = & $PSMUX has-session -t $sessionName 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Session exists. Inspect its content to decide reuse vs. skip.
            $existingWindowsRaw = & $PSMUX list-windows -t $sessionName -F '#{window_index}' 2>&1
            $existingWindows = @($existingWindowsRaw | Where-Object { $_ -match '^\d+$' })
            $existingPanesRaw = & $PSMUX list-panes -t $sessionName -F '#{pane_index}' 2>&1
            $existingPanes = @($existingPanesRaw | Where-Object { $_ -match '^\d+$' })

            if ($existingWindows.Count -eq 1 -and $existingPanes.Count -eq 1) {
                # Empty default state (one window, one pane — the
                # auto-created shell with nothing in it). Safe to reuse.
                $reuseExisting = $true
                Write-Host "  Session '$sessionName' is empty default; reusing for restore" -ForegroundColor DarkGray
            } else {
                # User has been working in this session; preserve their state.
                Write-Host "  Session '$sessionName' has user state ($($existingWindows.Count) windows, $($existingPanes.Count) panes total); skipping" -ForegroundColor Yellow
                $skipped += $sessionName
                continue
            }
        }

        # Create session with first window
        $firstWindow = $session.windows | Select-Object -First 1
        $firstDir = if ($firstWindow.panes -and $firstWindow.panes[0].directory) {
            $firstWindow.panes[0].directory
        } else {
            $env:USERPROFILE
        }

        if ($reuseExisting) {
            # Reuse existing session: don't create, just rename the existing
            # window to match the saved name and use it as the first window.
            if ($firstWindow.name) {
                # Determine the existing window index, then rename it.
                $existingWinIdx = (& $PSMUX list-windows -t $sessionName -F '#{window_index}' 2>&1 | Out-String).Trim()
                if ($existingWinIdx -match '^\d+$') {
                    & $PSMUX rename-window -t "${sessionName}:${existingWinIdx}" $firstWindow.name 2>&1 | Out-Null
                }
            }
        } else {
            # Use the saved window name for the initial window
            & $PSMUX new-session -d -s $sessionName -c $firstDir $(if ($firstWindow.name) { @('-n', $firstWindow.name) } else { @() }) 2>&1 | Out-Null

            # Wait for session to be ready
            $ready = $false
            for ($w = 0; $w -lt 40; $w++) {
                Start-Sleep -Milliseconds 250
                $null = & $PSMUX has-session -t $sessionName 2>&1
                if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            }
            if (-not $ready) {
                Write-Host "  Failed to create session '$sessionName'" -ForegroundColor Red
                $failed += $sessionName
                continue
            }
        }

        # Get the actual base index used by the new session
        $baseIdx = (& $PSMUX show-options -t $sessionName -gv base-index 2>&1 | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($baseIdx) -or $baseIdx -match 'unknown') { $baseIdx = "0" }
        $baseIdx = [int]$baseIdx
        $firstWinIdx = $baseIdx

        # Helper: restore panes for a window target
        function Restore-WindowPanes {
            param($win, [string]$winTarget)

            # Create additional panes
            if ($win.panes.Count -gt 1) {
                for ($p = 1; $p -lt $win.panes.Count; $p++) {
                    $pDir = if ($win.panes[$p].directory) { $win.panes[$p].directory } else { $env:USERPROFILE }
                    & $PSMUX split-window -t $winTarget -c $pDir 2>&1 | Out-Null
                    Start-Sleep -Milliseconds 300
                }
            }

            # Replay the saved layout so split orientations and sizes match the original
            if ($win.layout) {
                & $PSMUX select-layout -t $winTarget $win.layout 2>&1 | Out-Null
            }

            # Restore pane titles
            foreach ($pane in $win.panes) {
                if ($pane.title -and $pane.title -ne '') {
                    & $PSMUX select-pane -t "${winTarget}.$($pane.index)" -T $pane.title 2>&1 | Out-Null
                }
            }

            # Restore active pane for this window
            $activePane = $win.panes | Where-Object { $_.active -eq $true } | Select-Object -First 1
            if ($activePane) {
                & $PSMUX select-pane -t "${winTarget}.$($activePane.index)" 2>&1 | Out-Null
            }

            # Restore zoomed state
            if ($win.zoomed -eq $true -and $win.panes.Count -gt 1) {
                & $PSMUX resize-pane -Z -t $winTarget 2>&1 | Out-Null
            }

            # Restore running processes
            if ($restoreProcesses) {
                foreach ($pane in $win.panes) {
                    if ($pane.command -and (Should-RestoreProcess $pane.command)) {
                        & $PSMUX send-keys -t "${winTarget}.$($pane.index)" $pane.command Enter 2>&1 | Out-Null
                        Start-Sleep -Milliseconds 200
                    }
                }
            }
        }

        # Restore first window
        Restore-WindowPanes -win $firstWindow -winTarget "${sessionName}:${firstWinIdx}"

        # Create and restore remaining windows
        $remainingWindows = $session.windows | Select-Object -Skip 1
        foreach ($win in $remainingWindows) {
            $winDir = if ($win.panes -and $win.panes[0].directory) {
                $win.panes[0].directory
            } else {
                $env:USERPROFILE
            }

            $newWinArgs = @("-t", $sessionName, "-c", $winDir)
            if ($win.name) {
                $newWinArgs = @("-t", $sessionName, "-n", $win.name, "-c", $winDir)
            }
            & $PSMUX new-window @newWinArgs 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500

            # Get the actual index of the newly created window
            $lastWinIdx = (& $PSMUX list-windows -t $sessionName -F '#{window_index}' 2>&1 | Out-String).Trim() -split "`n" | Select-Object -Last 1
            $lastWinIdx = $lastWinIdx.Trim()

            Restore-WindowPanes -win $win -winTarget "${sessionName}:${lastWinIdx}"
        }

        # Select the active window (do this last so it sticks)
        $activeWin = $session.windows | Where-Object { $_.active -eq $true } | Select-Object -First 1
        if ($activeWin) {
            $currentWindows = (& $PSMUX list-windows -t $sessionName -F '#{window_index}' 2>&1 | Out-String).Trim() -split "`n"
            $savedWindows = @($session.windows)
            for ($i = 0; $i -lt $savedWindows.Count; $i++) {
                if ($savedWindows[$i].active -eq $true -and $i -lt $currentWindows.Count) {
                    $targetIdx = $currentWindows[$i].Trim()
                    & $PSMUX select-window -t "${sessionName}:${targetIdx}" 2>&1 | Out-Null
                    break
                }
            }
        }

        $restoredCount++
        $totalWindows += $session.windows.Count
        Write-Host "  Restored session: $sessionName ($($session.windows.Count) windows)" -ForegroundColor Green
    }

    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    $elapsedStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F1}s", $elapsed)

    $summary = "psmux-resurrect: restored $restoredCount sessions, $totalWindows windows in $elapsedStr"
    if ($skipped.Count -gt 0) {
        $summary = "psmux-resurrect: restored $restoredCount/$totalSessions, skipped $($skipped.Count) (already running)"
    }
    if ($failed.Count -gt 0) {
        $summary += " - failed: $($failed -join ', ')"
    }

    Set-ResurrectStatus $summary
    & $PSMUX display-message -d $SUMMARY_TOAST_MS $summary 2>&1 | Out-Null
    & $PSMUX refresh-client -S 2>&1 | Out-Null

    # Keep the persistent status visible for the same window as the toast, then clear
    Start-Sleep -Milliseconds $SUMMARY_TOAST_MS
}
finally {
    Clear-ResurrectStatus
    & $PSMUX refresh-client -S 2>&1 | Out-Null
    & $releaseSlot
}
