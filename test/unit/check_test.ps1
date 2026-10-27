<#
.SYNOPSIS
  Unit tests for check.ps1: synthetic UE4SS.log files, in the format the pinned UE4SS writes, for every scenario,
  each passing as written and failing after one targeted change. Proves the patterns, not the game.
.EXAMPLE
  pwsh -NoProfile -File test/unit/check_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$check = Join-Path $repo 'check.ps1'
$script:passed = 0; $script:failed = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("markers-check-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

$script:t = 0
function L([string] $tag, [string] $msg) { $script:t++; "[2026-10-26 01:00:{0:D2}.{1:D7}] [Lua] [$tag] $msg" -f [int]($script:t / 1000 % 60), $script:t }
function U([string] $msg) { $script:t++; "[2026-10-26 01:00:00.{0:D7}] $msg" -f $script:t }
function M([string] $msg) { L 'Markers' $msg }
function Dr([string] $msg) { L 'MarkersDriver' $msg }

function Run([string[]] $log, [string] $scenario, [string] $target = 'host') {
    $p = Join-Path $tmp "$scenario-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    Set-Content $p $log
    $out = & pwsh -NoProfile -NonInteractive -File $check -Log $p -Scenario $scenario -Target $target 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Expect([string[]] $log, [string] $scenario, [int] $code, [string] $name, [string] $mustSay, [string] $target = 'host') {
    $r = Run $log $scenario $target
    $ok = $r.Code -eq $code -and (-not $mustSay -or $r.Out -match $mustSay)
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name (exit $($r.Code), want $code)"; Write-Host ($r.Out -split "`n" | Where-Object { $_ -match 'FAIL|warn' } | Out-String) }
}
# The log without the lines matching $pattern / with $line added.
function Without([string[]] $log, [string] $pattern) { @($log | Where-Object { $_ -notmatch $pattern }) }

$P1 = '/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_2147482001'
$P2 = '/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_2147481500'
$P3 = '/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_2147481000'
function Start-Log([string] $scenario, [string] $onRevive = 'restore') { @(
    (U "Starting Lua mod 'Nucleus'"), (L 'Nucleus' 'READY version=0.2.0 native=0.2.0 ue4ss=v3.0.1-1181-g83330635 boot=1'),
    (U "Starting Lua mod 'MarkersDriver'"), (Dr "SCENARIO $scenario"), (Dr 'LOADED 40 steps'), (U "Starting Lua mod 'Markers'"),
    (M 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'), (M "READY onRevive=$onRevive"),
    (M 'DEBUG hud tick n=120 poll avg 20 max 90'), (M "PAWN first $P1")) }
function Restored([string] $n = '3') { @(
    (M "RESTORE location 'Weather Station' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M "RESTORE location 'Crash Site' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M "RESTORE satellite 'Satellite' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M "RESTORED n=$n (from actors 3, from the snapshot 0, failed 0, old destroyed 3) flags=6 satelliteFlags=1")) }
function DriverRestored([string] $p) { @(
    (Dr "OK ONE $p exactly one waypoint actor per marker (3 markers, 3 actors)"), (Dr "OK BOUND $p every location waypoint's Character is the new pawn"),
    (Dr "OK LOCAL $p every waypoint actor has bReplicates=false"), (Dr "OK DRAWN $p every marker's waypoint is painted"),
    (Dr "OK FLAGSMATCH $p the map shows exactly the marked flags selected (Crash Site,Satellite,Weather Station)")) }
$endPass = Dr 'END result=PASS checks=14 failures=0'

# ---------------------------------------------------------------- revive
$revive = (Start-Log 'revive') + @(
    (Dr 'OK MARKED mark 3 markers, one waypoint actor each (Crash Site,Satellite,Weather Station)'), (Dr 'OK DRAWN before every marker''s waypoint is painted'),
    (M "LOST pawn=$P1 snapshot n=3 (locations 2, satellite 1)"),
    (M "REVIVE pawn=$P2 was=$P1 snapshot=3 onRevive=restore")) + (Restored) + (DriverRestored 'revive1') + @(
    (Dr 'ANSWER journal-same-after-revive=yes'),
    (M "LOST pawn=$P2 snapshot n=3 (locations 2, satellite 1)"),
    (M "REVIVE pawn=$P3 was=$P2 snapshot=3 onRevive=clear"),
    (M "CLEAR location 'Weather Station'"), (M "CLEAR location 'Crash Site'"), (M "CLEAR satellite 'Satellite'"),
    (M 'CLEARED n=3 (failed 0) flags=6 satelliteFlags=1'),
    (Dr 'OK NONE revive2 no waypoint actor left (0)'), (Dr 'OK NOPAINT revive2 no waypoint painted'), (Dr 'OK FLAGSNONE revive2 no flag selected ()'),
    $endPass)
Expect $revive 'revive' 0 'revive: passes as written' 'All checks passed'
Expect $revive 'revive' 0 'revive -Target vm: passes' 'All checks passed' 'vm'
Expect (Without $revive 'CLEARED n=3') 'revive' 1 'revive: no CLEARED -> fails' 'not: REVIVE'
Expect (Without $revive 'RESTORED n=3') 'revive' 1 'revive: no RESTORED -> fails' 'RESTORED n=3'
Expect (($revive -replace "satellite 'Satellite' respawned bReplicates=false", "satellite 'Satellite' respawned bReplicates=true")) 'revive' 1 'revive: a replicated waypoint -> fails' 'bReplicates=true'
Expect (Without $revive 'LOST pawn=') 'revive' 1 'revive: no snapshot -> fails' 'LOST'
Expect ($revive + @(M "REBOUND pawn=$P3 was=$P2 (a new pawn without a HUD loss: restore only, never clear)") + (Restored)) 'revive' 1 'revive: a REBOUND -> fails' 'REBOUND'
Expect ($revive + @(M 'ERROR restore failed: boom')) 'revive' 1 'revive: an ERROR line -> fails' 'ERROR'
Expect ($revive + @(M 'WARN restore: could not update the map''s flags (boom)')) 'revive' 1 'revive: a WARN -> fails' 'WARN'
Expect ($revive + @(M 'WARN hud slow tick 1.4 ms (steady state)')) 'revive' 0 'revive -Target vm: a steady slow tick is soft' 'warn:' 'vm'
Expect ($revive + @(U 'stack traceback:')) 'revive' 1 'revive: a traceback -> fails' 'stack traceback'
Expect ($revive -replace 'END result=PASS', 'END result=FAIL') 'revive' 1 'revive: driver END FAIL -> fails' 'END result=PASS'
Expect ($revive + @(Dr 'FAIL BOUND revive1 every location waypoint''s Character is the new pawn')) 'revive' 1 'revive: a driver FAIL -> fails' 'FAIL'
Expect ($revive + @(M "RESTORE location 'X' respawned bReplicates=false via SpawnActor+ReceiveBeginPlay (deferred spawn failed: x)")) 'revive' 0 'revive: the fallback spawn is only a warning' 'warn:'
$unacted = $revive + @(M "AGAIN pawn=$P3 (its HUD came back within 15 s of the revive: running revive again)")
Expect $unacted 'revive' 1 'revive: an AGAIN without RESTORED/CLEARED -> fails' 'not: AGAIN'

# ---------------------------------------------------------------- probe
$probe = (Start-Log 'probe') + @(
    (Dr 'MAPOPEN 1 journal=Journal_C_1 mapui=MapUI_C_1 flags=6 dupes=0 constructs+1 first=LevelLocationUI_C_1'),
    (Dr 'ANSWER construct-every-open=yes flags-rebuilt-each-open=no (constructs=4 over 4 opens)'),
    (Dr 'OK MARKED mark 4 markers, one waypoint actor each (A,B,C,Satellite)'), (Dr 'PAINT before A=120 B=118 C=119 Satellite=120'),
    (Dr 'OK DRAWN before every marker''s waypoint is painted'),
    (M "LOST pawn=$P1 snapshot n=4 (locations 3, satellite 1)"), (M "DEBUG PAWN back $P1"),
    (Dr 'OK REPRO after RemoveAllWidgets no waypoint is painted (0 painted): the bug, and the paint hook sees it'),
    (Dr 'ANSWER repair rerun-beginplay(B)=not-drawn respawn(C)=drawn respawn(Satellite)=drawn toggle-space(A)=drawn'),
    (Dr 'OK RESPAWN-DRAWN a respawned waypoint is painted again (Markers'' way)'),
    (Dr 'OK LIVENESS a waypoint destroyed by its flag is not counted alive (FindAllOf=1, alive=0)'), $endPass)
Expect $probe 'probe' 0 'probe: passes as written' 'All checks passed'
Expect $probe 'probe' 0 'probe: prints the answers' 'ANSWER repair'
Expect ($probe + @(M "REVIVE pawn=$P2 was=$P1 snapshot=4 onRevive=restore") + (Restored)) 'probe' 1 'probe: any revive action -> fails' 'REVIVE'
Expect (Without $probe 'OK LIVENESS') 'probe' 1 'probe: no LIVENESS -> fails' 'LIVENESS'
Expect (Without $probe 'ANSWER construct') 'probe' 1 'probe: no construct answer -> fails' 'construct-every-open'

# ---------------------------------------------------------------- death
$death = (Start-Log 'death') + @(
    (Dr 'OK MARKED mark 3 markers, one waypoint actor each (A,B,Satellite)'), (Dr "KILL death $P1 ExplosionDamage ok=true "),
    (M "LOST pawn=$P1 snapshot n=3 (locations 2, satellite 1)"),
    (M 'PAWN /Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Spectator_C_1 (Spectator_C) is not a first-person character: not a revive'),
    (Dr 'OK DEAD the player no longer controls its first-person character'), (Dr 'OK KEPT the waypoint actors survive the death (3 of 3)'),
    (Dr 'OK UNTOUCHED no waypoint was rebound after a death without a revive'), $endPass)
Expect $death 'death' 0 'death: passes as written' 'All checks passed'
Expect ($death + @(M "REBOUND pawn=$P2 was=$P1 (x)") + (Restored)) 'death' 1 'death: a REBOUND -> fails' 'REBOUND'
Expect (Without $death 'LOST pawn') 'death' 1 'death: no snapshot -> fails' 'LOST'

# ---------------------------------------------------------------- no-core, old-core
$noCore = @((U "Starting Lua mod 'MarkersDriver'"), (Dr 'SCENARIO no-core'), (U "Starting Lua mod 'Markers'"),
    (M 'Nucleus is not installed. Markers will not run.'), (Dr 'OK NOMARKERS match1 reached the match; Markers'' one line is judged by check.ps1'), $endPass)
Expect $noCore 'no-core' 0 'no-core: passes as written' 'All checks passed'
Expect ($noCore + @(M 'READY onRevive=restore')) 'no-core' 1 'no-core: a second Markers line -> fails' '#1'
$oldCore = @((U "Starting Lua mod 'Nucleus'"), (Dr 'SCENARIO old-core'), (Dr 'OLDCORE published nucleus.version=0.1.0 (from Nucleus''s installed mod.json)'),
    (M 'ERROR Nucleus 0.1.0 is not compatible; Markers needs 0.2.0 (^ rules). Update Nucleus. Markers will not run.'),
    (Dr 'OK NOMARKERS match1 reached the match'), $endPass)
Expect $oldCore 'old-core' 0 'old-core: passes as written' 'All checks passed'
Expect ($oldCore -replace 'needs 0\.2\.0', 'needs 0.3.0') 'old-core' 1 'old-core: the need must be dependsOn''s minimum' 'not compatible'

# ---------------------------------------------------------------- pair
$victim = (Start-Log 'pair-victim') + @(
    (Dr 'OK MARKED mark 3 markers, one waypoint actor each (Crash Site,Satellite,Weather Station)'), (Dr 'VICTIM ready marked=Crash Site,Satellite,Weather Station'),
    (M "LOST pawn=$P1 snapshot n=3 (locations 2, satellite 1)"), (M "REVIVE pawn=$P2 was=$P1 snapshot=3 onRevive=restore")) + (Restored) + (DriverRestored 'revive') + @($endPass)
Expect $victim 'pair-victim' 0 'pair-victim: passes as written' 'All checks passed'
Expect (Without $victim 'OK DRAWN revive') 'pair-victim' 1 'pair-victim: not drawn after the revive -> fails' 'DRAWN'
$hostv = ($victim -replace 'SCENARIO pair-victim', 'SCENARIO pair-hostvictim')
Expect $hostv 'pair-hostvictim' 0 'pair-hostvictim: passes as written' 'All checks passed'
$pairHost = @((Dr 'SCENARIO pair-host'), (Dr 'KILL victim x ExplosionDamage ok=true '), (Dr 'VICTIM after death pawn class=Spectator_C'),
    (Dr 'REINFORCE radio:Reinformant() ok=true '), (Dr "OK REVIVED the victim has a new first-person character $P2"), $endPass)
Expect $pairHost 'pair-host' 0 'pair-host: passes as written' 'All checks passed'
Expect ($pairHost -replace 'class=Spectator_C', 'class=BP_ThirdPersonCharacter_C') 'pair-host' 1 'pair-host: victim became a monster -> fails (inconclusive)' 'BP_ThirdPersonCharacter_C'

# ---------------------------------------------------------------- hand
$hand = @((M 'CONNECT ok Nucleus 0.2.0 (pong)'), (M 'READY onRevive=restore'), (M "PAWN first $P1"),
    (M "LOST pawn=$P1 snapshot n=1 (locations 1, satellite 0)"), (M "REVIVE pawn=$P2 was=$P1 snapshot=1 onRevive=restore"),
    (M "RESTORE location 'A' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M 'RESTORED n=1 (from actors 1, from the snapshot 0, failed 0, old destroyed 1) flags=6 satelliteFlags=1'))
Expect $hand 'hand' 0 'hand: passes as written' 'All checks passed'
Expect (Without $hand 'RESTORED') 'hand' 1 'hand: a revive not acted on -> fails' 'not: REVIVE'
Expect (Without $hand 'READY') 'hand' 1 'hand: no READY -> fails' 'READY'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("check_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
