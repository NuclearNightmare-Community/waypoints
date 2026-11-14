<#
.SYNOPSIS
  Pure helpers for deploy.ps1 (dot-source it), testable on their own (test/unit/deploy_test.ps1).
  Version needs use the same rule as core's nucleus.semver (api-contract.md, "Versioning"; core story 18): a need is
  a minimum. ">=X.Y.Z", the old caret form "^X.Y.Z" and a bare "X.Y.Z" all mean "this version or newer", and a need
  below the installed core's compatibility floor (its mod.json "compat.floor") is refused. Versions are plain
  MAJOR.MINOR.PATCH; anything else is not a version.
.EXAMPLE
  . ./deploy-lib.ps1; Test-VersionNeed -Version '0.4.0' -Need '>=0.2.0'   # ok
#>

# The Scripts/ files a deploy installs and a release ships under ue4ss/Mods/<name>/Scripts/ (deploy.ps1 and
# build.ps1 both use this list). No settings file ships: Nucleus keeps the values in Mods/<name>/settings.json.
$ModScripts = 'main.lua', 'revive.lua', 'waypoints.lua', 'mapbuttons.lua', 'game.lua', 'panelfit.lua'

# ConvertTo-Semver '0.2.0' -> @{ Major = 0; Minor = 2; Patch = 0 }, or $null when the text isn't plain semver
# (ASCII digits only, 1-9 per part, nothing after the patch, not even a newline).
function ConvertTo-Semver {
    param([AllowNull()] [AllowEmptyString()] [object] $Text)
    if ($Text -isnot [string]) { return $null }
    if ($Text -notmatch '\A([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})\z') { return $null }
    return @{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3] }
}

# ConvertFrom-VersionNeed '>=0.2.0' -> the minimum as ConvertTo-Semver gives it, or $null when the text isn't
# ">=X.Y.Z", "^X.Y.Z" or "X.Y.Z" (at most 64 bytes, as core's semver.parseNeed).
function ConvertFrom-VersionNeed {
    param([AllowNull()] [AllowEmptyString()] [object] $Need)
    if ($Need -isnot [string] -or $Need.Length -eq 0 -or $Need.Length -gt 64) { return $null }
    $body = if ($Need.StartsWith('>=')) { $Need.Substring(2) } elseif ($Need.StartsWith('^')) { $Need.Substring(1) } else { $Need }
    return ConvertTo-Semver $body
}

# Compare-Semver a b -> -1 | 0 | 1 for two ConvertTo-Semver results.
function Compare-Semver {
    param([Parameter(Mandatory)] $A, [Parameter(Mandatory)] $B)
    foreach ($k in 'Major', 'Minor', 'Patch') { if ($A[$k] -ne $B[$k]) { return $(if ($A[$k] -lt $B[$k]) { -1 } else { 1 }) } }
    return 0
}

# Test-VersionNeed -Version <have> -Need <need> [-Floor <floor>] -> 'ok' | 'core-too-old' | 'mod-too-old' | 'bad-have',
# as core's semver.check: 'bad-have' when the installed version isn't plain semver (an installed mod.json we don't
# control: simply not compatible), 'core-too-old' when it is below the need's minimum, 'mod-too-old' when the minimum
# is below the floor. A floor that is missing or not plain semver means no floor. A need that isn't ">=X.Y.Z",
# "^X.Y.Z" or "X.Y.Z" throws (it's our own mod.json, so that's a bug to fix, not a reason to refuse an install).
function Test-VersionNeed {
    param(
        [AllowNull()] [AllowEmptyString()] [object] $Version,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Need,
        [AllowNull()] [AllowEmptyString()] [object] $Floor
    )
    $n = ConvertFrom-VersionNeed $Need
    if (-not $n) { throw "unsupported version need '$Need' (only >=MAJOR.MINOR.PATCH, ^MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH)" }
    $h = ConvertTo-Semver $Version
    if (-not $h) { return 'bad-have' }
    if ((Compare-Semver $h $n) -lt 0) { return 'core-too-old' }
    $f = ConvertTo-Semver $Floor
    if ($f -and (Compare-Semver $n $f) -lt 0) { return 'mod-too-old' }
    return 'ok'
}

# Edit-ModsTxt -Lines <mods.txt lines> -Remove <names> -Add <names in order> -After <name> -> new lines.
# Drops every line of each name in -Remove and -Add (enabled or not), then inserts "<name> : 1" for each of -Add, in
# order: right below -After's line when that line is above "Keybinds : 1"; otherwise right above Keybinds (AGENTS.md:
# never appended at the end), or at the end only when there is no Keybinds line at all. Other lines keep their order.
function Edit-ModsTxt {
    param(
        [AllowEmptyCollection()] [string[]] $Lines = @(),
        [string[]] $Remove = @(),
        [string[]] $Add = @(),
        [string] $After
    )
    $names = @($Remove) + @($Add) | Where-Object { $_ }
    $kept = [Collections.Generic.List[string]]::new()
    foreach ($l in $Lines) {
        $drop = $false
        foreach ($n in $names) { if ($l -match ('^\s*' + [regex]::Escape($n) + '\s*:')) { $drop = $true; break } }
        if (-not $drop) { $kept.Add($l) }
    }
    if (-not $Add) { return , $kept.ToArray() }
    $k = -1; $a = -1
    for ($i = 0; $i -lt $kept.Count; $i++) {
        if ($k -lt 0 -and $kept[$i] -match '^\s*Keybinds\s*:') { $k = $i }
        if ($After -and $a -lt 0 -and $kept[$i] -match ('^\s*' + [regex]::Escape($After) + '\s*:')) { $a = $i }
    }
    $at = if ($a -ge 0 -and ($k -lt 0 -or $a -lt $k)) { $a + 1 } elseif ($k -ge 0) { $k } else { $kept.Count }
    $kept.InsertRange($at, [string[]]@($Add | ForEach-Object { "$_ : 1" }))
    return , $kept.ToArray()
}

# Get-ModsTxtState -Lines <lines> -Name <name> -> 'enabled' | 'disabled' | 'absent' (the first line for that name).
function Get-ModsTxtState {
    param([AllowEmptyCollection()] [string[]] $Lines = @(), [Parameter(Mandatory)] [string] $Name)
    foreach ($l in $Lines) {
        if ($l -match ('^\s*' + [regex]::Escape($Name) + '\s*:\s*(\d+)')) { return $(if ($Matches[1] -eq '1') { 'enabled' } else { 'disabled' }) }
    }
    return 'absent'
}

# ConvertTo-SettingsJson -Manifest <mod.json object> -Override @{ name = value } -> the text of Mods/<name>/settings.json
# (the values file Nucleus's settings service keeps, Nucleus 0.9.0): a flat JSON object of the overridden values only,
# in the order mod.json declares them, each checked against its declaration: int (an integer from min to max) or enum
# (one of "values"). $null when there is nothing to override (deploy.ps1 then leaves any existing file alone). An
# undeclared name, another type or a bad value throws.
function ConvertTo-SettingsJson {
    param([Parameter(Mandatory)] $Manifest, [hashtable] $Override = @{})
    if (-not $Override.Count) { return $null }
    $declared = [ordered]@{}
    if ($Manifest.settings) { foreach ($p in $Manifest.settings.PSObject.Properties) { $declared[$p.Name] = $p.Value } }
    foreach ($k in $Override.Keys) { if (-not $declared.Contains($k)) { throw "setting '$k' is not declared in mod.json" } }
    $parts = @()
    foreach ($name in $declared.Keys) {
        if (-not $Override.ContainsKey($name)) { continue }
        $s, $v = $declared[$name], $Override[$name]
        switch ($s.type) {
            'int' {
                if (-not ($v -is [int] -or $v -is [long]) -or $v -lt $s.min -or $v -gt $s.max) {
                    throw "setting '$name' = '$v' is not an integer from $($s.min) to $($s.max)"
                }
                $parts += ('"{0}":{1}' -f $name, $v)
            }
            'enum' {
                $values = @($s.values)
                if (-not $values.Count) { throw "setting '$name': an enum needs a non-empty 'values' list" }
                foreach ($x in $values) { if ($x -isnot [string] -or $x -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw "setting '$name': enum value '$x' is not a plain word" } }
                # -ccontains: enum values are case-sensitive, as Nucleus compares them.
                if ($v -isnot [string] -or -not ($values -ccontains $v)) { throw "setting '$name' = '$v' is not one of $($values -join ', ')" }
                $parts += ('"{0}":"{1}"' -f $name, $v)
            }
            default { throw "setting '$name': type '$($s.type)' is not supported here (int, enum)" }
        }
    }
    return '{' + ($parts -join ',') + '}'
}

# ConvertTo-DevLua [-DebugLog] [-Profile] -> the text of Scripts/dev.lua (test-only flags; deploy.ps1 -Test writes it,
# the mod reads it as text and never runs it), or $null when neither flag is on.
function ConvertTo-DevLua {
    param([switch] $DebugLog, [switch] $Profile)
    $parts = @()
    if ($DebugLog) { $parts += 'debug = true' }
    if ($Profile) { $parts += 'profile = true' }
    if (-not $parts) { return $null }
    return "-- Written by deploy.ps1 -Test (test only; never shipped). Read as text by main.lua, never run.`nreturn { $($parts -join ', ') }`n"
}

# Read-ModsTxt <path> -> @{ Lines; Newline; Trailing; Bom }: the lines plus how the file ends them, so
# Write-ModsTxt writes back byte-identical text when the lines are unchanged.
function Read-ModsTxt {
    param([Parameter(Mandatory)] [string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $trailing = $text.EndsWith("`n")
    $body = if ($trailing) { $text.Substring(0, $text.Length - $(if ($text.EndsWith("`r`n")) { 2 } else { 1 })) } else { $text }
    $lines = if ($body.Length) { [string[]]($body -split "`r?`n") } else { [string[]]@() }
    return @{ Lines = $lines; Newline = $nl; Trailing = $trailing; Bom = $bom }
}
function Write-ModsTxt {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $File, [AllowEmptyCollection()] [string[]] $Lines = @())
    $text = ($Lines -join $File.Newline) + $(if ($File.Trailing -and $Lines.Count) { $File.Newline } else { '' })
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new([bool]$File.Bom))
}
