# player-control.ps1 — runs in the Windows interactive session. Watches command.txt
# (written by the WSL bsnowplaying service when a BS9000 transport key is pressed) and
# injects the matching global media key, which Spotify / MusicBee / most players obey.
# Launched by the "BeoSound Player Control" logon Scheduled Task. Blocks forever.
$ErrorActionPreference = 'SilentlyContinue'
$cmdFile = Join-Path $PSScriptRoot 'command.txt'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MediaKey {
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    public static void Tap(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);          // key down
        keybd_event(vk, 0, 2, UIntPtr.Zero);          // key up (KEYEVENTF_KEYUP = 2)
    }
}
"@
$VK = @{ playpause = 0xB3; stop = 0xB2; next = 0xB0; prev = 0xB1 }   # VK_MEDIA_* codes

$last = ''
while ($true) {
    try {
        if (Test-Path $cmdFile) {
            $line = (Get-Content -LiteralPath $cmdFile -Raw).Trim()
            if ($line -and $line -ne $last) {
                $last = $line
                $cmd = ($line -split '\s+')[-1]        # "<seq> <command>" -> command
                if ($VK.ContainsKey($cmd)) { [MediaKey]::Tap([byte]$VK[$cmd]) }
            }
        }
    } catch {}
    Start-Sleep -Milliseconds 150
}
