<#
.SYNOPSIS
  Stages Waypoints as a release package: build/package/Mods/<name>/{mod.json, Scripts/}, <name> = mod.json "name".
.DESCRIPTION
  Writes only build/package/ (ignored by git), deleted first, in the layout tools/release/release.ps1 maps to the
  player zip (_bmad-output/specs/spec-distribution-v0/packages.md): Mods/<name>/mod.json (this repo's, byte for
  byte) and Mods/<name>/Scripts/ with the Lua files deploy.ps1 installs (deploy-lib.ps1 $ModScripts). No settings
  file: Nucleus's settings service uses mod.json's defaults until the player changes a value (then it writes
  Mods/<name>/settings.json in the game), and the test-only Scripts/dev.lua never ships. No DLL and no pak: the mod is Lua only, and it never ships any of core's files.
  Never touches a game copy. Exit 0 on success; a missing source file, a bad mod.json name or a stray settings file stops it (exit 1). Settings declarations are checked by Nucleus at run time, not here.
.EXAMPLE
  ./build.ps1
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'deploy-lib.ps1')

$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]*\z') { throw "mod.json name '$name' is not a folder name" }
foreach ($f in $ModScripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $here "Scripts\$f") -PathType Leaf)) { throw "missing Scripts/$f" }
}

$pkgRoot = Join-Path $here 'build\package'
Remove-Item -LiteralPath $pkgRoot -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $pkgRoot) { throw "could not delete $pkgRoot" }
$modDir = Join-Path $pkgRoot "Mods\$name"
$scripts = Join-Path $modDir 'Scripts'
New-Item -ItemType Directory -Force $scripts | Out-Null
Copy-Item -LiteralPath (Join-Path $here 'mod.json') -Destination $modDir
foreach ($f in $ModScripts) { Copy-Item -LiteralPath (Join-Path $here "Scripts\$f") -Destination $scripts }
$stray = @(Get-ChildItem -LiteralPath $modDir -Recurse -File | Where-Object { $_.Name -in 'settings.json', 'settings.lua', 'dev.lua' })
if ($stray) { throw "refusing: the package would ship $($stray.Name -join ', ')" }

Write-Host "$name $($manifest.version) staged in build/package/:"
Get-ChildItem -LiteralPath $pkgRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
    Write-Host ("  {0,-40} {1,8:N0} bytes" -f $_.FullName.Substring($pkgRoot.Length + 1).Replace('\', '/'), $_.Length)
}
exit 0
