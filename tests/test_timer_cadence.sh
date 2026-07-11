#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMER="$ROOT/systemd/move-dovi5-to-quarantine.timer"

grep -Fx 'Description=Run DoVi 5 delete-and-recover scan every 15 minutes' "$TIMER" >/dev/null
grep -Fx 'OnBootSec=10min' "$TIMER" >/dev/null
grep -Fx 'OnActiveSec=15min' "$TIMER" >/dev/null
grep -Fx 'OnUnitInactiveSec=15min' "$TIMER" >/dev/null

if grep -F 'OnCalendar=' "$TIMER" >/dev/null; then
    echo "timer should not be daily OnCalendar based" >&2
    exit 1
fi

echo "Timer cadence test passed"
