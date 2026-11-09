<#
.SYNOPSIS
  Runs one Waypoints scenario end to end: prepare core, deploy (with the test driver), launch, serve key requests, wait,
  close, restore core, check.
.DESCRIPTION
  Launches only through the workspace's tools/launch.ps1 (which passes -userdir). Stops when the driver logs its END
  line, the game exits (crash), or -TimeoutSec runs out (hang); then closes the game, force-killing it (and any crash
  reporter) after 15 s. Only ever stops the Shipping exe under this instance, never the real install or another copy.
  The driver writes "<seq> key ENTER" to its Scripts/request.txt for touchdown; this script posts the key to the
  game window's message queue (PostMessage WM_KEYDOWN/WM_KEYUP: no foreground change, no global input), then writes
  <seq> to done.txt.
  Scenarios that break core on purpose put it back afterwards, also after a crash or Ctrl+C (and at the start of the
  next run if this one was killed):
    no-core:  moves Mods/Nucleus to ue4ss/_waypoints-test-backup/ and takes its line out of mods.txt.
    old-core: sets the installed Nucleus mod.json version to 0.1.0 (the driver publishes it as core's runtime version,
              since a real 0.1.0 core has no UI helpers to build).
  Both first check that deploy.ps1 refuses without -Force (story 1 AC 2 and 3), then deploy with -Force.
  Keeps the log as <workspace>/dumps/<copy>/waypoints/<scenario>.log (ignored by git) and runs check.ps1 on it.
  Core must already be installed (Nucleus's own deploy.ps1). Steam must be running. Don't type into the game while
  it runs.
  -Target vm runs the scenario in the Hyper-V VM NNB instead (tools/vm/vm-sp.ps1, README "Tests in the VM"): Nucleus
  from the host's mods/Nucleus/build/package (its own deploy.ps1 -Staged), Waypoints and the driver (deploy.ps1
  -Staged, with the same refusal checks for no-core and old-core) go into the VM's copy of the same build, the VM's
  game is launched, Enter is pressed there with tools/vm/vm-key.ps1, and the VM copy is put back as it was
  afterwards. It never builds and never touches the host's game copy or a host game, so it can run while someone
  plays on the host. The log is kept as <scenario>.vm.log and judged with check.ps1 -Target vm.
  Every Waypoints scenario runs in the VM too (none judges timing).
.EXAMPLE
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario revive
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario probe -Target vm
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [ValidateSet('probe', 'revive', 'death', 'no-core', 'old-core')]
    [string] $Scenario = 'revive',
    [int] $TimeoutSec = 0, # 0: per scenario (probe 600, revive 720, others 480); x1.5 in the VM
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
$ErrorActionPreference = 'Stop'
$hostTimeout = switch ($Scenario) { 'probe' { 600 } 'revive' { 720 } default { 480 } }
if ($TimeoutSec -le 0 -and $Target -eq 'host') { $TimeoutSec = $hostTimeout }
$CoreName = 'Nucleus'
$here     = $PSScriptRoot
$name     = (Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json).name
$driver   = "${name}Driver"
$inst     = (Resolve-Path $Instance).Path
$root     = Split-Path (Split-Path $inst)
$outDir   = Join-Path $root "dumps\$(Split-Path $inst -Leaf)\$($name.ToLowerInvariant())"
# Where deploy.ps1 and Break-Core/Restore-Core work: the instance, or with -Target vm the host-side staging folder.
function Set-DeployTarget([string] $instance) {
    $script:deployInst = $instance
    $script:ue4ss    = Join-Path $instance 'NuclearNightmare\Binaries\Win64\ue4ss'
    $script:modsDir  = Join-Path $script:ue4ss 'Mods'
    $script:modsTxt  = Join-Path $script:modsDir 'mods.txt'
    $script:log      = Join-Path $script:ue4ss 'UE4SS.log'
    $script:scripts  = Join-Path $script:modsDir "$driver\Scripts"
    $script:backup   = Join-Path $script:ue4ss '_waypoints-test-backup'
}
Set-DeployTarget $inst
$exeName  = 'NuclearNightmare-Win64-Shipping'
New-Item -ItemType Directory -Force $outDir | Out-Null

Add-Type -Namespace WaypointsRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
'@

function Get-OurGame { Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
function Stop-Game {
    $p = Get-OurGame
    if ($p) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force } }
    Get-Process -Name 'CrashReportClient*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-OurGame) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
function Invoke-Request([string] $cmd) {
    if ($cmd -eq 'key ENTER') {
        $p = Get-OurGame
        $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
        if ($h -eq [IntPtr]::Zero) { Write-Host '  key skipped: no game window'; return }
        $down = [WaypointsRun.Win]::PostMessage($h, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)            # WM_KEYDOWN, VK_RETURN, scan 0x1C
        Start-Sleep -Milliseconds 80
        $up = [WaypointsRun.Win]::PostMessage($h, 0x0101, [IntPtr]0x0D, [IntPtr]([int64]0xC01C0001))   # WM_KEYUP
        Write-Host ("  posted ENTER to the game window (down={0} up={1})" -f $down, $up)
    } else { Write-Host "  unknown request: $cmd" }
}
# deploy.ps1 ends with exit 1 when it refuses, so it always runs in its own pwsh.
function Invoke-Deploy([string[]] $a) {
    if ($Target -eq 'vm') { $a += '-Staged' }
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $here 'deploy.ps1') -Instance $script:deployInst @a 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

# ---------------------------------------------------------------- breaking and restoring core
function Restore-Core {
    if (-not (Test-Path $backup)) { return }
    $saved = Join-Path $backup $CoreName
    if (Test-Path $saved) {
        if (Test-Path (Join-Path $modsDir $CoreName)) { throw "Both $saved and Mods/$CoreName exist; sort them out by hand." }
        Move-Item $saved (Join-Path $modsDir $CoreName)
    }
    $json = Join-Path $backup 'mod.json'
    if (Test-Path $json) { Copy-Item $json (Join-Path $modsDir "$CoreName\mod.json") -Force }
    $txt = Join-Path $backup 'mods.txt'
    if (Test-Path $txt) { Copy-Item $txt $modsTxt -Force }
    Remove-Item $backup -Recurse -Force
    Write-Host "Restored $CoreName (and mods.txt) from $backup."
}
function Break-Core {
    New-Item -ItemType Directory -Force $backup | Out-Null
    Copy-Item $modsTxt (Join-Path $backup 'mods.txt') -Force
    switch ($Scenario) {
        'no-core' {
            Move-Item (Join-Path $modsDir $CoreName) (Join-Path $backup $CoreName)
            $lines = @(Get-Content $modsTxt | Where-Object { $_ -notmatch ('^\s*' + [regex]::Escape($CoreName) + '\s*:') })
            Set-Content $modsTxt $lines
            Write-Host "Moved Mods/$CoreName to $backup and took it out of mods.txt."
        }
        'old-core' {
            $json = Join-Path $modsDir "$CoreName\mod.json"
            Copy-Item $json (Join-Path $backup 'mod.json') -Force
            $text = Get-Content $json -Raw
            $new = [regex]::Replace($text, '("version"\s*:\s*")[^"]*(")', '${1}0.1.0${2}', 1)
            if ($new -eq $text) { throw "could not set the version in $json" }
            [IO.File]::WriteAllText($json, $new)
            Write-Host "Set the installed $CoreName mod.json version to 0.1.0 (original kept in $backup)."
        }
    }
}

# The scenario's deploy: no-core and old-core first break core and check that deploy.ps1 refuses without -Force.
$script:runFailures = @()
function Deploy-Scenario {
    if ($Scenario -in 'no-core', 'old-core') {
        Break-Core
        $r = Invoke-Deploy @()
        $why = if ($Scenario -eq 'no-core') { "$CoreName is not installed" } else { "$CoreName 0\.1\.0 is installed, but $name needs >=" }
        if ($r.Code -eq 1 -and $r.Out -match "^$name not deployed: $why" -and ($r.Out -split "`r?`n").Count -eq 1) {
            Write-Host "ok:   deploy.ps1 refused without -Force: $($r.Out)"
        } else {
            Write-Host "FAIL: deploy.ps1 should refuse with one line (exit $($r.Code)): $($r.Out)"
            $script:runFailures += 'deploy refusal'
        }
        $r = Invoke-Deploy @('-Test', '-Scenario', $Scenario, '-Force')
    } else {
        $r = Invoke-Deploy @('-Test', '-Scenario', $Scenario)
    }
    Write-Host $r.Out
    if ($r.Code -ne 0) { throw "deploy.ps1 failed (exit $($r.Code))" }
}

if ($Target -eq 'vm') {
    . (Join-Path $root 'tools\vm\vm-sp.ps1')
    # No Waypoints scenario judges timing: all of them may run in the VM.
    Assert-NNBSpScenario -Scenario $Scenario -HostOnly @()
    # Core comes from the host's own build/package, installed by core's own deploy.ps1 (never built here).
    $coreDeploy = Join-Path $root "mods\$CoreName\deploy.ps1"
    if (-not (Test-Path $coreDeploy)) { throw "$CoreName's deploy.ps1 not found at $coreDeploy (the VM run installs core from its build/package)." }
    $kept = Join-Path $outDir "$Scenario.vm.log"
    Remove-Item $kept -ErrorAction SilentlyContinue
    $run = Invoke-NNBSpRun -Instance $inst -TestMod $driver -Mods $CoreName, $driver, $name -Paks "$CoreName.pak" `
        -EndPattern "\[$driver\] END result=" -TimeoutSec (Get-NNBSpTimeout $hostTimeout $TimeoutSec) -LogOut $kept -Prepare {
            param($stage)
            & pwsh -NoProfile -NonInteractive -File $coreDeploy -Instance $stage -Staged
            if ($LASTEXITCODE -ne 0) { throw "$CoreName's deploy.ps1 failed in the stage (exit $LASTEXITCODE)" }
            Set-DeployTarget $stage
            Deploy-Scenario
        }
    $code = 0
    if ($run.Log) {
        & pwsh -NoProfile -NonInteractive -File (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario -Target vm
        $code = $LASTEXITCODE
    } else { Write-Host 'No UE4SS.log from the VM.'; $code = 1 }
    if ($script:runFailures) { Write-Host "run.ps1 check(s) failed: $($script:runFailures -join ', ')"; $code = 1 }
    exit $code
}

if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running (a dev copy or the real game); not launching.' }
Restore-Core # a run that was killed may have left core broken
if (-not (Test-Path (Join-Path $modsDir "$CoreName\mod.json"))) { throw "$CoreName is not installed in $modsDir; install it with its own deploy.ps1 first." }

$sw = [Diagnostics.Stopwatch]::StartNew()
$result = 'not started'
try {
    Deploy-Scenario

    Remove-Item $log -ErrorAction SilentlyContinue
    & (Join-Path $root 'tools\launch.ps1') -Instance $inst
    $req = Join-Path $scripts 'request.txt'
    $done = Join-Path $scripts 'done.txt'
    $lastSeq = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $result = 'timeout (hang?)'
    Start-Sleep -Seconds 5
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-OurGame)) { $result = 'game exited (crash?)'; break }
        if (Test-Path $req) {
            $text = Get-Content $req -Raw -ErrorAction SilentlyContinue
            if ($text -match '^(\d+) (.+)$' -and [int]$Matches[1] -gt $lastSeq) {
                $lastSeq = [int]$Matches[1]
                Write-Host ("[{0,5:N1}s] request {1}: {2}" -f $sw.Elapsed.TotalSeconds, $lastSeq, $Matches[2])
                Invoke-Request $Matches[2]
                Set-Content $done $lastSeq -NoNewline
            }
        }
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern "\[$driver\] END result=" -Quiet)) { $result = 'finished'; break }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Write-Host ("Run {0} after {1:N0} s." -f $result, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 2
    Stop-Game
    Restore-Core
}

$kept = Join-Path $outDir "$Scenario.log"
if (Test-Path $log) { Copy-Item $log $kept -Force } else { Write-Host "No UE4SS.log at $log" }
& pwsh -NoProfile -NonInteractive -File (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario
$code = $LASTEXITCODE
if ($script:runFailures) { Write-Host "run.ps1 check(s) failed: $($script:runFailures -join ', ')"; $code = 1 }
exit $code
