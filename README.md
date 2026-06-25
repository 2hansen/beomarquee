# beomarquee — song titles on the glass, from Linux

**beomarquee** makes a **Bang & Olufsen Beosound 9000** (MK III) display the **scrolling
song title** of whatever is playing on a PC, lets you **control playback from the BS9000's
own remote / front-panel keys**, and plays the **audio** — all without the dead Windows
*BeoPlayer* application.

It does this by driving the **BeoPort 1671** (B&O's USB↔Masterlink adapter) directly from a
small Python program, which impersonates a Masterlink **N.MUSIC source** on the bus. The
reverse-engineering that made this possible is written up in [`PROTOCOL.md`](PROTOCOL.md).

> **Status:** working and running hands-free on the hifi PC. Reboot → log in → a few seconds
> later the BS9000 scrolls the current track; the remote's transport keys drive the player.

---

## 1. How it works (the big picture)

There are **two completely separate paths** to the Beosound. Keeping them separate is the
key to understanding everything else.

```
                                   ┌──────────────────────── THE HIFI PC ────────────────────────┐
                                   │                                                              │
  ♪ AUDIO  (plain analog, no software involved)                                                  │
  Spotify / foobar2000 ──► Windows line-out 3.5mm ──► BeoPort "audio in" ─┐                       │
                                                                          │                       │
  🖥  CONTROL + DISPLAY  (this project)                                    │                       │
                                                                          ▼                       │
  Windows side (interactive session)            WSL2 (Ubuntu, systemd)    BeoPort 1671 (USB)      │
  ┌─────────────────────────────┐               ┌────────────────────┐   ┌──────────────────┐    │
  │ nowplaying-writer.ps1        │  nowplaying   │                    │   │                  │    │
  │  reads SMTC "now playing" ───┼──.txt (file)─►│  bsnowplaying.py   │──►│ usbipd-attached  │    │
  │  (Spotify / foobar2000 only) │               │  • N.MUSIC source  │   │ to WSL, driven   │    │
  │                              │               │    center          │   │ over USB by pyusb│────┼─► Masterlink bus ─► BS9000 glass
  │ player-control.ps1           │◄─command.txt──│  • scrolls track   │◄──│                  │    │       (scrolls title)
  │  injects media keys ◄────────┼──(file)       │  • decodes remote  │   └──────────────────┘    │
  │  (play/pause/next/prev/stop) │               │    key presses     │            ▲               │
  └─────────────────────────────┘               └────────────────────┘            │               │
                                                                          BS9000 remote / front keys│
                                                                                                    │
                                   └────────────────────────────────────────────────────────────────┘
```

* **Audio** is a normal analog cable: a Windows media player → 3.5 mm line-out → BeoPort →
  Masterlink. No software in this repo touches the audio. (Whatever Windows sends to that
  output device reaches the Beosound — so set the player's output to the BeoPort feed.)
* **Display + control** is the software. The BeoPort is detached from Windows and
  **attached into WSL** with [usbipd-win](https://github.com/dorssel/usbipd-win); a Python
  program in WSL speaks the BeoPort's USB protocol, announces itself as the **N.MUSIC**
  source, and paints the glass.

### Why the two little "file bridges"?

The Python display program runs as a **WSL systemd service**, which has **no bridge back into
Windows** (no `WSL_INTEROP`), so it cannot read Windows "now playing" or press media keys
directly. Two tiny PowerShell helpers run on the **Windows** side instead, and they talk to
the Python program through two plain text files in this folder:

| File | Written by | Read by | Carries |
|------|------------|---------|---------|
| `nowplaying.txt` | `nowplaying-writer.ps1` (Windows) | `bsnowplaying.py` (WSL) | the current `Artist - Title` |
| `command.txt`    | `bsnowplaying.py` (WSL)          | `player-control.ps1` (Windows) | a transport command on a key press |

---

## 2. What each file does

### Live runtime — WSL2 side (Ubuntu)

| File | What it does | Why |
|------|--------------|-----|
| **`bsnowplaying.py`** | The heart of the project. Opens the BeoPort over USB, runs the init handshake, becomes the **N.MUSIC source center**, and scrolls the current track on the BS9000 glass. Also decodes inbound **remote key** telegrams and writes them to `command.txt`. Reads the track from `nowplaying.txt`. | The Beosound only shows a song title if a *source center* feeds it one; this program is that source center, reimplemented on Linux. |
| **`nowplaying2.ps1`** | A PowerShell SMTC reader, used **only** as the interactive fallback when you run `bsnowplaying.py` by hand (it's loaded and base64-encoded at startup). The systemd service uses the `nowplaying.txt` file bridge instead. | Keeps `./run.sh` usable on a machine where the writer task isn't running. *(Live dependency — do not move it to `archive/`.)* |
| **`run.sh`** | Manual launcher for `bsnowplaying.py` (sets `PYTHONPATH`, passes flags through). | For testing/tuning by hand: `./run.sh --speed 0.15`. |
| **`install-service.sh`** | One-time installer (run with `sudo`). Installs a **udev rule** so the BeoPort is openable without root, generates the **`bsnowplaying.service`** systemd unit, enables it for boot, and starts it. | Turns the manual script into a boot-autostart service that waits for the BeoPort and self-restarts. |

### Live runtime — Windows side (interactive session)

| File | What it does | Why |
|------|--------------|-----|
| **`attach-beoport.ps1`** | Loops forever: whenever the BeoPort (`0cd4:0101`) is present but not attached to WSL, runs `usbipd attach --wsl`. That call also **boots the WSL distro if it's cold**, which starts systemd and the display service. | One task brings up the whole chain after login. (Replaces the flaky built-in `--auto-attach`.) |
| **`nowplaying-writer.ps1`** | Runs in the Windows interactive session (where Windows SMTC is visible), every ~1.5 s writes the current `Artist - Title` to `nowplaying.txt`. **Whitelisted to Spotify + foobar2000 only** so Teams/browsers/video calls never hijack the glass. | The systemd service can't read SMTC itself; this is the "now playing" half of the file bridge. |
| **`player-control.ps1`** | Runs in the Windows interactive session, watches `command.txt`, and injects the matching **global media key** (play/pause, stop, next, prev). | The systemd service can't press keys; this is the "remote control" half of the file bridge. Spotify/foobar2000 obey system media keys. |
| **`run-hidden.vbs`** | A `wscript` shim that launches a PowerShell script with a **genuinely hidden** window, then waits. Used by all three scheduled tasks. | Windows 11 **ignores `-WindowStyle Hidden`** when Windows Terminal is the default console host — this shim is the reliable fix for "terminal windows pop open on every reboot". |

### Setup / registration (run once, or to update)

| File | What it does |
|------|--------------|
| **`register-beoport-task.ps1`** | Creates the **`BeoPort Auto-Attach`** logon scheduled task. |
| **`register-nowplaying-writer.ps1`** | Creates the **`BeoSound NowPlaying Writer`** logon scheduled task. |
| **`register-player-control.ps1`** | Creates the **`BeoSound Player Control`** logon scheduled task. |
| **`register-hidden-tasks.ps1`** | **Re-points all three tasks** to launch via `run-hidden.vbs` (windowless). ⚠️ The three `register-*` scripts above still create the tasks with a *visible* PowerShell action — so **always run `register-hidden-tasks.ps1` last**, and re-run it any time you re-register a task. |

### Runtime data (auto-generated — leave them, don't edit)

| File | Contents |
|------|----------|
| `nowplaying.txt` | Current `Artist - Title` (refreshed ~1.5 s). |
| `command.txt`    | Last transport command + a sequence number. |

### Reference & docs

| File | Contents |
|------|----------|
| [`PROTOCOL.md`](PROTOCOL.md) | The reverse-engineered BeoPort USB ↔ Masterlink protocol (framing, init handshake, telegrams, checksum, key codes). |
| [`RE-capture-recipe.md`](RE-capture-recipe.md) | How the protocol captures were taken (USBPcap), if you ever need to re-capture. |
| [`TROUBLESHOOTING.txt`](TROUBLESHOOTING.txt) | The 2-minute "nothing lit up" checklist. |
| B&O MLGW protocol spec | Official source-ID / checksum-convention reference. Not redistributed here — download from [mlgw.bang-olufsen.dk](https://mlgw.bang-olufsen.dk/). |
| `bsdisplay.py` | Standalone utility to push **arbitrary** text to the glass — handy for testing. |
| `driver-backup/` | _(local only — gitignored)_ Exported proprietary B&O Windows BeoPort driver; only for reverting to BeoPlayer. Not redistributed. |
| `archive/` | _(local only — gitignored)_ One-time reverse-engineering scaffolding and the parked dual-source experiment. Not part of the live setup. |

---

## 3. Boot / startup order

When the hifi PC reboots and you log in:

```
1.  Windows logon
       │   three logon scheduled tasks fire, each via run-hidden.vbs (no visible window):
       ├─► BeoPort Auto-Attach        → attach-beoport.ps1
       ├─► BeoSound NowPlaying Writer → nowplaying-writer.ps1   (starts writing nowplaying.txt)
       └─► BeoSound Player Control    → player-control.ps1      (starts watching command.txt)
2.  attach-beoport.ps1 runs `usbipd attach --wsl`
       │   → attaches the BeoPort into WSL
       │   → boots the Ubuntu WSL distro if it was cold
3.  WSL systemd starts bsnowplaying.service
       │   (Restart=always: retries every 5 s until the BeoPort is present)
4.  bsnowplaying.py opens the BeoPort, runs the init handshake,
    and arms itself as the N.MUSIC source center
5.  On the Beosound, select N.MUSIC  (re-arm catches it whenever you select it)
       └─► the glass scrolls the current track; remote keys drive the player
```

**Manual start (no reboot), for testing:** make sure the BeoPort is attached to WSL, then
`./run.sh` in this folder, and select N.MUSIC on the Beosound.

---

## 4. Installing from scratch on a new machine

**Prerequisites (Windows):**
1. Install [usbipd-win](https://github.com/dorssel/usbipd-win).
2. Share the BeoPort once (persists across reboots): `usbipd bind --busid <X-Y>`
   (find it with `usbipd list`; the BeoPort is VID:PID `0cd4:0101`).
3. Close / uninstall the old **BeoPlayer** — it holds the device and blocks the attach.

**WSL (Ubuntu, systemd enabled):**
4. `sudo apt install libusb-1.0-0 usbutils`
5. `pip install --user --break-system-packages pyusb libusb-package`
6. From this folder: `sudo ./install-service.sh`

**Windows scheduled tasks (in this order):**
7. `powershell -ExecutionPolicy Bypass -File .\register-beoport-task.ps1`
8. `powershell -ExecutionPolicy Bypass -File .\register-nowplaying-writer.ps1`
9. `powershell -ExecutionPolicy Bypass -File .\register-player-control.ps1`
10. `powershell -ExecutionPolicy Bypass -File .\register-hidden-tasks.ps1`  ← **must be last**

Then reboot, log in, and select N.MUSIC on the Beosound.

> **Paths:** the scripts assume this folder lives under OneDrive on the hifi PC and that WSL
> sees it at `/mnt/c/...`. The systemd unit resolves the user/paths at install time, so the
> Windows username doesn't matter, but the folder must be reachable from both Windows and WSL.

---

## 5. Day-to-day operations

```bash
# WSL — service control & logs
sudo systemctl restart bsnowplaying          # reload after editing bsnowplaying.py
journalctl -u bsnowplaying -f                 # live log:  ♪ track / ↻ re-armed / ⏯ key

# Windows — task state (PowerShell)
Get-ScheduledTask 'BeoPort Auto-Attach','BeoSound NowPlaying Writer','BeoSound Player Control' |
    Select TaskName, State
```

Tunables on `bsnowplaying.py` (and `run.sh`): `--speed <sec/frame>` (scroll speed, default 0.2),
`--idle "<text>"` (shown when nothing is playing, default `BEOSOUND 9000`).
Add players to the display whitelist by editing `$allow` in `nowplaying-writer.ps1`.

---

## 6. Troubleshooting

Start with [`TROUBLESHOOTING.txt`](TROUBLESHOOTING.txt). The usual order:

1. **Is the BeoPort attached to WSL?**  `usbipd list` → state should be **Attached**.
2. **Is the service up and what does it see?**  `journalctl -u bsnowplaying -n 30 --no-pager`.
3. **Glass blank but music playing?** Usually nothing is *actually* playing (audio is analog,
   so silence = blank), or the source center wasn't armed — **re-select N.MUSIC** on the Beosound.
4. **Wrong app on the glass / Teams hijacking it?** Check the `$allow` whitelist in `nowplaying-writer.ps1`.
5. **Terminal windows pop open on reboot?** A task got re-registered the plain way — re-run
   `register-hidden-tasks.ps1`.
6. **Remote keys don't control playback?** The injected media keys aren't reaching the player;
   fallback options (SendKeys / AppCommand) are noted in the design history.

---

## License & disclaimer

This project is released under the [MIT License](LICENSE).

It is an independent, community reverse-engineering effort and is **not affiliated with,
authorized, or endorsed by Bang & Olufsen**. *Beosound*, *BeoPort*, *BeoPlayer*, *Beo4*,
*Masterlink*, and related names are trademarks of Bang & Olufsen, used here only to describe
interoperability. The protocol details were reverse-engineered from observation of traffic
between hardware the author owns, for the purpose of interoperating with that hardware.

No Bang & Olufsen software, firmware, drivers, or copyrighted documents are redistributed in
this repository. Use at your own risk — driving USB hardware with an unofficial implementation
can misbehave; you are responsible for your own equipment.
