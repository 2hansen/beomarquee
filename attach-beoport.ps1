# Keep the BeoPort 1671 (VID:PID 0cd4:0101) attached to WSL. Launched by the "BeoPort
# Auto-Attach" logon Scheduled Task; blocks forever in a simple, self-controlled loop.
#
# Why a loop instead of `usbipd attach --auto-attach`: that built-in monitor exited on its
# own under Task Scheduler (LastTaskResult 0xC000013A / CONTROL_C_EXIT). This loop we control:
# every few seconds, if the BeoPort is present-but-not-attached, (re)attach it. It also
# doubles as the WSL starter -- `usbipd attach --wsl` boots the Ubuntu distro if it isn't
# running, which then starts systemd and the enabled bsnowplaying.service. So one logon task
# brings up the whole chain after a reboot.
$ErrorActionPreference = 'Continue'

$usbipd = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
if (-not (Test-Path $usbipd)) { $usbipd = (Get-Command usbipd.exe -ErrorAction Stop).Source }
$busid = '8-2'   # BeoPort 1671 on this box (stable port); resolved by hardware id below if it moves
$reattachReq = Join-Path $PSScriptRoot 'reattach-request'   # WSL drops this when the link wedges (Errno 110)

while ($true) {
    try {
        $line = (& $usbipd list) | Where-Object { $_ -match '0cd4:0101' } | Select-Object -First 1
        if ($line) {
            if ($line -match '^\s*(\S+)\s+0cd4:0101') { $busid = $Matches[1] }

            # Self-heal the recurring BeoPort/usbip wedge: the WSL service hits Errno 110 on every
            # write while the device still shows 'Attached', so a plain re-attach won't fix it --
            # it needs a detach+reattach to re-enumerate a fresh node. WSL signals via this file.
            if (Test-Path $reattachReq) {
                Write-Host "[attach-beoport] reattach-request seen -> detach+reattach busid $busid to clear wedge"
                & $usbipd detach --busid $busid
                Start-Sleep -Seconds 2
                & $usbipd attach --wsl Ubuntu --busid $busid
                Remove-Item -LiteralPath $reattachReq -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            elseif ($line -notmatch 'Attached') {
                # The usbipd bind ("Shared" state) is supposed to be persistent but does NOT
                # reliably survive a reboot / USB-port change (busid moved 8-2 -> 8-4 once and
                # the share was lost -> attach refuses with "Device is not shared"). Binding
                # needs admin, which is why this task runs at RunLevel Highest -- so it can
                # self-heal that case unattended instead of needing a manual elevated bind.
                if ($line -match 'Not shared') {
                    Write-Host "[attach-beoport] busid $busid is 'Not shared' -> binding ..."
                    & $usbipd bind --busid $busid
                }
                Write-Host "[attach-beoport] attaching busid $busid to WSL ..."
                & $usbipd attach --wsl Ubuntu --busid $busid    # also boots Ubuntu if it's cold
            }
        }
        # else: device unplugged entirely -> nothing to do, just wait
    } catch {
        Write-Host "[attach-beoport] $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 3
}
