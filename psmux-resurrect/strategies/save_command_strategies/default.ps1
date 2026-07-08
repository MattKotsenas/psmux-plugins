#!/usr/bin/env pwsh
# Example @resurrect-save-command-strategy: 'default'
#
# Records the pane's current command verbatim -- the built-in behaviour you
# get when @resurrect-save-command-strategy is unset. Shipped as a reference
# for authoring your own save strategy.
#
# Contract: print exactly one line to stdout = the command to persist.
# Echo $Command unchanged when you cannot improve on it.
param(
    [Parameter(Position = 0)] [AllowEmptyString()] [string] $Command,
    [Parameter(Position = 1)] [AllowEmptyString()] [string] $PanePid,
    [Parameter(Position = 2)] [AllowEmptyString()] [string] $Directory
)

Write-Output $Command
