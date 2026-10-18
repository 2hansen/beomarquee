# player-control.ps1 — runs in the Windows interactive session. Watches command.txt
# (written by the WSL bsnowplaying service when a BS9000 transport key is pressed) and
# drives the player via the SMTC session API.
#
# WHY SMTC instead of synthetic media keys: the old version used keybd_event to inject
# VK_MEDIA_* keys. That FAILS when Windows is LOCKED — locking switches the active input
# desktop to the secure (Winlogon) desktop, so injected keystrokes never reach the player
# on the user desktop. The SMTC control methods (TryTogglePlayPauseAsync / TrySkipNext /
# TrySkipPrevious / TryStop) are direct API calls into the OS media service that owns the
# session — no synthetic input, no desktop/foreground dependency — so they work while
# locked, exactly like the now-playing READ already does.
#
# Launched by the "BeoSound Player Control" logon Scheduled Task. Blocks forever.
$ErrorActionPreference = 'SilentlyContinue'
$cmdFile = Join-Path $PSScriptRoot 'command.txt'

# WinRT async-await helper (same pattern as nowplaying2.ps1).
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$g = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($t, $ty) { ($g.MakeGenericMethod($ty).Invoke($null, @($t))).GetAwaiter().GetResult() }

[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
$MgrType  = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$BoolType = [bool]

$script:mgr = $null
function Get-Mgr {
    if ($script:mgr) { return $script:mgr }
    try { $script:mgr = Await ($MgrType::RequestAsync()) ($MgrType) } catch { $script:mgr = $null }
    return $script:mgr
}

# Drive the session Windows considers current — exactly where the OS routes the keyboard
# media keys. No whitelist / no custom preference: the remote behaves like pressing
# play/pause on the keyboard (just lock-proof, via SMTC instead of synthetic keys).
function Get-Target {
    $m = Get-Mgr
    if (-not $m) { return $null }
    try { return $m.GetCurrentSession() }
    catch { $script:mgr = $null; return $null }   # drop a stale manager so it re-requests next time
}

# Classic iTunes for Windows does NOT publish SMTC (it grabs the keyboard media keys itself),
# so it is read/driven via its COM scripting interface instead. Guarded on iTunes.exe running
# (New-Object would otherwise LAUNCH iTunes), and every reference is released immediately —
# a held COM reference makes iTunes nag "applications are using the scripting interface" on quit.
function Use-ITunes([scriptblock]$f) {
    if (-not (Get-Process iTunes -ErrorAction SilentlyContinue)) { return $null }
    $it = $null
    try { $it = New-Object -ComObject iTunes.Application; return (& $f $it) }
    catch { return $null }
    finally { if ($it) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($it) } }
}

# Which player the remote drives: the one that most recently STARTED playing. iTunes is seen
# via COM; an SMTC player counts only when its state/track CHANGES into Playing (a level check
# would be fooled by Spotify's stale 'Playing' status after a pause). Sampled every ~1s.
$script:active = 'smtc'
$script:smtcKey = ''
function Update-Active {
    if (Use-ITunes { param($it) $it.PlayerState -eq 1 }) { $script:active = 'itunes'; return }
    $s = Get-Target
    if (-not $s) { return }
    try {
        $status = "$($s.GetPlaybackInfo().PlaybackStatus)"
        $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        $key = "$($s.SourceAppUserModelId)|$status|$($p.Title)"
        if ($key -ne $script:smtcKey) {
            $script:smtcKey = $key
            if ($status -eq 'Playing') { $script:active = 'smtc' }
        }
    } catch {}
}

function Do-ITunesCmd($cmd) {
    Use-ITunes {
        param($it)
        switch ($cmd) {
            'playpause' { $it.PlayPause() }
            'stop'      { $it.Pause() }          # same STOP = pause semantics as the SMTC path
            'next'      { $it.NextTrack() }
            'prev'      { $it.PreviousTrack() }
        }
        $true
    }
}

function Do-Cmd($cmd) {
    if ($script:active -eq 'itunes' -and (Do-ITunesCmd $cmd)) { return }
    $s = Get-Target
    if (-not $s) { return }
    switch ($cmd) {
        # GO = TryTogglePlayPause, which flips the player's REAL state. We do NOT decide by
        # PlaybackStatus: Spotify's SMTC status is stale (it reads 'Playing' even after a
        # confirmed pause), so a status-based branch always chose Pause and GO could never
        # resume. Toggle is handled by the player itself, so it resumes from pause reliably.
        # (We only ever pause now -- never hard-stop -- so the resume-from-STOPPED concern
        # that once motivated a status branch no longer applies.)
        'playpause' { Await ($s.TryTogglePlayPauseAsync()) $BoolType | Out-Null }
        # STOP key = PAUSE (resumable), not a hard TryStopAsync: a true SMTC Stop unloads the
        # current media, so GO afterwards can't resume (only skip-to-next revived it). Pause
        # keeps the track loaded so GO resumes it. The Beo4 has no separate pause key.
        'stop'      { Await ($s.TryPauseAsync())           $BoolType | Out-Null }
        'next'      { Await ($s.TrySkipNextAsync())        $BoolType | Out-Null }
        'prev'      { Await ($s.TrySkipPreviousAsync())    $BoolType | Out-Null }
    }
}

$last = ''
$tick = 0
while ($true) {
    try {
        if (($tick++ % 7) -eq 0) { Update-Active }    # ~1s at the 150ms poll
        if (Test-Path $cmdFile) {
            $line = (Get-Content -LiteralPath $cmdFile -Raw).Trim()
            if ($line -and $line -ne $last) {
                $last = $line
                $cmd = ($line -split '\s+')[-1]        # "<seq> <command>" -> command
                Do-Cmd $cmd
            }
        }
    } catch {}
    Start-Sleep -Milliseconds 150
}
