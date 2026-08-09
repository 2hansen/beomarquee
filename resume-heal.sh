#!/usr/bin/env bash
# resume-heal.sh -- SURGICAL post-sleep usbip recovery that does NOT nuke the WSL VM.
#
# Run as root, from the "BeoSound Resume Rebuild" task on Windows:
#     wsl -d Ubuntu -u root -e bash "<repo>/resume-heal.sh"
#
# WHY (replaces `wsl --shutdown` in resume-rebuild.ps1, 2026-08-04):
#   After sleep the inbound read URB deadlocks in D-state (usb_kill_urb) and usbipd
#   detach/attach can't reap it. Historically we cleared that with `wsl --shutdown`
#   -- the whole-VM hammer, which also kills every OTHER process in this WSL (Claude
#   Code sessions, tools, etc). But tearing down just the vhci PORT reaps the same
#   wedged URB (proven live: "only root sysfs vhci detach or wsl --shutdown" clears
#   it). This writes the vhci `detach` knob for each attached port instead -- the VM
#   and all other processes survive. The existing reattach-request -> attach-beoport
#   loop then re-attaches a fresh node and bsnowplaying rebinds, exactly as before.
#
# Exit codes: 0 = healed, or nothing to heal (no attached port / no vhci in this VM)
#             2 = could NOT act (vhci is there but we are not root)
#             -> resume-rebuild.ps1 falls back to `wsl --shutdown` on non-zero.
set -u
VHCI=/sys/devices/platform/vhci_hcd.0
log(){ echo "$(date '+%F %T') [resume-heal] $*"; }

# No vhci at all => usbip has never attached inside THIS VM, so there is no wedged URB to
# reap and nothing for `wsl --shutdown` to clear either. Happens when the VM was not running
# at wake time (this very call cold-boots it). Seen live 2026-08-09: heal hit a fresh VM,
# exited 2, and the caller nuked a VM that had nothing wrong with it. Report success instead
# -- the reattach-request the caller writes afterwards is all that is needed.
if [ ! -e "$VHCI/detach" ]; then
    log "no $VHCI -- usbip never attached in this VM (nothing wedged); no fallback needed"
    exit 0
fi

# Present but not writable => we are not root. That IS a real failure: a wedged URB may be
# sitting there and we cannot reap it, so the caller must fall back to the whole-VM hammer.
if [ ! -w "$VHCI/detach" ]; then
    log "$VHCI/detach not writable (not running as root) -- aborting; caller should fall back to wsl --shutdown"
    exit 2
fi

# status columns: hub port sta spd dev sockfd local_busid ; sockfd != 000000 => attached
detached=0
while read -r hub port sta spd dev sockfd busid; do
    [ "$sockfd" = "000000" ] && continue
    p=$((10#$port))                          # "0000" -> 0
    log "detaching vhci port $p (busid=$busid dev=$dev sockfd=$sockfd) -> reaps the wedged URB"
    if printf '%s' "$p" > "$VHCI/detach" 2>/dev/null; then
        detached=$((detached+1))
    else
        log "WARN: detach of port $p failed"
    fi
done < <(tail -n +2 "$VHCI/status")

if [ "$detached" -eq 0 ]; then
    log "no attached vhci ports found -- nothing to detach (link may already be clean)"
fi

log "restarting bsnowplaying.service for a clean process against the (soon) fresh node"
systemctl restart bsnowplaying.service 2>/dev/null \
    || log "WARN: could not restart bsnowplaying.service"

log "done -- Windows side now writes reattach-request; attach-beoport re-attaches a fresh node"
exit 0
