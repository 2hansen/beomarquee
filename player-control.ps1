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

# Only ever control the real music players (mirror of the now-playing writer's whitelist),
# so a stray browser / Teams session can't be driven by the remote.
$allow = @('Spotify', 'foobar2000', 'MusicBee')
function Is-Allowed($id) { if (-not $id) { return $false }; foreach ($a in $allow) { if ($id -match $a) { return $true } }; return $false }

$script:mgr = $null
function Get-Mgr {
    if ($script:mgr) { return $script:mgr }
    try { $script:mgr = Await ($MgrType::RequestAsync()) ($MgrType) } catch { $script:mgr = $null }
    return $script:mgr
}

# PlaybackStatus renders by NAME in PowerShell ('Playing' / 'Paused' / 'Stopped' / ...), so
# compare the name — robust against the numeric enum (Playing is actually 5, NOT 4).
function Is-Playing($s) { try { return "$($s.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing' } catch { return $false } }

# Pick the session the remote should drive: a whitelisted Playing session first; else any
# Playing session; else a whitelisted current session; else the current session (so a
# play/resume from a paused OR stopped state still targets the last-active player).
function Get-Target {
    $m = Get-Mgr
    if (-not $m) { return $null }
    try {
        $sessions = @($m.GetSessions())
        foreach ($s in $sessions) { if ((Is-Allowed $s.SourceAppUserModelId) -and (Is-Playing $s)) { return $s } }
        foreach ($s in $sessions) { if (Is-Playing $s) { return $s } }
        $cur = $m.GetCurrentSession()
        if ($cur -and (Is-Allowed $cur.SourceAppUserModelId)) { return $cur }
        return $cur
    } catch { $script:mgr = $null; return $null }   # drop a stale manager so it re-requests next time
}

function Do-Cmd($cmd) {
    $s = Get-Target
    if (-not $s) { return }
    switch ($cmd) {
        # GO = explicit play/pause by status, NOT TryTogglePlayPause: toggle won't reliably
        # resume from a STOPPED state, so GO couldn't restart playback after a stop. Pause
        # only when actually playing; otherwise Play (resumes from paused AND stopped).
        'playpause' { if (Is-Playing $s) { Await ($s.TryPauseAsync()) $BoolType | Out-Null } else { Await ($s.TryPlayAsync()) $BoolType | Out-Null } }
        'stop'      { Await ($s.TryStopAsync())            $BoolType | Out-Null }
        'next'      { Await ($s.TrySkipNextAsync())        $BoolType | Out-Null }
        'prev'      { Await ($s.TrySkipPreviousAsync())    $BoolType | Out-Null }
    }
}

$last = ''
while ($true) {
    try {
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
