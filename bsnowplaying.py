#!/usr/bin/env python3
"""
bsnowplaying — show MusicBee's current track on the Beosound 9000 glass, auto-updating.

Architecture:
  MusicBee (Windows) plays audio -> line-out -> BeoPort 3.5mm  (audio path, unchanged)
  This app (WSL) becomes the N.MUSIC source-center over USB and scrolls the track text.
  Now-playing comes from MusicBee's WINDOW TITLE ("Artist - Title - MusicBee"), read
  via powershell.exe (MusicBee doesn't publish to Windows SMTC).

Run (hifi box, BeoPort attached to WSL, dev node writable, MusicBee running):
  PYTHONPATH=~/.local/lib/python3.14/site-packages python3 bsnowplaying.py
Then select N.MUSIC on the Beosound (within 20s) if it isn't already active. Ctrl-C to stop.

Options:
  --speed 0.2   seconds per scroll frame (default 0.2)
  --idle "BO HIFI"   text shown when MusicBee is paused/stopped/closed
"""
import sys, os, time, threading, subprocess, base64
import usb.core, usb.util

HERE = os.path.dirname(os.path.abspath(__file__))
NOWPLAYING_PS1 = os.path.join(HERE, "nowplaying2.ps1")
NOWPLAYING_TXT = os.path.join(HERE, "nowplaying.txt")  # written by nowplaying-writer.ps1 (Windows interactive session)
NP_STALE_SEC = 10                                      # ignore the file if the writer stopped refreshing it
COMMAND_TXT = os.path.join(HERE, "command.txt")        # WE write here on a BS9000 key; player-control.ps1 injects the media key
# BS9000 / Beo4 transport key codes -> player command (verified on this BS9000 2026-06-24)
KEYMAP = {
    0x35: "playpause",   # GO
    0x36: "stop",        # STOP
    0x1e: "next",        # STEP UP (∧)
    0x1f: "prev",        # STEP DOWN (V)
    0x34: "next",        # WIND  >>  -> next track
    0x32: "prev",        # REWIND << -> prev track
}
# encode the PS script as -EncodedCommand (UTF-16LE base64) — avoids all path/space/quoting issues
with open(NOWPLAYING_PS1, encoding="utf-8") as _f:
    NOWPLAYING_ENC = base64.b64encode(_f.read().encode("utf-16-le")).decode()

VID, PID = 0x0CD4, 0x0101
EP_OUT, EP_IN = 0x01, 0x81

INIT_FRAMES = [
    "6001f161", "600380290061", "60012961", "6005f60082808361", "6002e70161", "60012661",
    "6010e0c029010b0000000403040a01000b0061", "6010e0c129010b0000000403040a01000c0061",
    "6002e70061", "6005e31400000061", "6005e50100000061", "6002eaff61", "6002ea8161", "6005e50100000061",
]
RESPONSE_PREFIX = [
    "6002ea8061", "6002ea8161", "6005e50101000061",
    "600ee0c1c20114007a006c010801880061",
    "602ce083c20114007a00871f047a0100001fbe01000000ff0201000301010103000200000000010000000000e50061",
    "6017e0c1c20114000000820a01067a0002000000000001a80061",
]
STATUS_FRAME = bytes.fromhex("602ce083c20114007a00871f047a0100001fbe01000000ff0201000301010103000200000000010000000000e50061")

def display_frame(text, cc=0x01):
    tele = bytes.fromhex("83c2012c007a000611000300")[:11] + bytes([cc, 0x01, 0x00, 0x00])
    t = text.encode("ascii", "replace")[:12]; t = t + b" " * (12 - len(t))
    tele = tele + t
    cs = sum(tele) & 0xFF
    payload = b"\xe0" + tele + bytes([cs, 0x00])
    return bytes([0x60, len(payload)]) + payload + b"\x61"

# ---- now-playing ----
# Primary source = nowplaying.txt, refreshed every ~1.5s by nowplaying-writer.ps1 running
# in the Windows INTERACTIVE session (where SMTC is visible). This is the reliable path for
# the systemd service, which has no WSL->Windows interop. Fallback = call powershell directly,
# which only works when bsnowplaying is run from an interactive WSL shell (manual ./run.sh).
def _read_file_track():
    # returns (text_or_None, fresh): fresh=True means the writer is current -> authoritative,
    # so an empty file genuinely means "nothing playing" (don't fall back to powershell).
    try:
        if time.time() - os.path.getmtime(NOWPLAYING_TXT) > NP_STALE_SEC:
            return (None, False)                       # writer stopped / stale
        with open(NOWPLAYING_TXT, encoding="utf-8") as f:
            return (f.read().strip() or None, True)
    except Exception:
        return (None, False)

def _read_powershell_track():
    try:
        out = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-EncodedCommand", NOWPLAYING_ENC],
            capture_output=True, text=True, timeout=8).stdout.strip()
    except Exception:
        return None
    return out or None

def read_track():
    text, fresh = _read_file_track()
    if fresh:
        return text                                    # authoritative (None = nothing playing)
    return _read_powershell_track()                    # writer not running -> interactive fallback

class Poller(threading.Thread):
    def __init__(self, interval=2.0):
        super().__init__(daemon=True)
        self.interval = interval; self.text = None; self.stop = False
    def run(self):
        misses = 0
        while not self.stop:
            t = read_track()
            if t:
                self.text = t; misses = 0
            else:                                      # confirmed-empty after 2 reads -> back to idle
                misses += 1
                if misses >= 2:
                    self.text = None
            time.sleep(self.interval)

# ---- USB ----
def open_dev():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit("BeoPort (0CD4:0101) not found. Attach to WSL (usbipd) + chmod the dev node.")
    try:
        if dev.is_kernel_driver_active(0): dev.detach_kernel_driver(0)
    except (NotImplementedError, usb.core.USBError): pass
    dev.set_configuration(); usb.util.claim_interface(dev, 0)
    return dev

def w(dev, f):
    data = bytes.fromhex(f) if isinstance(f, str) else f
    for attempt in range(3):                       # tolerate transient interrupt-write timeouts
        try:
            dev.write(EP_OUT, data, timeout=1000)
            return
        except usb.core.USBTimeoutError:
            if attempt == 2: raise
            time.sleep(0.05)

def wait_request(dev, seconds):
    buf = b""; end = time.time() + seconds
    while time.time() < end:
        try:
            d = bytes(dev.read(EP_IN, 64, timeout=120))
            if d and set(d) != {0xFF}:
                buf += d
                if "6c0a01" in buf.hex(): return True
        except usb.core.USBError: pass
    return False

# ---- inbound (BS9000 -> us): parse BEO4 transport/key telegrams off EP_IN ----
# Received telegram frame = 60 <len> 00 <ML telegram> 61. A key press is a COMMAND
# telegram: tg[3]==0x0a, payload type 0x0d (BEO4_KEY); key code is the last byte.
_inbuf = b""

def _scan_inbound(buf):
    cmds = []; dist = False
    while True:
        i = buf.find(b"\x60")
        if i < 0: buf = b""; break
        if i + 2 > len(buf): buf = buf[i:]; break          # need 60 + len
        ln = buf[i + 1]; end = i + 2 + ln
        if end >= len(buf): buf = buf[i:]; break            # frame incomplete -> wait
        if buf[end] == 0x61:
            payload = buf[i + 2:end]; buf = buf[end + 1:]
            if payload and payload[0] == 0x00 and len(payload) >= 9:
                tg = payload[1:]
                if tg[3] == 0x0a and tg[7] == 0x0d:         # COMMAND / BEO4_KEY -> transport key
                    cmds.append(tg)
                elif tg[3] == 0x0b and tg[7] == 0x6c:       # REQUEST / DISTRIBUTION -> N.MUSIC selected
                    dist = True
        else:
            buf = buf[i + 1:]                               # misaligned 0x60 -> skip
    if len(buf) > 256: buf = buf[-256:]                     # bound the buffer
    return cmds, dist, buf

_cmd_seq = 0
_last_key = (None, 0.0)
def _emit_command(key):
    # write "<seq> <command>" to command.txt for player-control.ps1; debounce key repeats
    global _cmd_seq, _last_key
    cmd = KEYMAP.get(key)
    now = time.time()
    if cmd is None:
        print("  RXKEY unmapped key=0x%02x" % key, flush=True); return
    if _last_key[0] == key and now - _last_key[1] < 0.4:    # ignore telegram repeats / double-fire
        return
    _last_key = (key, now); _cmd_seq += 1
    try:
        tmp = COMMAND_TXT + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("%d %s" % (_cmd_seq, cmd))
        os.replace(tmp, COMMAND_TXT)                         # atomic swap so the watcher never reads a partial line
        print("  ⏯ key 0x%02x -> %s" % (key, cmd), flush=True)
    except Exception as e:
        print("  ! command write failed:", e, flush=True)

def drain(dev, seconds):
    global _inbuf
    end = time.time() + seconds
    while time.time() < end:
        try:
            d = bytes(dev.read(EP_IN, 64, timeout=80))
            if d and set(d) != {0xFF}: _inbuf += d
        except usb.core.USBError: pass
    dist = False
    if _inbuf:
        cmds, dist, _inbuf = _scan_inbound(_inbuf)
        for tg in cmds:
            _emit_command(tg[-1])
    return dist                                            # True = BS9000 (re)requested distribution

def main():
    args = sys.argv[1:]; speed = 0.2; idle = "BEOSOUND 9000"; i = 0
    while i < len(args):
        if args[i] == "--speed": speed = float(args[i+1]); i += 2
        elif args[i] == "--idle": idle = args[i+1]; i += 2
        else: i += 1

    poller = Poller(); poller.start()
    dev = open_dev()

    print("init handshake ...")
    for f in INIT_FRAMES: w(dev, f); time.sleep(0.06)
    drain(dev, 0.5)
    print("select N.MUSIC on the Beosound (re-arm catches it any time) ...")
    print("  request seen:", wait_request(dev, 4), "(proceeding; re-arm handles later selects)")
    for f in RESPONSE_PREFIX: w(dev, f); time.sleep(0.06)
    last_estab = time.time()

    print(f"now-playing -> Beosound glass. Ctrl-C to stop.\n(idle text: {idle!r}, scroll {speed}s/frame)")
    shown = None       # current marquee string
    s = ""; idx = 0; cc = 1
    last_print = ""
    try:
        while True:
            track = poller.text or idle
            if track != shown:                 # track changed -> reset scroll
                shown = track
                s = (track + "   ") if len(track) > 12 else track
                idx = 0
                if track != last_print:
                    print("  ♪", track); last_print = track
            view = (s + s)[idx % len(s): idx % len(s) + 12] if len(s) > 12 else s
            try:
                w(dev, STATUS_FRAME); time.sleep(0.04)
                w(dev, display_frame(view, (cc % 2) + 1))
            except usb.core.USBError as e:         # transient blip -> skip this frame, keep running
                print(f"  ! usb write skipped ({e.errno}); continuing"); time.sleep(0.2)
            if drain(dev, max(0.0, speed - 0.05)):     # BS9000 (re)selected N.MUSIC -> re-arm source
                if time.time() - last_estab > 1.5:
                    for f in RESPONSE_PREFIX: w(dev, f); time.sleep(0.02)
                    last_estab = time.time()
                    print("  ↻ N.MUSIC selected -> source re-armed", flush=True)
            idx += 1; cc += 1
    except KeyboardInterrupt:
        poller.stop = True
        print("\nstopped (last frame stays on the glass).")

if __name__ == "__main__":
    main()
