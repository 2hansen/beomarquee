#!/usr/bin/env python3
"""
bsdisplay — show any text on the Beosound 9000 glass, from Linux, via the BeoPort 1671.

Becomes a minimal N.MUSIC source-center: replays the init handshake, answers the
BS9000's DISTRIBUTION_REQUEST, then continuously marquees your text until Ctrl-C.

Usage:
  python bsdisplay.py "Now playing: Samsung - Over The Horizon"
  python bsdisplay.py --speed 0.4 "Shorter text"     # seconds per scroll frame
  python bsdisplay.py --static "BO HIFI"              # no scrolling (<=12 chars)

Prereqs (hifi box, BeoPort attached to WSL via usbipd, BeoPlayer closed):
  sudo chmod 666 /dev/bus/usb/<BUS>/<DEV>
  PYTHONPATH=~/.local/lib/python3.14/site-packages python3 bsdisplay.py "..."

After you start it, select N.MUSIC on the Beosound (within 60s) if it isn't already
the active source. The glass then shows your text. Ctrl-C to stop (the last frame
stays on the glass until you change source on the Beosound).
"""
import sys, time, os
import usb.core, usb.util

VID, PID = 0x0CD4, 0x0101
EP_OUT, EP_IN = 0x01, 0x81

INIT_FRAMES = [
    "6001f161", "600380290061", "60012961", "6005f60082808361", "6002e70161", "60012661",
    "6010e0c029010b0000000403040a01000b0061", "6010e0c129010b0000000403040a01000c0061",
    "6002e70061", "6005e31400000061", "6005e50100000061", "6002eaff61", "6002ea8161", "6005e50100000061",
]
# response prefix: distribution-response + status + track-info (establish the live session)
RESPONSE_PREFIX = [
    "6002ea8061", "6002ea8161", "6005e50101000061",
    "600ee0c1c20114007a006c010801880061",
    "602ce083c20114007a00871f047a0100001fbe01000000ff0201000301010103000200000000010000000000e50061",
    "6017e0c1c20114000000820a01067a0002000000000001a80061",
]
STATUS_FRAME = bytes.fromhex("602ce083c20114007a00871f047a0100001fbe01000000ff0201000301010103000200000000010000000000e50061")

def display_frame(text, cc=0x01):
    """DISPLAY_SOURCE (0x06) carrying `text` (12-char field), checksum = sum(telegram) mod 256."""
    tele = bytes.fromhex("83c2012c007a000611000300")[:11] + bytes([cc, 0x01, 0x00, 0x00])
    t = text.encode("ascii", "replace")[:12]; t = t + b" " * (12 - len(t))
    tele = tele + t
    cs = sum(tele) & 0xFF
    payload = b"\xe0" + tele + bytes([cs, 0x00])
    return bytes([0x60, len(payload)]) + payload + b"\x61"

def open_dev():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit("BeoPort (0CD4:0101) not found. Attach it to WSL (usbipd) and chmod the dev node.")
    try:
        if dev.is_kernel_driver_active(0): dev.detach_kernel_driver(0)
    except (NotImplementedError, usb.core.USBError): pass
    dev.set_configuration(); usb.util.claim_interface(dev, 0)
    return dev

def w(dev, f):
    dev.write(EP_OUT, bytes.fromhex(f) if isinstance(f, str) else f, timeout=1000)

def wait_request(dev, seconds):
    buf = b""; end = time.time() + seconds
    while time.time() < end:
        try:
            d = bytes(dev.read(EP_IN, 64, timeout=120))
            if d and set(d) != {0xFF}:
                buf += d
                if "6c0a01" in buf.hex():
                    return True
        except usb.core.USBError:
            pass
    return False

def drain(dev, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try: dev.read(EP_IN, 64, timeout=80)
        except usb.core.USBError: pass

def main():
    args = sys.argv[1:]
    speed = 0.2; static = False
    out = []
    i = 0
    while i < len(args):
        if args[i] == "--speed": speed = float(args[i+1]); i += 2
        elif args[i] == "--static": static = True; i += 1
        else: out.append(args[i]); i += 1
    text = " ".join(out) or "BO HIFI"

    dev = open_dev()
    print("init handshake ...")
    for f in INIT_FRAMES: w(dev, f); time.sleep(0.06)
    drain(dev, 0.5)

    print("waiting up to 20s — select N.MUSIC on the Beosound if it isn't already ...")
    got = wait_request(dev, 20)
    print("  request seen:" , got, "(proceeding either way)")

    # establish the session; seed the name with the first window of text
    first = text[:12] if (static or len(text) <= 12) else (text + "   ")[:12]
    for f in RESPONSE_PREFIX: w(dev, f); time.sleep(0.06)
    w(dev, display_frame(first, 0x01)); time.sleep(0.06)
    w(dev, display_frame(first, 0x02)); time.sleep(0.06)

    if static or len(text) <= 12:
        print(f"showing '{text}' (static). Ctrl-C to stop.")
        cc = 1
        try:
            while True:
                w(dev, STATUS_FRAME); time.sleep(0.04)
                w(dev, display_frame(text, (cc % 2) + 1)); cc += 1
                drain(dev, 0.8)
        except KeyboardInterrupt:
            print("\nstopped (last frame stays on the glass).")
        return

    print(f"scrolling '{text}' at {speed}s/frame. Ctrl-C to stop.")
    s = text + "   "
    i = 0; cc = 1
    try:
        while True:
            view = (s + s)[i % len(s): i % len(s) + 12]
            w(dev, STATUS_FRAME); time.sleep(0.04)
            w(dev, display_frame(view, (cc % 2) + 1))
            drain(dev, max(0.0, speed - 0.05))
            i += 1; cc += 1
    except KeyboardInterrupt:
        print("\nstopped (last frame stays on the glass).")

if __name__ == "__main__":
    main()
