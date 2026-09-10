#!/usr/bin/env bash
# test.sh [--perf | --sim N [--map ID] [--seed N]]
# Headless: no browser, no display. Everything the exported page runs, run here.
set -euo pipefail
cd "$(dirname "$0")"
GODOT="${GODOT:-godot}"
$GODOT --headless --import >/dev/null 2>&1 || true
if [ $# -gt 0 ]; then
  exec $GODOT --headless --script res://scripts/tests.gd -- "$@"
fi
exec $GODOT --headless --script res://scripts/tests.gd
