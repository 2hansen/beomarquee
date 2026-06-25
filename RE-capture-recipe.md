# BeoPort 1671 — Reverse-Engineering & Capture Recipe

Goal: learn the BeoPort's **USB protocol** so a small app can replace BeoPlayer —
driving the BeoPort to (1) announce an N.MUSIC source, (2) push track-text telegrams,
(3) relay the BS9000's transport keys back to a Windows player. Audio stays on the 3.5 mm.

Device: **VID `0x0CD4` / PID `0x0101`** (B&O own VID, custom driver).

---

## The method in one sentence
**Differential capture with a verification oracle:** record the USB wire (PC→BeoPort) and
the Masterlink bus (BeoPort→BS9000, via the MLGW sniffer) *at the same time*, do one labelled
action at a time, then line up "USB bytes sent" against "ML telegram that appeared." Once the
framing is understood, **construct** new commands (e.g. track text) and **confirm** them on the
sniffer + the BS9000 display — so we never need BeoPlayer to have sent them.

Two wires, two captures:
```
  [Windows music] --USB--> [BeoPort] --Masterlink--> [BS9000]
                    ^                        ^
              USBPcap/Wireshark        MLGW "Direct MasterLink"  (the oracle)
              (input side)             (output side, decoded)
```

---

## Tools (all free)
- **Wireshark** (Windows installer — tick **USBPcap** during install). Captures USB.
- **Microsoft USBView** (or *USB Device Tree Viewer*) — read the device descriptor.
- **Home Assistant** with the `giachello/mlgw` integration, **Direct MasterLink enabled**.
- A **log** (spreadsheet/notepad) for Action → bytes.
- *Later (synthesis phase):* **Zadig** (bind WinUSB), **Python + pyusb/libusb**, **`winsdk`** (now-playing).

---

## Step 0 — Enumerate the device (10 min)
1. Device Manager → find BeoPort → **Details → Hardware IDs** → confirm `USB\VID_0CD4&PID_0101`.
2. Open **USBView/USB Tree Viewer** → select the BeoPort. Record:
   - Number of **interfaces** and **endpoints**; each endpoint's **type** (Bulk / Interrupt / Control)
     and **direction** (IN = device→PC, OUT = PC→device). We expect ~1 OUT (send) + 1 IN (receive).
   - The interface **class** (CDC? Vendor-specific 0xFF?).
3. **FTDI probe (optional, big payoff):** note the driver name. If it smells like FTDI, the chip may be
   a reprogrammed FTDI under B&O's VID — then it's just serial bytes and synthesis gets much easier.
   Send me the descriptor and I'll tell you which case we're in.

➡️ **Send me:** the full USBView text dump for the device.

---

## Step 1 — Arm the USB capture
1. Launch **Wireshark** → you'll see **USBPcapN** interfaces (one per root hub).
2. In USBView, note which **root hub** the BeoPort sits under → start capture on that USBPcap interface.
3. Reduce noise: unplug other USB devices on that hub if you can; close other USB-heavy apps.
4. Useful Wireshark display filters (apply after you see the device address):
   - `usb.device_address == N`   (N = the BeoPort's address, visible in early packets)
   - `usb.transfer_type == 0x03` (bulk)   or   `== 0x01` (interrupt)
   - `usb.capdata`               (only packets that actually carry payload bytes)

---

## Step 2 — Arm the ML oracle
**NOTE:** this integration has **no options/reconfigure screen** — "Direct MasterLink"
(`CONF_MLGW_USE_MLLOG`) is a checkbox that only appears in **initial setup**. So you must
**delete and re-add** the integration to enable it.
1. **Settings → Devices & Services** → **Master Link Gateway** card → **⋮ → Delete**.
2. **+ Add Integration** → "Master Link Gateway" → enter **Host/IP**, **username+password = the MLGW
   ADMIN account** (the backdoor needs admin-level, not a limited user), and **tick "Direct
   MasterLink."**
3. HA → **Developer Tools → Events** → *Listen to* event type **`mlgw.ML_telegram`** → **Start**.
4. Put the HA events window next to Wireshark. Both are timestamped — that's how we align them.
5. **Sanity check:** press a key on the BS9000 → you should see `mlgw.ML_telegram` events. If nothing
   appears, the credentials probably weren't admin-level (the backdoor silently won't engage).

---

## Step 3 — The capture protocol (discipline matters)
Do **one action at a time**, then **wait ~5 seconds in silence**. The silent gaps segment both
captures so each action is isolated. Speak each step into your log with a rough timestamp.

| # | Action in BeoPlayer / on the system | What we're hunting |
|---|---|---|
| A | Plug in BeoPort / launch BeoPlayer fresh | **Init / handshake** burst (replay verbatim later) |
| B | Select N.MUSIC so the BS9000 plays from the PC | **Source-announce** telegram |
| C | Press **Play** | play state |
| D | **Pause**, wait, **Play** | state toggles |
| E | **Next track** (do this 3×, different songs) | track change — and any **text** telegram |
| F | **Volume** up / down | volume cmd |
| G | **Stop** | stop state |
| H | Press **Next / Play / Stop on the BS9000 (or Beo4)** | **inbound** USB (BeoPort→PC) = transport relay |
| I | **Standby** the BS9000 | standby telegram |

Tip for E: pick songs with **very different, long titles** — makes the ASCII obvious in the bytes.

---

## Step 4 — Export & align
1. Wireshark → **File → Export Packet Dissections → As JSON** (keeps `usb.capdata` hex). Save the
   `.pcapng` too.
2. For each action's time window, pull the **OUT** payload bytes (PC→BeoPort) and **IN** payload
   bytes (BeoPort→PC).
3. From HA, copy the `mlgw.ML_telegram` entries in the same windows (decoded fields + any raw bytes).
4. Build the alignment table:

   | Action | USB OUT bytes (hex) | USB IN bytes (hex) | ML telegram(s) seen (decoded) |
   |--------|---------------------|--------------------|-------------------------------|

➡️ **Send me:** the exported JSON (or the table) + the copied HA telegram log.

---

## Step 5 — Decode (I do most of this)
- **Framing:** across all OUT packets, find the repeated header shape — sync/start byte, length,
  type, payload, optional checksum/terminator.
- **Correlate:** for action B, the sniffer shows a telegram like `dest=C1 src=C2 … payload=0x45/0x87 …`.
  Look for those signature bytes (`C1`, `C2`, `0x7A`=N.MUSIC, the payload-type) **inside** the USB OUT
  payload.
  - **Bytes appear verbatim (just wrapped)** → **transparent pipe**: we can synthesise *any* telegram,
    incl. track text. 🎉
  - **Bytes don't appear (USB payload is short/coded)** → **smart device**: we build a command
    dictionary from the mapping and are limited to what it exposes.
- **Checksum hunt:** compare two near-identical captures that differ by one value (e.g. two track
  numbers / two titles). The byte(s) that change in lockstep reveal the checksum and the payload field.
- **Inbound:** decode action H so the app knows when the BS9000 says "next/play/stop."

---

## Step 6 — Synthesise & verify (the proof)
1. **Bind WinUSB** to the BeoPort with **Zadig** (this disables BeoPlayer — that's the point), or do the
   synthesis phase on **Linux** (libusb auto-detaches). Capture stays on Windows where BeoPlayer runs.
2. Python (`pyusb`/`libusb`, or `pyserial` if FTDI-inside):
   - open device, claim interface, find OUT/IN endpoints
   - **replay the handshake** bytes from action A
   - **send the source-announce** bytes from action B → watch the **sniffer**: does the BS9000 see the
     source? Select it.
   - **construct a track-text telegram**: wrap the known `0x0B`/`0x06` ASCII payload (`dest=0xC1 src=0xC2
     type=0x0A srcsel=0x7A`) in the discovered framing → send.
   - watch the **sniffer** (telegram appears?) and the **BS9000 glass** (title shows?). Iterate
     payload-type / `info_type` / offsets / checksum until accepted.
3. Then add: read **now-playing** via Windows SMTC (`GlobalSystemMediaTransportControlsSessionManager`,
   Python `winsdk`) → push matching track text on every track change. And handle inbound transport keys.

---

## Gotchas
- **USBPcap noise** — pick the right root hub; unplug other USB.
- **Telegram chunking** — one logical telegram may span USB packets, or several telegrams batch into one.
- **Two different checksums** — ML bus parity (mark/space) is done *in the BeoPort hardware* (don't worry
  about it); but the **USB layer** may have its own checksum — that's the one to find in Step 5.
- **Driver claim** — Zadig/WinUSB or Linux/libusb needed to transmit from our own code.
- **Low risk** — malformed ML telegrams are harmless; the BS9000 just ignores or briefly shows garbage.
  You can't brick anything on the bus.

---

## Division of labour
- **You:** Steps 0–4 (enumerate, capture, export) → send me the descriptor + traces + telegram log.
- **Me:** Step 5 (decode framing + correlation) and write the Step-6 Python; you run it and we iterate
  against the sniffer.

## Reference
- ML telegram format + IDs: `giachello/mlgw` `gateway.py` (`decode_ml_to_dict`) + `const.py`.
- Open MDT software (GitLab) for ML source / track-text emit logic.
- Track text payload best-bet: **`0x0B` EXTENDED_SOURCE_INFORMATION** (ASCII from byte[24]); source
  **N.MUSIC = 0x7A**, BS9000 = AUDIO_MASTER **0xC1**, PC source center **0xC2**.
