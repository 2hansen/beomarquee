# Re-point the three BeoSound logon tasks to launch via run-hidden.vbs so they
# start with NO visible terminal window. Fixes the Win11 "three terminals open
# on reboot" annoyance: -WindowStyle Hidden is ignored when Windows Terminal is
# the default console host, so we launch through wscript.exe instead (window
# style 0 = genuinely hidden). Triggers/settings/principal are left untouched.
#
#   powershell -ExecutionPolicy Bypass -File .\register-hidden-tasks.ps1 [-ShowWindowTitle]
#
# Re-run any time to re-apply (e.g. after re-registering a task the old way).
# -ShowWindowTitle : forward that switch to the NowPlaying Writer (active-window fallback).
param([switch]$ShowWindowTitle)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs  = Join-Path $here 'run-hidden.vbs'
if (-not (Test-Path $vbs)) { throw "run-hidden.vbs not found next to this file: $vbs" }

$map = @{
    'BeoPort Auto-Attach'        = 'attach-beoport.ps1'
    'BeoSound NowPlaying Writer' = 'nowplaying-writer.ps1'
    'BeoSound Player Control'    = 'player-control.ps1'
}

foreach ($name in $map.Keys) {
    $ps1 = Join-Path $here $map[$name]
    if (-not (Test-Path $ps1)) { Write-Warning "skip '$name': $ps1 missing"; continue }

    $arg = "`"$vbs`" `"$ps1`""
    if ($name -eq 'BeoSound NowPlaying Writer' -and $ShowWindowTitle) { $arg += " -ShowWindowTitle" }
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arg

    Set-ScheduledTask -TaskName $name -Action $action | Out-Null
    Write-Host "Updated '$name' -> wscript run-hidden.vbs $($map[$name])"
}

Write-Host ""
Write-Host "Done. Restart the tasks now (no reboot needed):"
Write-Host "  Get-ScheduledTask 'BeoPort Auto-Attach','BeoSound NowPlaying Writer','BeoSound Player Control' | Stop-ScheduledTask"
Write-Host "  Get-ScheduledTask 'BeoPort Auto-Attach','BeoSound NowPlaying Writer','BeoSound Player Control' | Start-ScheduledTask"
