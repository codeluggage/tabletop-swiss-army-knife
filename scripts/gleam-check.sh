#!/usr/bin/env bash
# gleam-check.sh — type-check the Gleam project nearest an edited file.
#
# Harness-agnostic. Three ways to call it:
#   1. Claude Code PostToolUse hook: receives tool JSON on stdin; reads .tool_input.file_path.
#   2. Manual / git pre-commit / Emacs after-save: pass a file path as $1.
#   3. No arg, no stdin: builds the project rooted at $PWD.
#
# Walks UP from the target file to the nearest gleam.toml and runs `gleam check`
# there, so it does the right thing in a multi-project tree (server/ client/ shared/).
# `check` (not `build`) on purpose: type/variant/arity/exhaustiveness errors with no
# codegen — the fast inner-loop gate. `gleam run`/`gleam test` build artifacts when needed.
# Non-fatal by design: prints check output, but never blocks the edit (exit 0)
# unless BLOCK_ON_FAIL=1. AGENTS.md does NOT depend on this script — it's a safety net.
set -uo pipefail

# --- resolve the target file -------------------------------------------------
file="${1:-}"
if [ -z "$file" ] && [ ! -t 0 ]; then
  # stdin is a pipe (e.g. CC hook JSON). Extract file_path without requiring jq.
  payload="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  else
    file="$(printf '%s' "$payload" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
fi

# Only care about Gleam sources; ignore everything else silently.
case "$file" in
  *.gleam) ;;
  "") ;;                       # no file -> fall through to $PWD build
  *) exit 0 ;;
esac

# --- find the nearest gleam.toml --------------------------------------------
start_dir="$PWD"
[ -n "$file" ] && [ -e "$file" ] && start_dir="$(cd "$(dirname "$file")" && pwd)"

dir="$start_dir"
while [ "$dir" != "/" ]; do
  [ -f "$dir/gleam.toml" ] && break
  dir="$(dirname "$dir")"
done
if [ ! -f "$dir/gleam.toml" ]; then
  exit 0   # not inside a Gleam project; nothing to do
fi

# --- pick a gleam invocation (mise-aware) -----------------------------------
if command -v gleam >/dev/null 2>&1; then
  GLEAM=(gleam)
elif command -v mise >/dev/null 2>&1; then
  GLEAM=(mise exec gleam -- gleam)
else
  echo "gleam-check: no gleam on PATH and no mise; skipping" >&2
  exit 0
fi

# --- build -------------------------------------------------------------------
out="$(cd "$dir" && "${GLEAM[@]}" check 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
  echo "gleam check FAILED in ${dir#"$PWD"/} — fix before continuing:" >&2
  echo "$out" | tail -40 >&2
  [ "${BLOCK_ON_FAIL:-0}" = "1" ] && exit 2   # exit 2 = CC feeds stderr back to the model
fi
exit 0
