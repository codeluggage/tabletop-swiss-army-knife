# CLAUDE.md - Gleam agent bootstrap (Claude Code)

<!-- gleam-for-agents:v1 -->

`AGENTS.md` is the primary reference - it is auto-loaded by Claude Code and other AI frameworks. It holds the check-loop workflow, the few semantics models still miss, and the idiom rules. This file is Claude Code-specific configuration only.

## Claude Code hook setup

A `PostToolUse` hook runs `gleam check` after every `.gleam` file edit, catching type errors immediately (`check` = fast type/variant/arity/exhaustiveness, no codegen). To enable, add to `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "BLOCK_ON_FAIL=1 \"$CLAUDE_PROJECT_DIR/scripts/gleam-check.sh\""
          }
        ]
      }
    ]
  }
}
```

The script walks up to the nearest `gleam.toml` and type-checks. Non-`.gleam` edits are silently ignored. `BLOCK_ON_FAIL=1` feeds compile errors back so you fix them before continuing.

## Reference files

Topic-specific references live in `.agents/` - read the one for the layer you're touching before the first line of that layer, not all up front:

- `.agents/gleam-stdlib.md` - stdlib fn names, `dynamic/decode` engine
- `.agents/gleam-data.md` - JSON encode/parse, Postgres (pog), Squirrel
- `.agents/gleam-frontend.md` - Lustre MVU, events, effects, rsvp, JS FFI
- `.agents/gleam-backend.md` - Wisp handlers, routing, middleware, DB wiring, project layout
- `.agents/gleam-testing.md` - gleeunit, Birdie snapshots, terminal doc-grep
