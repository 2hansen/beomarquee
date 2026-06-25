# BeoPort 1671 — USB ↔ Masterlink protocol (reverse-engineered)

Source: `startup.pcapng` (BeoPlayer launch → N.MUSIC select on BS9000 → play → keys),
de-framed with the reassembler in `parse2.py` / the inline scripts. Device VID:PID `0CD4:0101`.

## USB framing
Every USB interrupt transfer (EP 0x01 OUT, EP 0x81 IN) carries fragments of a frame:

```
60 <len> <payload[len]> 61
```
- `60` = SOF, `61` = EOF, `<len>` = number of payload bytes (NOT counting 60/len/61).
- Frames are **fragmented** across 7–9 byte INT packets on the wire — reassemble by concatenating
  the per-direction stream and cutting on `60 <len> … 61`.
- **Payload first byte = a command tag:**
  - `e0` = "transmit this ML telegram" → the rest of the payload is a raw ML telegram (+ a 2-byte
    trailer, see below). This is the OUT tag we use to inject.
  - `00` = "received ML telegram" (IN direction) → rest is the telegram the BS9000 put on the bus.
  - other bytes (`f1 80 29 f6 e7 26 e3 e5 ea …`) = **BeoPort device-control opcodes** (configure/enable
    the adapter; not ML telegrams).
- TX telegram trailer: after the ML telegram, 2 bytes before `61` (e.g. `a5 00`, `88 00`, `e5 00`).
  The first of these is a **per-telegram checksum = (sum of all telegram bytes) & 0xFF**, the second
  is `00`.
  - For the `0x06` DISPLAY_SOURCE telegram the checksum **is enforced**: a wrong/stale value is
    silently dropped by the BS9000 (this is exactly why early "send custom text" tests with the
    captured `a5` copied verbatim were ignored). You **must** recompute it — see `display_frame()`
    in `bsnowplaying.py` (`cs = sum(tele) & 0xFF`).
  - The fixed establishment frames in Seq 2 carry their own correct trailers and are replayed
    verbatim, so no recompute is needed there.

## ML telegram layout (de-framed, as MLGW shows it)
```
[0] dest   c1=AUDIO_MASTER(BS9000)  c2=SOURCE_CENTER(BeoPort/us)  83=ALL_LINK_DEVICES  c0=VIDEO_MASTER
[1] src
[2] 01
[3] type   0a=COMMAND 2c=INFO 0b=REQUEST 14=RESPONSE
[4] 00
[5] srcsel 7a=N.MUSIC  a1=N.RADIO
[6] 00
[7] payload type
[8] plen
[9+] payload
```

## Sequence 1 — INIT HANDSHAKE (replay verbatim at app startup)
USB OUT control opcodes BeoPlayer sends right after launch — this is what puts the BeoPort into
forwarding/source-center mode (without it, the adapter does NOT relay bus telegrams to USB IN —
confirmed: a cold listener saw nothing):
```
f1
80 29 00
29
f6 00 82 80 83
e7 01
26
e0|c0 29 01 0b 00 00 00 04 03 04 0a 01 00 0b 00     (TX ping → VIDEO_MASTER c0)
e0|c1 29 01 0b 00 00 00 04 03 04 0a 01 00 0c 00     (TX ping → BS9000 c1)
e7 00
e3 14 00 00 00
e5 01 00 00 00
ea ff
ea 81
e5 01 00 00 00
```
(IN during init: idle/ack frames `01 01 01 29`, `41 01 01 29`, `49 01 31 02 03`, and an RX telegram
`29 c1 01 14 00 00 00 04 03 04 01 01 01`.)

## Sequence 2 — answer the BS9000's request (the key handshake)
When the user selects N.MUSIC on the BS9000, it sends INBOUND:
```
RX: c2 c1 01 0b 7a 00 00 6c 0a 01 00 00 00 00 02 02 01 00 02 00   = DISTRIBUTION_REQUEST (payload 0x6c)
```
BeoPlayer replies with this burst (our app must reproduce it):
```
ctrl ea 80
ctrl ea 81
ctrl e5 01 01 00 00
TX  c1 c2 01 14 00 7a 00 6c 01 08 01 88 00              DISTRIBUTION RESPONSE (type RESPONSE, payload 6c, status 08)
TX  83 c2 01 14 00 7a 00 87 1f 04 7a 01 00 00 1f be 01 00 00 00 ff 02 01 00 03 01 01 01 03 00 02 00 00 00 00 01 00 00 00 00 00 e5 00   STATUS_INFO (payload 0x87)
TX  c1 c2 01 14 00 00 00 82 0a 01 06 7a 00 02 00 00 00 00 00 01 a8 00          TRACK_INFO_LONG (payload 0x82)
TX  83 c2 01 2c 00 7a 00 06 11 00 03 01 01 00 00 <12 ASCII> a5 00              DISPLAY_SOURCE "N.MUSIC" (counter 01)
TX  83 c2 01 2c 00 7a 00 06 11 00 03 02 01 00 00 <12 ASCII> a6 00              DISPLAY_SOURCE "N.MUSIC" (counter 02)
TX  6x  83 c2 01 2c 00 7a 00 0b <plen> 00 <field#16> 00 01 01 7a 02 00 00 00 01 00 04 00 03 <ASCII>   EXTENDED_SOURCE_INFORMATION
        field1=genre  field2  field3=artist  field4=title  field5=album  field6
```

## Sequence 3 — inbound transport keys (BS9000 → us, EP 0x81), for player control
```
c2 c1 01 0a 7a 00 00 0d 02 01 7a <KEY>     COMMAND/BEO4_KEY for N.MUSIC
c2 c1 01 0a 7a 00 00 14 00 04              (status-ish)
c2 c1 01 0a 7a 00 00 11 00 02
c2 c1 01 0a a1 00 00 11 00 02              (a1 = N.RADIO source)
```
A key press is a COMMAND telegram (`tg[3]==0x0a`) with payload type `0x0d` (BEO4_KEY); the key
code is the **last byte**. Verified key codes on this BS9000 (see `KEYMAP` in `bsnowplaying.py`):

| Key (Beo4 / front panel) | Code   | Mapped to  |
|--------------------------|--------|------------|
| GO                       | `0x35` | play/pause |
| STOP                     | `0x36` | stop       |
| STEP UP (∧)              | `0x1e` | next       |
| STEP DOWN (V)            | `0x1f` | prev       |
| WIND (`>>`)              | `0x34` | next       |
| REWIND (`<<`)            | `0x32` | prev       |

(Two ways to skip, by design.) The app debounces telegram repeats (~0.4 s) and writes
`"<seq> <command>"` to `command.txt`; `player-control.ps1` injects the matching global media key.

## Sequence 4 — track text & scrolling on the glass (SOLVED)
The MK III glass **does** render arbitrary text — but not by accepting `0x0b`
EXTENDED_SOURCE_INFORMATION, and not via late `0x06` updates with arbitrary counter values. The
real mechanism is the `0x06` DISPLAY_SOURCE telegram plus a **timing/latch** trick:

- The glass latches its displayed string from the DISPLAY_SOURCE telegram at the **moment of source
  establishment** (right after it sends the `6c` DISTRIBUTION_REQUEST). BeoPlayer just happens to put
  the source label `"N.MUSIC"` in that text field — which is why the stock glass only ever shows
  `N.MUSIC`. Put the song there instead and the glass shows the song.
- **Mid-session repaint (this is the scroll engine):** re-send the DISPLAY_SOURCE **pair** —
  counter `01` then counter `02` — interleaved with a STATUS_INFO keepalive, and the glass repaints
  **without** re-selecting the source. Sending a single `0x06` with an arbitrary counter does *not*
  repaint; the alternating `01`/`02` pair is what the glass accepts as a live update.
- **Marquee:** the display field is 12 chars and the BS9000 has no native scroll, so scrolling is
  source-faked — shift a 12-char window across `text + "   "` one char per frame, alternating the
  counter byte `01`/`02` each frame, ~0.2 s/frame, with STATUS_INFO fired ~40 ms before each frame.

DISPLAY_SOURCE telegram (the one whose text field we own):
```
83 c2 01 2c 00 7a 00 06 11 00 03 <cc> 01 00 00 <12 ASCII>   cc = 01 / 02 (alternating)
                                                            trailer = <sum&0xFF> 00
```
Reference implementation: `display_frame()` + the main loop in `bsnowplaying.py`.

## What this unlocks
- ✅ **Source-center app**: replay Seq 1, listen for the `6c` request, fire Seq 2, keep alive →
  the BS9000 accepts us as the N.MUSIC source and routes the 3.5 mm audio. Fully replaces BeoPlayer
  **on Linux**.
- ✅ **Track text + scrolling on the glass** via Seq 4 — arbitrary text, live marquee, no Windows /
  BeoPlayer. (Earlier notes that the MK III "can't render artist/title" were wrong; they were sending
  the *source label* in `0x06`, or `0x0b` which the glass ignores, or `0x06` with a stale checksum.)
- ✅ **Player control** from the BS9000's own keys via Seq 3.
