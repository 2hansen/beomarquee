# Register the "BeoPort Auto-Attach" logon Scheduled Task (run once, no admin needed
# since usbipd attach works unprivileged on this box). Re-run to update it.
#
#   powershell -ExecutionPolicy Bypass -File .\register-beoport-task.ps1
#
# Trigger = at logon of the current user. (This box does NOT auto-login -> the task
# fires when Bo logs in. If you later enable auto-login, reboot becomes fully
# hands-free: logon -> attach monitor -> WSL systemd service -> glass lit.)
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'attach-beoport.ps1'
if (-not (Test-Path $script)) { throw "attach-beoport.ps1 not found next to this file: $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# No time limit (the monitor blocks forever); auto-restart if it ever exits.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName 'BeoPort Auto-Attach' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force

Write-Host "Registered 'BeoPort Auto-Attach'. Test now without reboot:  Start-ScheduledTask -TaskName 'BeoPort Auto-Attach'"
