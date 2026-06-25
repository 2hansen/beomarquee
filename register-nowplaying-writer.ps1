# Register the "BeoSound NowPlaying Writer" logon Scheduled Task (interactive session,
# no admin needed). Re-run to update. Must run interactively (LogonType Interactive) so
# the writer can see SMTC media sessions.
#
#   powershell -ExecutionPolicy Bypass -File .\register-nowplaying-writer.ps1
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'nowplaying-writer.ps1'
if (-not (Test-Path $script)) { throw "nowplaying-writer.ps1 not found next to this file: $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName 'BeoSound NowPlaying Writer' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force

Write-Host "Registered 'BeoSound NowPlaying Writer'. Starting it now..."
Start-ScheduledTask -TaskName 'BeoSound NowPlaying Writer'
