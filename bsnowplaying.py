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
  --speed 0.3   seconds per scroll-text frame (default 0.3)
  --ka 1.0      seconds between keepalive frames (default 1.0); required to keep the
                BeoPort forwarding inbound remote keys -- see note below
  --idle "..."  text shown when nothing is playing (default "BEOSOUND 9000")
  --no-display  diagnostic: send keepalive only, no scrolling text

Bus-load note: the BeoPort drops inbound remote-key telegrams when our OUTBOUND rate is
too high (~10 frames/sec starved keys; ~5/sec is reliable). Keepalive and scroll therefore
run on independent timers so the total stays well under that ceiling while keys stay reliable.
"""
import sys, os, time, threading, subprocess, base64
import usb.core, usb.util

HERE = os.path.dirname(os.path.abspath(__file__))
NOWPLAYING_PS1 = os.path.join(HERE, "nowplaying2.ps1")
NOWPLAYING_TXT = os.path.join(HERE, "nowplaying.txt")  # written by nowplaying-writer.ps1 (Windows interactive session)
NP_STALE_SEC = 10                                      # ignore the file if the writer stopped refreshing it
COMMAND_TXT = os.path.join(HERE, "command.txt")        # WE write here on a BS9000 key; player-control.ps1 injects the media key
# --- USB-link self-heal: the BeoPort/usbip link periodically wedges (writes return Errno 110
# while the device still enumerates). The ONLY proven recovery is a usbipd detach+reattach to
# re-enumerate a fresh node -- which must run on Windows (the systemd service has no WSL interop
# to call usbipd.exe itself). So we signal it via a file the attach-beoport.ps1 loop watches. ---
REATTACH_REQ = os.path.join(HERE, "reattach-request")  # WE touch this when wedged; attach-beoport.ps1 power-cycles the link
WEDGE_COUNT  = os.path.join(HERE, "wedge-count")        # consecutive init-wedge counter across service restarts

def _read_wedge_count():
    try: return int((open(WEDGE_COUNT).read().strip() or "0"))
    except Exception: return 0

def _write_wedge_count(n):
    try:
        with open(WEDGE_COUNT, "w") as f: f.write(str(n))
    except Exception: pass

def _request_reattach():
    try:
        with open(REATTACH_REQ, "w") as f: f.write("wedge")
        print("  ⚠ wrote reattach-request -> asking Windows to power-cycle the usbip link", flush=True)
    except Exception: pass
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
    for ep in (EP_OUT, EP_IN):                      # clear any halted/stalled endpoint (Errno 32 Pipe error)
        try: dev.clear_halt(ep)                      # left over from a previous wedge -> recover in-process
        except usb.core.USBError: pass
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
_last_key = (None, 0.0)        # (key, time of the LAST telegram seen for that key)
KEY_BURST_GAP = 0.5           # one physical press = one command: a held key emits a burst of
                              # repeated telegrams; collapse them while they keep arriving
                              # within this gap. A real release+press (gap > this) fires again.
def _emit_command(key):
    # write "<seq> <command>" to command.txt for player-control.ps1; one fire per press-burst
    global _cmd_seq, _last_key
    cmd = KEYMAP.get(key)
    now = time.time()
    if cmd is None:
        print("  RXKEY unmapped key=0x%02x" % key, flush=True); return
    prev_key, prev_t = _last_key
    _last_key = (key, now)                                 # ALWAYS update last-seen so a held key
                                                           # stays a single burst (window slides)
    if prev_key == key and now - prev_t < KEY_BURST_GAP:   # still the same ongoing burst -> suppress
        return
    _cmd_seq += 1
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


class InboundReader(threading.Thread):
    """Continuously drain EP_IN so BS9000 key telegrams are never missed.

    The old single-threaded loop wrote scroll frames for most of each ~0.2s cycle and only
    read inbound (`drain`) for a brief window. Key telegrams arriving during the write phase
    queued in the device buffer, and the slow read rate couldn't keep up with the constant
    Masterlink bus chatter -> the buffer backed up and intermittently DROPPED telegrams, so a
    press landed only sometimes. This thread reads back-to-back (concurrent with the writer,
    since EP_IN and EP_OUT are independent pipes), keeping the buffer drained so every key is
    caught. It owns the inbound parse globals; the main thread no longer calls `drain`."""
    def __init__(self, dev):
        super().__init__(daemon=True)
        self.dev = dev; self.stop = False
        self.buf = b""; self.dist_event = threading.Event()
    def run(self):
        while not self.stop:
            try:
                d = bytes(self.dev.read(EP_IN, 64, timeout=200))
            except usb.core.USBError:
                continue                                   # timeout / transient blip -> keep reading
            if not d or set(d) == {0xFF}:
                continue
            self.buf += d
            cmds, dist, self.buf = _scan_inbound(self.buf)
            for tg in cmds:
                _emit_command(tg[-1])
            if dist:
                self.dist_event.set()                      # BS9000 (re)selected N.MUSIC -> main re-arms

def main():
    # Bus-load budget: the BeoPort drops inbound key telegrams when our OUTBOUND rate is too high
    # (~10 tele/sec starved keys; ~5/sec is reliable). So keepalive and scroll run on INDEPENDENT
    # timers: STATUS_FRAME (keepalive -- required or the BeoPort stops forwarding keys) every `ka`s,
    # and the scrolling display_frame every `speed`s. Defaults keep total well under the safe ceiling.
    args = sys.argv[1:]; speed = 0.3; ka = 1.0; idle = "BEOSOUND 9000"; i = 0
    no_display = False
    while i < len(args):
        if args[i] == "--speed": speed = float(args[i+1]); i += 2
        elif args[i] == "--ka": ka = float(args[i+1]); i += 2          # keepalive interval (s)
        elif args[i] == "--idle": idle = args[i+1]; i += 2
        elif args[i] == "--no-display": no_display = True; i += 1       # diagnostic: keepalive only, no scrolling text
        else: i += 1

    poller = Poller(); poller.start()
    dev = open_dev()

    print("init handshake ...")
    try:
        for f in INIT_FRAMES: w(dev, f); time.sleep(0.06)
    except usb.core.USBError as e:
        # Link wedged: device enumerates but refuses interrupt writes -- seen as both Errno 110
        # (timeout) and Errno 32 (Pipe error / endpoint stall). One transient could be bad luck;
        # two consecutive service starts wedging = a real wedge -> ask Windows to detach+reattach
        # (re-enumerate a fresh node), which is the only thing that clears it.
        n = _read_wedge_count() + 1
        print(f"  ! init write wedged ({e}), consecutive starts={n}", flush=True)
        if n >= 2:
            _request_reattach(); _write_wedge_count(0)
        else:
            _write_wedge_count(n)
        poller.stop = True
        sys.exit(1)                                    # systemd restarts (RestartSec=5); fresh node after reattach
    _write_wedge_count(0)                              # init succeeded -> clear the wedge counter
    drain(dev, 0.5)
    print("select N.MUSIC on the Beosound (re-arm catches it any time) ...")
    print("  request seen:", wait_request(dev, 4), "(proceeding; re-arm handles later selects)")
    for f in RESPONSE_PREFIX: w(dev, f); time.sleep(0.06)
    last_estab = time.time()

    reader = InboundReader(dev); reader.start()    # take over EP_IN now that init reads are done

    print(f"now-playing -> Beosound glass. Ctrl-C to stop.\n(idle text: {idle!r}, scroll {speed}s/frame, keepalive {ka}s)")
    shown = None       # current marquee string
    s = ""; idx = 0; cc = 1
    last_print = ""
    skips = 0          # consecutive display-write failures -> detect a mid-run link wedge
    TICK = 0.05        # loop granularity; the two timers below decide what actually gets sent
    last_ka = 0.0; last_scroll = 0.0       # 0.0 -> both fire on the first iteration
    try:
        while True:
            now = time.time()
            track = poller.text or idle
            if track != shown:                 # track changed -> reset scroll
                shown = track
                s = (track + "   ") if len(track) > 12 else track
                idx = 0
                if track != last_print:
                    print("  ♪", track); last_print = track
            try:
                sent_ka = False
                if now - last_ka >= ka:                        # keepalive tick: keeps the BeoPort forwarding inbound keys
                    w(dev, STATUS_FRAME); last_ka = now; sent_ka = True
                if not no_display and now - last_scroll >= speed:   # scroll tick: advance the marquee one step
                    if sent_ka: time.sleep(0.04)               # brief gap when a keepalive just went out
                    view = (s + s)[idx % len(s): idx % len(s) + 12] if len(s) > 12 else s
                    w(dev, display_frame(view, (cc % 2) + 1))
                    idx += 1; cc += 1; last_scroll = now
                skips = 0
            except usb.core.USBError as e:         # transient blip -> skip this frame, keep running
                skips += 1
                print(f"  ! usb write skipped ({e.errno}); continuing"); time.sleep(0.2)
                if skips >= 25:                    # ~5s of solid failures = a real wedge, not a blip ->
                    _request_reattach()            # ask Windows to power-cycle the link, then restart clean
                    print("  ⚠ sustained USB write wedge -> requesting reattach + restarting", flush=True)
                    poller.stop = True; reader.stop = True
                    sys.exit(1)
            time.sleep(TICK)                       # inbound reading runs in InboundReader
            if reader.dist_event.is_set():             # BS9000 (re)selected N.MUSIC -> re-arm source
                reader.dist_event.clear()
                if time.time() - last_estab > 1.5:
                    for f in RESPONSE_PREFIX: w(dev, f); time.sleep(0.02)
                    last_estab = time.time()
                    print("  ↻ N.MUSIC selected -> source re-armed", flush=True)
    except KeyboardInterrupt:
        poller.stop = True; reader.stop = True
        print("\nstopped (last frame stays on the glass).")

if __name__ == "__main__":
    main()
