#!/usr/bin/env bash
#
# Persists the Apple Silicon GPU wired-memory ceiling across reboots.
#
# Why: macOS caps GPU-wired memory near 75% of RAM (~18GB of 24GB). A 17-18GB
# model plus its KV cache lands just past that, so part of the model runs on CPU
# and every token waits on the slow half. Raising the ceiling puts the whole
# model on the GPU.
#
# This is a CEILING, not a reservation — it does not take memory from macOS,
# it only permits the GPU to wire more when something asks for it.
#
# Requires sudo: a LaunchDaemon runs as root at boot, unlike the user-level
# LaunchAgent that runs the Ollama server.
#
# Usage:  sudo bash scripts/install-gpu-limit.sh [--dry-run|--uninstall]
set -euo pipefail

LABEL="com.personalbrain.gpulimit"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

: "${BRAIN_GPU_WIRED_MB:=20480}"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --uninstall)
    [ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
    launchctl bootout "system/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed ${LABEL}. The ceiling reverts to the macOS default on next reboot."
    echo "To revert immediately: sudo sysctl iogpu.wired_limit_mb=0"
    exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only" >&2; exit 1; }
if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo bash scripts/install-gpu-limit.sh" >&2; exit 1
fi

# Refuse a value that would leave macOS too little to work with.
RAM_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
MAX_SAFE=$(( RAM_MB * 88 / 100 ))
if [ "$BRAIN_GPU_WIRED_MB" -gt "$MAX_SAFE" ]; then
  echo "refusing ${BRAIN_GPU_WIRED_MB}MB on a ${RAM_MB}MB machine (cap ${MAX_SAFE}MB)." >&2
  echo "Leaving macOS under ~12% of RAM invites swapping, which costs more than the spill." >&2
  exit 1
fi
echo "==> ${BRAIN_GPU_WIRED_MB}MB ceiling on ${RAM_MB}MB of RAM"

if [ "$DRY" -eq 1 ]; then
  echo "  [dry-run] would write $PLIST and bootstrap it"
  exit 0
fi

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/sysctl</string>
    <string>iogpu.wired_limit_mb=${BRAIN_GPU_WIRED_MB}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null || { echo "plist malformed" >&2; exit 1; }

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

sysctl iogpu.wired_limit_mb

cat <<EOF

  Done. The ceiling is reapplied at every boot.

  Verify after your next reboot:
    sysctl iogpu.wired_limit_mb
    ollama run qwen3.6:27b-q4_K_M --think=false "hi"
    ollama ps

  PROCESSOR should read 100% GPU.

  Uninstall: sudo bash scripts/install-gpu-limit.sh --uninstall

EOF
