<#
.SYNOPSIS
  Markers' two-player scenarios for tools/vm/pair.ps1 (the workspace's pair tooling): the real revive, which a solo
  player can't have (the last player's death ends the match). Ready to run; NOT RUN yet.
.DESCRIPTION
  A -ScenarioFile for pair.ps1: dot-sourced by it after its own pair-scenarios.ps1, in the same shape (Summary,
  Prereq, VMSetup, VMRestore, BeforeJoin, AfterJoin, PlaySec, LobbyMinutes, Check, HostModPaths), and adds mk-client
  and mk-host to its $PairScenarios (the last lines of this file).
    HostModPaths  a scriptblock returning UE4SS mod folders or package folders (mods/Nucleus/build/package), run once
                  at pair.ps1's step 3 (it stages them); pair.ps1 installs them into the HOST copy for the run only
                  (their mods are the first lines of mods.txt in this order: Nucleus first) and removes them afterwards.
  pair.ps1 refuses to start if any of them is already installed in the host copy (not by pair.ps1); mk-client's
  Prereq also refuses a host copy with Markers or core of its own (the host must stay unmodded but for the driver).
  Roles (test/MarkersDriver scenario.txt):
    mk-client  B (VM, client) = Nucleus + Markers + MarkersDriver "pair-victim": marks two flags and the satellite,
               is killed by the host, revived through the host's radio; then the revive checks on B.
               A (host) = MarkersDriver "pair-host" only (no Markers): a modded client of an unmodded host (CAP-3),
               and the host side of the kill and the reinforcement: BP_Radio_C:Reinformant(), the computer's
               "call reinforcement" (it picks SpawnReinforcementMethod2 when the dead player is queued, else the
               spectator path), called from Lua on the host, where the radio has authority.
    mk-host    A (host) = Nucleus + Markers + MarkersDriver "pair-hostvictim": marks, dies, calls Reinformant itself.
               B (VM) vanilla (UE4SS off): stays alive so the match goes on, and sees no change (CAP-3).
  Friends-only lobbies only (AGENTS.md "Networking"): pair.ps1's PairDriver creates them and stops the run if the
  flags ever say otherwise. Nothing is sent to anyone: the kill and the reinforcement are the game's own host-side
  functions on the test accounts' characters.
  Judging: mk-client -> check.ps1 -Scenario pair-victim on the VM log and -Scenario pair-host on the host log;
  mk-host -> check.ps1 -Scenario pair-hostvictim on the host log.
.EXAMPLE
  # from the workspace's main checkout (Nucleus built: mods/Nucleus/build.ps1; no game running on the host):
  ./tools/vm/pair.ps1 -Scenario mk-client -ScenarioFile mods/markers/test/pair/markers-scenarios.ps1
  ./tools/vm/pair.ps1 -Scenario mk-host   -ScenarioFile mods/markers/test/pair/markers-scenarios.ps1
  # after an aborted run: both games closed, host and VM copies put back
  ./tools/vm/pair.ps1 -Stop -Scenario mk-client -ScenarioFile mods/markers/test/pair/markers-scenarios.ps1
#>

$script:MarkersRepo = Split-Path (Split-Path $PSScriptRoot)
$script:NucleusPackage = Join-Path $MainCheckout 'mods\Nucleus\build\package'   # mods/ isn't in a workspace worktree

# Markers (and its driver, with the role in scenario.txt) staged by Markers' own deploy.ps1 -Staged into a fake copy,
# exactly what a host deploy installs. Returns the staged folders: @{ Markers; Driver; Core }.
function Get-MarkersStage([Parameter(Mandatory)] [ValidateSet('pair-victim', 'pair-host', 'pair-hostvictim')] [string] $Role) {
    if (-not (Test-Path (Join-Path $NucleusPackage 'Mods\Nucleus\mod.json'))) { throw "No Nucleus package at $NucleusPackage; build it with mods/Nucleus/build.ps1 (not while a game runs)." }
    $stage = Join-Path ([IO.Path]::GetTempPath()) "nn-markers-stage-$Role"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $win64 = Join-Path $stage 'NuclearNightmare\Binaries\Win64'
    $mods = Join-Path $win64 'ue4ss\Mods'
    New-Item -ItemType Directory -Force $mods | Out-Null
    Set-Content (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe') 'stage'
    Set-Content (Join-Path $win64 'ue4ss\UE4SS.dll') 'stage'
    Copy-Item (Join-Path $NucleusPackage 'Mods\Nucleus') $mods -Recurse
    [IO.File]::WriteAllText((Join-Path $mods 'mods.txt'), "Nucleus : 1`r`nKeybinds : 1`r`n")
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $MarkersRepo 'deploy.ps1') -Instance $stage -Test -Scenario $Role -Staged 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Markers' deploy.ps1 failed in the stage: $out" }
    @{ Markers = Join-Path $mods 'Markers'; Driver = Join-Path $mods 'MarkersDriver'; Core = $NucleusPackage }
}

# check.ps1 on one machine's log; -Target vm for the VM's (core's slow-tick warnings are soft there).
function Get-MarkersCheck([string] $Log, [string] $Scenario, [ValidateSet('host', 'vm')] [string] $Target = 'host') {
    if (-not ($Log -and (Test-Path $Log))) { return [ordered]@{ Scenario = $Scenario; Verdict = 'FAIL'; Note = "no log ($Log)" } }
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $MarkersRepo 'check.ps1') -Log $Log -Scenario $Scenario -Target $Target 2>&1 | Out-String
    [ordered]@{ Scenario = $Scenario; Verdict = $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }); Failures = @($out -split "`r?`n" | Where-Object { $_ -match '^FAIL' }) }
}

$script:MarkersPairScenarios = @{
    'mk-client' = @{
        Summary = 'Markers: B (client, modded) marks 2 flags + satellite, A (host, MarkersDriver only) kills B (DeathEvent) and reinforces it via the radio; B''s markers must come back'
        Prereq = {
            # The host stays unmodded but for the driver (CAP-3): no Markers or core of its own in the host copy.
            $own = @('Markers', 'Nucleus' | Where-Object { Test-Path (Join-Path $modsDir $_) }) + @('Nucleus.pak' | Where-Object { Test-Path (Join-Path $inst "NuclearNightmare\Content\Paks\LogicMods\$_") })
            if ($own.Count) { throw "mk-client needs a host copy without Markers or core; found $($own -join ', ') in $inst. Remove them (their deploy.ps1 -Remove) first." }
        }
        HostModPaths = { @((Get-MarkersStage -Role 'pair-host').Driver) }
        VMSetup = {
            $s = Get-MarkersStage -Role 'pair-victim'
            Restore-VMBaseline
            Invoke-VMDeploy -UE4SS On
            # Order matters: Nucleus first, then the driver, then Markers (vm-deploy adds each above Keybinds in turn).
            & (Join-Path $Workspace "tools/vm/vm-deploy.ps1") -Path $s.Core -First
            Invoke-VMDeploy -Path $s.Driver, $s.Markers
        }
        VMRestore = {
            $s = Get-MarkersStage -Role 'pair-victim'
            Invoke-VMDeploy -Remove -Path $s.Markers, $s.Driver, $s.Core
            Restore-VMBaseline
        }
        AfterJoin = {
            Save-ShotAt -Seconds 120 -Name 'marked' -Expect 'B in the match with 2 location waypoints and the satellite waypoint on screen'
            Wait-HostLine '\[MarkersDriver\] KILL victim ' 600 | Out-Null
            Save-ShotAt -Seconds 15 -Name 'dead' -Expect 'B dead (spectator view or death screen); no waypoints'
            Wait-HostLine '\[MarkersDriver\] OK REVIVED ' 300 | Out-Null
            Save-ShotAt -Seconds 10 -Name 'revived' -Expect 'B revived: the same 3 waypoints on screen with distances, white (bound to the live pawn)'
        }
        PlaySec = 60; LobbyMinutes = 1
        Check = {
            $r = [ordered]@{ Victim = (Get-MarkersCheck $vmLogPath 'pair-victim' -Target vm); Host = (Get-MarkersCheck (Join-Path $outDir "$Label.host.UE4SS.log") 'pair-host') }
            $r.Verdict = if ($r.Victim.Verdict -eq 'PASS' -and $r.Host.Verdict -eq 'PASS') { 'PASS' } else { 'FAIL' }
            $r
        }
    }
    'mk-host' = @{
        Summary = 'Markers: A (host, modded) marks 2 flags + satellite, dies, reinforces itself via the radio; A''s markers must come back; vanilla B unaffected'
        HostModPaths = { $s = Get-MarkersStage -Role 'pair-hostvictim'; @($s.Core, $s.Driver, $s.Markers) }
        VMSetup = { Restore-VMBaseline }
        VMRestore = { Restore-VMBaseline }
        AfterJoin = {
            Wait-HostLine '\[MarkersDriver\] KILL death ' 900 | Out-Null
            Save-ShotAt -Seconds 5 -Name 'host-dead' -Expect 'B (vanilla) still playing; nothing unusual on B''s screen'
            Wait-HostLine '\[MarkersDriver\] END result=' 400 | Out-Null
            Save-ShotAt -Seconds 2 -Name 'after' -Expect 'B (vanilla): its own markers (if any) unchanged; no notification or chat from the mod'
        }
        PlaySec = 60; LobbyMinutes = 1
        Check = {
            $r = [ordered]@{ HostVictim = (Get-MarkersCheck (Join-Path $outDir "$Label.host.UE4SS.log") 'pair-hostvictim') }
            $r.Verdict = $r.HostVictim.Verdict
            $r
        }
    }
}

# Into pair.ps1's table (it checks that no built-in scenario is replaced); a test may dot-source this file without it.
if ($script:PairScenarios -is [hashtable]) { foreach ($k in $MarkersPairScenarios.Keys) { $script:PairScenarios[$k] = $MarkersPairScenarios[$k] } }
