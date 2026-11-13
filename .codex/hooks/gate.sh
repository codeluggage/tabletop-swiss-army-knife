#!/bin/sh
# Codex hook when the agent wants to finish: check, test and format must pass.
# Exit 2 sends the failure back as the next thing to fix. A second stop in a row
# is let through, so the agent never loops.
cd "$(dirname "$0")/../.." || exit 0
if grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then echo '{}'; exit 0; fi
for step in "gleam check" "gleam test" "gleam format --check src test dev"; do
  out=$($step 2>&1) || { printf '%s failed:\n%s\n' "$step" "$(printf '%s\n' "$out" | tail -60)" >&2; exit 2; }
done
echo '{}'
