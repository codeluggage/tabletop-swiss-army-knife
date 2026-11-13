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

Build before you serve. After a change, build again and reload the page; the
app shows "New version - Reload" when the new build is ready.
