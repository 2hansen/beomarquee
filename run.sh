#!/usr/bin/env bash
# Manual launcher for bsnowplaying.py — shows MusicBee's current track on the
# Beosound 9000 glass. Resolves its own dir so it works from any cwd.
#
#   ./run.sh                 # defaults: --speed 0.2 --idle "BO HIFI"
#   ./run.sh --speed 0.15    # any bsnowplaying.py flags are passed through
#
# Preconditions: BeoPort (0CD4:0101) attached to WSL via usbipd + dev node
# writable, MusicBee running on Windows. Select N.MUSIC on the Beosound
# within ~20s of start. Ctrl-C to stop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${PYTHONPATH:-$HOME/.local/lib/python3.14/site-packages}"
exec python3 "$HERE/bsnowplaying.py" "$@"
