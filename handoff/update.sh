#!/usr/bin/env bash
# Refreshes the handoff copies: current ledger, Claude memory, owner preferences. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
ledger=$(ls -t .superpowers/sdd/*/progress.md 2>/dev/null | head -1 || true)
[ -n "$ledger" ] && cp "$ledger" handoff/ledger-current-stage.md && echo "ledger: $ledger"
mem="$HOME/.claude/projects/C--Users-mtska-Downloads-Lifepath-2-0/memory"
mkdir -p handoff/private/memory
[ -d "$mem" ] && cp "$mem"/*.md handoff/private/memory/ && echo "memory: copied"
pref=$(ls "$APPDATA"/Claude/rpm/*/*/plugin_*/skills/prefskill/references/prefbackup.md 2>/dev/null | head -1 || true)
[ -n "$pref" ] && cp "$pref" handoff/private/preferences.md && echo "preferences: copied"
git log --oneline -15 > handoff/private/recent-commits.txt
echo "Now update handoff/STATE.md by hand and commit handoff/ (private/ stays local)."
