<#
.SYNOPSIS
  Judges one run of Markers from UE4SS.log.
.DESCRIPTION
  Prints Markers', the driver's and UE4SS's relevant lines, then checks the patterns the scenario needs.
  A pattern must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines;
  "?pattern" is a soft check (reported as "warn:", never failing); "?!pattern" is a soft check that it matches nowhere.
  Then the scenario's computed checks: READY after CONNECT ok; LOST before the first REVIVE; every REVIVE, REBOUND and
  AGAIN followed by its RESTORED or CLEARED line before the next one; and for probe, the story 2 answers.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
  Scenarios (run.ps1 drives them): probe, revive, death, no-core, old-core. Pair scenarios (tools/vm/pair.ps1 with
  test/pair/markers-scenarios.ps1): pair-victim and pair-hostvictim judge the modded player's log, pair-host the host's
  driver. hand: a log from the README's hand check (Markers connected, no error, and every revive acted on).
  unit needs no log: it runs test.ps1.
  -Target vm judges a log from run.ps1 -Target vm: core's "hud slow tick" WARN under Markers' tag is soft there (the
  VM's game shares the CPU with the host). Markers has no timing scenario, so nothing is host-only.
.EXAMPLE
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\markers\revive.log -Scenario revive
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario hand
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\markers\probe.vm.log -Scenario probe -Target vm
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('probe', 'revive', 'death', 'no-core', 'old-core', 'pair-victim', 'pair-host', 'pair-hostvictim', 'hand', 'unit')]
    [string] $Scenario = 'revive',
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
if ($Scenario -eq 'unit') { & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test.ps1'); exit $LASTEXITCODE }
$CoreName = 'Nucleus'
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$C = [regex]::Escape($name); $D = [regex]::Escape("${name}Driver"); $K = [regex]::Escape($CoreName)
$needVer = ($manifest.dependsOn | Where-Object id -eq $CoreName.ToLowerInvariant()).version.TrimStart('^')
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
# Core's UI helpers log with Markers' tag; a slow tick is core's to judge (soft). In the VM every slow tick is soft.
$warnRule = if ($Target -eq 'vm') { "!\[$C\] WARN (?!hud slow tick )" } else { "!\[$C\] WARN (?!hud slow tick .*(HUD event|steady state, a Lua GC step ran inside it))" }
$running = @(
    "\[$C\] CONNECT ok $K \d+\.\d+\.\d+ "
    "#1|\[$C\] READY onRevive=(restore|clear)\s*$"
    "!\[$C\] ERROR"
    $warnRule
    "?!\[$C\] WARN hud slow tick "
    # Local only (CAP-3): every waypoint Markers spawns is unreplicated.
    "!\[$C\] RESTORE .*bReplicates=true"
    # The deferred spawn is the game's own path; the fallback working is fine, but say so.
    "?!\[$C\] RESTORE .*via SpawnActor\+ReceiveBeginPlay"
)
$driven = $running + @(
    "\[$D\] SCENARIO $([regex]::Escape($Scenario))\s*$"
    "\[$D\] END result=PASS"
)
$noAction = "!\[$C\] (REVIVE|REBOUND|AGAIN|RESTORED|CLEARED) "
function Get-RestoredChecks([string] $p) {
    @("\[$D\] OK ONE $p ", "\[$D\] OK BOUND $p ", "\[$D\] OK LOCAL $p ", "\[$D\] OK DRAWN $p ", "\[$D\] OK FLAGSMATCH $p ")
}
$expect = @{
    'probe' = $driven + @(
        "\[$C\] PAWN first "
        $noAction
        "\[$D\] OK MARKED mark 4 markers", "\[$D\] OK DRAWN before ", "\[$D\] OK REPRO ", "\[$D\] OK RESPAWN-DRAWN ", "\[$D\] OK LIVENESS ", "\[$D\] OK LIVEOK "
        "\[$D\] ANSWER construct-every-open=(yes|no|unknown) ", "\[$D\] ANSWER repair "
    )
    'revive' = $driven + @(
        "\[$C\] PAWN first "
        "\[$C\] LOST pawn=.* snapshot n=3 \(locations 2, satellite 1\)"
        "#2|\[$C\] REVIVE pawn="
        "\[$C\] REVIVE pawn=.* snapshot=3 onRevive=restore\s*$"
        "\[$C\] REVIVE pawn=.* onRevive=clear\s*$"
        "\[$C\] RESTORED n=3 \(from actors 3, from the snapshot 0, failed 0, old destroyed 3\)"
        "\[$C\] RESTORE satellite 'Satellite' respawned bReplicates=false"
        "\[$C\] CLEARED n=3 \(failed 0\)"
        "!\[$C\] RESTORED .*failed [1-9]"
        "!\[$C\] CLEARED .*failed [1-9]"
        "!\[$C\] REBOUND "
        "\[$D\] OK MARKED mark 3 markers", "\[$D\] OK DRAWN before "
        "\[$D\] OK NONE revive2 ", "\[$D\] OK NOPAINT revive2 ", "\[$D\] OK FLAGSNONE revive2 "
        "\[$D\] ANSWER journal-same-after-revive=(yes|no)"
    ) + (Get-RestoredChecks 'revive1')
    'death' = $driven + @(
        "\[$C\] PAWN first "
        "\[$C\] LOST pawn=.* snapshot n=3 \(locations 2, satellite 1\)"
        $noAction
        "\[$D\] OK MARKED mark 3 markers", "\[$D\] OK DEAD ", "\[$D\] OK KEPT ", "\[$D\] OK UNTOUCHED "
    )
    'no-core' = @(
        "#1|\[$C\] "
        "\[$C\] $K is not installed\. $C will not run\.\s*$"
        "\[$D\] OK NOMARKERS match1 "
        "\[$D\] END result=PASS"
    )
    'old-core' = @(
        "#1|\[$C\] "
        "\[$D\] OLDCORE published $($K.ToLowerInvariant())\.version=0\.1\.0 "
        "\[$C\] ERROR $K 0\.1\.0 is not compatible; $C needs $NeedRx \(\^ rules\)\. Update $K\. $C will not run\.\s*$"
        "\[$D\] OK NOMARKERS match1 "
        "\[$D\] END result=PASS"
    )
    'pair-victim' = $driven + @(
        "\[$C\] LOST pawn=.* snapshot n=3 "
        "\[$C\] REVIVE pawn=.* snapshot=3 onRevive=restore\s*$"
        "\[$C\] RESTORED n=3 .*failed 0"
        "\[$D\] VICTIM ready marked="
    ) + (Get-RestoredChecks 'revive')
    'pair-hostvictim' = $driven + @(
        "\[$C\] LOST pawn=.* snapshot n=3 "
        "\[$C\] REVIVE pawn=.* snapshot=3 onRevive=restore\s*$"
        "\[$C\] RESTORED n=3 .*failed 0"
    ) + (Get-RestoredChecks 'revive')
    'pair-host' = @(
        "\[$D\] SCENARIO pair-host\s*$"
        "\[$D\] REINFORCE radio:Reinformant\(\) ok=true"
        "\[$D\] OK REVIVED "
        "\[$D\] END result=PASS"
        "!\[$D\] VICTIM after death pawn class=BP_ThirdPersonCharacter_C"
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
    if ($Scenario -in 'revive', 'pair-victim', 'pair-hostvictim') {
        $il, $iv = (IndexOf "\[$C\] LOST pawn="), (IndexOf "\[$C\] REVIVE pawn=")
        if ($il -ge 0 -and $iv -gt $il) { Pass 'the snapshot (LOST) comes before the first REVIVE' } else { Fail "LOST before REVIVE (LOST at line $il, REVIVE at line $iv)" }
    }
}
if ($Scenario -in 'probe', 'revive', 'pair-victim', 'pair-hostvictim') {
    Write-Host '--- answers ---'
    $lines | Where-Object { $_ -match "\[$D\] (ANSWER|MAPOPEN|PAINT|AIM|LIVENESS|REPAIR|RESPAWN|JOURNAL) " } | ForEach-Object { Write-Host ($_ -replace '^.*\[MarkersDriver\] ', '') }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
