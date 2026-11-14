<#
.SYNOPSIS
  Judges one run of Waypoints from UE4SS.log.
.DESCRIPTION
  Prints Waypoints', the driver's and UE4SS's relevant lines, then checks the patterns the scenario needs.
  A pattern must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines;
  "?pattern" is a soft check (reported as "warn:", never failing); "?!pattern" is a soft check that it matches nowhere.
  Then the scenario's computed checks: READY after CONNECT ok; LOST before the first REVIVE; every REVIVE, REBOUND and
  AGAIN followed by its RESTORED or CLEARED line before the next one; for buttons, MARKALL's marked and flags equal the
  driver's EXPECT line (the map's distinct flag names minus the 2 marked by hand, plus 1 for a satellite flag) and a
  MAPSYNC after CLEARALL (the reopen), and MARKALL's flags equal the driver's MAP line (its table's count for the map
  the run travelled to); buttons also needs the panel placed under the map on both key opens (PANELPLACE) and a
  PANELFIT with a numeric rect, at least one hit and partial=0 on at least 2 of the run's map opens (none above 0); and for probe, the story 2 answers.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
  Scenarios (run.ps1 drives them): probe, revive, death, buttons, buttons-revive (the routine check: every check of
  buttons and of revive, from one match), no-core, old-core. Pair scenarios (tools/vm/pair.ps1 with
  test/pair/waypoints-scenarios.ps1): pair-victim and pair-hostvictim judge the modded player's log, pair-host the host's
  driver. hand: a log from the README's hand check (Waypoints connected, no error, and every revive acted on).
  unit needs no log: it runs test.ps1.
  -Target vm judges a log from run.ps1 -Target vm: core's "hud slow tick" WARN under Waypoints' tag is soft there (the
  VM's game shares the CPU with the host). Waypoints has no timing scenario, so nothing is host-only.
.EXAMPLE
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\waypoints\revive.log -Scenario revive
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario hand
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\waypoints\probe.vm.log -Scenario probe -Target vm
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('probe', 'revive', 'death', 'buttons', 'buttons-revive', 'no-core', 'old-core', 'pair-victim', 'pair-host', 'pair-hostvictim', 'hand', 'unit')]
    [string] $Scenario = 'revive',
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
if ($Scenario -eq 'unit') { & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test.ps1'); exit $LASTEXITCODE }
$CoreName = 'Nucleus'
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$C = [regex]::Escape($name); $D = [regex]::Escape("${name}Driver"); $K = [regex]::Escape($CoreName)
$needVer = ($manifest.dependsOn | Where-Object id -eq 'nuclearnightmare-community.nucleus').version
$NeedRx = [regex]::Escape($needVer)
if (-not $Log) {
    if (-not $Instance) { Write-Host 'FAIL: pass -Log <file> or -Instance <copy>'; exit 1 }
    $Log = Join-Path (Resolve-Path $Instance) 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
}
if (-not (Test-Path $Log)) { Write-Host "FAIL: no log at $Log"; exit 1 }

$lines = @(Get-Content $Log)
Write-Host "--- $name lines ($Scenario) ---"
$lines | Where-Object {
    ($_ -match "\[$C\]|\[$D\]" -and $_ -notmatch "\[$C\] (DEBUG )?hud ") -or
    $_ -match 'Error executing script|threw an exception|removing hook|Unhandled Exception|stack traceback|\[script_hook\]'
} | ForEach-Object { $_ -replace '^\[[^\]]+\]\s*', '' -replace '^\[Lua\]\s*', '' }

$always = @(
    '!Unhandled Exception'
    '!Error executing script'
    '!removing hook'
    '!stack traceback'
    '!\[script_hook\]'
    '!A function requiring userdata as param #1 was called without userdata'
    "!\[$D\] FAIL "
    "!\[$D\] .*STEP '.*' threw"
)
# Core's UI helpers log with Waypoints' tag; a slow tick is core's to judge (soft). On the host a steady-state one is
# judged after the patterns (a computed check: soft during a map arrival); in the VM every slow tick is soft.
$warnRule = "!\[$C\] WARN (?!hud slow tick )"
$running = @(
    "\[$C\] CONNECT ok $K \d+\.\d+\.\d+ "
    # 0.2.0: Mark all / Clear all set up on core's panels and buttons (buttons=no means core lacked them: an ERROR too).
    "#1|\[$C\] READY onRevive=(restore|clear) buttons=yes\s*$"
    "!\[$C\] ERROR"
    $warnRule
    "?!\[$C\] WARN hud slow tick "
    # Local only (CAP-3): every waypoint Waypoints spawns is unreplicated.
    "!\[$C\] RESTORE .*bReplicates=true"
    # The deferred spawn is the game's own path; the fallback working is fine, but say so.
    "?!\[$C\] RESTORE .*via SpawnActor\+ReceiveBeginPlay"
)
$driven = $running + @(
    "\[$D\] SCENARIO $([regex]::Escape($Scenario))\s*$"
    "\[$D\] END result=PASS"
    # The driver's kill is one CallDamageEvent(1000) and the game's own death; its re-kill after 30 s is allowed but said.
    "?!\[$D\] KILL .*FALLBACK "
)
# A death the driver caused (V8.1.5+): the game's own signals, Health <= 0 with the death gate open, then a spectator.
function Get-DeathChecks([string] $p) { @("\[$D\] OK DIED $p ", "\[$D\] OK SPECTATOR $p ") }
$noAction = "!\[$C\] (REVIVE|REBOUND|AGAIN|RESTORED|CLEARED) "
function Get-RestoredChecks([string] $p) {
    @("\[$D\] OK ONE $p ", "\[$D\] OK BOUND $p ", "\[$D\] OK LOCAL $p ", "\[$D\] OK DRAWN $p ", "\[$D\] OK FLAGSMATCH $p ")
}
# The revive checks (revive, and the routine buttons-revive): restore, then with clear nothing left.
$reviveChecks = @(
    "\[$C\] LOST pawn=.* snapshot n=3 \(locations 2, satellite 1\)"
    "#2|\[$C\] REVIVE pawn="
    "\[$C\] REVIVE pawn=.* snapshot=3 onRevive=restore\s*$"
    "\[$C\] REVIVE pawn=.* onRevive=clear\s*$"
    # 0.3.0: the driver sets onRevive=clear through Nucleus's settings service (settings-set), between the two revives.
    "#1|\[$D\] SETTINGS onRevive=clear via settings-set reply=ok:"
    "\[$D\] OK SETTINGS onRevive=clear accepted by $K's settings service"
    "\[$C\] RESTORED n=3 \(from actors 3, from the snapshot 0, failed 0, old destroyed 3\)"
    "\[$C\] RESTORE satellite 'Satellite' respawned bReplicates=false"
    "\[$C\] CLEARED n=3 \(failed 0\)"
    "!\[$C\] RESTORED .*failed [1-9]"
    "!\[$C\] CLEARED .*failed [1-9]"
    "!\[$C\] REBOUND "
    "\[$D\] OK DRAWN before "
    "\[$D\] OK NONE revive2 ", "\[$D\] OK NOPAINT revive2 ", "\[$D\] OK FLAGSNONE revive2 "
    "\[$D\] ANSWER journal-same-after-revive=(yes|no)"
    "\[$D\] SOLO revive1 EOGLock=true ok=true", "\[$D\] SOLO revive2 EOGLock=false ok=true"
) + (Get-RestoredChecks 'revive1') + (Get-DeathChecks 'revive1') + (Get-DeathChecks 'revive2')

# The buttons checks (buttons, and the routine buttons-revive): Mark all, Clear all, the reopen, the panel's place.
$buttonsChecks = @(
    "\[$D\] OK MAPKEY ", "\[$D\] EXPECT buttons marked=\d+ flags=\d+ satellite=(yes|no) "
    # The map the run travelled to (-Map, default Tower Island), its flag count from the driver's table.
    "#1|\[$D\] MAP \w+ /Game/Maps/\S+ flags=\d+\s*$", "\[$D\] OK FLAGCOUNT "
    # Mark all: one press, the 2 flags marked by hand already up, nothing failed; the world agrees (driver).
    "#1|\[$C\] MARKALL "
    "\[$C\] MARKALL marked=\d+ already=2 failed=0 waypoints=\d+ flags=\d+ satellite=(yes|none)\s*$"
    "\[$C\] MARK location '"
    "\[$D\] OK BPOINT markall ", "\[$D\] OK ALLMARKED markall ", "\[$D\] OK ALLSELECTED markall ", "\[$D\] OK LOCAL markall "
    # Clear all: one press, nothing failed, no waypoint left.
    "#1|\[$C\] CLEARALL "
    "\[$C\] CLEARALL cleared=\d+ direct=\d+ failed=0 waypoints=0 flags=\d+\s*$"
    "\[$D\] OK BPOINT clearall ", "\[$D\] OK ALLCLEARED clearall ", "\[$D\] OK NONESELECTED clearall "
    # Every map open synced (the Lua open while marking, the key opens), and the flags match the actors on the reopen.
    "\[$C\] MAPSYNC flags=\d+ selected=\d+ satellite=(yes|no|none)\s*$"
    "\[$D\] OK FLAGSMATCH reopen "
    # Story 5: the panel under the map square. Both key opens: placed where the intent says, in the host canvas's
    # units (driver PANELPLACE); and Waypoints' debug-only fit check: no drawn widget cuts into the panel.
    "#2|\[$D\] OK PANELPLACE "
    "\[$C\] PANELFIT rect=\(-?\d+,-?\d+\)-\(-?\d+,-?\d+\) screen=\d+x\d+ hits=[1-9]\d* partial=0\s*$"
    "!\[$C\] PANELFIT .*partial=[1-9]"
)
$expect = @{
    'probe' = $driven + @(
        "\[$C\] PAWN first "
        $noAction
        "\[$D\] OK MARKED mark 4 waypoints", "\[$D\] OK DRAWN before ", "\[$D\] OK REPRO ", "\[$D\] OK RESPAWN-DRAWN ", "\[$D\] OK LIVENESS ", "\[$D\] OK LIVEOK "
        "\[$D\] ANSWER construct-every-open=(yes|no|unknown) ", "\[$D\] ANSWER repair "
    )
    'revive' = $driven + @("\[$C\] PAWN first ", "\[$D\] OK MARKED mark 3 waypoints") + $reviveChecks
    'buttons' = $driven + @("\[$C\] PAWN first ", $noAction, "\[$D\] OK MARKED mark 2 waypoints") + $buttonsChecks
    # The routine check: both in one match; the revive part marks again after Clear all (phase remark).
    'buttons-revive' = $driven + @("\[$C\] PAWN first ", "\[$D\] OK MARKED mark 2 waypoints", "\[$D\] OK MARKED remark 3 waypoints") + $buttonsChecks + $reviveChecks
    'death' = $driven + @(
        "\[$C\] PAWN first "
        # Soft since V8.1.3: the game's managed death no longer calls RemoveAllWidgets, so the HUD (and core's `lost`)
        # may stay through the death (V8.1.5: no LOST). Nothing is lost without it: the snapshot is only used by a revive.
        "?\[$C\] LOST pawn=.* snapshot n=3 \(locations 2, satellite 1\)"
        $noAction
        "\[$D\] OK MARKED mark 3 waypoints", "\[$D\] OK DEAD ", "\[$D\] OK KEPT ", "\[$D\] OK UNTOUCHED "
    ) + (Get-DeathChecks 'death')
    'no-core' = @(
        "#1|\[$C\] "
        "\[$C\] $K is not installed\. $C will not run\.\s*$"
        "\[$D\] OK NOWAYPOINTS match1 "
        "\[$D\] END result=PASS"
    )
    'old-core' = @(
        "#1|\[$C\] "
        "\[$D\] OLDCORE published $($K.ToLowerInvariant())\.version=0\.1\.0 "
        "\[$C\] ERROR $K 0\.1\.0 is older than $C needs \($NeedRx\)\. Update $K\. $C will not run\.\s*$"
        "\[$D\] OK NOWAYPOINTS match1 "
        "\[$D\] END result=PASS"
    )
    'pair-victim' = $driven + @(
        "\[$C\] LOST pawn=.* snapshot n=3 "
        "\[$C\] REVIVE pawn=.* snapshot=3 onRevive=restore\s*$"
        "\[$C\] RESTORED n=3 .*failed 0"
        "\[$D\] VICTIM ready marked="
        # Mark all / Clear all on the client after the revive (its 3 waypoints already up), each pressed through
        # core's <Core>_OnClicked (not an OS click); the world checks as in buttons.
        "\[$D\] BPRESS markAll via ${K}_OnClicked ok=true", "\[$D\] BPRESS clearAll via ${K}_OnClicked ok=true"
        "#1|\[$C\] MARKALL ", "\[$C\] MARKALL marked=\d+ already=3 failed=0 "
        "#1|\[$C\] CLEARALL ", "\[$C\] CLEARALL cleared=\d+ direct=\d+ failed=0 waypoints=0 "
        "\[$D\] OK ALLMARKED pair ", "\[$D\] OK ALLSELECTED pair ", "\[$D\] OK ALLCLEARED pair ", "\[$D\] OK NONESELECTED pair "
    ) + (Get-RestoredChecks 'revive') + (Get-DeathChecks 'victim')
    'pair-hostvictim' = $driven + @(
        "\[$C\] LOST pawn=.* snapshot n=3 "
        "\[$C\] REVIVE pawn=.* snapshot=3 onRevive=restore\s*$"
        "\[$C\] RESTORED n=3 .*failed 0"
    ) + (Get-RestoredChecks 'revive') + (Get-DeathChecks 'death')
    'pair-host' = @(
        "\[$D\] SCENARIO pair-host\s*$"
        "\[$D\] REINFORCE radio:Reinformant\(\) ok=true"
        "\[$D\] OK SPECTATOR victim "
        "\[$D\] OK REVIVED "
        # CAP-3: the unmodded host's own waypoint, untouched by the client's revive, Mark all and Clear all.
        "\[$D\] OK MARKED host 1 waypoints", "\[$D\] OK UNAFFECTED host "
        "\[$D\] END result=PASS"
        "!\[$D\] VICTIM after death pawn class=BP_ThirdPersonCharacter_C"
        # The victim kills itself (its own CallDamageEvent RPC); the host's kill 30 s later is the fallback, said.
        "?!\[$D\] KILL victim FALLBACK "
    )
    'hand' = $running
}

$failed = 0
$warned = 0
function Fail([string] $label) { Write-Host "FAIL: $label"; $script:failed++ }
function Pass([string] $label) { Write-Host "ok:   $label" }
Write-Host "--- checks ($Scenario) ---"
foreach ($pattern in ($always + $expect[$Scenario])) {
    if ($pattern.StartsWith('#')) {
        $count, $p = $pattern.Substring(1) -split '\|', 2
        $hits = @($lines | Where-Object { $_ -match $p }).Count
        if ($hits -eq [int]$count) { Pass "$pattern (found $hits)" } else { Fail "$pattern (found $hits)" }
    } elseif ($pattern.StartsWith('?!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(2) }) { Write-Host "warn: $pattern"; $warned++ } else { Pass $pattern }
    } elseif ($pattern.StartsWith('?')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Pass $pattern } else { Write-Host "warn: $pattern"; $warned++ }
    } elseif ($pattern.StartsWith('!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Fail $pattern } else { Pass $pattern }
    } else {
        if ($lines | Where-Object { $_ -match $pattern }) { Pass $pattern } else { Fail $pattern }
    }
}

function IndexOf([string] $p) { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $p) { return $i } } return -1 }

if ($Scenario -notin 'no-core', 'old-core', 'pair-host') {
    $ic, $ir = (IndexOf "\[$C\] CONNECT ok "), (IndexOf "\[$C\] READY ")
    if ($ic -ge 0 -and $ir -gt $ic) { Pass 'READY comes after CONNECT ok' } else { Fail "READY comes after CONNECT ok (CONNECT at line $ic, READY at line $ir)" }
    # Every action announced (REVIVE, REBOUND, AGAIN) is carried out (RESTORED or CLEARED) before the next one.
    $open = $null; $acted = 0; $unacted = @()
    foreach ($l in $lines) {
        if ($l -match "\[$C\] (REVIVE|REBOUND|AGAIN) pawn=") { if ($open) { $unacted += $open }; $open = $Matches[1] }
        elseif ($l -match "\[$C\] (RESTORED|CLEARED) " -and $open) { $acted++; $open = $null }
    }
    if ($open) { $unacted += $open }
    if ($unacted) { Fail "every REVIVE/REBOUND/AGAIN is followed by RESTORED or CLEARED (not: $($unacted -join ', '))" }
    elseif ($acted) { Pass "every REVIVE/REBOUND/AGAIN is followed by RESTORED or CLEARED ($acted)" }
    if ($Scenario -in 'revive', 'buttons-revive', 'pair-victim', 'pair-hostvictim') {
        $il, $iv = (IndexOf "\[$C\] LOST pawn="), (IndexOf "\[$C\] REVIVE pawn=")
        if ($il -ge 0 -and $iv -gt $il) { Pass 'the snapshot (LOST) comes before the first REVIVE' } else { Fail "LOST before REVIVE (LOST at line $il, REVIVE at line $iv)" }
    }
}
# Core's HUD poll (it logs with Waypoints' tag; Waypoints itself has no per-tick work). On the host a steady-state slow
# tick fails, unless a Lua GC step ran inside it or it came during a map arrival: from the driver's WORLD or TOUCHDOWN
# line to its HUD line, while the game loads the map and plays the landing showcase. V8.2.1 revive (2026-11-09): one
# 2208 us poll there, between VIEW and HUD; the minute's average 91 us, the next minute's max 202 us.
if ($Target -eq 'host' -and $Scenario -notin 'no-core', 'old-core') {
    $arriving = $false; $slowHard = @(); $slowSoft = 0
    foreach ($l in $lines) {
        if ($l -match "\[$D\] (WORLD|TOUCHDOWN) ") { $arriving = $true }
        elseif ($l -match "\[$D\] HUD \S+ pawn=") { $arriving = $false }
        elseif ($l -match "\[$C\] WARN hud slow tick " -and $l -notmatch 'HUD event|a Lua GC step ran inside it') {
            if ($arriving) { $slowSoft++ } else { $slowHard += ($l -replace '^.*\] WARN ', '') }
        }
    }
    $rule = 'no steady-state hud slow tick outside a map arrival'
    if ($slowHard) { Fail "$rule (not: $($slowHard -join '; '))" }
    else { Pass ("$rule" + $(if ($slowSoft) { " ($slowSoft during one: soft)" } else { '' })) }
}
if ($Scenario -in 'buttons', 'buttons-revive') {
    # The AC: MARKALL marked = the map's distinct flag names - 2 + 1 with a satellite flag; flags = the distinct names.
    $exp = $lines | Where-Object { $_ -match "\[$D\] EXPECT buttons marked=(\d+) flags=(\d+) satellite=(yes|no) " } | Select-Object -First 1
    $mk = $lines | Where-Object { $_ -match "\[$C\] MARKALL marked=(\d+) already=\d+ failed=\d+ waypoints=(\d+) flags=(\d+) satellite=(\w+)" } | Select-Object -First 1
    if ($exp -and $mk) {
        $null = $exp -match "EXPECT buttons marked=(\d+) flags=(\d+) satellite=(yes|no) "; $em, $ef, $es = [int]$Matches[1], [int]$Matches[2], $Matches[3]
        $null = $mk -match "MARKALL marked=(\d+) already=\d+ failed=\d+ waypoints=(\d+) flags=(\d+) satellite=(\w+)"; $gm, $gw, $gf, $gs = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $Matches[4]
        $wantSat = if ($es -eq 'yes') { 'yes' } else { 'none' }
        $rule = "MARKALL matches the map (marked $gm of $em expected, flags $gf of $ef, waypoints $gw of $($ef + $(if ($es -eq 'yes') { 1 } else { 0 })), satellite $gs of $wantSat)"
        if ($gm -eq $em -and $gf -eq $ef -and $gs -eq $wantSat -and $gw -eq ($ef + $(if ($es -eq 'yes') { 1 } else { 0 }))) { Pass $rule } else { Fail $rule }
    } else { Fail 'MARKALL matches the map (no EXPECT or MARKALL line)' }
    $im, $ic = (IndexOf "\[$C\] MARKALL "), (IndexOf "\[$C\] CLEARALL ")
    $is = -1; for ($i = [Math]::Max($ic, 0); $i -lt $lines.Count; $i++) { if ($ic -ge 0 -and $lines[$i] -match "\[$C\] MAPSYNC ") { $is = $i; break } }
    if ($im -ge 0 -and $ic -gt $im -and $is -gt $ic) { Pass 'MARKALL, then CLEARALL, then a MAPSYNC (the reopen)' }
    else { Fail "MARKALL, then CLEARALL, then a MAPSYNC (MARKALL at line $im, CLEARALL at $ic, MAPSYNC after it at $is)" }
    # The map's count from the driver's table (the SPEC's 10/6/7/9) is what Mark all saw.
    $mp = $lines | Where-Object { $_ -match "\[$D\] MAP \w+ \S+ flags=\d+" } | Select-Object -First 1
    if ($mp -and $mk) {
        $null = $mp -match "MAP (\w+) \S+ flags=(\d+)"; $mkey, $mf = $Matches[1], [int]$Matches[2]
        $null = $mk -match ' flags=(\d+) '; $gf2 = [int]$Matches[1]
        $rule = "MARKALL flags=$gf2 is $mkey's $mf"
        if ($gf2 -eq $mf) { Pass $rule } else { Fail $rule }
    } else { Fail 'MARKALL flags is the map''s count (no MAP or MARKALL line)' }
    # Story 5: at least 2 of the run's map opens measured (the Lua open while marking and the two key opens all count).
    $fits = @($lines | Where-Object { $_ -match "\[$C\] PANELFIT rect=\(-?\d+,-?\d+\)-\(-?\d+,-?\d+\) screen=\d+x\d+ hits=[1-9]\d* partial=0\s*$" }).Count
    if ($fits -ge 2) { Pass "at least 2 good PANELFIT lines (found $fits)" } else { Fail "at least 2 good PANELFIT lines (found $fits)" }
}
if ($Scenario -in 'probe', 'revive', 'buttons-revive', 'pair-victim', 'pair-hostvictim') {
    Write-Host '--- answers ---'
    $lines | Where-Object { $_ -match "\[$D\] (ANSWER|MAPOPEN|PAINT|AIM|LIVENESS|REPAIR|RESPAWN|JOURNAL) " } | ForEach-Object { Write-Host ($_ -replace '^.*\[WaypointsDriver\] ', '') }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
