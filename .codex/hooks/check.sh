#!/bin/sh
# Codex hook after a file edit: type-check the project.
# Exit 2 sends the errors back to the agent, so it fixes them before going on.
cd "$(dirname "$0")/../.." || exit 0
out=$(gleam check 2>&1) || { printf 'gleam check failed:\n%s\n' "$out" >&2; exit 2; }
exit 0
