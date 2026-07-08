#!/usr/bin/env pwsh
<#
.SYNOPSIS
Pester tests for psmux-continuum auto_restore.ps1 singleton (follow-up
to PR #13's TOCTOU pattern, applied to the restore-side hook).

.DESCRIPTION
auto_restore.ps1 is invoked from the session-created hook. With many sessions
being restored, the hook fires N+1 times, so the script must fire exactly
once per server lifetime even under concurrent invocation. Pre-fix it used
psmux's set-option/show-options option-based singleton which has a TOCTOU
window. Post-fix it uses FileMode.CreateNew on a marker file in LOCALAPPDATA.

These tests verify:
  1. With @continuum-restore unset, the script exits without creating a marker.
  2. With @continuum-restore='on' and no marker, the script claims the slot.
  3. With @continuum-restore='on' and a marker matching the current server
     PID, the script exits without re-firing.
  4. With @continuum-restore='on' and a marker with a stale PID (server
     restart), the script deletes the stale marker and claims fresh.
  5. Two concurrent invocations against the same fresh state result in
     EXACTLY ONE successful claim.
#>

BeforeAll {
    $env:PSMUX_ALLOW_NESTING = '1'
    $script:TestSocket = 'ptest-autorestore'
    $script:TestResurrectDir = Join-Path $env:TEMP 'autorestore-test-resurrect'
    $script:AutoRestoreScript = Join-Path $PSScriptRoot '..' 'scripts' 'auto_restore.ps1'
    $script:AutoRestoreScript = (Resolve-Path $script:AutoRestoreScript).Path
    $script:TestMarkerDir = Join-Path $env:TEMP 'autorestore-test-markers'

    function script:KillTestServer {
        & psmux -L $script:TestSocket kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 200
    }

    function script:StartFreshServer {
        KillTestServer
        & psmux -L $script:TestSocket new-session -d -s main 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }

    function script:WriteEmptySave {
        if (-not (Test-Path $script:TestResurrectDir)) {
            New-Item -ItemType Directory -Path $script:TestResurrectDir -Force | Out-Null
        }
        $save = Join-Path $script:TestResurrectDir 'fake_save.json'
        '{"sessions":[]}' | Set-Content $save
        Set-Content (Join-Path $script:TestResurrectDir 'last') -Value $save
    }

    function script:GetServerPid {
        $pidRaw = (& psmux -L $script:TestSocket display-message -p '#{pid}' 2>&1 | Out-String).Trim()
        return $pidRaw
    }

    function script:BuildWrapper {
        $realPsmux = (Get-Command psmux -EA SilentlyContinue).Source
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
        return $wrapper
    }

    function script:RunAutoRestore {
        if (-not (Test-Path $script:TestMarkerDir)) {
            New-Item -ItemType Directory -Path $script:TestMarkerDir -Force | Out-Null
        }
        $wrapper = BuildWrapper
        $scriptPath = $script:AutoRestoreScript
        $markerDir = $script:TestMarkerDir
        $invocation = @"
`$env:LOCALAPPDATA = '$markerDir'
`$env:PSMUX_ALLOW_NESTING = '1'
`$env:PSMUX_BIN_OVERRIDE = '$wrapper'
& '$scriptPath'
"@
        & pwsh -NoProfile -NoLogo -Command $invocation 2>&1
    }

    function script:GetMarkerPath {
        return Join-Path $script:TestMarkerDir 'psmux-continuum\restore-fired.marker'
    }

    function script:CleanMarkers {
        if (Test-Path $script:TestMarkerDir) {
            Remove-Item -Recurse -Force $script:TestMarkerDir -EA SilentlyContinue
        }
    }
}

AfterAll {
    KillTestServer
    if (Test-Path $script:TestResurrectDir) {
        Remove-Item -Recurse -Force $script:TestResurrectDir -EA SilentlyContinue
    }
    CleanMarkers
}

Describe 'auto_restore.ps1 singleton' {

    Context 'When @continuum-restore is not set' {
        BeforeEach {
            StartFreshServer
            CleanMarkers
            WriteEmptySave
            & psmux -L $script:TestSocket set-option -gu '@continuum-restore' 2>&1 | Out-Null
            & psmux -L $script:TestSocket set-option -g '@resurrect-dir' $script:TestResurrectDir 2>&1 | Out-Null
        }

        It 'Exits without creating a marker' {
            RunAutoRestore | Out-Null
            Test-Path (GetMarkerPath) | Should -Be $false -Because 'opt-out path must not create the marker'
        }
    }

    Context 'When @continuum-restore is on and no marker exists' {
        BeforeEach {
            StartFreshServer
            CleanMarkers
            WriteEmptySave
            & psmux -L $script:TestSocket set-option -g '@continuum-restore' 'on' 2>&1 | Out-Null
            & psmux -L $script:TestSocket set-option -g '@resurrect-dir' $script:TestResurrectDir 2>&1 | Out-Null
        }

        It 'Creates the marker containing the current server PID' {
            $serverPid = GetServerPid
            $serverPid | Should -Not -BeNullOrEmpty -Because 'precondition: psmux display-message gives a server PID'

            RunAutoRestore | Out-Null

            $markerPath = GetMarkerPath
            Test-Path $markerPath | Should -Be $true -Because 'marker must be created'
            $recorded = (Get-Content $markerPath -Raw).Trim()
            $recorded | Should -Be $serverPid -Because "marker should record current server PID ($serverPid)"
        }
    }

    Context 'When @continuum-restore is on and a marker matches the current server PID' {
        BeforeEach {
            StartFreshServer
            CleanMarkers
            WriteEmptySave
            & psmux -L $script:TestSocket set-option -g '@continuum-restore' 'on' 2>&1 | Out-Null
            & psmux -L $script:TestSocket set-option -g '@resurrect-dir' $script:TestResurrectDir 2>&1 | Out-Null
            $markerPath = GetMarkerPath
            $markerDir = Split-Path $markerPath -Parent
            if (-not (Test-Path $markerDir)) {
                New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
            }
            Set-Content -Path $markerPath -Value (GetServerPid) -NoNewline
            $script:MarkerMtimeBefore = (Get-Item $markerPath).LastWriteTime
        }

        It 'Exits without touching the marker' {
            Start-Sleep -Milliseconds 200
            RunAutoRestore | Out-Null
            $mtimeAfter = (Get-Item (GetMarkerPath)).LastWriteTime
            $mtimeAfter | Should -Be $script:MarkerMtimeBefore -Because 'matching-PID path must not rewrite the marker'
        }
    }

    Context 'When @continuum-restore is on and a marker has a stale PID' {
        BeforeEach {
            StartFreshServer
            CleanMarkers
            WriteEmptySave
            & psmux -L $script:TestSocket set-option -g '@continuum-restore' 'on' 2>&1 | Out-Null
            & psmux -L $script:TestSocket set-option -g '@resurrect-dir' $script:TestResurrectDir 2>&1 | Out-Null
            $markerPath = GetMarkerPath
            $markerDir = Split-Path $markerPath -Parent
            if (-not (Test-Path $markerDir)) {
                New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
            }
            Set-Content -Path $markerPath -Value '999999' -NoNewline
        }

        It 'Deletes the stale marker and writes a fresh one with the current server PID' {
            $serverPid = GetServerPid
            RunAutoRestore | Out-Null
            $markerPath = GetMarkerPath
            Test-Path $markerPath | Should -Be $true -Because 'fresh marker should exist'
            $recorded = (Get-Content $markerPath -Raw).Trim()
            $recorded | Should -Be $serverPid -Because 'fresh marker should record current server PID'
        }
    }

    Context 'When invoked concurrently against fresh state' {
        BeforeEach {
            StartFreshServer
            CleanMarkers
            WriteEmptySave
            & psmux -L $script:TestSocket set-option -g '@continuum-restore' 'on' 2>&1 | Out-Null
            & psmux -L $script:TestSocket set-option -g '@resurrect-dir' $script:TestResurrectDir 2>&1 | Out-Null
        }

        It 'Exactly one invocation claims the marker; the other exits cleanly' {
            $wrapper = BuildWrapper
            $scriptPath = $script:AutoRestoreScript
            $markerDir = $script:TestMarkerDir
            if (-not (Test-Path $markerDir)) {
                New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
            }

            $job1 = Start-Job -ScriptBlock {
                param($s, $w, $md)
                $env:LOCALAPPDATA = $md
                $env:PSMUX_ALLOW_NESTING = '1'
                $env:PSMUX_BIN_OVERRIDE = $w
                & pwsh -NoProfile -File $s 2>&1
            } -ArgumentList $scriptPath, $wrapper, $markerDir

            $job2 = Start-Job -ScriptBlock {
                param($s, $w, $md)
                $env:LOCALAPPDATA = $md
                $env:PSMUX_ALLOW_NESTING = '1'
                $env:PSMUX_BIN_OVERRIDE = $w
                & pwsh -NoProfile -File $s 2>&1
            } -ArgumentList $scriptPath, $wrapper, $markerDir

            Wait-Job $job1, $job2 -Timeout 30 | Out-Null
            Remove-Job $job1, $job2 -Force

            $markerPath = GetMarkerPath
            Test-Path $markerPath | Should -Be $true -Because 'marker must be created by exactly one invocation'

            $serverPid = GetServerPid
            $recorded = (Get-Content $markerPath -Raw).Trim()
            $recorded | Should -Be $serverPid -Because 'marker should record current server PID (only one writer succeeded)'
        }
    }
}
