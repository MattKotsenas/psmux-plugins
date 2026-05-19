#!/usr/bin/env pwsh
<#
.SYNOPSIS
Pester tests for psmux-resurrect restore.ps1 pane-level reconciliation
(psmux/psmux-plugins#22 follow-up + the empty-default-session reuse fix).

.DESCRIPTION
Uses an ISOLATED psmux server (separate -L socket) so the test never touches
the user's running psmux. Each test:
  1. Tears down any leftover test server
  2. Spins up a fresh test server (creates an empty default session)
  3. Optionally pre-populates it (for "user has state" scenarios)
  4. Writes a synthetic save JSON to a temp resurrect dir
  5. Invokes restore.ps1 against the test server
  6. Asserts the resulting psmux state matches expectations
  7. Tears down

Requires Pester 5.x. Run with:
  Invoke-Pester -Path psmux-resurrect/tests/restore-pane-level.Tests.ps1

.NOTES
The test psmux server runs on socket name 'ptest-restore' so it never
collides with the user's normal server.
#>

BeforeAll {
    $env:PSMUX_ALLOW_NESTING = '1'
    $script:TestSocket = 'ptest-restore'
    $script:TestResurrectDir = Join-Path $env:TEMP 'psmux-resurrect-test'
    $script:RestoreScript = Join-Path $PSScriptRoot '..' 'scripts' 'restore.ps1'
    $script:RestoreScript = (Resolve-Path $script:RestoreScript).Path

    function script:KillTestServer {
        & psmux -L $script:TestSocket kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 200
    }

    function script:StartFreshServer {
        param([string]$SessionName = 'main')
        KillTestServer
        & psmux -L $script:TestSocket new-session -d -s $SessionName 2>&1 | Out-Null
        # Wait for psmux to actually have the session + 1 window visible.
        # new-session is async; sleeping a flat 300ms is not reliable.
        if (-not (WaitForWindowCount -SessionName $SessionName -Expected 1 -TimeoutMs 5000)) {
            throw "StartFreshServer timed out waiting for $SessionName to have 1 window"
        }
    }

    function script:CountWindows {
        param([string]$SessionName)
        $raw = & psmux -L $script:TestSocket list-windows -t $SessionName -F '#{window_index}' 2>&1
        @($raw | Where-Object { $_ -match '^\d+$' }).Count
    }

    function script:GetWindowNames {
        param([string]$SessionName)
        $raw = @(& psmux -L $script:TestSocket list-windows -t $SessionName -F '#{window_name}' 2>&1)
        @($raw | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -notmatch '^\s*$' })
    }

    function script:SessionExists {
        param([string]$SessionName)
        & psmux -L $script:TestSocket has-session -t $SessionName 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    }

    function script:WaitForWindowCount {
        param([string]$SessionName, [int]$Expected, [int]$TimeoutMs = 5000)
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline) {
            $count = CountWindows -SessionName $SessionName
            if ($count -eq $Expected) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }

    function script:WriteSaveJson {
        param($Sessions)
        if (-not (Test-Path $script:TestResurrectDir)) {
            New-Item -ItemType Directory -Path $script:TestResurrectDir -Force | Out-Null
        }
        $saveFile = Join-Path $script:TestResurrectDir 'psmux_resurrect_test.json'
        $payload = [pscustomobject]@{ sessions = $Sessions }
        $payload | ConvertTo-Json -Depth 10 | Set-Content $saveFile
        $lastFile = Join-Path $script:TestResurrectDir 'last'
        Set-Content -Path $lastFile -Value $saveFile
        return $saveFile
    }

    function script:RunRestore {
        # Set @resurrect-dir on the TEST server so restore.ps1 reads from it.
        & psmux -L $script:TestSocket set-option -g '@resurrect-dir' $script:TestResurrectDir 2>&1 | Out-Null

        # Write a wrapper .cmd that calls the real psmux binary with -L <socket>.
        # .cmd is faster than .ps1 (no pwsh-spawn overhead per psmux invocation),
        # which avoids flakiness when restore.ps1 calls psmux dozens of times.
        $realPsmux = (Get-Command psmux -EA SilentlyContinue).Source
        if (-not $realPsmux) { throw "Real psmux not found on PATH" }
        $wrapperDir = Join-Path $env:TEMP 'psmux-test-wrapper'
        if (-not (Test-Path $wrapperDir)) {
            New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null
        }
        $wrapper = Join-Path $wrapperDir 'psmux-test-wrapper.cmd'
        $sock = $script:TestSocket
        @"
@echo off
`"$realPsmux`" -L "$sock" %*
"@ | Set-Content $wrapper

        # Invoke restore.ps1 in a child pwsh with the override env var set.
        $rs = $script:RestoreScript
        $invocation = @"
`$env:PSMUX_ALLOW_NESTING = '1'
`$env:PSMUX_BIN_OVERRIDE = '$wrapper'
& '$rs'
"@
        pwsh -NoProfile -NoLogo -Command $invocation
    }
}

AfterAll {
    KillTestServer
    if (Test-Path $script:TestResurrectDir) {
        Remove-Item -Recurse -Force $script:TestResurrectDir -EA SilentlyContinue
    }
}

Describe 'Pane-level reconciliation' {

    Context 'When target session is the empty default (1 window, 1 pane)' {

        BeforeEach {
            StartFreshServer -SessionName 'main'
        }

        It 'Reuses the existing empty session for the saved first window' {
            $sessions = @(
                [pscustomobject]@{
                    name    = 'main'
                    windows = @(
                        [pscustomobject]@{
                            index = 1
                            name  = 'editor'
                            active = $true
                            panes = @(
                                [pscustomobject]@{
                                    index     = 1
                                    active    = $true
                                    directory = $env:USERPROFILE
                                    command   = 'pwsh'
                                }
                            )
                        }
                    )
                }
            )
            WriteSaveJson $sessions | Out-Null

            RunRestore

            CountWindows -SessionName 'main' | Should -Be 1 -Because 'one saved window should be present after reuse'
            $names = @(GetWindowNames -SessionName 'main')
            $names[0] | Should -Be 'editor' -Because 'reused window should be renamed to match saved name'
        }

        It 'Adds saved additional windows on top of the reused first window' {
            $sessions = @(
                [pscustomobject]@{
                    name    = 'main'
                    windows = @(
                        [pscustomobject]@{
                            index = 1
                            name  = 'editor'
                            active = $true
                            panes = @([pscustomobject]@{
                                index = 1; active = $true; directory = $env:USERPROFILE; command = 'pwsh'
                            })
                        },
                        [pscustomobject]@{
                            index = 2
                            name  = 'logs'
                            panes = @([pscustomobject]@{
                                index = 1; active = $true; directory = $env:USERPROFILE; command = 'pwsh'
                            })
                        },
                        [pscustomobject]@{
                            index = 3
                            name  = 'build'
                            panes = @([pscustomobject]@{
                                index = 1; active = $true; directory = $env:USERPROFILE; command = 'pwsh'
                            })
                        }
                    )
                }
            )
            WriteSaveJson $sessions | Out-Null

            RunRestore

            CountWindows -SessionName 'main' | Should -Be 3 -Because 'reuse + 2 new windows'
            $names = GetWindowNames -SessionName 'main'
            $names | Should -Contain 'editor'
            $names | Should -Contain 'logs'
            $names | Should -Contain 'build'
        }
    }

    Context 'When target session has user state (multiple windows)' {

        BeforeEach {
            StartFreshServer -SessionName 'main'
            # Add a second window to simulate user activity.
            # psmux new-window completes async; wait for the window to be visible.
            & psmux -L $script:TestSocket new-window -t 'main' -n 'user-opened' 2>&1 | Out-Null
            WaitForWindowCount -SessionName 'main' -Expected 2 -TimeoutMs 5000 | Out-Null
        }

        It 'Skips and preserves the existing user state' {
            # Precondition: setup actually produced 2 windows
            SessionExists -SessionName 'main' | Should -Be $true -Because 'precondition: setup created main'
            $countBefore = CountWindows -SessionName 'main'
            $countBefore | Should -Be 2 -Because 'precondition: setup added a user-opened window on top of default'

            $sessions = @(
                [pscustomobject]@{
                    name    = 'main'
                    windows = @(
                        [pscustomobject]@{
                            index = 1
                            name  = 'editor'
                            active = $true
                            panes = @([pscustomobject]@{
                                index = 1; active = $true; directory = $env:USERPROFILE; command = 'pwsh'
                            })
                        }
                    )
                }
            )
            WriteSaveJson $sessions | Out-Null

            RunRestore
            $countAfter = CountWindows -SessionName 'main'

            $countAfter | Should -Be $countBefore -Because 'user state must not be modified'
            $names = @(GetWindowNames -SessionName 'main')
            $names | Should -Contain 'user-opened' -Because 'user-created window should still be there'
        }
    }

    Context 'When target session does not exist' {

        BeforeEach {
            KillTestServer
            # Start server with a placeholder session so 'main' doesn't exist.
            & psmux -L $script:TestSocket new-session -d -s 'placeholder' 2>&1 | Out-Null
            Start-Sleep -Milliseconds 300
        }

        It 'Creates the session from scratch (existing pre-fix behavior)' {
            $sessions = @(
                [pscustomobject]@{
                    name    = 'main'
                    windows = @(
                        [pscustomobject]@{
                            index = 1
                            name  = 'editor'
                            active = $true
                            panes = @([pscustomobject]@{
                                index = 1; active = $true; directory = $env:USERPROFILE; command = 'pwsh'
                            })
                        }
                    )
                }
            )
            WriteSaveJson $sessions | Out-Null

            RunRestore

            $sessionsRaw = & psmux -L $script:TestSocket list-sessions -F '#{session_name}' 2>&1
            $sessionsRaw | Should -Contain 'main'
            CountWindows -SessionName 'main' | Should -Be 1
        }
    }
}
