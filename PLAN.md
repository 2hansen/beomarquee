# BeoSound 9000 Source-Center App — Build Plan

_Last updated: 2026-06-23_

## Goal

A small middle-layer app between the OS and the **BeoPort 1671** that fully replaces the
dead Windows **BeoPlayer**. It makes any OS media player appear on the Masterlink bus as an
**N.MUSIC source**, so the BeoSound 9000:

1. plays the audio,
2. **shows the scrolling song title on its glass** (the thing BeoPlayer never did), and
3. can be driven from its own remote / front-panel keys.

## Key framing (don't lose this)

**This app is a control + metadata layer, NOT an audio pipe.**
The BeoPort injects the PC's analog line-out onto the Masterlink audio conductors in
hardware. The app never handles audio bytes. It only drives the BeoPort over USB to:

- **announce a source** so the BS9000 routes that analog audio (distribution handshake),
- **push display text** (track-text telegrams), and
- **receive the BS9000's remote keys** (inbound transport telegrams).

These are exactly the three "distribute" jobs: sound source · display text · remote commands.

## Architecture

```
   ANY OS media player  --audio-->  PC line-out  --3.5mm-->  BeoPort audio-in
   (VLC / Spotify / mpd)                                          |
        |  metadata + transport (MPRIS on Linux / SMTC on Win)    |
        v                                                         |
 +----------------------------  THE APP  ----------------------+  |
 |  Player Bridge       Source-Center         Remote Relay     |  |
 |  read now-playing,   announce N.MUSIC,     BS9000 keys ->    |  |
 |  send transport      answer 0x6c req,      drive player      |  |
 |       |              keepalive    |             ^           |  |
 |       +---------------+-----------+-------------+           |  |
 |                ML Telegram Codec                            |  |
 |     build/parse . checksum = sum(bytes) mod 256 . src IDs   |  |
 |                       |                                     |  |
 |                USB Transport (libusb)                       |  |
 |   EP0x01 OUT / EP0x81 IN . 60..61 framing . reassembly      |  |
 |   . init-handshake replay                                   |  |
 +-----------------------+--------------------------------------+  |
                        | USB                                     |
                  +-----v------+                                  |
                  | BeoPort1671|<---------------------------------+
                  +-----+------+
                        | Masterlink (audio + telegrams)
                  +-----v------+
                  | BeoSound9000|  glass: "Artist - Title" (scrolling)
                  +-------------+
```

## Internal modules

### 1. USB Transport
- Claim the BeoPort via libusb/pyusb. Interrupt OUT on EP `0x01`, IN on EP `0x81`.
- Frame codec: `60 <len> e0 <telegram> 61` (len = bytes after the 3-byte header;
  `e0` = "TX this telegram", `00` = received telegram, other bytes = BeoPort control opcodes).
- Reassemble fragmented IN frames.
- Replay the captured **init opcode sequence** that flips the BeoPort into forwarding mode:
  `f1 / 802900 / 29 / f600828083 / e701 / 26 / [TX ping c0 + c1] / e700 / e314000000 /
  e501000000 / eaff / ea81 / e501000000`.
- _Status: mostly proven. `bsend.py` already TXes; EP0x81 listener works._

### 2. ML Telegram Codec
- Build/parse Masterlink telegrams.
- **Checksum = 8-bit sum of telegram bytes mod 256** (verified: our captured 0x06 telegram
  sums to 0xA5). Covers byte[0] through the last text byte; excludes USB framing and the
  checksum byte itself.
- Telegram types used: `0x06`/TRACK_TEXT_8, `0x87` STATUS_INFO, `0x82` TRACK_INFO_LONG,
  `0x6c` DISTRIBUTION_REQUEST/RESPONSE, `0x0d` BEO4_KEY.
- Source IDs: `0x7a` = N.MUSIC.

### 3. Source-Center state machine
- On startup: announce N.MUSIC source.
- When the BS9000 sends `0x6c` DISTRIBUTION_REQUEST (user selects N.MUSIC), fire the
  captured **response burst** (distribution response + STATUS_INFO + source-display).
- Keepalive so the source stays "live." This is what makes the BS9000 route the 3.5mm audio.

### 4. Player Bridge (pluggable backend)
- Interface: `now_playing()`, `on_change()`, `play() / pause() / next() / prev() / stop()`.
- Backends: **MPRIS** (D-Bus, Linux) and **SMTC** (`winsdk`, Windows).
- On metadata change -> format "Artist - Title" -> display feeder -> emit `TRACK_TEXT_8`
  frames in a **shift-loop** for scroll (the LinkPlayer-proven method; BS9000 can't scroll
  `_LONG` natively).

### 5. Remote Relay
- Parse inbound BS9000 transport telegrams: `c2 c1 01 0a 7a 00 00 0d 02 01 7a <KEY>`
  (0x34 = Go/Play, step family 0x36/0x75) -> call the player backend's transport methods.

## Track-text telegram reference (the unlocked piece)

USB-framed: `60 1E E0 <telegram> 00 61`

```
TRACK_TEXT_8 : 83 c2 01 2C 00 7a 00 06 11 00 03 01 01 00 00 <tx> <cs>
TRACK_TEXT_12: 83 c2 01 2C 00 7a 00 06 11 00 03 02 01 00 00 <tx> <cs>
                                          ^^ 01 = 8-char display, 02 = 12-char display
   <tx> = song ASCII (replicate captured 12-byte field; pad spaces / truncate)
   <cs> = sum(telegram bytes) mod 256
```

- BeoPlayer already sends the `_8` form every track change but fills `<tx>` with the source
  label "N.MUSIC". The BS9000 renders this telegram fine -> we just swap `<tx>` and fix `<cs>`.
- Earlier "BO ROCKS" test failed only because we kept the stale `a5` checksum after changing
  the text; the BS9000 silently drops bad-checksum telegrams (the MLGW sniffer doesn't
  validate, which is why it looked like it went through).
- **Scroll = source-faked**: send successive frames, each shifted one character.
  Confirmed by Phil London (LinkPlayer) and by Bo having seen LinkPlayer scroll text on this
  exact BS9000.

## Where it runs

| Option | Pros | Cons |
|---|---|---|
| **A. Native Windows** (current hifi PC) | BeoPort already there; audio + SMTC + USB in one process; fastest to validate | Needs Zadig/WinUSB (disables BeoPlayer driver — fine, we're replacing it); ties to a Windows box |
| **B. WSL2** | pyusb already proven via usbipd | SMTC lives in Windows -> awkward cross-boundary metadata bridge. Avoid. |
| **C. Pi appliance** (clean end state) | Self-contained: Pi runs mpd/mpv (MPRIS), audio out -> BeoPort, USB -> BeoPort; no Windows; "boring universal tool" | New hardware to set up; do after the protocol's proven |

**Recommendation:** prototype on **A** (fastest validation — BeoPort already attached, all RE
done there). Build the Player Bridge as a pluggable interface from day one so the **Pi
appliance (C)** is a backend swap later, not a rewrite.

## Build phases (each ends in something visible)

- **P1 · Track-text MVP** _(immediate next experiment)_ — send `TRACK_TEXT_8` with a custom
  string + correct checksum during a live session -> glass shows custom text instead of
  "N.MUSIC". Proves the whole premise. _Just patch `send_test.py` to compute the checksum._
- **P2 · Source center** — replay init + answer `0x6c` -> BS9000 selects N.MUSIC and plays
  the 3.5mm audio with **no BeoPlayer running**. BeoPlayer retired.
- **P3 · Live display** — wire the Player Bridge (SMTC) so the real now-playing title scrolls
  on every track change.
- **P4 · Remote relay** — BS9000 Play/Next/Prev keys drive the OS player.
- **P5 · Daemonize** — keepalive, USB-reconnect, run as a service, config (source name,
  scroll speed, text format). Optionally port to the Pi.

## Done vs. new

- **Done (RE behind us):** USB framing, init handshake, distribution request/response capture,
  telegram formats, checksum algorithm, inbound key format.
- **New code:** the five modules above. P1 is a tiny patch.

## Tech stack

- Python (pyusb + libusb already working).
- Linux metadata/transport: D-Bus MPRIS (`dbus-next` / `playerctl`).
- Windows metadata/transport: `winsdk` (GlobalSystemMediaTransportControlsSessionManager).

## Resume pointer

Start at **P1**: patch `send_test.py` to compute `<cs> = sum(telegram bytes) mod 256` instead
of copying `a5` verbatim, send a custom `TRACK_TEXT_8` during a live BeoPlayer session, and
watch the glass. See also `PROTOCOL.md`, `notes.txt`, `MlgwProto0240.pdf` in this folder.
