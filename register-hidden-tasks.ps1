# Re-point the three BeoSound logon tasks to launch via run-hidden.vbs so they
# start with NO visible terminal window. Fixes the Win11 "three terminals open
# on reboot" annoyance: -WindowStyle Hidden is ignored when Windows Terminal is
# the default console host, so we launch through wscript.exe instead (window
# style 0 = genuinely hidden). Triggers/settings left untouched; the principal is
# explicitly re-applied (see below) because Set-ScheduledTask -Action would reset it.
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

    # Set-ScheduledTask -Action ALONE silently resets the principal to default RunLevel
    # Limited (it does NOT leave it untouched). The BeoPort Auto-Attach task must stay at
    # RunLevel Highest so it can `usbipd bind` unattended, so capture the current RunLevel,
    # set the action, then re-assert it via object mutation (the -Principal param did not
    # reliably hold Highest on this build).
    $saveRunLevel = (Get-ScheduledTask -TaskName $name -ErrorAction Stop).Principal.RunLevel
    Set-ScheduledTask -TaskName $name -Action $action | Out-Null
    $t = Get-ScheduledTask -TaskName $name
    if ($t.Principal.RunLevel -ne $saveRunLevel) {
        $t.Principal.RunLevel = $saveRunLevel
        $t | Set-ScheduledTask | Out-Null
    }
    Write-Host "Updated '$name' -> wscript run-hidden.vbs $($map[$name]) (RunLevel $((Get-ScheduledTask -TaskName $name).Principal.RunLevel))"
}

Write-Host ""
Write-Host "Done. Restart the tasks now (no reboot needed):"
Write-Host "  Get-ScheduledTask 'BeoPort Auto-Attach','BeoSound NowPlaying Writer','BeoSound Player Control' | Stop-ScheduledTask"
Write-Host "  Get-ScheduledTask 'BeoPort Auto-Attach','BeoSound NowPlaying Writer','BeoSound Player Control' | Start-ScheduledTask"
