# BeoSound Resume Rebuild -- runs ONCE on every resume-from-sleep (fired by the
# "BeoSound Resume Rebuild" scheduled task; event-triggered on Kernel-Power ID 107).
# See register-resume-task.ps1.
#
# WHY THIS EXISTS (2026-07-05): sleeping the box severs the usbip TCP socket between
# usbipd (Windows) and the WSL vhci driver while bsnowplaying has an inbound read URB
# in flight. On resume that URB cannot be reaped -> the reader thread wedges in D-state
# (usb_kill_urb) and the whole service deadlocks BELOW the level any try/except or a
# systemd restart can recover. PROVEN LIVE 2026-07-05: `usbipd detach/attach` does NOT
# clear it (the WSL vhci port stays orphaned, sockfd alive); only tearing down the WSL
# VM kernel state does. So on every resume we `wsl --shutdown` (nuke the VM), then drop
# a reattach-request -- the attach-beoport loop re-attaches the BeoPort, which cold-boots
# Ubuntu -> systemd -> a FRESH bsnowplaying with a clean link.
#
# Cost: ~10s of glass downtime after each wake (WSL cold boot). Accepted trade for a
# guaranteed-clean link on every resume. NOTE: this also kills any Claude Code / other
# session running in this WSL at wake time -- this box's WSL is dedicated to beomarquee.
$ErrorActionPreference = 'Continue'

$logFile     = Join-Path $PSScriptRoot 'resume-rebuild.log'
$reattachReq = Join-Path $PSScriptRoot 'reattach-request'   # attach-beoport.ps1 watches this
$wsl         = Join-Path $env:SystemRoot 'System32\wsl.exe'

function Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 262144)) {
            Set-Content -LiteralPath $logFile -Value (Get-Content -LiteralPath $logFile -Tail 400)
        }
        Add-Content -LiteralPath $logFile -Value $line
    } catch {}
}

Log '[resume-rebuild] resume detected -> tearing down WSL to rebuild the usbip link'
Start-Sleep -Seconds 5      # let Windows + usbipd settle after wake before touching WSL

try {
    & $wsl --shutdown
    Log "[resume-rebuild] wsl --shutdown exit $LASTEXITCODE"
} catch {
    Log "[resume-rebuild] ERROR running wsl --shutdown: $($_.Exception.Message)"
}

# Belt-and-suspenders: force the attach-beoport loop to detach+reattach (its reattach-request
# branch runs a detach+attach regardless of whether usbipd still reports the device 'Attached'
# to the now-dead VM). The attach re-enumerates a fresh node AND cold-boots Ubuntu -> systemd
# -> bsnowplaying. Written AFTER the shutdown so the loop rebuilds against a clean VM.
try {
    Set-Content -LiteralPath $reattachReq -Value 'resume' -Force
    Log '[resume-rebuild] wrote reattach-request -> attach-beoport loop will re-attach + cold-boot Ubuntu'
} catch {
    Log "[resume-rebuild] ERROR writing reattach-request: $($_.Exception.Message)"
}
