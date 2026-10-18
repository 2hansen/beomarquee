# Register the "BeoSound Resume Rebuild" scheduled task -- fires resume-rebuild.ps1 ONCE on
# every resume-from-sleep, to guarantee a clean usbip link after the box wakes (the post-sleep
# D-state wedge that no in-process self-heal can recover -- see resume-rebuild.ps1 for the why).
# Launched hidden via run-hidden.vbs (no window flash), same pattern as the other BeoSound
# tasks. Registering a task needs admin -> run from an ELEVATED PowerShell. Re-run to update.
#
#   powershell -ExecutionPolicy Bypass -File .\register-resume-task.ps1
#
# Trigger = System event log, Microsoft-Windows-Kernel-Power EventID 107
# ("The system has resumed from sleep") -- the canonical "we just woke up" marker.
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs    = Join-Path $here 'run-hidden.vbs'
$script = Join-Path $here 'resume-rebuild.ps1'
foreach ($p in @($vbs, $script)) { if (-not (Test-Path $p)) { throw "missing next to this file: $p" } }

# Hidden launch: wscript run-hidden.vbs "<resume-rebuild.ps1>"  (window style 0, no flash)
$action = New-ScheduledTaskAction -Execute 'wscript.exe' `
    -Argument ('"{0}" "{1}"' -f $vbs, $script)

# Event trigger: New-ScheduledTaskTrigger has no event-log option, so build a
# MSFT_TaskEventTrigger CIM instance with an XPath subscription for the resume event.
$subscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=107)]]</Select></Query></QueryList>"
$class   = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $class -ClientOnly
$trigger.Enabled      = $true
$trigger.Subscription = $subscription

# One-shot: allow on battery; retry a few times if wsl.exe is momentarily unavailable at wake.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# Interactive: on resume-from-sleep the console session is still logged on, so the task runs.
# wsl --shutdown needs no elevation, so RunLevel Limited (default) is fine.
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive

Register-ScheduledTask -TaskName 'BeoSound Resume Rebuild' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Registered 'BeoSound Resume Rebuild' (trigger: Kernel-Power EventID 107)."
Write-Host "Dry-run without sleeping:  Start-ScheduledTask -TaskName 'BeoSound Resume Rebuild'"
Write-Host "  (^ that WILL run wsl --shutdown + rebuild -- expect ~10s of glass downtime.)"
