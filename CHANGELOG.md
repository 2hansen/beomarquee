# Changelog

All notable changes to **beomarquee** are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **The Beosound sleeps and wakes with the PC.** Put the machine to sleep and the Beosound goes
  to standby; wake it and the Beosound comes back on N.MUSIC, ready to play. Both directions are
  guarded so it only ever undoes its own work: it switches the unit off **only if the unit was
  playing this PC** — a Beosound on CD or the radio is left alone — and switches it back on
  **only if it was the one that switched it off**, so a unit you deliberately left off stays off.
  Waking selects the source without starting playback; you press play. Optional and off by
  default: it needs Home Assistant with the Masterlink Gateway integration (copy `ha.env.example`
  to `ha.env`, then run `register-power-watch.ps1`).
- **iTunes for Windows on the glass and the remote.** Classic iTunes doesn't report to the
  Windows media controls, so it is now read and driven through its own COM scripting interface:
  the glass shows the iTunes track while it plays, and the Beo4 transport keys drive whichever
  player — iTunes or an SMTC player like Spotify — most recently started playing. Only used
  while iTunes is already running (it is never launched by the scripts).

### Fixed
- **A wake with WSL not running no longer restarts the whole WSL environment for nothing.**
  If WSL is not running when the machine wakes, there is no USB link to repair — the targeted
  teardown now reports that as "nothing to do" instead of as a failure, so the fallback full
  `wsl --shutdown` is skipped. It still runs whenever the teardown genuinely cannot act.

### Changed
- **Resume recovery logs why it did what it did.** The teardown step's own messages are now
  written to `resume-rebuild.log` alongside its exit code.

### Fixed
- **Worked around, then dropped, a WSL kernel regression that had blocked every USB attach.**
  Starting with WSL kernel `6.18.40.1` (first seen 2026-09-11), usbipd-win's internal
  `mount -t drvfs` call (against `C:\Program Files\usbipd-win\WSL`) failed with `mount() failed:
  Operation not supported`, so every `usbipd attach` errored with "Mounting ... within WSL
  failed" — the BeoPort never showed up in WSL at all, independent of the app, the device, or any
  prior sleep/wedge issue. Root cause was a WSL-side drvfs regression, tracked upstream at
  microsoft/WSL#41475, fixed in microsoft/WSL#41487. Workaround at the time:
  `install-usbipd-mount-workaround.sh`, installing a systemd unit that bind-mounted the same
  folder into place at boot so usbipd's own broken mount step was skipped. **2026-09-11, same
  day: upgraded to WSL 2.9.11 (preview) and confirmed the native `usbipd attach` now succeeds
  on its own — the workaround service was disabled, its unit file removed, and
  `install-usbipd-mount-workaround.sh` deleted from the repo.** See
  `TROUBLESHOOTING.txt` for history; keep an eye out in case a future WSL update regresses this
  differently.

## [1.1.2] — 2026-08-04

### Added
- **Full accented-character support on the glass.** Danish `Æ Ø Å`, the umlaut/diaeresis vowels
  `Ä Ë Ï Ö Ü`, `Œ`, `ß` and `Ñ` now show as their real letters instead of `?`. The Beosound's
  display has a custom character ROM — its glyphs sit at non-standard byte positions, so the
  correct bytes are now sent per character. Characters with no ROM glyph degrade gracefully —
  accents stripped to the base letter (`café→CAFE`), typographic dashes/quotes normalised, and
  anything still unmappable (emoji, CJK, odd symbols) shown as a blank rather than a stray `?`
  (a `?` you actually typed still shows). New `--enc`, `--rawhex` and `--sweep` options are
  included for probing a display's character ROM.
- **Survives sleep/suspend.** A Windows resume-from-sleep task now rebuilds the BeoPort
  link automatically whenever the machine wakes. Sleeping the machine severs the
  USB-over-IP link between Windows and WSL mid-transfer, which used to deadlock the reader
  and leave the glass dark until a manual restart. The link is now torn down and rebuilt on
  every wake, with no intervention.

### Changed
- **Resume recovery is surgical — it no longer restarts the whole WSL environment.** When
  it rebuilds the link after sleep it tears down just the USB port from inside WSL (a root
  `vhci` sysfs detach) instead of shutting down the entire WSL VM, so anything else running
  in that WSL keeps running. It falls back to the full `wsl --shutdown` only if the targeted
  teardown fails, so recovery is no less reliable than before.
- **Remote transport mirrors the keyboard media keys exactly.** Dropped the player
  whitelist and the custom session-preference ladder from the remote relay; it now drives
  the session Windows considers current — the same session the OS routes a keyboard
  play/pause key to. Standard OS behavior instead of a hardcoded gate. (The now-playing
  *glass* keeps its whitelist — that's a custom display choice with no OS equivalent to
  defer to.)
- **True single-character scroll.** The marquee now advances exactly one character per
  display refresh instead of appearing to hop two — the glass only latches on a complete
  frame pair, so the text steps once per pair. Tracks clear fully and scroll in from the
  right, at a factory-like cadence. Default scroll speed is now 0.5 s/frame.

### Fixed
- **GO reliably resumes playback.** The player's media-status field can report "playing"
  for a few seconds after a real pause, so the old status-based GO always took the pause
  branch and could never resume. GO now toggles the player's actual play/pause state; STOP
  pauses (keeping the track loaded) rather than a hard stop that unloads the media so
  nothing can resume it.
- **A hung usbipd can't freeze the auto-attach loop.** Every `usbipd` call is wrapped in a
  hard timeout — a call that hangs (seen right after a wake while Windows is still settling)
  is killed and retried on the next tick instead of stalling the whole attach loop. Attach
  activity is logged to a self-trimming file.

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

[1.1.2]: https://github.com/2hansen/beomarquee/releases/tag/v1.1.2
[1.1.0]: https://github.com/2hansen/beomarquee/releases/tag/v1.1.0
[1.0.0]: https://github.com/2hansen/beomarquee/releases/tag/v1.0.0
