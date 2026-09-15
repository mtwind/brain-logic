#!/usr/bin/env bash
#
# Brings audio back after the model has starved it, without a reboot.
#
# Why this exists: macOS refuses every mlock once free memory drops below
# vm.global_no_user_wire_amount (~5.9GB on a 24GB machine), and CoreAudio wires
# an 80KB buffer to start any output device. The resident model is 17GB, which
# puts free memory near 7%, so audio devices stop starting. coreaudiod itself
# stays healthy -- which is why the speakers test fine and only a reboot seems
# to help.
#
# The failure is sticky: freeing memory later does not revive a device whose IO
# thread already failed to start. coreaudiod has to be restarted. It respawns
# automatically, in about a second.
#
# ORDER MATTERS. Unloading the model first is not politeness -- restarting the
# daemon while memory is still under the floor just reproduces the failure.
#
# The real fix is a model that fits the budget (~14GB). No smaller variant of
# either bake-off candidate exists on the registry, so this is the mitigation
# until that changes. See docs/decision-log.md, 2026-09-07.
#
# Usage: bash scripts/audio-recover.sh [--dry-run|--status]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"

DRY=0
MODE="recover"
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --status)  MODE="status" ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# The floor mlock is measured against, and how much room there is right now.
floor_mb=$(( $(sysctl -n vm.global_no_user_wire_amount) / 1048576 ))
total_mb=$(( $(sysctl -n hw.memsize) / 1048576 ))
free_pct=$({ memory_pressure -Q 2>/dev/null || true; } | awk '/free percentage/{gsub(/%/,"",$NF); print $NF}')
free_mb=$(( total_mb * ${free_pct:-0} / 100 ))

echo "  free ${free_mb}MB of ${total_mb}MB (${free_pct:-?}%), mlock floor ${floor_mb}MB"
if [ "$free_mb" -lt "$floor_mb" ]; then
  echo "  UNDER the floor — audio devices cannot start in this state"
else
  echo "  above the floor — audio should be able to start"
fi

# Reported, never guessed at: `ollama ps` is the only thing that knows.
loaded=$({ ollama ps 2>/dev/null || true; } | awk 'NR>1 && NF {print $1}')
if [ -n "$loaded" ]; then
  echo "  resident: $(printf '%s ' $loaded)"
else
  echo "  resident: no model loaded"
fi

[ "$MODE" = "status" ] && exit 0

if [ -n "$loaded" ]; then
  for m in $loaded; do
    echo "==> unloading ${m}"
    run ollama stop "$m"
  done
  [ "$DRY" -eq 0 ] && sleep 2
else
  echo "==> nothing to unload"
fi

echo "==> restarting coreaudiod (respawns automatically)"
if [ "$DRY" -eq 1 ]; then
  echo "  [dry-run] sudo killall coreaudiod"
else
  sudo killall coreaudiod || {
    echo "could not signal coreaudiod — needs sudo from an interactive terminal" >&2
    exit 1
  }
  sleep 1
fi

cat <<EOF

  Done. Press play again — apps that were mid-playback may need a nudge.

  If audio is still dead, it is not this: check Sound in System Settings for a
  changed output device. This script only fixes the memory-starvation case.

  Status without changing anything:  bash scripts/audio-recover.sh --status

EOF
