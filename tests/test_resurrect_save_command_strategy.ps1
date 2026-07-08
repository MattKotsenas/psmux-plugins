#!/usr/bin/env pwsh
# =============================================================================
# psmux-resurrect: Save-command strategy resolution unit tests
# Validates Get-SaveCommand in scripts/save_strategy.ps1 against the
# tmux-resurrect @save-command-strategy contract: single GLOBAL strategy,
# <strategy>.ps1 lookup, user-dir precedence over plugin-dir fallback,
# pane_pid pass-through, and fallback-to-bare-command on every failure path.
# =============================================================================
$ErrorActionPreference = 'Continue'

$pass = 0; $fail = 0

function Check($name, $cond, $detail = '') {
    if ($cond) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name $(if($detail){' >> ' + $detail})" -ForegroundColor Red
        $script:fail++
    }
}

$PSMUX = $null
foreach ($n in @('psmux', 'pmux', 'tmux')) {
    $b = Get-Command $n -ErrorAction SilentlyContinue
    if ($b) { $PSMUX = $b.Source; break }
}
if (-not $PSMUX) {
    Write-Host "FATAL: psmux binary not found!" -ForegroundColor Red
    exit 1
}

$PLUGIN_ROOT = Split-Path $PSScriptRoot -Parent
$PLUGIN_DIR  = Join-Path $PLUGIN_ROOT 'psmux-resurrect'
$SAVE_HELPER = Join-Path $PLUGIN_DIR 'scripts\save_strategy.ps1'

Write-Host "`n=== psmux-resurrect Save-Command Strategy Tests ===" -ForegroundColor Magenta
Write-Host "Helper: $SAVE_HELPER" -ForegroundColor Cyan

Check "save_strategy.ps1 exists" (Test-Path $SAVE_HELPER) $SAVE_HELPER
Check "bundled save_command_strategies dir exists" `
    (Test-Path (Join-Path $PLUGIN_DIR 'strategies\save_command_strategies')) ''
Check "default.ps1 reference strategy exists" `
    (Test-Path (Join-Path $PLUGIN_DIR 'strategies\save_command_strategies\default.ps1')) ''

. $SAVE_HELPER
Check "Get-SaveCommand is defined" (Get-Command Get-SaveCommand -ErrorAction SilentlyContinue) ''

# Scratch dir standing in for ~/.psmux/strategies/save_command_strategies.
# We do NOT change $env:USERPROFILE because psmux derives its socket path from
# it, and switching mid-run would lose the server we set options against.
$sandbox = Join-Path $env:TEMP "psmux_resurrect_save_test_$([guid]::NewGuid().ToString('N'))"
$sandboxStrategies = Join-Path $sandbox 'save_command_strategies'
$null = New-Item -ItemType Directory -Path $sandboxStrategies -Force

$OPT = '@resurrect-save-command-strategy'

try {
    & $PSMUX set-option -gu $OPT 2>&1 | Out-Null

    # --- Phase 1: no strategy set -> returns bare command (no spawn) ---
    Write-Host "`n--- Phase 1: No strategy set ---" -ForegroundColor Yellow
    $r = Get-SaveCommand -PaneCommand 'pwsh' -PanePid '1234' -Directory $sandbox `
        -PsmuxBin $PSMUX -PluginDir $PLUGIN_DIR -UserStrategiesDir $sandboxStrategies
    Check "unset $OPT -> returns bare command" ($r -eq 'pwsh') "Got: $r"

    # --- Phase 2: strategy set, no file on disk -> bare ---
    Write-Host "`n--- Phase 2: Strategy set, file missing ---" -ForegroundColor Yellow
    & $PSMUX set-option -g $OPT 'absent' 2>&1 | Out-Null
    $r = Get-SaveCommand -PaneCommand 'vim' -PanePid '77' -Directory $sandbox `
        -PsmuxBin $PSMUX -PluginDir $PLUGIN_DIR -UserStrategiesDir $sandboxStrategies
    Check "strategy set but file missing -> bare command" ($r -eq 'vim') "Got: $r"

    # --- Phase 3: user-dir strategy invoked, receives command|pid|dir ---
    Write-Host "`n--- Phase 3: User-dir strategy + pane_pid pass-through ---" -ForegroundColor Yellow
    $userStrategyPath = Join-Path $sandboxStrategies 'tag.ps1'
    @'
param([string]$Command, [string]$PanePid, [string]$Directory)
"TAG($Command|$PanePid|$Directory)"
'@ | Set-Content -Path $userStrategyPath -Encoding UTF8
    & $PSMUX set-option -g $OPT 'tag' 2>&1 | Out-Null
    $r = Get-SaveCommand -PaneCommand 'clod' -PanePid '3812' -Directory 'C:\work' `
        -PsmuxBin $PSMUX -PluginDir $PLUGIN_DIR -UserStrategiesDir $sandboxStrategies
    Check "user-dir strategy invoked with command|pid|dir" ($r -eq 'TAG(clod|3812|C:\work)') "Got: $r"

    # --- Phase 4: plugin-dir fallback (bundled default) when user-dir absent ---
    Write-Host "`n--- Phase 4: Plugin-dir fallback ---" -ForegroundColor Yellow
    & $PSMUX set-option -g $OPT 'default' 2>&1 | Out-Null
    $r = Get-SaveCommand -PaneCommand 'htop' -PanePid '9' -Directory $sandbox `
        -PsmuxBin $PSMUX -PluginDir $PLUGIN_DIR -UserStrategiesDir $sandboxStrategies
    Check "bundled default.ps1 echoes bare command" ($r -eq 'htop') "Got: $r"

    # --- Phase 5: user-dir overrides plugin-dir for same name ---
    Write-Host "`n--- Phase 5: User-dir precedence ---" -ForegroundColor Yellow
    $userDefault = Join-Path $sandboxStrategies 'default.ps1'
    @'
param([string]$Command, [string]$PanePid, [string]$Directory)
"USERDEFAULT($Command)"
'@ | Set-Content -Path $userDefault -Encoding UTF8
    $r = Get-SaveCommand -PaneCommand 'less' -PanePid '5' -Directory $sandbox `
        -PsmuxBin $PSMUX -PluginDir $PLUGIN_DIR -UserStrategiesDir $sandboxStrategies
    Check "user-dir default.ps1 wins over bundled" ($r -eq 'USERDEFAULT(less)') "Got: $r"

    # --- Phase 6: strategy prints nothing -> bare ---
    Write-Host "`n--- Phase 6: Empty strategy output ---" -ForegroundColor Yellow
    $silent = Join-Path $sandboxStrategies 'silent.ps1'
    @'
param([string]$Command, [string]$PanePid, [string]$Directory)
# prints nothing
'@ | Set-Content -Path $silent -Encoding UTF8
    & $PSMUX set-option -g $OPT 'silent' 2>&1 | Out-Null
    $r = Get-SaveCommand -PaneCommand 'bash' -PanePid '1' -Directory $sandbox `
        -PsmuxBin $PSMUX -PluginDir $PLUGIN_DIR -UserStrategiesDir $sandboxStrategies
    Check "empty strategy output -> bare command" ($r -eq 'bash') "Got: $r"
}
finally {
    & $PSMUX set-option -gu $OPT 2>&1 | Out-Null
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== Results: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
exit $(if ($fail -eq 0) { 0 } else { 1 })
