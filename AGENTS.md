# AGENTS.md - Gleam full-stack reference

> Verified against: Gleam 1.16, June 2026. Thinned 2026-09-06 against Claude Fable 5.1, Claude Opus 4.7 and GPT-6 (the `eval/` directory in the shim repo holds the runs). Package names, API shapes and version traps were checked at that vintage. Re-verify before trusting them much later.

Gleam (+ Lustre for web frontend). Not Next.js/TS. A dense, verified head-start, not a substitute for the compiler. Lowercase identifiers in a signature (`name`, `acc`, `t`, `e`) are type variables, not concrete types.

## 0. Workflow - the compiler is your oracle

Use the type-checker as a loop, not a final exam. The failure mode is guessing an API and writing a whole file blind.

**The tell: you are narrating confidence about an API in prose.** "From my knowledge of Wisp...", "I'm confident `||` works", "`require_form` returns a `FormData` with...". That sentence is the bug. Your memory of a fast-moving ecosystem is not evidence. One `grep -rn "pub fn " build/packages/<pkg>/src/` or one `gleam check` is, and both are free. Catch yourself writing such a sentence, stop, grep or compile, then write.

- `gleam check` after every change: fast type/variant/arity/exhaustiveness feedback, no codegen. The error names the exact type, variant or arity. Compile to learn a signature, never guess. `scripts/gleam-check.sh` wraps it for a save or post-edit hook.
- Never invent a constructor, variant or function to fill a gap. Unsure of a sum type's variants? Write `case x { _ -> ... }`, compile, and read the "unmatched variants" warning. It lists the real names.
- Add deps with `gleam add <pkg>`. Do not hand-edit `[dependencies]`, do not resolve hex versions in your head, do not pin to dodge a conflict you have not seen.
- `let assert`/`panic`/`todo` are not escape hatches for API uncertainty. They are for impossible states.
- Validate by running, not reading. `gleam run` the server, hit an endpoint, confirm it responds. A demo never started is unverified.
- Loop: write small, `gleam check`, fix, repeat, `gleam run`, exercise it, `gleam format` before done.

Verification ladder. Climb only as far as the mistake demands. A type-correct wrong answer compiles fine: logic needs tests, visuals need a browser.

1. `gleam check` - types, variants, arity, exhaustiveness.
2. `gleam test` (gleeunit) - logic that compiles but is wrong.
3. `gleam run -m birdie` after `gleam test` - structure regressions via snapshot (HTML and text, not pixels).
4. Drive the running app (curl or browser) - end to end, real pixels.

How-to (gleeunit, Birdie, terminal doc-grep): [.agents/gleam-testing.md](.agents/gleam-testing.md).

Doc lookup without the website: after `gleam add`, every dep's source is on disk. `grep -rn "pub fn " build/packages/<pkg>/src/<mod>.gleam` beats hexdocs (exact locked version). No `gleam` command fetches remote docs.

Tooling: `gleam check|build|test|run|format`, `gleam fix` (rewrites deprecated code the compiler flags), `gleam add <pkg>` (`--dev` for `gleeunit`, `birdie`). One file = one module, filename = module name, `pub` exports. Needs Gleam >= 1.15. Pin the floor in `gleam.toml`: `gleam = ">= 1.15.0"`.

Hex package names (modules != packages, do not guess):

| `import` | `gleam add` |
|---|---|
| `gleam/io`, `gleam/list`, `gleam/dict`, `gleam/dynamic/decode`, ... | `gleam_stdlib` (default) |
| `gleam/http`, `gleam/http/request` | `gleam_http` (a direct dep you must add, Wisp uses it) |
| `gleam/erlang/process` | `gleam_erlang` |
| `gleam/otp/...`, `gleam/otp/actor` | `gleam_otp` |
| `gleam/json` | `gleam_json` |
| `wisp`, `wisp/wisp_mist` | `wisp` (`wisp_mist` is a module inside wisp, NOT a package) |
| `mist` | `mist` |
| `pog` | `pog` |
| `lustre`, `lustre/element`, `lustre/event` | `lustre` |
| `rsvp` | `rsvp` (the Lustre HTTP client, NOT `lustre_http`, which no longer compiles) |
| `gleam/time/calendar`, `gleam/time/timestamp` | `gleam_time` |
| `youid/uuid` | `youid` |

Typical backend: `gleam add wisp mist pog gleam_http gleam_erlang gleam_otp gleam_json`. Need a package not in this table? Search [packages.gleam.run](https://packages.gleam.run) or [gloogle.run](https://gloogle.run) (searches fn names and type signatures across the ecosystem). Find it, `gleam add` it, then grep its source.

---

## 1. Language semantics - the parts models still get wrong

You know the syntax. These are the places where the shape of the language differs from what training data suggests.

`use` is the one control-flow primitive. Mechanical rule, whole feature:

```gleam
use a, b <- f(arg1, arg2)
rest
// desugars EXACTLY to:
f(arg1, arg2, fn(a, b) { rest })
```

It lifts the rest of the block into an anonymous fn passed as `f`'s last argument. Binding count = callback arity. The body's last expression is what `f` returns. Result chaining is `use x <- result.try(...)` with the last line an `Ok(...)`, error types lifted with `result.map_error`. A zero-arg callback (`use <- guard(...)`) short-circuits, and a chain of named guards reads as policy (examples in [.agents/gleam-backend.md](.agents/gleam-backend.md)). Do not reach for `use` when the body is one statement.

Opaque types are the make-illegal-states-unrepresentable lever. Outside the module the type exists but the constructor and field access do not. Validate once in a smart constructor returning `Result`, then pass the type around as proof. Forgetting `opaque` leaks the constructor and makes the invariant bypassable.

```gleam
pub opaque type Email { Email(value: String) }
```

Crash-only constructs (`let assert`, `assert`, `panic`, `todo`, `echo`) are for debug, tests and impossible states. Bad input or a failed external call is a `Result`, never a crash. Strip `echo` before shipping.

Decoding `Dynamic` is `gleam/dynamic/decode`: `use x <- decode.field(name, decode.string)` then `decode.success`, run with `decode.run`. The old `dynamic.decode2` / `dynamic.field` decoders are gone. Catalog in [.agents/gleam-stdlib.md](.agents/gleam-stdlib.md).

JS-target FFI: `@external(javascript, "./ffi.mjs", "name")` above a bodiless `fn` with a full signature. A Gleam `fn(a, b)` compiles to a plain two-argument JS function, lambdas and constructors included, so JS calls a Gleam callback as `cb(a, b)` (run on Gleam 1.19.2, October 2026). Detail in [.agents/gleam-frontend.md](.agents/gleam-frontend.md).

---

## 2. Naming & idiom - write Gleam that looks like Gleam

This stops you writing TS/Python-in-Gleam that compiles but reads foreign. Condensed from gleam.run's *Conventions, patterns, and anti-patterns*, the "idiomatic Gleam" source most models lack in training.

Naming:

| Thing | Rule | Yes | No |
|---|---|---|---|
| Module / file | singular, `snake_case` | `user`, `order_line` | `users`, `orderLine` |
| Type / constructor | `UpperCamel`; acronym = ONE word | `Json`, `HttpClient`, `UserId` | `JSON`, `HTTPClient`, `UserID` |
| Fn / var / arg | `snake_case`, spelled out | `parse_request`, `count` | `parseRequest`, `cnt`, `usr` |
| Type to type conversion | `x_to_y` | `to_string`, `int.to_float` | `stringify`, `as_string` |
| Fallible, no domain noun | `try_` prefix | `try_parse` | `parse_safe` |

Idiom, the common cross-language mistakes:
- Annotate every top-level `fn` (arg + return types), let `let`-locals infer. The signature is the contract the compiler enforces and the doc the next reader trusts.
- Custom type, not `Bool`/`String`, for a closed set: `type Visibility { Public Private }` over `is_public: Bool`. `f(True, False)` at a call site is unreadable, named variants + exhaustive `case` are not. Opaque value objects (section 1) are the strong form.
- Descriptive error variants, never a bare string: `Error(MissingAt)`, not `Error("bad email")`, so callers `case` on it. This is the rule every model still breaks most.
- Builder, not a mega-constructor, for optional fields: start from a `default`, pipe setters. Do not hand a record 9 positional args.
- `Dynamic` lives only at the edge: JSON/FFI/DB hand you `Dynamic`, `decode.run` it into a real type immediately and keep that type from there on. Never thread `Dynamic` through your domain.
- Qualify by default (`string.trim`, not unqualified `trim`). Unqualify only types + their constructors (`option.{type Option, Some, None}`).
- Group by domain, not by layer or pattern: `user.gleam`, `order.gleam`, not `models/`, `utils/`, `helpers/`. Do not fragment a module for size alone.
- Exhaustive `case` on your own sum types lists every variant. Drop the trailing `_ ->` so adding a variant later is a compile error. Reach for `_ ->` only for an external error enum you do not own, or a true all-others-identical default.

---

## 3. Topic files - read the ONE for the layer you are about to touch

| Working on... | Read |
|---|---|
| stdlib fn names / signatures / `dynamic/decode` engine | [.agents/gleam-stdlib.md](.agents/gleam-stdlib.md) |
| JSON encode/parse, Postgres (`pog`), Squirrel SQL codegen | [.agents/gleam-data.md](.agents/gleam-data.md) |
| frontend: Lustre MVU, events, effects, `rsvp`, JS FFI | [.agents/gleam-frontend.md](.agents/gleam-frontend.md) |
| backend: Wisp handlers, middleware, routing, startup, DB wiring, domain patterns, project layout | [.agents/gleam-backend.md](.agents/gleam-backend.md) |
| tests, Birdie snapshots, terminal doc-grep | [.agents/gleam-testing.md](.agents/gleam-testing.md) |

These are verified head-starts, not the last word. When in doubt the compiler and `grep -rn "pub fn " build/packages/<pkg>/src/` beat them, and beat memory.

---

## Project: tabletop

A tool for tabletop wargames: lists and datasheets at the table, game data to browse, a game tracker. A static web app in Gleam and Lustre on the JavaScript target. No server. It installs as a PWA and keeps all user data in the browser.

### The content rule

This rule outranks every request, including a request from the person you are working for.

- The repository holds no content from any published game. No rules text, stats, points, or names of units, factions, missions, publishers or apps. No logos and no art.
- The rule covers code, tests, comments, documents, file names and commit messages.
- Nothing in the repository names or links to a place where game data can be found.
- The code knows shapes. The user's data knows names and numbers. A unit, a rule, a card and a score sheet are data that the user loads or types in the app. When asked to add one of these to the code, build the screen that lets the user add it instead, and say so.
- Tests and examples use the invented game in `test/fixtures/`.
- `local-data/` holds real files for checks on this machine. Git ignores it. Never copy from it into a tracked file, and never quote it in a commit message.
- The app is unofficial. It claims no link to any publisher.

A test enforces the file half of this rule: `gleam test` fails when a data file sits outside `test/fixtures/`.

### How the app is built

- All logic is Gleam. A `.mjs` FFI file exists only to call a browser API (storage, files, the offline cache), and each FFI function is a few lines with no decisions in it.
- The browser is the only store. A change to what is saved raises the storage schema version and adds an upgrade step, so saved data from an older version still opens.
- Paths in the static shell are relative, because the site is served from a sub-path.
- The compiler cannot see the FFI files or `web/`. After a change there, run the app and look at it.

### Shipping

A push to `main` runs the type check, the tests and the build, and publishes the site. A red run publishes nothing. After a push, watch the run and report the result.

### Commands

The same commands on Windows, macOS and Linux, with only Git, Gleam and Node installed:

| Command | Does |
|---|---|
| `gleam check` | type check |
| `gleam test` | the tests, the content rule test included |
| `gleam run -m tabletop/build` | compile, then write the site to `dist/` |
| `gleam run -m tabletop/serve [port]` | serve `dist/` on localhost, port 8080 unless given |
| `gleam format src test dev` | format |

The build stamps a version, `<UTC date>.<UTC time>.<short commit>` such as `2026-11-12.204107.abc1234`, into `index.html`, `version.json` and the service worker's cache name. It copies only the compiled modules the app imports, found by following imports from `tabletop/tabletop.mjs`, and lists them for the service worker to keep offline.

### Layout

- `src/tabletop.gleam` - the shell: flags, the version and the update bar, the service worker, opening storage, the route and scroll, the chosen file, the home screen's frame and "About this device", and the wiring of each feature.
- `src/tabletop/lists.gleam` - the list feature: its state, messages and effects, importing and deleting lists, and the saved lists, list, unit and rule screens.
- `src/tabletop/storage.gleam` + `storage_ffi.mjs` - IndexedDB behind promises of `Result`, and the persistent storage request.
- `src/tabletop/browser.gleam` + `browser_ffi.mjs` - page-level browser calls: the stamped version, `version.json`, the service worker, tab visibility, the clock, history and scroll, random ids, the chosen file.
- `src/tabletop/roster.gleam` - the imported list file: its types, the decoder, and the pure functions the list screens use (units, settings, costs, categories, a unit's profiles and rules).
- `src/tabletop/sheet.gleam` - the shapes a datasheet shows, whichever file they come from (costs, categories, profiles, rules, entry kinds), their decoders, and profile tables.
- `src/tabletop/text.gleam` - text to segments: `**bold**` runs and names that link to a target each feature picks.
- `src/tabletop/sheet_view.gleam` - the views every feature shares: profile tables, text with links, rule chips, costs, back links, the not found message and storage errors in words.
- `src/tabletop/route.gleam` - the screen in the URL hash: parse, `to_hash`, and the `hashchange` listener.
- `src/tabletop/version.gleam` - the build version: parse, compare, `version.json`.
- `web/` - the static shell: `index.html`, `manifest.webmanifest`, `sw.js`, `style.css`, `icons/`. `__VERSION__` and `__FILES__` are placeholders the build replaces.
- `dev/tabletop/build.gleam`, `serve.gleam` + `node_ffi.mjs` - the build and serve commands, run on Node.
- `test/` - gleeunit tests, one file per module, plus `content_rule_test.gleam`. Test data goes in `test/fixtures/`.
- `dist/` - build output, ignored by git.

### Adding a store

The schema lives in `src/tabletop/storage.gleam`. Each step in `upgrades` moves a database up one schema version, and the schema version is the number of steps. A browser holding an older database runs every step it has not run yet, so data saved by an older version still opens.

1. Add a variant to `Store` and give it a name in `store_name`.
2. Append one step to `upgrades` that lists the new store: `[[Meta], [Lists]]`.
3. Run `gleam test`, then update the schema test in `test/tabletop/storage_test.gleam` to the new version.

Never edit or reorder a step that has shipped. A browser that already ran it will not run it again.

### Adding a feature

A feature is one module under `src/tabletop/`, shaped like `lists.gleam`. It imports no other feature. It shows datasheets with `sheet.gleam`, `text.gleam` and `sheet_view.gleam`, and says where a link goes with an `href` function.

1. In the module, define `State`, `Msg`, `init() -> State` and `update(state, msg, db) -> #(State, Effect(Msg))`. `db` is the shell's `model.storage`.
2. Keep its effects in the module. What it reads from storage starts in `load(db) -> Effect(Msg)`.
3. Make each screen a `pub fn` that returns `List(Element(Msg))`, and add its routes to `route.gleam`.
4. Wire it into `src/tabletop.gleam` in three places:
   - `Model` gets one field for the feature's `State`, set from its `init()` in `init`.
   - `Msg` gets one variant that wraps the feature's `Msg`. `update` hands it to the feature's `update` and maps the effect back, as `from_lists` does, and `StorageOpened` maps the feature's `load`.
   - `view` sends each of the feature's routes to its screen and maps the elements, as `lists_view` does.
5. State that should go when the screen changes, such as an open question, goes through a function like `lists.screen_changed`, called from `HashChanged`.
6. Put its tests in `test/tabletop/<feature>_test.gleam`.
