#!/usr/bin/env pwsh
# =============================================================================
# psmux-resurrect: End-to-end save-command-strategy wiring test
#
# Validates that save.ps1 routes each pane's command through the GLOBAL
# @resurrect-save-command-strategy (Get-SaveCommand), passes #{pane_pid} to the
# strategy, PERSISTS the strategy's transformed output, and that restore.ps1
# then replays that (arg-bearing) command via the ~tilde @resurrect-processes
# whitelist. This is the save-side mirror of test_resurrect_strategies_e2e.ps1.
#
# Isolation strategy: copy save.ps1/restore.ps1/save_strategy.ps1 + strategies/
# to a temp plugin dir, monkey-patch Get-PsmuxBin in the copies so $PSMUX
# becomes a pwsh wrapper that scrubs PSMUX_SESSION (to avoid nesting) and
# injects -L <socket> on every call. All psmux traffic from the patched scripts
# routes to an isolated server, leaving the user's default server untouched.
# =============================================================================
$ErrorActionPreference = 'Continue'

$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS: $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL: $name >> $detail" -ForegroundColor Red; $script:fail++ }
}

$PLUGIN_ROOT = Split-Path $PSScriptRoot -Parent
$PLUGIN_DIR  = Join-Path $PLUGIN_ROOT 'psmux-resurrect'
$realPsmux   = (Get-Command psmux -ErrorAction Stop).Source
$socketName  = 'resurrect_save_e2e'

$tempRoot = Join-Path $env:TEMP "psmux_resurrect_save_e2e_$([guid]::NewGuid().ToString('N'))"
$tempPlugin = Join-Path $tempRoot 'plugin-root\psmux-resurrect'
New-Item -ItemType Directory -Path $tempPlugin -Force | Out-Null
Copy-Item -Recurse (Join-Path $PLUGIN_DIR 'scripts')    $tempPlugin -Force
Copy-Item -Recurse (Join-Path $PLUGIN_DIR 'strategies') $tempPlugin -Force

$saveDir = Join-Path $tempRoot 'save'
New-Item -ItemType Directory -Path $saveDir -Force | Out-Null

# Marker the test strategy emits; whitelisted by prefix via the ~tilde form so
# restore actually replays the arg-bearing command it produces.
$echoMarker  = "RESUMED_MARKER_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$markerPrefix = 'RESUMED_MARKER'

# Isolated config: pre-sets options at config-source time so they propagate to
# every new session (runtime `set-option -g` only affects the current session).
$saveDirEsc = $saveDir.Replace("'", "''")
$confFile = Join-Path $tempRoot 'test.psmux.conf'
@"
set -g @resurrect-save-command-strategy 'e2etest'
set -g @resurrect-dir '$saveDirEsc'
set -g @resurrect-processes '~$markerPrefix'
"@ | Set-Content $confFile -Encoding ASCII

# Env-stripping wrapper that also loads the test config. -f is honored at
# server startup; subsequent invocations ignore it but still target the socket.
$wrapperPath = Join-Path $tempRoot 'psmux-wrapper.ps1'
@"
Remove-Item Env:PSMUX_SESSION -ErrorAction SilentlyContinue
Remove-Item Env:PSMUX_TARGET_SESSION -ErrorAction SilentlyContinue
Remove-Item Env:TMUX -ErrorAction SilentlyContinue
Remove-Item Env:TMUX_PANE -ErrorAction SilentlyContinue
& '$realPsmux' -f '$confFile' -L $socketName @args
exit `$LASTEXITCODE
"@ | Set-Content -Path $wrapperPath -Encoding UTF8

# Patch Get-PsmuxBin in the copies to use the wrapper.
$wrapperEsc = $wrapperPath.Replace("'", "''")
$replacement = "function Get-PsmuxBin { '$wrapperEsc' }"
foreach ($rel in @('scripts\save.ps1','scripts\restore.ps1')) {
    $f = Join-Path $tempPlugin $rel
    $c = Get-Content $f -Raw
    $patched = [regex]::Replace($c, '(?ms)^function Get-PsmuxBin \{.*?^\}', $replacement)
    if ($patched -eq $c) { throw "patch failed: $f" }
    Set-Content -Path $f -Value $patched -NoNewline -Encoding UTF8
}

# Sentinel + the GLOBAL save-command strategy under test. It records that it was
# invoked (with the pane_pid it received) and emits a transformed, arg-bearing
# command that echoes the marker when restore replays it.
$sentinel   = Join-Path $env:TEMP "psmux_save_strategy_invoked_$([guid]::NewGuid().ToString('N')).txt"
$strategyFile = Join-Path $tempPlugin 'strategies\save_command_strategies\e2etest.ps1'
@"
param([string]`$Command, [string]`$PanePid, [string]`$Directory)
"save hit at `$(Get-Date -Format o); cmd=[`$Command]; pid=[`$PanePid]; dir=[`$Directory]" |
    Add-Content -Path '$sentinel' -Encoding UTF8
"echo $echoMarker pid=`$PanePid"
"@ | Set-Content -Path $strategyFile -Encoding UTF8

Write-Host "=== psmux-resurrect E2E Save-Command Strategy Wiring ===" -ForegroundColor Magenta
Write-Host "wrapper  : $wrapperPath"
Write-Host "conf     : $confFile"
Write-Host "sentinel : $sentinel"
Write-Host "marker   : $echoMarker"
Write-Host "strategy : $strategyFile"
Write-Host "plugin   : $tempPlugin"
Write-Host "save dir : $saveDir"

try {
    $subScript = @'
param(
    [string]$wrapperPath, [string]$tempPlugin, [string]$saveDir, [string]$sentinel,
    [string]$echoMarker, [string]$realPsmux, [string]$socket
)
$ErrorActionPreference = 'Continue'
function w { param([Parameter(ValueFromRemainingArguments)]$a) & $wrapperPath @a }

w kill-server 2>&1 | Out-Null
Start-Sleep 1

function ensure-session {
    param([string]$name)
    for ($i = 0; $i -lt 5; $i++) {
        w new-session -d -s $name -c $env:USERPROFILE 2>&1 | Out-Null
        Start-Sleep 2
        $listed = (w list-sessions -F '#{session_name}' 2>&1 | Out-String).Trim() -split "`r?`n"
        if ($listed -contains $name) { return $true }
    }
    return $false
}
$keepOk   = ensure-session 'keep'
$targetOk = ensure-session 'target'
Write-Host "  bootstrap: keep=$keepOk target=$targetOk"
if (-not ($keepOk -and $targetOk)) { throw "bootstrap failed" }

$stratOpt = (w show-options -gv '@resurrect-save-command-strategy' 2>&1 | Out-String).Trim()
Write-Host "  @resurrect-save-command-strategy (from conf) -> [$stratOpt]"

$targetPanePid = (w list-panes -t 'target:0' -F '#{pane_pid}' 2>&1 | Out-String).Trim()
Write-Host "  target pane_pid -> [$targetPanePid]"

# SAVE (patched scripts route through wrapper). Get-SaveCommand must invoke the
# global strategy for every pane and persist its output.
$saveOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempPlugin 'scripts\save.ps1') 2>&1 | Out-String
Write-Host "  save.ps1 output: $($saveOut.Trim())"

$lastFile = Join-Path $saveDir 'last'
$savedFile = if (Test-Path $lastFile) { (Get-Content $lastFile -Raw).Trim() } else { '' }
$savedSessNames = ''; $savedTargetPaneCmd = $null
if ($savedFile -and (Test-Path $savedFile)) {
    $saved = Get-Content $savedFile -Raw | ConvertFrom-Json
    $savedSessNames = ($saved.sessions | ForEach-Object name) -join ','
    $tgt = $saved.sessions | Where-Object name -EQ 'target' | Select-Object -First 1
    if ($tgt) { $savedTargetPaneCmd = $tgt.windows[0].panes[0].command }
    Write-Host "  saved target pane command -> [$savedTargetPaneCmd]"
}

# Kill only 'target'; 'keep' holds the server + config-sourced options.
w kill-session -t target 2>&1 | Out-Null
Start-Sleep 1
$afterKill = (w list-sessions -F '#{session_name}' 2>&1 | Out-String).Trim()

# RESTORE: the saved arg-bearing command must be ~tilde-whitelisted and replayed.
$restoreOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempPlugin 'scripts\restore.ps1') 2>&1 | Out-String
Write-Host "  restore.ps1 output:"; Write-Host $restoreOut
Start-Sleep 8

$restored = (w list-sessions -F '#{session_name}' 2>&1 | Out-String).Trim()
$captured = (& $wrapperPath capture-pane -p -t 'target:0' 2>&1 | Out-String)
Write-Host "  --- captured pane content (len=$($captured.Length)) ---"; Write-Host $captured

Write-Host "<<<PAYLOAD_START>>>"
[PSCustomObject]@{
    TargetPanePid        = $targetPanePid
    SavedSessions        = $savedSessNames
    SavedTargetPaneCmd   = $savedTargetPaneCmd
    SessionsAfterKill    = $afterKill
    SessionsAfterRestore = $restored
    SentinelExists       = Test-Path $sentinel
    SentinelContent      = if (Test-Path $sentinel) { Get-Content $sentinel -Raw } else { '' }
    PaneCaptured         = $captured
} | ConvertTo-Json -Depth 4 -Compress
Write-Host ""
Write-Host "<<<PAYLOAD_END>>>"
'@

    $runner = Join-Path $tempRoot 'runner.ps1'
    Set-Content -Path $runner -Value $subScript -Encoding UTF8

    $result = & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner `
        $wrapperPath $tempPlugin $saveDir $sentinel $echoMarker $realPsmux $socketName 2>&1
    $resultText = ($result | Out-String)
    Write-Host "`n--- Subprocess output ---" -ForegroundColor Cyan
    Write-Host $resultText
    Write-Host "--- End subprocess output ---" -ForegroundColor Cyan

    $payload = $null
    if ($resultText -match '(?s)<<<PAYLOAD_START>>>\s*(\{.*?\})\s*<<<PAYLOAD_END>>>') {
        try { $payload = $Matches[1] | ConvertFrom-Json } catch {
            Write-Host "  payload JSON parse failed: $_" -ForegroundColor Red
        }
    }

    Check "subprocess emitted JSON payload" ($payload -ne $null) ''
    if ($payload) {
        Check "save captured 'target' + 'keep' sessions" `
            (($payload.SavedSessions -match '\btarget\b') -and ($payload.SavedSessions -match '\bkeep\b')) "Got: [$($payload.SavedSessions)]"

        Check "save-command strategy was invoked at SAVE time (sentinel exists)" `
            $payload.SentinelExists "Sentinel: $sentinel"

        Check "strategy received the pane_pid (#{pane_pid} threaded through save.ps1)" `
            ($payload.SentinelContent -match 'pid=\[\d+\]') "Got: [$($payload.SentinelContent)]"

        Check "save PERSISTED the strategy's transformed command (not the bare one)" `
            ($payload.SavedTargetPaneCmd -match "^echo\s+$([regex]::Escape($echoMarker))\s+pid=\d+$") "Got: [$($payload.SavedTargetPaneCmd)]"

        Check "target killed before restore" `
            ($payload.SessionsAfterKill -notmatch '\btarget\b') "Got: [$($payload.SessionsAfterKill)]"

        Check "restore re-created 'target'" `
            ($payload.SessionsAfterRestore -match '\btarget\b') "Got: [$($payload.SessionsAfterRestore)]"

        Check "restore replayed the transformed command (~tilde whitelist matched)" `
            ($payload.PaneCaptured -match [regex]::Escape($echoMarker)) "Looking for [$echoMarker] in capture"
    }
}
finally {
    if (Test-Path $wrapperPath) {
        & pwsh -NoProfile -File $wrapperPath kill-server 2>&1 | Out-Null
    }
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $sentinel -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Magenta
Write-Host "  E2E Save-Command Strategy Wiring" -ForegroundColor Magenta
Write-Host "  PASS: $pass  FAIL: $fail" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "======================================" -ForegroundColor Magenta

if ($fail -gt 0) { exit 1 }
exit 0
