# Put the Beosound 9000 into standby when this PC sleeps, and bring it back on N.MUSIC when
# the PC wakes. Launched by the "BeoSound Power Watch" logon Scheduled Task; blocks forever.
#
# WHY IT TALKS TO HOME ASSISTANT AND NOT TO THE BUS (settled empirically 2026-08-09):
#   The obvious route was to send a Beo4 STANDBY key over the BeoPort ourselves. It does not
#   work: outbound key injection was tested with four different address/framing variants AND
#   with a known-good key (GO 0x35, the byte the remote demonstrably uses) against an awake
#   unit -- every one was silently ignored. The outbound telegram layout is simply not
#   understood yet. Home Assistant's Masterlink Gateway integration already solved this, so we
#   drive the unit through HA's REST API instead. Two calls, no protocol RE:
#       media_player.turn_off                       -> unit goes to standby   (verified on the
#       media_player.select_source  source=N.MUSIC  -> unit comes up on us     bus, +0.2s/+1.0s)
#   A bonus: an HTTP call to the HA box does not touch the BeoPort/usbip path at all, so the
#   standby command does NOT have to win a race against the USB link dying as Windows suspends.
#   That was the one make-or-break unknown in the original bus-based design; this route removes it.
#
# THE TWO GUARDS (deliberately asymmetric -- this is not a blind save/restore):
#   * On sleep  -- only if the Beosound is actually playing US. bsnowplaying.py publishes that
#     to `source-state`; if the user is on CD or the radio we leave their music alone.
#   * On wake   -- only if WE were the one that put it into standby (the `standby-flag` file,
#     written at sleep and surviving it). The bus gives no readable "it is in standby" signal we
#     trust yet, so we remember what we did instead of trying to detect it. That also means a
#     unit the user deliberately left off stays off.
#
# CONFIG: copy ha.env.example to ha.env and fill in HA_URL + HA_TOKEN (ha.env is gitignored --
# it holds a long-lived access token, keep it out of the repo).
#
# DRY RUN -- exercise either half once and exit, without sleeping the machine:
#   powershell -ExecutionPolicy Bypass -File .\power-watch.ps1 -Test suspend
#   powershell -ExecutionPolicy Bypass -File .\power-watch.ps1 -Test resume
param([ValidateSet('suspend', 'resume')][string]$Test)

$ErrorActionPreference = 'Continue'

$logFile     = Join-Path $PSScriptRoot 'power-watch.log'
$sourceState = Join-Path $PSScriptRoot 'source-state'    # written by bsnowplaying.py: n.music | other
$standbyFlag = Join-Path $PSScriptRoot 'standby-flag'    # WE wrote the standby -> we may undo it
$envFile     = Join-Path $PSScriptRoot 'ha.env'

function Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 262144)) {
            Set-Content -LiteralPath $logFile -Value (Get-Content -LiteralPath $logFile -Tail 400)
        }
        Add-Content -LiteralPath $logFile -Value $line
    } catch {}
    Write-Host $line
}

# --- config ---------------------------------------------------------------------------------
if (-not (Test-Path $envFile)) {
    Log "[power-watch] no ha.env next to this script -- copy ha.env.example and fill it in. Exiting."
    exit 1
}
$cfg = @{}
foreach ($line in (Get-Content -LiteralPath $envFile)) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $cfg[$k.Trim()] = $v.Trim()
}
$haUrl  = $cfg['HA_URL']  -replace '/+$', ''
$haTok  = $cfg['HA_TOKEN']
$entity = if ($cfg['BS_ENTITY']) { $cfg['BS_ENTITY'] } else { 'media_player.beosound_9000' }
$source = if ($cfg['BS_SOURCE']) { $cfg['BS_SOURCE'] } else { 'N.MUSIC' }
if (-not $haUrl -or -not $haTok) { Log "[power-watch] ha.env is missing HA_URL or HA_TOKEN. Exiting."; exit 1 }

# --- HA service call ------------------------------------------------------------------------
function Invoke-HA([string]$service, [hashtable]$data, [int]$timeoutSec = 5) {
    try {
        $body = ($data + @{ entity_id = $entity }) | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -TimeoutSec $timeoutSec `
            -Uri ("{0}/api/services/media_player/{1}" -f $haUrl, $service) `
            -Headers @{ Authorization = "Bearer $haTok"; 'Content-Type' = 'application/json' } `
            -Body $body | Out-Null
        return $true
    } catch {
        Log ("[power-watch] HA {0} failed: {1}" -f $service, $_.Exception.Message)
        return $false
    }
}

function Get-SourceState {
    try { return (Get-Content -LiteralPath $sourceState -Raw -ErrorAction Stop).Trim() } catch { return '' }
}

# --- the two actions --------------------------------------------------------------------------
function On-Suspend {
    $state = Get-SourceState
    if ($state -ne 'n.music') {
        # Unknown counts as "not ours" on purpose: never risk switching off a unit that is
        # playing something else. Empty = bsnowplaying has not seen the bus select N.MUSIC.
        Log ("[power-watch] sleep -> source is '{0}', not ours; leaving the Beosound alone" -f $state)
        return
    }
    # Short timeout: this runs on the way into suspend, so it must not hang the shutdown path.
    if (Invoke-HA 'turn_off' @{} 3) {
        Set-Content -LiteralPath $standbyFlag -Value 'we-set-standby' -Force
        Log "[power-watch] sleep -> Beosound was on N.MUSIC; sent standby (flag set for wake)"
    } else {
        Log "[power-watch] sleep -> standby call failed; NOT setting the flag (nothing to undo)"
    }
}

function On-Resume {
    if (-not (Test-Path $standbyFlag)) {
        Log "[power-watch] wake -> we did not put it into standby; leaving it as the user left it"
        return
    }
    if ((Get-SourceState) -eq 'n.music') {
        Log "[power-watch] wake -> already back on N.MUSIC; nothing to do"
        Remove-Item -LiteralPath $standbyFlag -Force -ErrorAction SilentlyContinue
        return
    }
    # Networking is not up the instant Windows resumes, so retry for ~30s before giving up.
    $ok = $false
    for ($i = 1; $i -le 15 -and -not $ok; $i++) {
        $ok = Invoke-HA 'select_source' @{ source = $source } 5
        if (-not $ok) { Start-Sleep -Seconds 2 }
    }
    if ($ok) { Log ("[power-watch] wake -> selected {0} on the Beosound" -f $source) }
    else     { Log "[power-watch] wake -> could not reach HA after ~30s; giving up this wake" }
    # Clear the flag either way: a flag left behind would hijack a LATER wake, long after the
    # user may have turned the unit on themselves.
    Remove-Item -LiteralPath $standbyFlag -Force -ErrorAction SilentlyContinue
}

if ($Test) {
    Log ("[power-watch] DRY RUN: {0}" -f $Test)
    if ($Test -eq 'suspend') { On-Suspend } else { On-Resume }
    exit 0
}

# --- watch ------------------------------------------------------------------------------------
# PowerModeChanged (not a Scheduled Task event trigger) because the SLEEP half is timing
# critical: an event-log-triggered task starts too late to be sure it runs before the machine is
# down. SystemEvents raises this in-process, on its own pumped thread, on the way into suspend.
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged `
    -SourceIdentifier 'BeoPowerMode' | Out-Null
Log ("[power-watch] watching for sleep/wake (entity {0}, source {1})" -f $entity, $source)

# Handled in the main scope rather than in a -Action block so the config and helpers above are
# all in scope; SystemEvents still queues the event from its own thread while we wait.
while ($true) {
    $ev = Wait-Event -SourceIdentifier 'BeoPowerMode' -Timeout 3600
    if (-not $ev) { continue }                                  # idle tick, just loop
    $mode = $null
    try { $mode = $ev.SourceArgs[1].Mode } catch {}
    Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
    switch ("$mode") {
        'Suspend' { On-Suspend }
        'Resume'  { On-Resume }
        default   { }                                           # StatusChange (battery etc) -- ignore
    }
}
