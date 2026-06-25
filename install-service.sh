#!/usr/bin/env bash
# Install bsnowplaying as a boot-autostart systemd service on the HIFI BOX
# (the WSL instance that has the BeoPort attached via usbipd + MusicBee on Windows).
#
# Run this ON THE HIFI BOX, once:   sudo ./install-service.sh
#
# It:
#   1. installs a udev rule so the invoking user can open the BeoPort without root,
#   2. generates /etc/systemd/system/bsnowplaying.service with paths resolved here,
#   3. enables it for boot and starts it now.
#
# The service uses Restart=always with no start-rate limit, so until usbipd
# attaches the BeoPort it simply retries every 5s ("device not found" -> exit
# -> restart). That retry loop IS the graceful wait-for-device behaviour.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo ./install-service.sh" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_USER="${SUDO_USER:-}"
if [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]]; then
  echo "Run via 'sudo ./install-service.sh' as your normal login user (so SUDO_USER is set)," >&2
  echo "not as root directly — the service must run as the user who can reach the dev node." >&2
  exit 1
fi
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
PYPATH="$RUN_HOME/.local/lib/python3.14/site-packages"
SCRIPT="$HERE/bsnowplaying.py"

echo "user=$RUN_USER  home=$RUN_HOME"
echo "script=$SCRIPT"

# 1. udev rule: BeoPort 1671 = 0cd4:0101 -> world-rw dev node
cat > /etc/udev/rules.d/99-beoport.rules <<'EOF'
# BeoPort 1671 (Bang & Olufsen) — let non-root open it for bsnowplaying
SUBSYSTEM=="usb", ATTR{idVendor}=="0cd4", ATTR{idProduct}=="0101", MODE="0666"
EOF
udevadm control --reload-rules || true
udevadm trigger || true

# 2. systemd unit — quote the space-containing script path
cat > /etc/systemd/system/bsnowplaying.service <<EOF
[Unit]
Description=Beosound 9000 now-playing display (MusicBee -> BS9000 glass)
After=multi-user.target
# never stop retrying — until usbipd attaches the BeoPort the app just exits + restarts
StartLimitIntervalSec=0

[Service]
Type=simple
User=$RUN_USER
Environment=PYTHONPATH=$PYPATH
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 "$SCRIPT"
Restart=always
RestartSec=5
# follow the app's own output: journalctl -u bsnowplaying -f

[Install]
WantedBy=multi-user.target
EOF

# 3. enable for boot + (re)start now — restart, not just --now, so a re-run reloads new code
systemctl daemon-reload
systemctl enable bsnowplaying.service
systemctl restart bsnowplaying.service

echo
echo "Installed. Status:"
systemctl --no-pager --full status bsnowplaying.service || true
echo
echo "Follow logs:   journalctl -u bsnowplaying -f"
echo "Stop/disable:  sudo systemctl disable --now bsnowplaying.service"
