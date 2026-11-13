# Tabletop

A tool for tabletop wargames that runs in your browser. Install it to your
phone or computer from the browser menu and it works offline. There is no
server: everything you save stays in your browser on that device.

Tabletop is unofficial. It is not made, endorsed or supported by any game
publisher, and it is tied to none.

It ships with no game data. Each person loads their own. Game data comes in as
one zip file of data files that you bring yourself.

## Change it with Codex

To change the app by talking to Codex on Windows, with no programming, read
[START-HERE.md](START-HERE.md).

## Run it yourself

You need Git, [Gleam](https://gleam.run) and [Node.js](https://nodejs.org).
The same commands work on Windows, macOS and Linux.

```sh
gleam check                    # type check
gleam test                     # run the tests
gleam run -m tabletop/build    # build the site into dist/
gleam run -m tabletop/serve    # serve dist/ at http://localhost:8080/
gleam run -m tabletop/serve 9000   # or on another port
```

Build before you serve. After a change, build again and reload the page. A
build from a later minute shows a "New version" bar with a Reload button.

## Versions

A version is the minute it was built, on the UK clock, such as
`2026.11.13.1542`. The app shows it at the top of every screen.

## Publish

```sh
gleam run -m tabletop/publish        # checks, sends main to GitHub, waits until the site is live
gleam run -m tabletop/versions       # the versions that went live, newest first
gleam run -m tabletop/versions 1542  # the versions that match 1542
gleam run -m tabletop/live_check     # after a build: may dist/ replace the live site?
```

A push to `main` checks, tests and builds the site on GitHub, then publishes
it to GitHub Pages and tags the commit with its version. A version that is not
later than the live one, or that saves data in an older layout, does not go
live.

## Licence

Tabletop is free software under the GNU General Public License, version 3 or
later. Copyright 2026 the Tabletop contributors. The full text is in
[LICENSE](LICENSE).

Anyone may use, change and share it. Whoever shares a changed version shares
its source under the same licence and keeps the credit.

The packages it builds on are under the Apache 2.0 and MIT licences.
