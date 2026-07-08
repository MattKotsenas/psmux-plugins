#!/usr/bin/env pwsh
# psmux-resurrect: Strategy resolution for SAVING pane commands
#
# Port of tmux-resurrect's @resurrect-save-command-strategy. At save time,
# instead of recording the bare pane_current_command, an optional GLOBAL
# strategy can compute a richer command to persist (e.g. resolve a shell
# alias, or an agent's resumable session id) so that restore can replay
# something more useful than the raw command name.
#
# Unlike the per-program RESTORE strategies (@resurrect-strategy-<program>),
# there is exactly ONE save strategy for all panes, matching tmux-resurrect's
# global @save-command-strategy contract.
#
# Activation (in psmux.conf):
#   set -g @resurrect-save-command-strategy '<strategy-name>'
#
# Lookup order (first match wins):
#   1. ~/.psmux/strategies/save_command_strategies/<strategy>.ps1  (user; override)
#   2. <plugin>/strategies/save_command_strategies/<strategy>.ps1  (bundled)
#
# Strategy contract:
#   Invoked as: pwsh -NoProfile -File <strategy>.ps1 <paneCommand> <panePid> <directory>
#   Writes ONE line to stdout: the command to persist for this pane.
#   Must echo the original command if it cannot improve on it.
#
# Default (option unset): record the bare pane_current_command. No child
# process is spawned in the default case, so save stays cheap per pane.

function Get-SaveCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PaneCommand,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PanePid,
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $PsmuxBin,
        [Parameter(Mandatory)] [string] $PluginDir,
        [string] $UserStrategiesDir = (Join-Path $env:USERPROFILE '.psmux\strategies\save_command_strategies')
    )

    $strategyName = ''
    try {
        $raw = (& $PsmuxBin show-options -gv '@resurrect-save-command-strategy' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $raw -and
            $raw -notmatch 'unknown option|error|no server|not found|refused') {
            $strategyName = $raw
        }
    } catch {}
    # Unset (or blank) strategy => record the bare command, no spawn.
    if ([string]::IsNullOrWhiteSpace($strategyName)) { return $PaneCommand }

    $pluginStrategies = Join-Path $PluginDir 'strategies\save_command_strategies'
    $candidates = @(
        (Join-Path $UserStrategiesDir ('{0}.ps1' -f $strategyName)),
        (Join-Path $pluginStrategies  ('{0}.ps1' -f $strategyName))
    )
    $strategyFile = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $strategyFile) { return $PaneCommand }

    $stdout = $null
    try {
        $stdout = & pwsh -NoProfile -ExecutionPolicy Bypass -File $strategyFile $PaneCommand $PanePid $Directory 2>$null
    } catch {
        return $PaneCommand
    }
    if ($null -eq $stdout) { return $PaneCommand }

    $resolved = (($stdout -join "`n") -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($resolved)) { return $PaneCommand }
    return $resolved.Trim()
}
