# Register the "BeoSound Player Control" logon Scheduled Task (interactive session so the
# injected media keys reach the foreground/most-recent player). No admin needed. Re-run to update.
#
#   powershell -ExecutionPolicy Bypass -File .\register-player-control.ps1
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'player-control.ps1'
if (-not (Test-Path $script)) { throw "player-control.ps1 not found next to this file: $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName 'BeoSound Player Control' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force

Write-Host "Registered 'BeoSound Player Control'. Starting it now..."
Start-ScheduledTask -TaskName 'BeoSound Player Control'
