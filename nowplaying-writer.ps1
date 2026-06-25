# nowplaying-writer.ps1 — runs in the Windows INTERACTIVE session (where SMTC is visible)
# and writes the current "Artist - Title" to nowplaying.txt every ~1.5s. The WSL systemd
# service (bsnowplaying.py) reads that file, so it never needs WSL->Windows interop.
#
# Launched by the "BeoSound NowPlaying Writer" logon Scheduled Task. Blocks forever.
$ErrorActionPreference = 'SilentlyContinue'
$out = Join-Path $PSScriptRoot 'nowplaying.txt'

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$g = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($t, $ty) { ($g.MakeGenericMethod($ty).Invoke($null, @($t))).GetAwaiter().GetResult() }
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null

# Only these music players ever reach the glass. Teams (MSTeams_8wekyb3d8bbwe!MSTeams),
# browsers, video calls, etc. publish SMTC too — the whitelist keeps them off the display.
$allow = @('Spotify', 'foobar2000')
function Allowed($id) { foreach ($a in $allow) { if ($id -like "*$a*") { return $true } } return $false }

function Get-NowPlaying {
    $result = $null
    try {
        $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        if ($mgr) {
            $playing = $null
            foreach ($s in $mgr.GetSessions()) {                       # prefer a whitelisted player that is Playing
                if ((Allowed $s.SourceAppUserModelId) -and $s.GetPlaybackInfo().PlaybackStatus -eq 4) { $playing = $s; break }
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

while ($true) {
    $np = Get-NowPlaying
    try { [System.IO.File]::WriteAllText($out, [string]$np, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    Start-Sleep -Milliseconds 1500
}
