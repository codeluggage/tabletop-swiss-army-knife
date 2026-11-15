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
- A record that is made from other data holds a version and is built again from that data, never migrated.
- Paths in the static shell are relative, because the site is served from a sub-path.
- The compiler cannot see the FFI files or `web/`. After a change there, run the app and look at it.

### Shipping

`gleam run -m tabletop/publish` is the one way to the live site. A push to `main` runs the type check, the tests and the build in GitHub Actions. Before a deploy, Actions compares the new version with the live site and stops when the storage schema number is lower or the new version is not later. Before it sends, publish asks the live site only about the storage schema number, and sends nothing when the new one is lower. Whether the version is later is left to GitHub, because GitHub's own build stamps the version and the clock on this computer says nothing true about it. When the live version cannot be read, publish sends, and the check on GitHub decides. After a deploy, Actions tags the commit with the version. A failed check, test, build or live check publishes nothing. When the type check, the tests or the build fail on GitHub, publish runs them on this computer. When they pass there, it says to ask the person who helps with the project. When another step fails, the live check included, publish sends the same work once more as an empty commit with the message `publish again`, and when that fails too, it says to ask the person who helps with the project. When only the tag fails, the site is already live: publish says so in the line before its last two, and the versions command does not list that version.

### Working with the person

The person you work for plays tabletop games and is not a developer. They write to you in everyday words, often from a phone. They see the result in the app on their phone. `START-HERE.md` is their guide.

#### What a request means

- A request for a change means: make the change and make it live. Do not ask whether to publish.
- "What do you think?", "how would you do it?" or "show me an idea" means: answer in words. Change nothing.
- "Put it back", "undo that" or "the way it was in 1542" means: bring the old behaviour back as a new change, and make it live. See "Undo" below.

#### Make a change live

1. Work in this folder, on the branch `main`. One folder, one branch, one site. The person has no local preview, so the live site is where they look.
2. Start with `git pull --no-rebase origin main`, so you have the newest files.
3. Say in one or two plain sentences what you will change. Then make that one change.
4. After you edit a `.gleam` file, run `gleam check` and fix every error.
5. Run `gleam format src test dev`. Commit with a short lowercase message that names nothing from a game.
6. Run `gleam run -m tabletop/publish`. It checks the code, publishes it, and waits until the site is live.
7. If publish stops, read its last lines. Fix what they name, commit, and run publish again. If the lines say to ask the person who helps with the project, tell the person exactly that and stop.
8. If publish was cut off before it printed its last two lines, run `gleam run -m tabletop/publish` again. With nothing new to send, it picks up the wait where it was.
9. Reply with the last two lines that publish printed, and one sentence that says where in the app to look. When the line before them says to tell the person who helps with the project, say that too.

`gleam run -m tabletop/publish` is the only way you publish. Do not run `git push` yourself.

#### Versions

- The app shows its version at the top of every screen, like `2026.11.13.1542`. It is the date and the time of publishing, on the UK clock.
- The person names a version by its last four digits. "I'm on 1542" means the version that ends in `1542`.
- To find a version, run `gleam run -m tabletop/versions 1542`. It prints the versions that match and what changed in each.
- When the person names a time in words, such as "an hour ago" or "before dinner", run `gleam run -m tabletop/versions`, show the newest five with what changed, and ask which one they mean.
- The build makes each version. You read it from the output of publish. You do not write one.

#### Undo

1. Find the version the person means with the versions command.
2. Find the commits that made the change, with `git log`.
3. Run `git revert --no-edit <commit>` on those commits, newest first. Skip a commit whose message starts with "Merge", and never revert it. Skip a commit named `publish again` the same way: it is empty, and `git revert` stops on it. Then follow "Make a change live" from step 4.
4. Leave `upgrades` in `src/tabletop/storage.gleam` as it is, even when the change you undo added a store. Remove the screens and keep the store. A phone that already has the store cannot open an app that has fewer.

#### Wrap up and hand off

Each reply in a thread sends the whole thread to the model again. So a long thread uses up the person's plan faster than a new thread that starts from a short note.

When the person says "wrap up", "hand off" or "let's stop":

1. First, reply with what was left unsaid, as a short list in plain words. Look for: something you assumed and did not check, a step you skipped, something that may look wrong in the app, a request you did only in part, and what you would do differently now. When there is nothing, say "Nothing left unsaid."
2. Then write `handoff.md` in this folder, over the old one. It is for the next thread, not for the person. Write the date, the live version, what the person asked for, what is done, what is not done and why, and the one next step. Keep it under 30 lines. Git ignores this file, so do not commit it.
3. End with one sentence: the person can start a new thread now, and the new thread reads the handoff by itself.

After the third change in one thread, end your reply with one sentence that offers a wrap-up and a new thread.

At the start of a thread, if `handoff.md` exists, read it before you act. It can be old: run `gleam run -m tabletop/versions` and compare the newest version with the one in the handoff. What the person asks now comes before anything in the handoff.

#### Always

- When a request would put game content into the code (rules text, stats, points, names), build the screen where the person adds it themselves, and say why in one sentence.
- Leave `.codex/` alone. A change there turns the checks off until the person trusts the hooks again.
- Use plain words in every reply. Show code only when the person asks for it.
- When a command asks for a permission or a login, tell the person in one sentence what to tap or type.

### Commands

The same commands on Windows, macOS and Linux, with only Git, Gleam and Node installed:

| Command | Does |
|---|---|
| `gleam check` | type check |
| `gleam test` | the tests, the content rule test included |
| `gleam run -m tabletop/build` | compile, then write the site to `dist/` |
| `gleam run -m tabletop/serve [port]` | serve `dist/` on localhost, port 8080 unless given |
| `gleam format src test dev` | format |
| `gleam run -m tabletop/publish` | take the saved work on `main` to the live site, wait until it is live, and print which version is live |
| `gleam run -m tabletop/versions [digits]` | the ten newest versions that went live, each with the first line of its newest commit that is not a merge or a `publish again`; with digits, only the ones that match, such as `1542` |
| `gleam run -m tabletop/live_check` | after a build: may `dist/` replace the live site? Exits 1 with the reason when it may not |

The build stamps a version, the minute of the build on the London clock such as `2026.11.13.1542`, into `index.html`, `version.json` and the service worker's cache name, and the short commit into `index.html`. The app shows the version at the top of every screen, and the commit in "About this device". `version.json` holds `release` (the version), `commit`, `schema` (the storage schema version) and `version`. `version` is the old stamp, `<UTC date>.<UTC time>.<short commit>` such as `2026-11-13.154207.776d09c`. It stays because an app installed before versions reads only that key to offer its Reload bar. No new code reads it. The build copies only the compiled modules the app imports, found by following imports from `tabletop/tabletop.mjs`, and lists them for the service worker to keep offline.

### Layout

- `src/tabletop.gleam` - the shell: flags, the version line at the top of every screen and the update bar, the service worker, opening storage, the route and scroll, the chosen file and which feature gets it by its kind (a zip, a backup file, other text), the home screen's frame and "About this device", and the wiring of each feature, the list screens' links into game data and their cards included, the cards on the data set and node screens, the list names for a new game and the way back to a game on a list's screen, and every feature reading its stores again after a restore.
- `src/tabletop/lists.gleam` - the list feature: its state, messages and effects, importing and deleting lists, and the saved lists, list, unit and rule screens.
- `src/tabletop/data.gleam` - the game data feature: its state, messages and effects, importing a zip one file at a time, building an older index again, opening a catalogue's scope, deleting a data set, the data set, catalogue and node screens with a place for the cards, and the links from a list into the data.
- `src/tabletop/cards.gleam` - the cards feature: its state, messages and effects, the card form, importing cards from a table file, deleting a card, which cards show for a place, a list and a unit, and the card screens and sections.
- `src/tabletop/tracker.gleam` - the game tracker: its state, messages and effects, every change saved at once, the "Games" section of the home screen, the score sheets and sheet screens with removing that asks first, the new game screen, the game screen with its round bar and an ended game read-only until Edit, and all games with deleting that asks first.
- `src/tabletop/score.gleam` - a score sheet and a game kept on one: the shapes, the scoring (each item, a round, the total, a counter's amount left, the result), the changes the sheet editor and the game screen make as plain functions, and their JSON. A game holds its own copy of its sheet.
- `src/tabletop/backup.gleam` - the backup feature: `kind`, which says for each store whether a backup holds it, the backup file written and read (JSON records as JSON, bytes as base64), what a backup holds in words, the "Backup" section of the home screen with the last backup's date, and the question before a restore: it reads which keys of the file are already on this device, and when some are it asks whether to add only what is missing or replace them with the copies in the file, then writes in one `storage.write`.
- `src/tabletop/table.gleam` - the text of a table file as rows of cells: tabs, commas, semicolons or pipes, whichever the first line holds most, quoted cells as in RFC 4180.
- `src/tabletop/effects.gleam` - effects the shell and the features share: a promise's value as a message.
- `src/tabletop/storage.gleam` + `storage_ffi.mjs` - IndexedDB behind promises of `Result`: JSON and bytes, every record of a store as it is stored, the keys of a store, many writes in one transaction, and the persistent storage request.
- `src/tabletop/browser.gleam` + `browser_ffi.mjs` - page-level browser calls: the stamped version and commit, `version.json`, the service worker, tab visibility, the clock, history and scroll, random ids, the chosen file's name and bytes, a file to download, and Windows-1252 bytes as text.
- `src/tabletop/roster.gleam` - the imported list file: its types, the decoder, and the pure functions the list screens use (units, settings, costs, categories, a unit's profiles and rules).
- `src/tabletop/sheet.gleam` - the shapes a datasheet shows, whichever file they come from (costs, categories, profiles, rules, entry kinds), their decoders, and profile tables.
- `src/tabletop/text.gleam` - text to segments: `**bold**` runs and names that link to a target each feature picks.
- `src/tabletop/zip.gleam` - a zip from its bytes: the entries in its central directory, and one entry's bytes as the zip stores them.
- `src/tabletop/bytes.gleam` + `bytes_ffi.mjs` - one zip entry unpacked to its bytes, inflated by the platform.
- `src/tabletop/catalogue.gleam` - one game data file, the game system or a catalogue: its nodes and modifiers, the full decoder, and the shallow read the import uses.
- `src/tabletop/data_index.gleam` - what the app keeps about a data set: a summary per file and its JSON, and the roots, grouping, search and scope files of a catalogue.
- `src/tabletop/scope.gleam` - the decoded files one catalogue reaches: every node by id, what is hidden when nothing is chosen, and the page of a node as data.
- `src/tabletop/sheet_view.gleam` - the views every feature shares: profile tables, text with links, rule chips, costs, back links, the not found message and storage errors in words.
- `src/tabletop/route.gleam` - the screen in the URL hash: parse, `to_hash`, going to a screen, and the `hashchange` listener, and the place a card belongs to.
- `src/tabletop/version.gleam` - the version a person can say: parse, compare, and `version.json` written and read.
- `web/` - the static shell: `index.html`, `manifest.webmanifest`, `sw.js`, `style.css`, `icons/`. `__VERSION__` and `__FILES__` are placeholders the build replaces.
- `dev/tabletop/build.gleam`, `serve.gleam` + `node_ffi.mjs` - the build and serve commands, run on Node.
- `dev/tabletop/publish.gleam` - the publish command: take in GitHub's `main`, run the checks and the build, ask the live site whether the storage schema number is lower, push, and wait for the deploy run. After a failed run, run the checks here or send the same work once more. Then wait until the live `version.json` shows the commit, and look for its version tag. With nothing to send, it only waits. It asks GitHub through `gh`, and directly when `gh` fails for any reason. Every message it prints is in `say`.
- `dev/tabletop/versions.gleam` - the versions command: the version tags, each with the first line of the newest commit under it that is not a merge or a `publish again`, and which ones match the digits a person says.
- `dev/tabletop/live_check.gleam` - the live check: may the version in `dist/version.json` replace the live one.
- `dev/tabletop/site.gleam` - the GitHub repository from the `origin` remote, the live site's address, and the live `version.json`.
- `.github/workflows/deploy.yml` - on a push to `main`: check, test, build, live check, deploy to GitHub Pages, then tag the commit with its version. A pull request runs only the check and the tests.
- `test/` - gleeunit tests, one file per module, plus `content_rule_test.gleam`. Test data goes in `test/fixtures/`.
- `test/tabletop/zip_writer.gleam` + `zip_writer_ffi.mjs` - writes the zips the tests read. `data_set_test.gleam` goes from a zip to pages on `test/fixtures/data/`, and on `local-data/` when it is there.
- `dist/` - build output, ignored by git.
- `.codex/hooks.json` + `hooks/` - Codex hooks: `gleam check` after each edit, and check, test and format before the agent finishes. Each hook has a `.sh` for macOS and Linux and a `.ps1` for Windows.
- `START-HERE.md` - the person's guide to changing the app with Codex on Windows.
- `LICENSE` - the GNU General Public License, version 3. The app is under version 3 or later.

### Adding a store

The schema lives in `src/tabletop/storage.gleam`. Each step in `upgrades` moves a database up one schema version, and the schema version is the number of steps. A browser holding an older database runs every step it has not run yet, so data saved by an older version still opens.

1. Add a variant to `Store` and give it a name in `store_name`.
2. Append one step to `upgrades` that lists the new store: `[[Meta], [Lists]]`.
3. Say whether the new store goes into a backup in `kind` in `src/tabletop/backup.gleam`: `Source` when it holds what the person loaded or typed, `Made` when the app builds it again from a source store, or `SomeKeys` with the keys that go when the rest belong to the device. The app does not compile until you do.
4. Run `gleam test`, then update the schema test in `test/tabletop/storage_test.gleam` to the new version.

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
