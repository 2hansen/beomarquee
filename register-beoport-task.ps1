# Register the "BeoPort Auto-Attach" logon Scheduled Task. Runs at RunLevel Highest so
# attach-beoport.ps1 can `usbipd bind` unattended if the share is ever lost (the bind is
# meant to be persistent but does NOT survive every reboot / port change -- see the note
# in attach-beoport.ps1). Registering the task itself needs admin (elevated PowerShell).
# Re-run to update it.
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

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName 'BeoPort Auto-Attach' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

# NOTE: `Register-ScheduledTask ... -RunLevel Highest` (via New-ScheduledTaskPrincipal,
# LogonType Interactive) does NOT reliably persist on this build (PS7/Win11) -- it stores
# back as Limited. Force it via object mutation, which DOES stick. Without Highest the task
# can't `usbipd bind` unattended when the share is lost after a reboot.
$t = Get-ScheduledTask -TaskName 'BeoPort Auto-Attach'
$t.Principal.RunLevel = 'Highest'
$t | Set-ScheduledTask | Out-Null

Write-Host ("Registered 'BeoPort Auto-Attach' (RunLevel {0}). Test now:  Start-ScheduledTask -TaskName 'BeoPort Auto-Attach'" -f (Get-ScheduledTask -TaskName 'BeoPort Auto-Attach').Principal.RunLevel)
