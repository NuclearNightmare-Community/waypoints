<#
.SYNOPSIS
  Unit tests for deploy-lib.ps1 (version needs, mods.txt editing, settings.lua) and deploy.ps1 end to end against a
  fake game instance in a temp folder (never a real copy: no game, no UE4SS, only the files deploy.ps1 looks at).
.EXAMPLE
  pwsh -NoProfile -File test/unit/deploy_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'deploy-lib.ps1')
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}
function Eq($got, $want, [string] $name) { Ok ($got -eq $want) $name "got '$got', want '$want'" }
function Throws([scriptblock] $b, [string] $text, [string] $name) {
    try { & $b; Ok $false $name 'did not throw' } catch { Ok ($_.Exception.Message -like "*$text*") $name $_.Exception.Message }
}

# ---------------------------------------------------------------- version needs (core story 18: the same cases as
# core's semver.check and AC 1-3: a need is a minimum; ^ and a bare version read as >=; the floor refuses older needs)
$cases = @(
    # AC 1: core 0.4.0 accepts older and equal needs, in all three forms.
    @('0.4.0', '>=0.1.0', $null, 'ok'), @('0.4.0', '>=0.2.0', $null, 'ok'), @('0.4.0', '>=0.3.0', $null, 'ok'),
    @('0.4.0', '>=0.4.0', $null, 'ok'), @('0.4.0', '^0.2.0', $null, 'ok'), @('0.4.0', '^0.3.0', $null, 'ok'),
    @('0.4.0', '0.2.0', $null, 'ok'), @('0.4.0', '0.3.0', $null, 'ok'), @('0.4.0', '>=0.2.0', '0.1.0', 'ok'),
    # AC 2: core 0.4.0 is older than a 0.5.0 need.
    @('0.4.0', '>=0.5.0', $null, 'core-too-old'), @('0.4.0', '^0.5.0', $null, 'core-too-old'), @('0.4.0', '0.5.0', $null, 'core-too-old'),
    @('0.4.0', '>=0.5.0', '0.1.0', 'core-too-old'),
    # AC 3: with the floor at 0.3.0, a need below it is the mod's problem; at the floor it is fine.
    @('0.4.0', '>=0.2.0', '0.3.0', 'mod-too-old'), @('0.4.0', '^0.2.0', '0.3.0', 'mod-too-old'), @('0.4.0', '>=0.3.0', '0.3.0', 'ok'),
    @('0.4.0', '>=0.5.0', '0.3.0', 'core-too-old'),
    # The old caret's limits are gone: newer minors and majors satisfy an older need.
    @('0.2.0', '>=0.2.0', $null, 'ok'), @('0.2.1', '>=0.2.0', $null, 'ok'), @('0.3.0', '^0.2.0', $null, 'ok'),
    @('1.2.0', '^0.2.0', $null, 'ok'), @('2.0.0', '>=1.2.0', $null, 'ok'), @('0.10.0', '>=0.9.0', $null, 'ok'),
    @('0.2.2', '>=0.2.3', $null, 'core-too-old'), @('0.1.9', '>=0.2.0', $null, 'core-too-old'), @('1.9.9', '>=2.0.0', $null, 'core-too-old'),
    # An installed version that isn't plain semver is not compatible.
    @('0.2', '>=0.2.0', $null, 'bad-have'), @('0.2.0-beta', '>=0.2.0', $null, 'bad-have'), @('v0.2.0', '>=0.2.0', $null, 'bad-have'),
    @(' 0.2.0', '>=0.2.0', $null, 'bad-have'), @("0.2.0`n", '>=0.2.0', $null, 'bad-have'), @('', '>=0.2.0', $null, 'bad-have'),
    @($null, '>=0.2.0', $null, 'bad-have'), @(2, '>=0.2.0', $null, 'bad-have'), @('00.2.0', '>=0.2.0', $null, 'ok'),
    # A floor that isn't plain semver (an installed mod.json we don't control) means no floor, as in core.
    @('0.4.0', '>=0.2.0', 'x', 'ok'), @('0.4.0', '>=0.2.0', '', 'ok'), @('0.4.0', '>=0.2.0', 3, 'ok')
)
foreach ($c in $cases) {
    Eq (Test-VersionNeed -Version $c[0] -Need $c[1] -Floor $c[2]) $c[3] "need: '$($c[0])' for '$($c[1])' (floor '$($c[2])')"
}
# A need that isn't >=X.Y.Z, ^X.Y.Z or X.Y.Z is a bug in our own mod.json: it throws (AC 5's bad needs).
foreach ($bad in @('', '>=', '>=x', '>=1.2', '<0.3.0', '~0.3.0', ('>=0.2.0' + ('0' * 293)), '3', '>= 0.3.0', '>=1234567890.0.0',
        '=0.3.0', '>=0.3.0 ', ">=0.3.0`n", '>=^0.3.0', '^>=0.3.0', '>=0.3.0.0', '>=0.3.0-beta')) {
    Throws { Test-VersionNeed -Version '0.4.0' -Need $bad } 'unsupported version need' "need: '$bad' throws"
}
Eq ('>=0.2.0' + ('0' * 293)).Length 300 'need: the long case is 300 characters'
Ok ($null -eq (ConvertFrom-VersionNeed ('>=0.' + ('1' * 61)))) 'need: over 64 bytes is not a need'
Eq ((ConvertFrom-VersionNeed '>=0.2.0').Minor) 2 'need: >= parses to its minimum'
Eq ((ConvertFrom-VersionNeed '^1.2.3').Patch) 3 'need: ^ parses to its minimum'
Ok ($null -eq (ConvertFrom-VersionNeed 3)) 'need: a non-string is not a need'
Eq ((ConvertTo-Semver '1.2.3').Minor) 2 'semver: parse'
Ok ($null -eq (ConvertTo-Semver '1.2.3.4')) 'semver: four parts is not a version'
Ok ($null -eq (ConvertTo-Semver ('1.2.' + [char]0x0663))) 'semver: non-ASCII digits are not a version'

# ---------------------------------------------------------------- mods.txt editing
$stock = @('CheatManagerEnablerMod : 1', 'ActorDumperMod : 0', 'BPModLoaderMod : 1', 'Keybinds : 1', '', '; comment')
$withCore = @('Nucleus : 1') + $stock
$r = Edit-ModsTxt -Lines $withCore -Add @('Waypoints') -After 'Nucleus'
Eq ($r -join '|') (@('Nucleus : 1', 'Waypoints : 1') + $stock -join '|') 'mods.txt: Waypoints right below Nucleus'
$r = Edit-ModsTxt -Lines $withCore -Add @('WaypointsDriver', 'Waypoints') -After 'Nucleus'
Eq ($r -join '|') (@('Nucleus : 1', 'WaypointsDriver : 1', 'Waypoints : 1') + $stock -join '|') 'mods.txt: driver then Waypoints below Nucleus'
$above = @('Waypoints : 1') + $withCore
$r = Edit-ModsTxt -Lines $above -Add @('Waypoints') -After 'Nucleus'
Eq ($r -join '|') (@('Nucleus : 1', 'Waypoints : 1') + $stock -join '|') 'mods.txt: a Waypoints line above Nucleus moves below it (story 1 AC 6)'
$twice = @('Nucleus : 1', 'Waypoints : 0', 'BPModLoaderMod : 1', '  Waypoints:1', 'Keybinds : 1')
$r = Edit-ModsTxt -Lines $twice -Add @('Waypoints') -After 'Nucleus'
Eq ($r -join '|') 'Nucleus : 1|Waypoints : 1|BPModLoaderMod : 1|Keybinds : 1' 'mods.txt: every old Waypoints line (disabled, spaced) replaced by one'
$r = Edit-ModsTxt -Lines $stock -Add @('Waypoints') -After 'Nucleus'
Eq ($r[3]) 'Waypoints : 1' 'mods.txt: no Nucleus line -> above Keybinds'
Eq ($r[4]) 'Keybinds : 1' 'mods.txt: ... Keybinds still follows'
$late = @('BPModLoaderMod : 1', 'Keybinds : 1', 'Nucleus : 1')
$r = Edit-ModsTxt -Lines $late -Add @('Waypoints') -After 'Nucleus'
Eq ($r -join '|') 'BPModLoaderMod : 1|Waypoints : 1|Keybinds : 1|Nucleus : 1' 'mods.txt: Nucleus below Keybinds -> Waypoints still above Keybinds'
$r = Edit-ModsTxt -Lines @('A : 1') -Add @('Waypoints') -After 'Nucleus'
Eq ($r -join '|') 'A : 1|Waypoints : 1' 'mods.txt: no Keybinds line at all -> at the end'
$r = Edit-ModsTxt -Lines @('Nucleus : 1', 'WaypointsDriver : 1', 'Waypoints : 1', 'Waypointswork : 1', 'Keybinds : 1') -Remove @('Waypoints', 'WaypointsDriver')
Eq ($r -join '|') 'Nucleus : 1|Waypointswork : 1|Keybinds : 1' 'mods.txt: remove only Waypoints and WaypointsDriver (not Waypointswork)'
$r = Edit-ModsTxt -Lines @() -Remove @('Waypoints')
Eq $r.Count 0 'mods.txt: empty stays empty'
Eq (Get-ModsTxtState -Lines $withCore -Name 'Nucleus') 'enabled' 'state: enabled'
Eq (Get-ModsTxtState -Lines @('Nucleus : 0') -Name 'Nucleus') 'disabled' 'state: disabled'
Eq (Get-ModsTxtState -Lines $stock -Name 'Nucleus') 'absent' 'state: absent'
Eq (Get-ModsTxtState -Lines @('NucleusX : 1') -Name 'Nucleus') 'absent' 'state: a longer name is not Nucleus'

# ---------------------------------------------------------------- settings.lua
$m = Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json
$text = ConvertTo-SettingsLua -Manifest $m
Ok ($text -match "(?m)^return \{ onRevive = `"restore`" \}$") 'settings: default onRevive = "restore"' $text
Ok ((ConvertTo-SettingsLua -Manifest $m -Override @{ onRevive = 'clear' }) -match 'return \{ onRevive = "clear" \}') 'settings: override clear'
Ok ((ConvertTo-SettingsLua -Manifest $m -DebugLog) -match 'return \{ onRevive = "restore", debug = true \}') 'settings: -DebugLog adds debug = true'
Throws { ConvertTo-SettingsLua -Manifest $m -Override @{ onRevive = 'wipe' } } 'is not one of restore, clear' 'settings: an unknown value refused'
Throws { ConvertTo-SettingsLua -Manifest $m -Override @{ onRevive = 'Clear' } } 'is not one of' 'settings: enum values are case-sensitive'
Throws { ConvertTo-SettingsLua -Manifest $m -Override @{ onRevive = 1 } } 'is not one of' 'settings: a number refused'
Throws { ConvertTo-SettingsLua -Manifest $m -Override @{ colour = 1 } } 'not declared' 'settings: undeclared refused'
# enum and int validation on synthetic manifests
$mk = { param($json) $json | ConvertFrom-Json }
Throws { ConvertTo-SettingsLua -Manifest (& $mk '{ "settings": { "x": { "type": "enum", "values": [], "default": "a" } } }') } 'non-empty' 'settings: an enum without values throws'
Throws { ConvertTo-SettingsLua -Manifest (& $mk '{ "settings": { "x": { "type": "enum", "values": ["a\"b"], "default": "a\"b" } } }') } 'not a plain word' 'settings: an enum value that would break the Lua string throws'
Throws { ConvertTo-SettingsLua -Manifest (& $mk '{ "settings": { "x": { "type": "float", "default": 1 } } }') } 'not supported' 'settings: unknown type throws'
Ok ((ConvertTo-SettingsLua -Manifest (& $mk '{ "settings": { "n": { "type": "int", "default": 3, "min": 1, "max": 5 } } }')) -match 'return \{ n = 3 \}') 'settings: int still works'
Throws { ConvertTo-SettingsLua -Manifest (& $mk '{ "settings": { "n": { "type": "int", "default": 9, "min": 1, "max": 5 } } }') } 'not an integer from 1 to 5' 'settings: int bounds'
# The generated file is valid Lua that main.lua's loader accepts: checked by main_test.lua with the same text.
Eq $m.settings.onRevive.label 'After a revive, your map waypoints' 'mod.json: the setting has its label'
Eq $m.settings.onRevive.changeable 'anytime' 'mod.json: changeable anytime'
Eq (@($m.settings.onRevive.values) -join ',') 'restore,clear' 'mod.json: values restore, clear'
Eq $m.settings.onRevive.default 'restore' 'mod.json: default restore'
Ok ($m.id -eq 'waypoints' -and $m.name -eq 'Waypoints' -and $m.version -eq '0.2.0' -and $m.scope -eq 'client') 'mod.json: id, name, version 0.2.0, scope'
Ok ($m.dependsOn[0].id -eq 'nucleus' -and $m.dependsOn[0].version -eq '>=0.5.0') 'mod.json: dependsOn nucleus >=0.5.0 (a minimum, core story 18; the panels and buttons it is verified on)'
Ok ($m.ue4ss -eq 'v3.0.1-1181-g83330635' -and $m.game.version -eq 'V8.2.1' -and $m.game.build -eq '26512322') 'mod.json: ue4ss and game build (V8.2.1 / 26512322)'
# The runtime need in main.lua equals dependsOn's minimum.
$mainLua = Get-Content (Join-Path $repo 'Scripts\main.lua') -Raw
Ok ($mainLua -match 'local CORE, NEED, ME = "Nucleus", ">=0.5.0", "Waypoints"') 'main.lua: need = dependsOn (>=0.5.0)'

# ---------------------------------------------------------------- mods.txt bytes
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("waypoints-deploy-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
try {
    $p = Join-Path $tmp 'mods.txt'
    foreach ($variant in @("A : 1`r`nKeybinds : 1`r`n", "A : 1`nKeybinds : 1", "A : 1`r`nKeybinds : 1")) {
        [IO.File]::WriteAllText($p, $variant)
        $f = Read-ModsTxt $p
        Write-ModsTxt $p $f $f.Lines
        Eq ([IO.File]::ReadAllText($p)) $variant "mods.txt io: round trip keeps bytes ($(($variant -replace "`r", '\r') -replace "`n", '\n'))"
    }
    [IO.File]::WriteAllBytes($p, [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("A : 1`r`n"))
    $f = Read-ModsTxt $p; Write-ModsTxt $p $f $f.Lines
    Eq ([BitConverter]::ToString([IO.File]::ReadAllBytes($p))) 'EF-BB-BF-41-20-3A-20-31-0D-0A' 'mods.txt io: BOM kept'

    # ------------------------------------------------------------ deploy.ps1 end to end, fake instance
    $inst = Join-Path $tmp 'game-instances\fake'
    $win64 = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
    $mods = Join-Path $win64 'ue4ss\Mods'
    New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus\Scripts'), (Join-Path $mods 'Keybinds') | Out-Null
    Set-Content (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe') 'fake'
    Set-Content (Join-Path $win64 'ue4ss\UE4SS.dll') 'fake'
    $stockTxt = "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`nKeybinds : 1`r`n"
    $coreTxt = "Nucleus : 1`r`n" + $stockTxt
    $modsTxt = Join-Path $mods 'mods.txt'
    $coreJson = Join-Path $mods 'Nucleus\mod.json'
    function Set-Core([string] $version, [string] $floor) {
        $compat = if ($floor) { ", `"compat`": { `"floor`": `"$floor`" }" } else { '' }
        Set-Content $coreJson "{ `"id`": `"nucleus`", `"name`": `"Nucleus`", `"version`": `"$version`"$compat }"
    }
    # Each deploy runs in its own pwsh (it ends with exit), with Get-Process stubbed: a real game may be running.
    function Deploy([string[]] $a) {
        $cmd = "function Get-Process { }; & '$(Join-Path $repo 'deploy.ps1')' -Instance '$inst' $($a -join ' '); exit `$LASTEXITCODE"
        $out = & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out }
    }
    function Txt { [IO.File]::ReadAllText($modsTxt) }

    # Core missing.
    [IO.File]::WriteAllText($modsTxt, $stockTxt)
    Remove-Item (Join-Path $mods 'Nucleus') -Recurse -Force
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Waypoints not deployed: Nucleus is not installed') 'deploy: core missing -> refused' $d.Out
    Ok (($d.Out.Trim() -split "`r?`n").Count -eq 1) 'deploy: refusal is one line' $d.Out
    Ok (-not (Test-Path (Join-Path $mods 'Waypoints'))) 'deploy: refused -> nothing installed'
    Eq (Txt) $stockTxt 'deploy: refused -> mods.txt untouched'

    # Core too old (0.1.0); a newer core is fine, with or without a floor; a floor above the need refuses, naming the
    # mod (core story 18 AC 1-3).
    New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus\Scripts') | Out-Null
    [IO.File]::WriteAllText($modsTxt, $coreTxt)
    Set-Core '0.1.0'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus 0\.1\.0 is installed, but Waypoints needs >=0\.5\.0; update Nucleus\.') 'deploy: core 0.1.0 -> refused, naming both versions' $d.Out
    Set-Core '0.4.0'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus 0\.4\.0 is installed, but Waypoints needs >=0\.5\.0; update Nucleus\.') 'deploy: core 0.4.0 (no panels on 0.5.0''s terms) -> refused' $d.Out
    Set-Core '0.6.0'
    $d = Deploy @()
    Ok ($d.Code -eq 0) 'deploy: core 0.6.0 (a newer minor) -> installed' $d.Out
    Set-Core '0.5.0' '0.1.0'
    $d = Deploy @()
    Ok ($d.Code -eq 0) 'deploy: core 0.5.0, floor 0.1.0 -> installed' $d.Out
    Set-Core '0.7.0' '0.6.0'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match '^Waypoints not deployed: Waypoints was made for Nucleus >=0\.5\.0, which this Nucleus 0\.7\.0 no longer supports \(oldest: 0\.6\.0\); update Waypoints\.') 'deploy: floor 0.6.0 above the need -> refused, naming the mod' $d.Out
    Ok (($d.Out.Trim() -split "`r?`n").Count -eq 1) 'deploy: the floor refusal is one line' $d.Out
    Set-Core '0.5.0' 'soon'
    $d = Deploy @()
    Ok ($d.Code -eq 0) 'deploy: a floor that is not X.Y.Z is no floor (as core)' $d.Out
    Deploy @('-Remove') | Out-Null
    [IO.File]::WriteAllText($modsTxt, $coreTxt)
    Set-Content $coreJson 'not json'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match "is not Nucleus's manifest") 'deploy: unreadable core mod.json -> refused' $d.Out

    # Core disabled.
    Set-Core '0.5.0'
    [IO.File]::WriteAllText($modsTxt, "Nucleus : 0`r`n" + $stockTxt)
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus is installed but disabled in mods\.txt') 'deploy: core disabled -> refused' $d.Out

    # Good core: installed below Nucleus, above Keybinds; settings.lua generated; no core files bundled.
    [IO.File]::WriteAllText($modsTxt, "Waypoints : 1`r`n" + $coreTxt) # a Waypoints line above Nucleus must move below it
    Set-Core '0.5.1'
    $d = Deploy @()
    Ok ($d.Code -eq 0) 'deploy: core 0.5.1 -> installed' $d.Out
    Eq (Txt) ("Nucleus : 1`r`nWaypoints : 1`r`n" + $stockTxt) 'deploy: Waypoints below Nucleus, above Keybinds'
    $files = @(Get-ChildItem (Join-Path $mods 'Waypoints') -Recurse -File | ForEach-Object { $_.FullName.Substring((Join-Path $mods 'Waypoints').Length + 1) } | Sort-Object)
    Eq ($files -join ',') 'mod.json,Scripts\game.lua,Scripts\main.lua,Scripts\mapbuttons.lua,Scripts\revive.lua,Scripts\settings.lua,Scripts\waypoints.lua' 'deploy: exactly the Waypoints files'
    Ok ((Get-Content (Join-Path $mods 'Waypoints\Scripts\settings.lua') -Raw) -match 'return \{ onRevive = "restore" \}') 'deploy: settings.lua from mod.json defaults'
    Ok (-not (Test-Path (Join-Path $mods 'WaypointsDriver'))) 'deploy: no driver without -Test'

    # -OnRevive clear.
    $d = Deploy @('-OnRevive', 'clear')
    Ok ((Get-Content (Join-Path $mods 'Waypoints\Scripts\settings.lua') -Raw) -match 'return \{ onRevive = "clear" \}') 'deploy: -OnRevive clear' $d.Out
    Eq (Txt) ("Nucleus : 1`r`nWaypoints : 1`r`n" + $stockTxt) 'deploy: redeploy keeps one Waypoints line'
    $d = Deploy @('-OnRevive', 'wipe')
    Ok ($d.Out -match 'does not belong to the set') 'deploy: -OnRevive wipe refused by the parameter' $d.Out

    # -Test: driver between Nucleus and Waypoints, scenario written, debug on.
    $d = Deploy @('-Test', '-Scenario', 'probe')
    Ok ($d.Code -eq 0) 'deploy -Test: installed' $d.Out
    Eq (Txt) ("Nucleus : 1`r`nWaypointsDriver : 1`r`nWaypoints : 1`r`n" + $stockTxt) 'deploy -Test: Nucleus, WaypointsDriver, Waypoints, then the rest'
    Eq ([IO.File]::ReadAllText((Join-Path $mods 'WaypointsDriver\Scripts\scenario.txt'))) 'probe' 'deploy -Test: scenario.txt'
    Ok ((Get-Content (Join-Path $mods 'Waypoints\Scripts\settings.lua') -Raw) -match 'return \{ onRevive = "restore", debug = true \}') 'deploy -Test: debug on'
    Ok (Test-Path (Join-Path $mods 'WaypointsDriver\Scripts\main.lua')) 'deploy -Test: the driver installed'
    $d = Deploy @('-Test', '-Scenario', 'buttons')
    Ok ($d.Code -eq 0 -and [IO.File]::ReadAllText((Join-Path $mods 'WaypointsDriver\Scripts\scenario.txt')) -eq 'buttons') 'deploy -Test: buttons' $d.Out
    # -Map (story 4): only a key of the driver's table, written to map.txt with -Test; a stale one removed.
    $mapTxt = Join-Path $mods 'WaypointsDriver\Scripts\map.txt'
    Ok (-not (Test-Path $mapTxt)) 'deploy -Test without -Map: no map.txt (the driver''s default map)'
    $d = Deploy @('-Test', '-Scenario', 'buttons', '-Map', 'Forest')
    Ok ($d.Code -eq 0 -and (Test-Path $mapTxt) -and [IO.File]::ReadAllText($mapTxt) -eq 'Forest') 'deploy -Test -Map Forest: map.txt holds only the key' $d.Out
    foreach ($k in 'LowIsland', 'TowerIsland', 'Crevasse') {
        $d = Deploy @('-Test', '-Scenario', 'buttons', '-Map', $k)
        Ok ($d.Code -eq 0 -and [IO.File]::ReadAllText($mapTxt) -eq $k) "deploy -Test -Map ${k}: map.txt" $d.Out
    }
    $d = Deploy @('-Test', '-Scenario', 'buttons')
    Ok ($d.Code -eq 0 -and -not (Test-Path $mapTxt)) 'deploy -Test after -Map: the stale map.txt removed' $d.Out
    Set-Content $mapTxt 'Forest' # a stray copy in the installed driver
    $d = Deploy @('-Test', '-Scenario', 'revive')
    Ok ($d.Code -eq 0 -and -not (Test-Path $mapTxt)) 'deploy -Test: a stray map.txt removed' $d.Out
    $d = Deploy @('-Test', '-Scenario', 'buttons', '-Map', '../x')
    Ok ($d.Out -match 'does not belong to the set' -and -not (Test-Path $mapTxt)) 'deploy -Map ../x: refused by the parameter' $d.Out
    $d = Deploy @('-Test', '-Scenario', 'buttons', '-Map', 'forest')
    Ok ($d.Out -match 'does not belong to the set' -and -not (Test-Path $mapTxt)) 'deploy -Map forest: wrong case refused by the parameter' $d.Out
    $d = Deploy @('-Map', 'Forest')
    Ok ($d.Code -eq 0 -and $d.Out -match 'needs -Test' -and -not (Test-Path (Join-Path $mods 'WaypointsDriver'))) 'deploy -Map without -Test: warns, writes nothing' $d.Out
    $d = Deploy @('-Test', '-Scenario', 'pair-victim', '-Staged')
    Ok ($d.Code -eq 0 -and [IO.File]::ReadAllText((Join-Path $mods 'WaypointsDriver\Scripts\scenario.txt')) -eq 'pair-victim') 'deploy -Test -Staged: pair-victim' $d.Out
    $d = Deploy @()
    Ok (-not (Test-Path (Join-Path $mods 'WaypointsDriver')) -and (Txt) -eq ("Nucleus : 1`r`nWaypoints : 1`r`n" + $stockTxt)) 'deploy without -Test removes the driver'

    # -Force: installs despite a missing core, above Keybinds.
    Set-Core '0.1.0'
    $d = Deploy @('-Force', '-Test', '-Scenario', 'old-core')
    Ok ($d.Code -eq 0 -and $d.Out -match 'forced: Nucleus 0\.1\.0 is installed') 'deploy -Force: warns and installs' $d.Out
    Remove-Item (Join-Path $mods 'Nucleus') -Recurse -Force
    [IO.File]::WriteAllText($modsTxt, $stockTxt)
    $d = Deploy @('-Force')
    Ok ($d.Code -eq 0) 'deploy -Force without core: installed' $d.Out
    Eq (Txt) "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`nWaypoints : 1`r`nKeybinds : 1`r`n" 'deploy -Force without core: above Keybinds'

    # -Remove: back to exactly the stock files (story 4 AC 3), Nucleus's line untouched (story 1 AC 5).
    $d = Deploy @('-Remove')
    Ok ($d.Code -eq 0 -and -not (Test-Path (Join-Path $mods 'Waypoints'))) 'deploy -Remove: no Waypoints files' $d.Out
    Eq (Txt) $stockTxt 'deploy -Remove: mods.txt byte-identical to stock'
    New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus') | Out-Null
    Set-Core '0.5.0'
    [IO.File]::WriteAllText($modsTxt, $coreTxt)
    Deploy @('-Test') | Out-Null
    Deploy @('-Remove') | Out-Null
    Eq (Txt) $coreTxt 'deploy -Remove after -Test: Nucleus line untouched, ours gone'
    Ok (-not (Test-Path (Join-Path $mods 'WaypointsDriver'))) 'deploy -Remove: driver gone'
    $before = Txt
    Deploy @('-Remove') | Out-Null
    Eq (Txt) $before 'deploy -Remove twice: nothing changes'
    Ok ((Get-ChildItem $mods -Directory | ForEach-Object Name | Sort-Object) -join ',' -eq 'Keybinds,Nucleus') 'deploy -Remove: Mods/ holds only what was there'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("deploy_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
