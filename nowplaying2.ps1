# nowplaying2.ps1 — universal "Artist - Title" for the Beosound display.
# 1) SMTC: pick the session that is actually Playing (covers Spotify, browsers, most apps)
# 2) fall back to MusicBee's window title (MusicBee doesn't use SMTC)
# Prints "Artist - Title" (or nothing). Optional: prepend source tag with -Tag.
param([switch]$Tag)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$g = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($t, $ty) { ($g.MakeGenericMethod($ty).Invoke($null, @($t))).GetAwaiter().GetResult() }

$result = $null; $src = $null
try {
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
    $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    if ($mgr) {
        $sessions = $mgr.GetSessions()
        $playing = $null
        foreach ($s in $sessions) {
            $pi = $s.GetPlaybackInfo()
            if ($pi -and $pi.PlaybackStatus -eq 4) { $playing = $s; break }   # 4 = Playing
        }
        if (-not $playing) { $playing = $mgr.GetCurrentSession() }
        if ($playing) {
            $p = Await ($playing.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            if ($p -and $p.Title) {
                if ($p.Artist) { $result = "$($p.Artist) - $($p.Title)" } else { $result = "$($p.Title)" }
                $src = $playing.SourceAppUserModelId
            }
        }
    }
} catch {}

if (-not $result) {
    $t = (Get-Process MusicBee -ErrorAction SilentlyContinue | Select-Object -ExpandProperty MainWindowTitle)
    if ($t) {
        if ($t.EndsWith(' - MusicBee')) { $t = $t.Substring(0, $t.Length - 11) }
        if ($t -and $t -ne 'MusicBee') { $result = $t; $src = 'MusicBee' }
    }
}

if ($result) { if ($Tag) { "[$src] $result" } else { $result } }
