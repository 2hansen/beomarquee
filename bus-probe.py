#!/usr/bin/env python3
"""bus-probe.py -- diagnostic: what does the BS9000 emit on EP_IN in each power state?

Purpose (2026-07-05 experiment): find a PRESENCE FINGERPRINT so beomarquee can tell
"BS9000 on N.MUSIC" vs "standby" vs "off-at-the-wall" apart -- the signal a future
presence-driven supervisor would spin the scroll worker up/down on.

It does the same INIT handshake + STATUS_FRAME keepalive as bsnowplaying (the BeoPort
only FORWARDS bus traffic to USB once it's been init'd + kept alive -- a fully silent
run sees nothing), but sends NO display frames and does NOT establish as source center,
so it won't paint the glass or grab the N.MUSIC source. Purely observes inbound.

The running service OWNS the interface, so stop it first:
    sudo systemctl stop bsnowplaying
    PYTHONPATH=$HOME/.local/lib/python3.14/site-packages python3 bus-probe.py [--secs 90]
    sudo systemctl start bsnowplaying     # when done
"""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usb.core
import bsnowplaying as bs                       # reuse VID/PID/EP/INIT_FRAMES/STATUS_FRAME/open_dev/w


def classify(tg):
    """tg = the ML telegram bytes (payload after the 0x00 that follows 0x60<len>)."""
    if len(tg) < 9:
        return "short"
    if tg[3] == 0x0a and tg[7] == 0x0d:
        return "KEY 0x%02x" % tg[-1]            # Beo4 transport key
    if tg[3] == 0x0b and tg[7] == 0x6c:
        return "DIST-REQ (N.MUSIC selected)"    # BS9000 asked us to distribute
    if tg[3] == 0x0b:
        return "REQUEST 0x%02x" % tg[7]
    if tg[3] == 0x01:
        return "flood/status[01]"               # the 60040101012961-style burst
    return "other tg[3]=0x%02x tg[7]=0x%02x" % (tg[3], tg[7])


def scan(buf):
    """Yield (label, rawhex) for every complete 60..61 frame; return leftover buffer."""
    out = []
    while True:
        i = buf.find(b"\x60")
        if i < 0:
            buf = b""; break
        if i + 2 > len(buf):
            buf = buf[i:]; break
        ln = buf[i + 1]; end = i + 2 + ln
        if end >= len(buf):
            buf = buf[i:]; break
        if buf[end] == 0x61:
            payload = buf[i + 2:end]; buf = buf[end + 1:]
            raw = bytes([0x60, ln]) + payload + b"\x61"
            if payload and payload[0] == 0x00:
                out.append((classify(payload[1:]), raw.hex()))
            else:
                out.append(("nonml", raw.hex()))
        else:
            buf = buf[i + 1:]
    if len(buf) > 512:
        buf = buf[-512:]
    return out, buf


def ts():
    return time.strftime("%H:%M:%S") + ("%.3f" % (time.time() % 1))[1:]


def main():
    secs = None
    a = sys.argv[1:]
    for i, x in enumerate(a):
        if x == "--secs" and i + 1 < len(a):
            secs = float(a[i + 1])

    dev = bs.open_dev()
    print("init handshake ...", flush=True)
    for f in bs.INIT_FRAMES:
        bs.w(dev, f); time.sleep(0.06)
    print("probing EP_IN. keepalive 1.0s, NO display, NO source establish.", flush=True)
    print("cycle the BS9000: N.MUSIC -> standby -> off-at-wall -> back on. Ctrl-C to stop.\n", flush=True)

    buf = b""
    last_ka = 0.0
    counts = {}                      # per-window telegram-label counts
    win_start = time.time()
    last_inbound = time.time()
    end = time.time() + secs if secs else None
    try:
        while True:
            now = time.time()
            if end and now > end:
                break
            if now - last_ka >= 1.0:                     # keepalive: keeps the BeoPort forwarding
                try: bs.w(dev, bs.STATUS_FRAME)
                except usb.core.USBError as e: print("%s  ! keepalive write err %s" % (ts(), e), flush=True)
                last_ka = now
            try:
                d = bytes(dev.read(bs.EP_IN, 64, timeout=200))
            except usb.core.USBError:
                d = b""
            if d and set(d) != {0xFF}:
                buf += d
                frames, buf = scan(buf)
                for label, raw in frames:
                    last_inbound = now
                    counts[label] = counts.get(label, 0) + 1
                    # print each non-flood telegram raw; flood/heartbeat get summarised below
                    if not label.startswith("flood"):
                        print("%s  %-28s %s" % (ts(), label, raw), flush=True)
            # once-per-2s rollup so quiet/off states are obvious at a glance
            if now - win_start >= 2.0:
                gap = now - last_inbound
                summary = " ".join("%s=%d" % (k, v) for k, v in sorted(counts.items())) or "(nothing)"
                print("%s  --- 2s: %s | idle=%.1fs ---" % (ts(), summary, gap), flush=True)
                counts = {}; win_start = now
    except KeyboardInterrupt:
        print("\nstopped.", flush=True)


if __name__ == "__main__":
    main()
