# Register the "BeoSound Power Watch" logon Scheduled Task -- the watcher that puts the
# Beosound into standby when this PC sleeps and selects N.MUSIC again when it wakes.
# Registering a task needs admin (elevated PowerShell). Re-run to update it.
#
#   powershell -ExecutionPolicy Bypass -File .\register-power-watch.ps1
#
# Trigger = at logon of the current user; the script then blocks forever on the power events.
# RunLevel Limited is enough (unlike the attach task, this one never calls usbipd).
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'power-watch.ps1'
if (-not (Test-Path $script)) { throw "power-watch.ps1 not found next to this file: $script" }
if (-not (Test-Path (Join-Path $here 'ha.env'))) {
    Write-Warning "ha.env not found -- copy ha.env.example to ha.env and fill in HA_URL + HA_TOKEN, or the task will exit immediately."
}

# Launched through run-hidden.vbs like the other watchers, so no console window ever flashes.
$vbs = Join-Path $here 'run-hidden.vbs'
if (Test-Path $vbs) {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ("`"$vbs`" `"$script`"")
} else {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
}

$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)

# No time limit (the watcher blocks forever); auto-restart if it ever exits. DontStopIfGoingOnBatteries
# matters here more than anywhere else -- this task's whole job happens as the machine powers down.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive

Register-ScheduledTask -TaskName 'BeoSound Power Watch' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Registered 'BeoSound Power Watch'. Start it now:  Start-ScheduledTask -TaskName 'BeoSound Power Watch'"
Write-Host "Then sleep + wake the box and check power-watch.log."
