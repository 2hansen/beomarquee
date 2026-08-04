# BeoSound Resume Rebuild -- runs ONCE on every resume-from-sleep (fired by the
# "BeoSound Resume Rebuild" scheduled task; event-triggered on Kernel-Power ID 107).
# See register-resume-task.ps1.
#
# WHY THIS EXISTS (2026-07-05): sleeping the box severs the usbip TCP socket between
# usbipd (Windows) and the WSL vhci driver while bsnowplaying has an inbound read URB
# in flight. On resume that URB cannot be reaped -> the reader thread wedges in D-state
# (usb_kill_urb) and the whole service deadlocks BELOW the level any try/except or a
# systemd restart can recover. PROVEN LIVE 2026-07-05: `usbipd detach/attach` does NOT
# clear it (the WSL vhci port stays orphaned, sockfd alive).
#
# SURGICAL RECOVERY (2026-08-04): the wedged URB is reaped by tearing down the vhci PORT,
# NOT only by tearing down the whole VM ("only root sysfs vhci detach or wsl --shutdown"
# clears it). So on resume we now run resume-heal.sh AS ROOT inside WSL -- it writes the
# vhci `detach` sysfs knob for each attached port and restarts bsnowplaying. The VM and
# every OTHER process in this WSL (Claude Code sessions, tools) SURVIVE. If that surgical
# heal can't act (not root / no vhci / error), we FALL BACK to the old `wsl --shutdown`
# hammer so recovery reliability is unchanged. Either way we then drop a reattach-request
# -- the attach-beoport loop re-attaches a fresh BeoPort node and bsnowplaying rebinds.
#
# Cost: ~a few seconds of glass downtime after each wake. No longer costs the whole VM.
$ErrorActionPreference = 'Continue'

$logFile     = Join-Path $PSScriptRoot 'resume-rebuild.log'
$reattachReq = Join-Path $PSScriptRoot 'reattach-request'   # attach-beoport.ps1 watches this
$wsl         = Join-Path $env:SystemRoot 'System32\wsl.exe'
$healScript  = Join-Path $PSScriptRoot 'resume-heal.sh'     # surgical in-WSL vhci detach (runs as root)

function Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 262144)) {
            Set-Content -LiteralPath $logFile -Value (Get-Content -LiteralPath $logFile -Tail 400)
        }
        Add-Content -LiteralPath $logFile -Value $line
    } catch {}
}

Log '[resume-rebuild] resume detected -> surgically tearing down the vhci port (VM stays up)'
Start-Sleep -Seconds 5      # let Windows + usbipd settle after wake before touching WSL

# Surgical heal: run resume-heal.sh AS ROOT inside WSL to detach the wedged vhci port(s)
# and bounce bsnowplaying, WITHOUT killing the VM. Fall back to `wsl --shutdown` on any
# failure (non-zero exit, or the whole call throwing) so recovery reliability is unchanged.
$fellBack = $false
try {
    $healWsl = (& $wsl -d Ubuntu -e wslpath -a "$healScript" 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($healWsl)) { throw "wslpath returned nothing for '$healScript'" }
    & $wsl -d Ubuntu -u root -e bash "$healWsl"
    $rc = $LASTEXITCODE
    Log "[resume-rebuild] resume-heal.sh exit $rc"
    if ($rc -ne 0) {
        Log "[resume-rebuild] surgical heal failed (rc=$rc) -> FALLBACK wsl --shutdown"
        & $wsl --shutdown
        Log "[resume-rebuild] wsl --shutdown exit $LASTEXITCODE"
        $fellBack = $true
    }
} catch {
    Log "[resume-rebuild] ERROR in surgical heal: $($_.Exception.Message) -> FALLBACK wsl --shutdown"
    & $wsl --shutdown
    Log "[resume-rebuild] wsl --shutdown exit $LASTEXITCODE"
    $fellBack = $true
}

# Belt-and-suspenders: force the attach-beoport loop to detach+reattach (its reattach-request
# branch runs a detach+attach regardless of whether usbipd still reports the device 'Attached').
# The attach re-enumerates a FRESH node that bsnowplaying rebinds. In the surgical path this
# runs against the still-live VM; in the fallback path it runs after the VM cold-boots. Written
# AFTER the heal/shutdown either way so the loop rebuilds against a clean link.
try {
    Set-Content -LiteralPath $reattachReq -Value 'resume' -Force
    $how = if ($fellBack) { 're-attach + cold-boot Ubuntu' } else { 're-attach a fresh node (VM stayed up)' }
    Log "[resume-rebuild] wrote reattach-request -> attach-beoport loop will $how"
} catch {
    Log "[resume-rebuild] ERROR writing reattach-request: $($_.Exception.Message)"
}
