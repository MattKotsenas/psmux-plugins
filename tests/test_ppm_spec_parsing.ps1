#!/usr/bin/env pwsh
# =============================================================================
# ppm: Get-PluginName spec-parsing test
# =============================================================================
# Regression guard for '#branch'-pinned @plugin specs. Branch names may contain
# '/' (e.g. 'temp/integration'), so a naive ($spec -split '/')[-1] returns the
# branch tail ('integration') instead of the plugin name. That collapsed every
# branch-pinned spec to the same name, so ppm sourced 0 plugins at server start
# (continuum never ran -> no auto-restore after a reboot).
#
# Get-PluginName is extracted from ppm.ps1 via the AST so this test exercises the
# shipped function without executing ppm's entry point (which binds keys and
# sources plugins against the live server).
# =============================================================================
$ErrorActionPreference = 'Stop'

$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name$(if($detail){' >> ' + $detail})" -ForegroundColor Red
        $script:fail++
    }
}

$ppm = Join-Path (Split-Path $PSScriptRoot -Parent) 'ppm\ppm.ps1'
Write-Host "`n=== ppm Get-PluginName parsing test ===" -ForegroundColor Magenta
Write-Host "ppm.ps1: $ppm" -ForegroundColor Cyan

# Load ONLY the Get-PluginName function definition; never run the entry point.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ppm, [ref]$null, [ref]$null)
$fn = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PluginName'
}, $true)
if (-not $fn) {
    Write-Host "FATAL: Get-PluginName not found in ppm.ps1" -ForegroundColor Red
    exit 1
}
Invoke-Expression $fn.Extent.Text

# name derivation across every supported spec shape, with and without '#branch'
$cases = @(
    @{ spec = 'MattKotsenas/psmux-plugins/psmux-continuum#temp/integration'; exp = 'psmux-continuum' }
    @{ spec = 'MattKotsenas/psmux-plugins/ppm#temp/integration';             exp = 'ppm' }
    @{ spec = 'owner/repo';                                                  exp = 'repo' }
    @{ spec = 'owner/repo#main';                                             exp = 'repo' }
    @{ spec = 'owner/mono/sub';                                              exp = 'sub' }
    @{ spec = 'owner/mono/sub#feature/foo/bar';                              exp = 'sub' }
    @{ spec = 'psmux-sensible';                                              exp = 'psmux-sensible' }
    @{ spec = 'psmux-sensible#temp/integration';                            exp = 'psmux-sensible' }
    @{ spec = 'git@github.com:owner/repo.git#dev';                           exp = 'repo' }
    @{ spec = 'https://github.com/owner/repo.git';                           exp = 'repo' }
)

Write-Host "`n--- name derivation across spec shapes ---" -ForegroundColor Yellow
foreach ($c in $cases) {
    $got = Get-PluginName $c.spec
    Check "spec '$($c.spec)' -> '$($c.exp)'" ($got -eq $c.exp) "got '$got'"
}

# Regression: a branch-pinned monorepo spec must resolve to the plugin name, not
# the branch tail. This is the exact failure that stopped continuum from loading.
Write-Host "`n--- regression: branch tail must not shadow the plugin name ---" -ForegroundColor Yellow
$branchPinned = 'MattKotsenas/psmux-plugins/psmux-continuum#temp/integration'
Check "branch tail 'integration' does not shadow the name" `
    ((Get-PluginName $branchPinned) -ne 'integration') "got '$(Get-PluginName $branchPinned)'"
Check "branch-pinned spec resolves to 'psmux-continuum'" `
    ((Get-PluginName $branchPinned) -eq 'psmux-continuum') "got '$(Get-PluginName $branchPinned)'"

Write-Host "`n=== RESULT: $pass pass / $fail fail ===" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
