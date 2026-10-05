#!/usr/bin/env bash
# Agent checklist for the Watch layout and pair-help copy.
# Unit tests cover the same rules. Pass a screenshot directory after capture-screenshots.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "${root}/scripts/watch-ui-checklist.py" "$@"
