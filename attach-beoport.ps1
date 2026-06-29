# Keep the BeoPort 1671 (VID:PID 0cd4:0101) attached to WSL. Launched by the "BeoPort
# Auto-Attach" logon Scheduled Task; blocks forever in a simple, self-controlled loop.
#
# Why a loop instead of `usbipd attach --auto-attach`: that built-in monitor exited on its
# own under Task Scheduler (LastTaskResult 0xC000013A / CONTROL_C_EXIT). This loop we control:
# every few seconds, if the BeoPort is present-but-not-attached, (re)attach it. It also
# doubles as the WSL starter -- `usbipd attach --wsl` boots the Ubuntu distro if it isn't
# running, which then starts systemd and the enabled bsnowplaying.service. So one logon task
# brings up the whole chain after a reboot.
#
# Hardening (2026-06-28): every usbipd call is wrapped in a hard timeout (Invoke-Usbipd) so a
# single hung usbipd.exe can no longer freeze the whole loop -- the freeze that left the
# BeoPort detached, the reattach-request unprocessed, and the WSL service death-looping. All
# actions/errors are timestamped to attach-beoport.log (Write-Host alone is discarded under
# the hidden wscript launch, so previously there was zero evidence after a failure).
$ErrorActionPreference = 'Continue'

$usbipd = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
if (-not (Test-Path $usbipd)) { $usbipd = (Get-Command usbipd.exe -ErrorAction Stop).Source }
$busid = '8-2'   # BeoPort 1671 on this box (stable port); resolved by hardware id below if it moves
$reattachReq = Join-Path $PSScriptRoot 'reattach-request'   # WSL drops this when the link wedges (Errno 110)
$logFile     = Join-Path $PSScriptRoot 'attach-beoport.log'
$USBIPD_TIMEOUT = 20   # seconds; any usbipd call exceeding this is killed and retried next tick

# --- timestamped logging to a rolling file (so a failure leaves evidence; Write-Host is
# discarded under the hidden wscript launcher). Trim to the last 400 lines past ~256 KB. ---
function Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 262144)) {
            $keep = Get-Content -LiteralPath $logFile -Tail 400
            Set-Content -LiteralPath $logFile -Value $keep
        }
        Add-Content -LiteralPath $logFile -Value $line
    } catch {}
    Write-Host $line
}

# --- run usbipd with a HARD timeout. Returns stdout (string) on success, or $null if the
# call timed out (process killed) or failed to start. A hung usbipd therefore costs one tick,
# not the whole loop. Args have no spaces (busid/flags), so a plain join is safe on WinPS 5.1
# where ProcessStartInfo.ArgumentList does not exist. ---
function Invoke-Usbipd([string[]]$cmdArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $usbipd
    $psi.Arguments              = ($cmdArgs -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Log "ERROR: failed to start usbipd $($cmdArgs -join ' '): $($_.Exception.Message)"
        return $null
    }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($USBIPD_TIMEOUT * 1000)) {
        try { $p.Kill() } catch {}
        Log "WARN: usbipd $($cmdArgs -join ' ') timed out after ${USBIPD_TIMEOUT}s -> killed (retry next tick)"
        return $null
    }
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    # Drop the constant benign USBPcap-filter warning (emitted on every call) so it doesn't
    # flood the log; keep any other stderr, which would be a real problem worth seeing.
    $stderrMeaningful = (($stderr -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch 'USBPcap' }) -join '; '
    if ($p.ExitCode -ne 0) {
        Log "WARN: usbipd $($cmdArgs -join ' ') exit $($p.ExitCode): $stderrMeaningful"
    } elseif ($stderrMeaningful) {
        Log "usbipd $($cmdArgs -join ' '): $stderrMeaningful"
    }
    return $stdout
}

Log "[attach-beoport] watcher started (usbipd=$usbipd, timeout=${USBIPD_TIMEOUT}s)"
$lastHeartbeat = Get-Date

while ($true) {
    try {
        $listOut = Invoke-Usbipd @('list')
        if ($null -eq $listOut) {
            Start-Sleep -Seconds 3; continue        # list hung/failed -> already logged; retry
        }
        $line = ($listOut -split "`r?`n") | Where-Object { $_ -match '0cd4:0101' } | Select-Object -First 1
        if ($line) {
            if ($line -match '^\s*(\S+)\s+0cd4:0101') { $busid = $Matches[1] }

            # Self-heal the recurring BeoPort/usbip wedge: the WSL service hits Errno 110 on every
            # write while the device still shows 'Attached', so a plain re-attach won't fix it --
            # it needs a detach+reattach to re-enumerate a fresh node. WSL signals via this file.
            if (Test-Path $reattachReq) {
                Log "[attach-beoport] reattach-request seen -> detach+reattach busid $busid to clear wedge"
                Invoke-Usbipd @('detach', '--busid', $busid) | Out-Null
                Start-Sleep -Seconds 2
                Invoke-Usbipd @('attach', '--wsl', 'Ubuntu', '--busid', $busid) | Out-Null
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
                    Log "[attach-beoport] busid $busid is 'Not shared' -> binding ..."
                    Invoke-Usbipd @('bind', '--busid', $busid) | Out-Null
                }
                Log "[attach-beoport] attaching busid $busid to WSL ..."
                Invoke-Usbipd @('attach', '--wsl', 'Ubuntu', '--busid', $busid) | Out-Null   # also boots Ubuntu if it's cold
            }
        }
        # else: device unplugged entirely -> nothing to do, just wait
    } catch {
        Log "[attach-beoport] $($_.Exception.Message)"
    }
    # heartbeat every ~5 min so the log distinguishes 'healthy & idle' from 'frozen'
    if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 5) {
        Log "[attach-beoport] heartbeat (busid $busid)"
        $lastHeartbeat = Get-Date
    }
    Start-Sleep -Seconds 3
}
