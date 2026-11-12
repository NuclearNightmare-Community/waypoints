<#
.SYNOPSIS
  Installs Waypoints into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Refuses (exit 1, one line) unless Nucleus (core) is installed in the copy, enabled in mods.txt, and its installed
  mod.json version satisfies Waypoints' dependsOn (a minimum, not below the installed core's compat.floor;
  deploy-lib.ps1). -Force installs anyway, for the failure scenarios
  (Waypoints' own runtime check then has to catch it).
  Installs ue4ss/Mods/Waypoints/{mod.json, Scripts/main.lua, revive.lua, waypoints.lua, game.lua} and generates
  Scripts/settings.lua from mod.json's setting defaults (-OnRevive overrides onRevive). Writes "Waypoints : 1" into
  mods.txt right below Nucleus's line and above "Keybinds : 1", moving it there if it was elsewhere. Never writes
  outside Mods/Waypoints, Mods/WaypointsDriver and those mods.txt lines, and never bundles any of core's files.
  -Test also installs the test driver (test/WaypointsDriver as Mods/WaypointsDriver, between Nucleus and Waypoints), writes
  the scenario to its Scripts/scenario.txt, and turns on Waypoints' DEBUG lines (settings.lua debug = true), which
  check.ps1 reads. The driver is never shipped.
  -Map (with -Test) writes the solo scenarios' match map to the driver's Scripts/map.txt: only a key of the driver's
  fixed table (LowIsland, TowerIsland, Forest, Crevasse); without -Map there is no map.txt (the driver's default,
  Tower Island). Every test deploy removes a stale map.txt first. -Map without -Test writes nothing (a warning).
  -Remove deletes Mods/Waypoints, Mods/WaypointsDriver and their mods.txt lines; nothing else changes (mods.txt keeps its
  bytes when it had no Waypoints lines).
  -Staged: $Instance is the host-side staging folder of a VM run (run.ps1 -Target vm, tools/vm/vm-sp.ps1), not a game
  copy; only the running-game check is skipped (no game runs from it, and the host's game may be in use meanwhile).
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -OnRevive clear
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Test -Scenario revive
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Test -Scenario buttons -Map Forest
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [ValidateSet('probe', 'revive', 'death', 'buttons', 'buttons-revive', 'no-core', 'old-core', 'pair-victim', 'pair-host', 'pair-hostvictim')]
    [string] $Scenario = 'revive',
    [ValidateSet('', 'LowIsland', 'TowerIsland', 'Forest', 'Crevasse', IgnoreCase = $false)] [string] $Map = '',  # '': the driver's default (TowerIsland)
    [ValidateSet('', 'restore', 'clear')] [string] $OnRevive = '',  # '': mod.json's default
    [switch] $Force,
    [switch] $Remove,
    [switch] $Staged
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

$CoreName = 'Nucleus' # core's folder and mods.txt name: the one place this script spells it
$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
$driver   = "${name}Driver"
$inst     = (Resolve-Path $Instance).Path
$win64    = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
$ue4ss    = Join-Path $win64 'ue4ss'
$modsDir  = Join-Path $ue4ss 'Mods'
$modsTxt  = Join-Path $modsDir 'mods.txt'
$files    = $ModScripts

function Stop-Deploy([string] $why) { Write-Host "$name not deployed: $why"; exit 1 }

if (-not (Test-Path (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'))) { Stop-Deploy "not a game instance: $inst" }
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) { Stop-Deploy "UE4SS is not installed in $win64" }
if (-not (Test-Path $modsTxt)) { Stop-Deploy "no mods.txt in $modsDir" }
if (-not $Staged -and (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue)) { Stop-Deploy 'Nuclear Nightmare is running; close it first.' }

$file  = Read-ModsTxt $modsTxt
$mine  = @($name, $driver)
$clean = Edit-ModsTxt -Lines $file.Lines -Remove $mine

if ($Remove) {
    foreach ($d in $mine) { Remove-Item (Join-Path $modsDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($clean.Count -ne $file.Lines.Count) { Write-ModsTxt $modsTxt $file $clean }
    Write-Host "$name removed (and $driver, if it was installed)."
    return
}

# Core: installed, enabled, and a version Waypoints' dependsOn accepts.
$dep = @($manifest.dependsOn | Where-Object { $_.id -eq $CoreName.ToLowerInvariant() })[0]
if (-not $dep) { throw "mod.json has no dependsOn entry for $($CoreName.ToLowerInvariant())" }
$coreJson = Join-Path $modsDir "$CoreName\mod.json"
$problem = $null
if (-not (Test-Path $coreJson)) {
    $problem = "$CoreName is not installed in $modsDir (no $CoreName\mod.json); install it first with its own deploy.ps1."
} else {
    $core = $null
    try { $core = Get-Content $coreJson -Raw | ConvertFrom-Json } catch { }
    $state = Get-ModsTxtState -Lines $clean -Name $CoreName
    $floor = $null
    try { $floor = $core.compat.floor } catch { }
    $fit = if ($core) { Test-VersionNeed -Version $core.version -Need $dep.version -Floor $floor }
    if (-not $core -or $core.id -ne $dep.id) {
        $problem = "$coreJson is not $CoreName's manifest (id '$($core.id)', expected '$($dep.id)')."
    } elseif ($fit -in 'core-too-old', 'bad-have') {
        $problem = "$CoreName $($core.version) is installed, but $name needs $($dep.version); update $CoreName."
    } elseif ($fit -eq 'mod-too-old') {
        $problem = "$name was made for $CoreName $($dep.version), which this $CoreName $($core.version) no longer supports (oldest: $floor); update $name."
    } elseif ($state -ne 'enabled') {
        $problem = "$CoreName is installed but $state in mods.txt; enable it ('$CoreName : 1', its first line)."
    }
}
if ($problem) {
    if (-not $Force) { Stop-Deploy $problem }
    Write-Warning "forced: $problem"
}

# Waypoints' files, and its settings from mod.json.
$override = @{}
if ($OnRevive) { $override.onRevive = $OnRevive }
$settings = ConvertTo-SettingsLua -Manifest $manifest -Override $override -DebugLog:$Test
foreach ($d in $mine) { Remove-Item (Join-Path $modsDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
$dest = Join-Path $modsDir "$name\Scripts"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here 'mod.json') (Join-Path $modsDir $name) -Force
foreach ($f in $files) { Copy-Item (Join-Path $here "Scripts\$f") $dest -Force }
[IO.File]::WriteAllText((Join-Path $dest 'settings.lua'), $settings, [Text.UTF8Encoding]::new($false))

# mods.txt: below core, above Keybinds. The driver goes between core and Waypoints (its old-core mode must run before
# Waypoints' main.lua).
$add = @($name)
if ($Map -and -not $Test) { Write-Warning "-Map $Map needs -Test (it picks the test driver's map); ignored." }
if ($Test) {
    Copy-Item (Join-Path $here 'test\WaypointsDriver') (Join-Path $modsDir $driver) -Recurse -Force
    foreach ($f in 'scenario.txt', 'map.txt', 'request.txt', 'done.txt') { Remove-Item (Join-Path $modsDir "$driver\Scripts\$f") -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText((Join-Path $modsDir "$driver\Scripts\scenario.txt"), $Scenario)
    if ($Map) { [IO.File]::WriteAllText((Join-Path $modsDir "$driver\Scripts\map.txt"), $Map) }
    $add = @($driver, $name)
}
$lines = Edit-ModsTxt -Lines $clean -Add $add -After $CoreName
Write-ModsTxt $modsTxt $file $lines

Write-Host "$name $($manifest.version) deployed$(if ($Test) { " with $driver (scenario $Scenario$(if ($Map) { ", map $Map" }))" }):"
Get-ChildItem (Join-Path $modsDir $name) -Recurse -File | ForEach-Object { Write-Host "  Mods/$name/$($_.FullName.Substring((Join-Path $modsDir $name).Length + 1)) ($($_.Length) bytes)" }
Write-Host "  settings.lua: $(($settings -split "`n")[1])"
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*[\w-]+\s*:\s*1' }) -join ', ')"
