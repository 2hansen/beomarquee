# Changelog

All notable changes to **beomarquee** are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-06-27

### Added
- **Self-healing USB attach.** The BeoPort auto-attach loop now runs `usbipd bind`
  automatically when it sees the device is `Not shared`. The usbipd bind is supposed to
  be persistent but does not always survive a reboot or a change of USB port (the device
  can also move to a new bus id) — when that happens the source would silently fail to
  come up. It now re-binds and re-attaches itself, with no manual intervention.

### Changed
- **Transport keys work while the screen is locked.** The remote-to-player relay now
  drives the player through the System Media Transport Controls (SMTC) session API
  (`TryTogglePlayPause` / `TrySkipNext` / `TrySkipPrevious` / `TryStop`) instead of
  injecting synthetic global media keys. Locking Windows switches the active input
  desktop to the secure desktop, which silently swallowed the synthetic key presses;
  the SMTC calls go straight to the OS media service and are unaffected by the lock —
  the same mechanism the now-playing display already relied on. The GO key resumes
  playback from both paused and stopped states (explicit play/pause by status) rather
  than a blind toggle, so it can restart the music after a stop.
- **Player whitelist for transport.** Only known music players (Spotify, foobar2000,
  MusicBee) are driven by the remote, so a stray browser or Teams media session can't
  be controlled by accident — mirroring the now-playing writer's whitelist.

### Fixed
- **Auto-attach task can re-bind unattended.** The "BeoPort Auto-Attach" scheduled task
  now runs at the elevated level required for `usbipd bind`, so the self-healing attach
  above works on its own after a reboot without an elevation prompt.
- **Privilege level no longer silently downgraded.** Re-applying the hidden-launch
  wrapper used to reset a task's run level back to the default; it now preserves it.
- **Reliable remote keypresses (root cause: bus-load starvation).** Inbound key detection
  runs in a dedicated USB reader thread that drains the input endpoint continuously, and —
  the decisive fix — the keepalive and the scrolling display now run on **independent
  timers** instead of one frame loop. The BeoPort stops forwarding inbound key telegrams to
  us when our *outbound* USB rate is too high: a fast continuous scroll (≈10 frames/sec)
  saturated the link and starved keypresses, so the remote's transport keys fired only
  intermittently. Decoupling the two timers keeps total output well under that ceiling
  (keepalive ≈1/sec, scroll ≈3/sec) while the glass still scrolls — keys are now caught
  reliably, locked or unlocked. Tunable via `--speed` and `--ka`.
- **One action per key press.** A single press emits a burst of repeated key telegrams;
  the debounce now collapses each burst to one command (it tracks the last telegram seen,
  not the last command sent), so a press skips exactly one track instead of two or three —
  which also stops the rapid-skip flood that briefly made the player stop responding.

## [1.0.0] — 2026-06-23

### Added
- Initial public release.
- Live now-playing track scrolled on the Beosound 9000 glass from Linux/WSL, over the
  BeoPort, with no Windows BeoPlayer software.
- Remote-to-player transport relay: Beosound transport keys drive the Windows player.
- Analog audio path via the BeoPort line-in.
- Optional `-ShowWindowTitle` fallback: show the active window title on the glass when
  nothing is playing.
- Hands-free autostart: logon scheduled tasks + a WSL systemd service bring the whole
  chain up after a reboot.

[1.1.0]: https://github.com/2hansen/beomarquee/releases/tag/v1.1.0
[1.0.0]: https://github.com/2hansen/beomarquee/releases/tag/v1.0.0
