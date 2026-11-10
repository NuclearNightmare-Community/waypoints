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
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("waypoints-check-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

$script:t = 0
function L([string] $tag, [string] $msg) { $script:t++; "[2026-10-26 01:00:{0:D2}.{1:D7}] [Lua] [$tag] $msg" -f [int]($script:t / 1000 % 60), $script:t }
function U([string] $msg) { $script:t++; "[2026-10-26 01:00:00.{0:D7}] $msg" -f $script:t }
function M([string] $msg) { L 'Waypoints' $msg }
function Dr([string] $msg) { L 'WaypointsDriver' $msg }

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
    (U "Starting Lua mod 'WaypointsDriver'"), (Dr "SCENARIO $scenario"), (Dr 'LOADED 40 steps'), (U "Starting Lua mod 'Waypoints'"),
    (M 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'), (M "READY onRevive=$onRevive"),
    (M 'DEBUG hud tick n=120 poll avg 20 max 90'), (M "PAWN first $P1")) }
function Restored([string] $n = '3') { @(
    (M "RESTORE location 'Weather Station' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M "RESTORE location 'Crash Site' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M "RESTORE satellite 'Satellite' respawned bReplicates=false via BeginDeferredActorSpawnFromClass"),
    (M "RESTORED n=$n (from actors 3, from the snapshot 0, failed 0, old destroyed 3) flags=6 satelliteFlags=1")) }
function DriverRestored([string] $p) { @(
    (Dr "OK ONE $p exactly one waypoint actor per waypoint (3 waypoints, 3 actors)"), (Dr "OK BOUND $p every location waypoint's Character is the new pawn"),
    (Dr "OK LOCAL $p every waypoint actor has bReplicates=false"), (Dr "OK DRAWN $p every waypoint's waypoint is painted"),
    (Dr "OK FLAGSMATCH $p the map shows exactly the marked flags selected (Crash Site,Satellite,Weather Station)")) }
$endPass = Dr 'END result=PASS checks=14 failures=0'
# The driver's kill (V8.1.5+): one CallDamageEvent(1000), then the game's own signals.
function DriverDeath([string] $p, [string] $body = $P1) { @(
    (Dr "KILL $p before guard=false hp=100.0"), (Dr "KILL $p $body CallDamageEvent(1000) ok=true "),
    (Dr "DYING $p +0.0 s guard=true hp=-900.0"),
    (Dr "LEFT $p +12.0 s the controller's pawn is Spectator_C (/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Spectator_C_1) managed=true fallback=false"),
    (Dr "OK DIED $p the character took the game's death: Health <= 0 and the terminal-death gate open (+0.0 s)"),
    (Dr "OK SPECTATOR $p the controller's pawn became Spectator_C (Spectator_C at +12.0 s)")) }

# ---------------------------------------------------------------- revive
$revive = (Start-Log 'revive') + @(
    (Dr 'OK MARKED mark 3 waypoints, one waypoint actor each (Crash Site,Satellite,Weather Station)'), (Dr 'OK DRAWN before every waypoint''s waypoint is painted'),
    (Dr 'SOLO revive1 EOGLock=true ok=true')) + (DriverDeath 'revive1') + @(
    (Dr 'REINFORCE revive1 ReinforceSpecficPlayer(dead body BP_FirstPersonCharacter_C_2147482001) ok=true '),
    (M "LOST pawn=$P1 snapshot n=3 (locations 2, satellite 1)"),
    (M "REVIVE pawn=$P2 was=$P1 snapshot=3 onRevive=restore")) + (Restored) + @((Dr 'SOLO revive1 EOGLock=false ok=true')) + (DriverRestored 'revive1') + @(
    (Dr 'ANSWER journal-same-after-revive=yes'),
    (Dr 'SOLO revive2 EOGLock=true ok=true')) + (DriverDeath 'revive2' $P2) + @(
    (M "LOST pawn=$P2 snapshot n=3 (locations 2, satellite 1)"),
    (M "REVIVE pawn=$P3 was=$P2 snapshot=3 onRevive=clear"),
    (M "CLEAR location 'Weather Station'"), (M "CLEAR location 'Crash Site'"), (M "CLEAR satellite 'Satellite'"),
    (M 'CLEARED n=3 (failed 0) flags=6 satelliteFlags=1'), (Dr 'SOLO revive2 EOGLock=false ok=true'),
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
# Core's slow tick on the host (the real format): hard in steady state, soft during a map arrival (WORLD/TOUCHDOWN to HUD)
# or with a Lua GC step inside it (V8.2.1 revive, 2026-11-09: one 2208 us poll during the landing showcase).
$slow = M 'WARN hud slow tick 2208 us (poll 2202 us, watchers 6 us; steady state)'
$arrival = @((Dr 'WORLD match1 /Game/Maps/SmallLoweIsland/SmallMap.SmallMap'), (Dr 'TOUCHDOWN match1 requesting Enter'),
    (Dr 'VIEW match1 the camera is Helicopter_BP_Showcase_Landing_C''s (5.6 s after the HUD)'))
$hudUp = Dr "HUD match1 pawn=$P1 (the pawn's camera since 15.0 s; before it: Helicopter_BP_Showcase_Landing_C)"
$head, $tail = $revive[0..9], $revive[10..($revive.Count - 1)]
Expect ($head + $arrival + @($slow, $hudUp) + $tail) 'revive' 0 'revive: a steady slow tick during the map arrival is soft' 'during one: soft'
Expect ($head + $arrival + @($hudUp, $slow) + $tail) 'revive' 1 'revive: a steady slow tick after the HUD -> fails' 'outside a map arrival'
Expect ($revive + @($slow)) 'revive' 1 'revive: a steady slow tick with no arrival -> fails' 'outside a map arrival'
Expect ($revive + @(M 'WARN hud slow tick 1800 us (poll 1790 us, watchers 10 us; steady state, a Lua GC step ran inside it)')) 'revive' 0 'revive: a slow tick with a GC step is soft' 'warn:'
Expect ($revive + @(M 'WARN hud slow tick 1800 us (poll 1000 us, watchers 800 us; HUD event: attached)')) 'revive' 0 'revive: a slow HUD-event tick is soft' 'warn:'
Expect ($head + $arrival + @($slow, $hudUp) + $tail) 'revive' 0 'revive -Target vm: an arrival slow tick is soft' 'warn:' 'vm'
Expect ($revive + @(U 'stack traceback:')) 'revive' 1 'revive: a traceback -> fails' 'stack traceback'
Expect ($revive -replace 'END result=PASS', 'END result=FAIL') 'revive' 1 'revive: driver END FAIL -> fails' 'END result=PASS'
Expect ($revive + @(Dr 'FAIL BOUND revive1 every location waypoint''s Character is the new pawn')) 'revive' 1 'revive: a driver FAIL -> fails' 'FAIL'
Expect ($revive + @(M "RESTORE location 'X' respawned bReplicates=false via SpawnActor+ReceiveBeginPlay (deferred spawn failed: x)")) 'revive' 0 'revive: the fallback spawn is only a warning' 'warn:'
$unacted = $revive + @(M "AGAIN pawn=$P3 (its HUD came back within 15 s of the revive: running revive again)")
Expect $unacted 'revive' 1 'revive: an AGAIN without RESTORED/CLEARED -> fails' 'not: AGAIN'
Expect (Without $revive 'OK DIED revive2') 'revive' 1 'revive: the second kill not seen dying -> fails' 'DIED revive2'
Expect (Without $revive 'OK SPECTATOR revive1') 'revive' 1 'revive: no spectator after the first kill -> fails' 'SPECTATOR revive1'
Expect (Without $revive 'SOLO revive2 EOGLock=false') 'revive' 1 'revive: the match never released -> fails' 'EOGLock=false'
Expect ($revive + @(Dr 'KILL revive1 FALLBACK still possessed after 30 s: Health 0 (ok=true) + DeathEvent ok=true ')) 'revive' 0 'revive: the driver''s fallback re-kill is only a warning' 'warn:.*FALLBACK'

# ---------------------------------------------------------------- probe
$probe = (Start-Log 'probe') + @(
    (Dr 'MAPOPEN 1 journal=Journal_C_1 mapui=MapUI_C_1 flags=6 dupes=0 constructs+1 first=LevelLocationUI_C_1'),
    (Dr 'ANSWER construct-every-open=yes flags-rebuilt-each-open=no (constructs=4 over 4 opens)'),
    (Dr 'OK MARKED mark 4 waypoints, one waypoint actor each (A,B,C,Satellite)'), (Dr 'PAINT before A=120 B=118 C=119 Satellite=120'),
    (Dr 'OK DRAWN before every waypoint''s waypoint is painted'),
    (M "LOST pawn=$P1 snapshot n=4 (locations 3, satellite 1)"), (M "DEBUG PAWN back $P1"),
    (Dr 'OK REPRO after RemoveAllWidgets no waypoint is painted (0 painted): the bug, and the paint hook sees it'),
    (Dr 'ANSWER repair rerun-beginplay(B)=not-drawn respawn(C)=drawn respawn(Satellite)=drawn toggle-space(A)=drawn'),
    (Dr 'OK RESPAWN-DRAWN a respawned waypoint is painted again (Waypoints'' way)'),
    (Dr 'OK LIVENESS a waypoint destroyed by its flag is not counted alive (FindAllOf=1, alive=0)'), (Dr 'OK LIVEOK the 4 live waypoints are all still counted alive (4)'), $endPass)
Expect $probe 'probe' 0 'probe: passes as written' 'All checks passed'
Expect $probe 'probe' 0 'probe: prints the answers' 'ANSWER repair'
Expect ($probe + @(M "REVIVE pawn=$P2 was=$P1 snapshot=4 onRevive=restore") + (Restored)) 'probe' 1 'probe: any revive action -> fails' 'REVIVE'
Expect (Without $probe 'OK LIVENESS') 'probe' 1 'probe: no LIVENESS -> fails' 'LIVENESS'
Expect (Without $probe 'ANSWER construct') 'probe' 1 'probe: no construct answer -> fails' 'construct-every-open'

# ---------------------------------------------------------------- death
$death = (Start-Log 'death') + @(
    (Dr 'OK MARKED mark 3 waypoints, one waypoint actor each (A,B,Satellite)')) + (DriverDeath 'death') + @(
    (M "LOST pawn=$P1 snapshot n=3 (locations 2, satellite 1)"),
    (M 'PAWN /Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Spectator_C_1 (Spectator_C) is not a first-person character: not a revive'),
    (Dr 'OK DEAD the player no longer controls its first-person character'), (Dr 'OK KEPT the waypoint actors survive the death (3 of 3)'),
    (Dr 'OK UNTOUCHED no waypoint was rebound after a death without a revive'), $endPass)
Expect $death 'death' 0 'death: passes as written' 'All checks passed'
Expect ($death + @(M "REBOUND pawn=$P2 was=$P1 (x)") + (Restored)) 'death' 1 'death: a REBOUND -> fails' 'REBOUND'
Expect (Without $death 'LOST pawn') 'death' 0 'death: no snapshot (V8.1.3+: the managed death keeps the HUD) -> only a warning' 'warn:.*LOST'
Expect (Without $death 'OK DIED death') 'death' 1 'death: the kill not seen dying -> fails' 'DIED death'
Expect (Without $death 'OK SPECTATOR death') 'death' 1 'death: no spectator -> fails' 'SPECTATOR death'

# ---------------------------------------------------------------- no-core, old-core
$noCore = @((U "Starting Lua mod 'WaypointsDriver'"), (Dr 'SCENARIO no-core'), (U "Starting Lua mod 'Waypoints'"),
    (M 'Nucleus is not installed. Waypoints will not run.'), (Dr 'OK NOWAYPOINTS match1 reached the match; Waypoints'' one line is judged by check.ps1'), $endPass)
Expect $noCore 'no-core' 0 'no-core: passes as written' 'All checks passed'
Expect ($noCore + @(M 'READY onRevive=restore')) 'no-core' 1 'no-core: a second Waypoints line -> fails' '#1'
$oldCore = @((U "Starting Lua mod 'Nucleus'"), (Dr 'SCENARIO old-core'), (Dr 'OLDCORE published nucleus.version=0.1.0 (from Nucleus''s installed mod.json)'),
    (M 'ERROR Nucleus 0.1.0 is older than Waypoints needs (>=0.2.0). Update Nucleus. Waypoints will not run.'),
    (Dr 'OK NOWAYPOINTS match1 reached the match'), $endPass)
Expect $oldCore 'old-core' 0 'old-core: passes as written' 'All checks passed'
Expect ($oldCore -replace 'needs \(>=0\.2\.0\)', 'needs (>=0.3.0)') 'old-core' 1 'old-core: the need must be dependsOn''s version' 'is older than'

# ---------------------------------------------------------------- pair
$victim = (Start-Log 'pair-victim') + @(
    (Dr 'OK MARKED mark 3 waypoints, one waypoint actor each (Crash Site,Satellite,Weather Station)'), (Dr 'VICTIM ready marked=Crash Site,Satellite,Weather Station'),
    (Dr "SELFKILL the host's signal: CallDamageEvent(1000) on my pawn $P1 ok=true "), (Dr 'DYING victim +0.2 s guard=false hp=-900.0'),
    (Dr 'OK DIED victim the character took the game''s death (+0.2 s)'), (Dr 'OK SPECTATOR victim the controller''s pawn became Spectator_C (Spectator_C at +12.1 s)'),
    (M "LOST pawn=$P1 snapshot n=3 (locations 2, satellite 1)"), (M "REVIVE pawn=$P2 was=$P1 snapshot=3 onRevive=restore")) + (Restored) + (DriverRestored 'revive') + @($endPass)
Expect $victim 'pair-victim' 0 'pair-victim: passes as written' 'All checks passed'
Expect (Without $victim 'OK DRAWN revive') 'pair-victim' 1 'pair-victim: not drawn after the revive -> fails' 'DRAWN'
Expect (Without $victim 'OK SPECTATOR victim') 'pair-victim' 1 'pair-victim: no spectator -> fails' 'SPECTATOR victim'
$hostv = ($victim -replace 'SCENARIO pair-victim', 'SCENARIO pair-hostvictim' -replace '(OK (DIED|SPECTATOR)) victim', '$1 death')
Expect $hostv 'pair-hostvictim' 0 'pair-hostvictim: passes as written' 'All checks passed'
Expect (Without $hostv 'OK DIED death') 'pair-hostvictim' 1 'pair-hostvictim: the kill not seen dying -> fails' 'DIED death'
$pairHost = @((Dr 'SCENARIO pair-host'), (Dr 'KILL victim x signal (the victim calls CallDamageEvent(1000) on its own pawn) guard=false hp=100.0'),
    (Dr 'DYING victim +3.1 s guard=true hp=-900.0'), (Dr 'VICTIM after death pawn class=Spectator_C'), (Dr 'OK SPECTATOR victim the victim''s pawn became Spectator_C (Spectator_C)'),
    (Dr 'REINFORCE radio:Reinformant() ok=true '), (Dr "OK REVIVED the victim has a new first-person character $P2"), $endPass)
Expect $pairHost 'pair-host' 0 'pair-host: passes as written' 'All checks passed'
Expect (Without $pairHost 'OK SPECTATOR victim') 'pair-host' 1 'pair-host: no spectator check -> fails' 'SPECTATOR victim'
Expect ($pairHost + @(Dr 'KILL victim FALLBACK still alive 30 s after the signal (hp=100.0): the host''s CallDamageEvent(1000) ok=true ')) 'pair-host' 0 'pair-host: the host''s fallback kill is only a warning' 'warn:.*FALLBACK'
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
