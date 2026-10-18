# nowplaying-writer.ps1 — runs in the Windows INTERACTIVE session (where SMTC is visible)
# and writes the current "Artist - Title" to nowplaying.txt every ~1.5s. The WSL systemd
# service (bsnowplaying.py) reads that file, so it never needs WSL->Windows interop.
#
# Launched by the "BeoSound NowPlaying Writer" logon Scheduled Task. Blocks forever.
#
# -ShowWindowTitle : when set, the glass falls back to the active window title whenever no
#                    whitelisted music is playing (see Get-Foreground). OFF by default — pass
#                    the switch (or re-register the task with it) to enable the ambient display.
param([switch]$ShowWindowTitle)
$ErrorActionPreference = 'SilentlyContinue'
# $out = Join-Path $PSScriptRoot 'nowplaying.txt'
$out = "C:\BeoSound\nowplaying.txt"

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$g = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($t, $ty) { ($g.MakeGenericMethod($ty).Invoke($null, @($t))).GetAwaiter().GetResult() }
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null

# Only these music players reach the glass via SMTC. Teams (MSTeams_8wekyb3d8bbwe!MSTeams),
# browsers, video calls, etc. publish SMTC too — the whitelist keeps that media junk off the
# display. When NONE of them is playing AND -ShowWindowTitle was passed, the glass falls back
# to the active window title (Get-Foreground below) — so SMTC music always wins over it.
$allow = @('Spotify', 'foobar2000', 'iTunes', 'PowerShell', 'WindowsTerminal', 'spotatui')
function Allowed($id) { foreach ($a in $allow) { if ($id -like "*$a*") { return $true } } return $false }

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

function Get-ITunesTrack {   # "Artist - Title" while iTunes is PLAYING (PlayerState 1), else $null
    Use-ITunes {
        param($it)
        if ($it.PlayerState -ne 1) { return $null }
        $t = $it.CurrentTrack
        try { if ($t.Artist) { "$($t.Artist) - $($t.Name)" } else { "$($t.Name)" } }
        finally { if ($t) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($t) } }
    }
}

function Get-NowPlaying {
    $result = $null
    try {
        $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        if ($mgr) {
            $playing = $null
            foreach ($s in $mgr.GetSessions()) {                       # prefer a whitelisted player that is Playing
                if ((Allowed $s.SourceAppUserModelId) -and $s.GetPlaybackInfo().PlaybackStatus -eq 4) { $playing = $s; break }
            }
            if (-not $playing) {                                       # a PLAYING iTunes beats a paused SMTC session
                $it = Get-ITunesTrack
                if ($it) { return $it }
            }
            if (-not $playing) {                                       # else the current session, but only if whitelisted
                $c = $mgr.GetCurrentSession()
                if ($c -and (Allowed $c.SourceAppUserModelId)) { $playing = $c }
            }
            if ($playing) {
                $p = Await ($playing.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                if ($p -and $p.Title) {
                    if ($p.Artist) { $result = "$($p.Artist) - $($p.Title)" } else { $result = "$($p.Title)" }
                }
            }
        }
    } catch {}
    return $result
}

# Win32 foreground-window title — the fallback shown on the glass when no whitelisted music
# is playing. Covers ANY app (Teams, Zoom, a browser meeting, an editor, …), so the glass
# isn't tied to one tool. Pipe-delimited titles keep only the meaningful first segment.
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Fg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
}
"@ | Out-Null

function Get-Foreground {
    $h = [Fg]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }
    $sb = New-Object System.Text.StringBuilder 512
    [void][Fg]::GetWindowText($h, $sb, $sb.Capacity)
    $t = $sb.ToString().Trim()
    if (-not $t) { return $null }
    if ($t -match '\s\|\s') { $t = ($t -split '\s\|\s')[0].Trim() }   # "Subj | Abakion | … | Microsoft Teams" -> "Subj"
    return $t
}

while ($true) {
    $np = Get-NowPlaying
    if (-not $np -and $ShowWindowTitle) { $np = Get-Foreground }   # SMTC music always wins; window title only if enabled
    try { [System.IO.File]::WriteAllText($out, [string]$np, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    Start-Sleep -Milliseconds 1500
}
