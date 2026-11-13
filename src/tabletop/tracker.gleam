//// The game tracker: score sheets the person sets up, and games kept on them
//// round by round for two players. Every change is saved at once, the round
//// on screen included, so a reload shows the same round and numbers. The
//// shapes and the scoring are in `tabletop/score`.
//// The shell in `tabletop.gleam` holds its `State`, wraps its `Msg`, sends it
//// the sheet and game routes, puts its "Games" section on the home screen,
//// hands the new game screen the person's lists, and puts its way back to a
//// game on a list's screen. It never sees the lists feature.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import tabletop/browser
import tabletop/effects
import tabletop/route.{type Route}
import tabletop/score.{
  type Edit, type Game, type Item, type Part, type Play, type Player, type Sheet,
  Count, Counters, Free, Gained, Items, One, Results, Scored, Spent, Toggle, Two,
}
import tabletop/sheet_view
import tabletop/storage.{type Database, type StorageError}

pub type State {
  State(
    /// `None` until the saved sheets are read.
    sheets: Option(Result(List(Sheet), StorageError)),
    /// `None` until the saved games are read.
    games: Option(Result(List(Game), StorageError)),
    problem: Option(Problem),
    /// What waits for Yes or No.
    confirming: Option(Confirm),
    /// The id of the ended game that Edit opened again.
    editing: Option(String),
  )
}

pub type Confirm {
  RemoveFromSheet(sheet_id: String, part: Part, index: Int)
  DeleteGame(game_id: String)
}

/// What went wrong with the last change.
pub type Problem {
  NotSaved(StorageError)
  NotDeleted(StorageError)
  NoStorage
  NoSheet
}

pub type Msg {
  SheetsLoaded(Result(List(Sheet), StorageError))
  GamesLoaded(Result(List(Game), StorageError))
  NewSheetClicked
  /// The simple start's fields by name.
  SimpleSubmitted(fields: List(#(String, String)))
  Edited(sheet_id: String, edit: Edit)
  RemoveClicked(sheet_id: String, part: Part, index: Int)
  DeleteClicked(game_id: String)
  Confirmed
  NotConfirmed
  /// The new game form's fields by name, with the lists it offered.
  StartSubmitted(
    lists: List(#(String, String)),
    fields: List(#(String, String)),
  )
  Played(game_id: String, play: Play)
  EndClicked(game_id: String)
  EditClicked(game_id: String)
  Saved(Result(Nil, StorageError))
  GameDeleted(game_id: String, result: Result(Nil, StorageError))
}

/// The rounds of a new sheet, until he changes them.
const default_rounds = 5

pub fn init() -> State {
  State(
    sheets: None,
    games: None,
    problem: None,
    confirming: None,
    editing: None,
  )
}

/// Read the saved sheets and games once storage has answered. When storage
/// did not open, they show why.
pub fn load(db: Result(Database, StorageError)) -> Effect(Msg) {
  case db {
    Ok(db) ->
      effect.batch([
        effects.from_promise(
          fn() { load_all(db, storage.Sheets, score.sheet_decoder()) },
          SheetsLoaded,
        ),
        effects.from_promise(
          fn() { load_all(db, storage.Games, score.game_decoder()) },
          GamesLoaded,
        ),
      ])
    Error(error) -> {
      use dispatch <- effect.from
      dispatch(SheetsLoaded(Error(error)))
      dispatch(GamesLoaded(Error(error)))
    }
  }
}

/// `db` is the open database or the reason it is not open, and `None` while
/// it opens. A change shows at once, and is saved when storage is open.
pub fn update(
  state: State,
  msg: Msg,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case msg {
    SheetsLoaded(sheets) -> #(
      State(..state, sheets: Some(sheets)),
      effect.none(),
    )
    GamesLoaded(games) -> #(State(..state, games: Some(games)), effect.none())
    NewSheetClicked -> {
      let sheet =
        score.Sheet(
          id: browser.random_id(),
          name: "New sheet",
          rounds: default_rounds,
          ask_first: False,
          counters: [],
          items: [],
          results: [],
        )
      put_sheet(state, sheet, db) |> then_go(route.SheetPage(sheet.id))
    }
    SimpleSubmitted(fields:) -> {
      let name = case field(fields, "name") {
        "" -> "Simple sheet"
        name -> name
      }
      let rounds = int.parse(field(fields, "rounds")) |> result.unwrap(1)
      let sheet =
        score.simple(browser.random_id(), name, rounds, browser.random_id())
      put_sheet(state, sheet, db) |> then_go(route.SheetPage(sheet.id))
    }
    Edited(sheet_id:, edit:) ->
      case list.find(saved_sheets(state), fn(sheet) { sheet.id == sheet_id }) {
        // A change moves places, so an open question about one goes.
        Ok(sheet) ->
          State(..state, confirming: None)
          |> put_sheet(score.edit(sheet, edit, browser.random_id), db)
        Error(Nil) -> #(state, effect.none())
      }
    RemoveClicked(sheet_id:, part:, index:) -> #(
      State(
        ..state,
        confirming: Some(RemoveFromSheet(sheet_id, part, index)),
        problem: None,
      ),
      effect.none(),
    )
    DeleteClicked(game_id:) -> #(
      State(..state, confirming: Some(DeleteGame(game_id)), problem: None),
      effect.none(),
    )
    NotConfirmed -> #(State(..state, confirming: None), effect.none())
    Confirmed ->
      case state.confirming, db {
        Some(RemoveFromSheet(sheet_id:, part:, index:)), _ ->
          update(
            State(..state, confirming: None),
            Edited(sheet_id, score.Remove(part, index)),
            db,
          )
        Some(DeleteGame(game_id:)), Some(Ok(db)) -> #(
          state,
          effects.from_promise(
            fn() { storage.delete(db, storage.Games, game_id) },
            GameDeleted(game_id, _),
          ),
        )
        Some(DeleteGame(..)), _ -> #(
          State(..state, confirming: None, problem: Some(NoStorage)),
          effect.none(),
        )
        None, _ -> #(state, effect.none())
      }
    StartSubmitted(lists:, fields:) -> {
      let chosen = field(fields, "sheet")
      case list.find(saved_sheets(state), fn(sheet) { sheet.id == chosen }) {
        Error(Nil) -> #(State(..state, problem: Some(NoSheet)), effect.none())
        Ok(sheet) -> {
          let name = fn(key, otherwise) {
            case field(fields, key) {
              "" -> otherwise
              name -> name
            }
          }
          let picked =
            list.find(lists, fn(found) { found.0 == field(fields, "list") })
            |> option.from_result
          let game =
            score.start(
              id: browser.random_id(),
              sheet:,
              started: browser.now_ms(),
              players: #(name("first", "Player 1"), name("second", "Player 2")),
              list: picked,
            )
          put_game(state, game, db) |> then_go(route.GamePage(game.id))
        }
      }
    }
    Played(game_id:, play:) ->
      case find_game(state, game_id) {
        Ok(game) -> put_game(state, score.play(game, play), db)
        Error(Nil) -> #(state, effect.none())
      }
    EndClicked(game_id:) ->
      update(
        State(..state, editing: None),
        Played(game_id, score.End(browser.now_ms())),
        db,
      )
    EditClicked(game_id:) -> #(
      State(..state, editing: Some(game_id)),
      effect.none(),
    )
    // Each save writes the whole record, so one that works after one that
    // failed has saved everything.
    Saved(Ok(Nil)) ->
      case state.problem {
        Some(NotSaved(_)) -> #(State(..state, problem: None), effect.none())
        _ -> #(state, effect.none())
      }
    Saved(Error(error)) -> #(
      State(..state, problem: Some(NotSaved(error))),
      effect.none(),
    )
    GameDeleted(game_id:, result: Ok(Nil)) -> {
      let games =
        list.filter(saved_games(state), fn(game) { game.id != game_id })
      #(State(..state, confirming: None, games: Some(Ok(games))), effect.none())
    }
    GameDeleted(result: Error(error), ..) -> #(
      State(..state, confirming: None, problem: Some(NotDeleted(error))),
      effect.none(),
    )
  }
}

/// The screen changed: the last problem, an open question and an ended
/// game's Edit go.
pub fn screen_changed(state: State) -> State {
  State(..state, problem: None, confirming: None, editing: None)
}

fn field(fields: List(#(String, String)), key: String) -> String {
  list.key_find(fields, key) |> result.unwrap("") |> string.trim
}

fn then_go(step: #(State, Effect(Msg)), to: Route) -> #(State, Effect(Msg)) {
  #(
    step.0,
    effect.batch([
      step.1,
      {
        use _ <- effect.from
        route.go(to)
      },
    ]),
  )
}

fn saved_sheets(state: State) -> List(Sheet) {
  case state.sheets {
    Some(Ok(sheets)) -> sheets
    Some(Error(_)) | None -> []
  }
}

fn saved_games(state: State) -> List(Game) {
  case state.games {
    Some(Ok(games)) -> games
    Some(Error(_)) | None -> []
  }
}

fn find_game(state: State, game_id: String) -> Result(Game, Nil) {
  list.find(saved_games(state), fn(game) { game.id == game_id })
}

// --- Storage ----------------------------------------------------------------

fn put_sheet(
  state: State,
  sheet: Sheet,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  let others =
    list.filter(saved_sheets(state), fn(other) { other.id != sheet.id })
  State(..state, sheets: Some(Ok([sheet, ..others])))
  |> save(db, storage.Sheets, sheet.id, score.encode_sheet(sheet))
}

fn put_game(
  state: State,
  game: Game,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  let others =
    list.filter(saved_games(state), fn(other) { other.id != game.id })
  State(..state, games: Some(Ok([game, ..others])))
  |> save(db, storage.Games, game.id, score.encode_game(game))
}

fn save(
  state: State,
  db: Option(Result(Database, StorageError)),
  store: storage.Store,
  key: String,
  value: json.Json,
) -> #(State, Effect(Msg)) {
  case db {
    Some(Ok(db)) -> #(
      state,
      effects.from_promise(fn() { storage.put(db, store, key, value) }, Saved),
    )
    Some(Error(_)) | None -> #(
      State(..state, problem: Some(NoStorage)),
      effect.none(),
    )
  }
}

// ponytail: a record that no longer decodes is left out and stays saved.
// Show it as unreadable, as the lists do, if the format ever changes.
fn load_all(
  db: Database,
  store: storage.Store,
  decoder: decode.Decoder(a),
) -> Promise(Result(List(a), StorageError)) {
  use records <- promise.map(storage.get_all(db, store, decoder))
  use records <- result.map(records)
  list.filter_map(records, fn(record) { result.replace_error(record.1, Nil) })
}

// --- Home -------------------------------------------------------------------

/// The newest game that has not ended.
fn in_progress(state: State) -> Result(Game, Nil) {
  newest_first(saved_games(state))
  |> list.find(fn(game) { game.ended == None })
}

fn newest_first(games: List(Game)) -> List(Game) {
  list.sort(games, fn(a, b) { int.compare(b.started, a.started) })
}

/// The "Games" section of the home screen: New game, the game in progress,
/// and the links to every game and to the score sheets.
pub fn home(state: State) -> List(Element(Msg)) {
  [
    html.section([], [
      html.h2([], [html.text("Games")]),
      link_button(route.NewGamePage, "button big", "New game"),
      games_status(state),
      case in_progress(state) {
        Ok(game) ->
          html.ul([attribute.class("rows")], [
            html.li([], [game_link(game)]),
          ])
        Error(Nil) -> element.none()
      },
      html.div([attribute.class("actions")], [
        link_button(route.GamesPage, "button", "All games"),
        link_button(route.SheetsPage, "button", "Score sheets"),
      ]),
    ]),
  ]
}

/// On a list's screen, the way back to the game in progress that picked the
/// list. Nothing when there is none.
pub fn back_to_game(state: State, list_id: String) -> List(Element(Msg)) {
  case
    list.find(newest_first(saved_games(state)), fn(game) {
      game.ended == None
      && option.map(game.list, fn(picked) { picked.0 }) == Some(list_id)
    })
  {
    Ok(game) -> [
      sheet_view.back_link(route.GamePage(game.id), "Back to the game"),
    ]
    Error(Nil) -> []
  }
}

fn link_button(to: Route, class: String, label: String) -> Element(msg) {
  html.a([attribute.class(class), attribute.href(route.to_hash(to))], [
    html.text(label),
  ])
}

/// A game as a row: the names, the totals and the result, then where it is.
fn game_link(game: Game) -> Element(msg) {
  let where = case game.ended {
    None ->
      "Round "
      <> int.to_string(game.round)
      <> " of "
      <> int.to_string(game.sheet.rounds)
      <> ". So far "
      <> score.result(game)
    Some(_) -> score.result(game)
  }
  html.a(
    [
      attribute.class("row-link"),
      attribute.href(route.to_hash(route.GamePage(game.id))),
    ],
    [
      html.span([attribute.class("name")], [
        html.text(
          game.players.0
          <> " "
          <> int.to_string(score.total(game, One))
          <> " – "
          <> int.to_string(score.total(game, Two))
          <> " "
          <> game.players.1,
        ),
      ]),
      sheet_view.meta(where),
      sheet_view.meta(
        sheet_name(game.sheet) <> ", " <> browser.local_time(game.started),
      ),
    ],
  )
}

fn sheet_name(sheet: Sheet) -> String {
  case string.trim(sheet.name) {
    "" -> "Untitled sheet"
    name -> name
  }
}

// --- All games --------------------------------------------------------------

/// Every game, newest first, each with Delete.
pub fn games_page(state: State) -> List(Element(Msg)) {
  [
    sheet_view.back_link(route.Home, "Home"),
    html.h1([], [html.text("All games")]),
    games_status(state),
    case state.games {
      Some(Ok([])) -> note("No games yet.")
      Some(Ok(games)) ->
        html.ul(
          [attribute.class("rows")],
          list.map(newest_first(games), fn(game) {
            html.li([attribute.class("saved")], [
              game_link(game),
              ask(
                "Delete this game?",
                "Delete",
                state.confirming == Some(DeleteGame(game.id)),
                DeleteClicked(game.id),
              ),
            ])
          }),
        )
      Some(Error(_)) | None -> element.none()
    },
    problem_view(state),
  ]
}

fn games_status(state: State) -> Element(msg) {
  case state.games {
    None -> note("Opening the games…")
    Some(Error(error)) ->
      note(
        "The saved games could not be read. "
        <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(_)) -> element.none()
  }
}

/// A button that asks first, in the page: `question` with Yes and No once
/// it was pressed.
fn ask(
  question: String,
  label: String,
  asking: Bool,
  clicked: Msg,
) -> Element(Msg) {
  case asking {
    False -> button(label, "button quiet", clicked)
    True ->
      html.div([attribute.class("confirm"), attribute.role("group")], [
        html.span([], [html.text(question)]),
        button("Yes", "button danger", Confirmed),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button"),
            attribute.autofocus(True),
            event.on_click(NotConfirmed),
          ],
          [html.text("No")],
        ),
      ])
  }
}

fn button(label: String, class: String, clicked: msg) -> Element(msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      event.on_click(clicked),
    ],
    [html.text(label)],
  )
}

// --- Score sheets -----------------------------------------------------------

/// The score sheets, "New sheet", and the simple start.
pub fn sheets_page(state: State) -> List(Element(Msg)) {
  [
    sheet_view.back_link(route.Home, "Home"),
    html.h1([], [html.text("Score sheets")]),
    case state.sheets {
      None -> note("Opening the score sheets…")
      Some(Error(error)) ->
        note(
          "The saved score sheets could not be read. "
          <> sheet_view.describe_storage_error(error),
        )
      Some(Ok([])) ->
        note(
          "No score sheets yet. A score sheet says what a game counts and what scores points.",
        )
      Some(Ok(sheets)) ->
        html.ul(
          [attribute.class("rows")],
          list.sort(sheets, fn(a, b) { string.compare(a.name, b.name) })
            |> list.map(fn(sheet) {
              html.li([], [
                html.a(
                  [
                    attribute.class("row-link"),
                    attribute.href(route.to_hash(route.SheetPage(sheet.id))),
                  ],
                  [
                    html.span([attribute.class("name")], [
                      html.text(sheet_name(sheet)),
                    ]),
                    sheet_view.meta(sheet_summary(sheet)),
                  ],
                ),
              ])
            }),
        )
    },
    problem_view(state),
    html.div([attribute.class("actions")], [
      button("New sheet", "button primary", NewSheetClicked),
    ]),
    html.section([], [
      html.h2([], [html.text("Start with a simple sheet")]),
      note(
        "A name, the number of rounds, and one score you type in each round. Change anything on its screen after.",
      ),
      html.form([event.on_submit(SimpleSubmitted)], [
        text_field("simple-name", "name", "Name", ""),
        html.div([attribute.class("field")], [
          html.label([attribute.for("simple-rounds")], [html.text("Rounds")]),
          html.input([
            attribute.type_("number"),
            attribute.id("simple-rounds"),
            attribute.name("rounds"),
            attribute.inputmode("numeric"),
            attribute.min("1"),
            attribute.default_value(int.to_string(default_rounds)),
          ]),
        ]),
        html.div([attribute.class("actions")], [
          html.button([attribute.type_("submit"), attribute.class("button")], [
            html.text("Start with a simple sheet"),
          ]),
        ]),
      ]),
    ]),
  ]
}

fn sheet_summary(sheet: Sheet) -> String {
  [
    count(sheet.rounds, "round", "rounds"),
    count(list.length(sheet.counters), "counter", "counters"),
    count(list.length(sheet.items), "scoring line", "scoring lines"),
  ]
  |> string.join(", ")
}

fn text_field(
  id: String,
  name: String,
  label: String,
  value: String,
) -> Element(msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.id(id),
      attribute.name(name),
      attribute.default_value(value),
      attribute.autocomplete("off"),
    ]),
  ])
}

/// One sheet's screen: every field, each saved when it changes.
pub fn sheet_page(state: State, sheet_id: String) -> List(Element(Msg)) {
  case state.sheets {
    None -> [note("Opening…")]
    Some(Error(error)) ->
      not_found(
        route.SheetsPage,
        "The saved score sheets could not be read. "
          <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(sheets)) ->
      case list.find(sheets, fn(sheet) { sheet.id == sheet_id }) {
        Error(Nil) ->
          not_found(route.SheetsPage, "This score sheet is not on this device.")
        Ok(sheet) -> sheet_editor(state, sheet)
      }
  }
}

fn not_found(back: Route, message: String) -> List(Element(msg)) {
  [sheet_view.back_link(back, "Back"), note(message)]
}

fn sheet_editor(state: State, sheet: Sheet) -> List(Element(Msg)) {
  let edited = fn(edit) { Edited(sheet.id, edit) }
  let asking = fn(part, index) {
    state.confirming == Some(RemoveFromSheet(sheet.id, part, index))
  }
  [
    sheet_view.back_link(route.SheetsPage, "All score sheets"),
    html.h1([], [html.text(sheet_name(sheet))]),
    problem_view(state),
    input_field(
      "sheet-name",
      "Name",
      "text",
      sheet.name,
      on_text(fn(value) { edited(score.Rename(value)) }),
    ),
    number_field("sheet-rounds", "Rounds", sheet.rounds, fn(value) {
      edited(score.SetRounds(value))
    }),
    html.label([attribute.class("check")], [
      html.input([
        attribute.type_("checkbox"),
        attribute.checked(sheet.ask_first),
        event.on_check(fn(ask) { edited(score.SetAskFirst(ask)) }),
      ]),
      html.text("Ask each round who went first"),
    ]),
    html.section([], [
      html.h2([], [html.text("Counters")]),
      note(
        "Things a player gains and spends. The gain each round is added by itself when a round starts.",
      ),
      ..list.index_map(sheet.counters, fn(counter, index) {
        let id = "counter-" <> int.to_string(index)
        part_view(
          sheet,
          Counters,
          index,
          list.length(sheet.counters),
          counter.name,
          asking(Counters, index),
          [
            input_field(
              id <> "-name",
              "Name",
              "text",
              counter.name,
              on_text(fn(value) { edited(score.CounterName(index, value)) }),
            ),
            number_field(id <> "-start", "Start", counter.start, fn(value) {
              edited(score.CounterStart(index, value))
            }),
            number_field(
              id <> "-gain",
              "Gain each round",
              counter.gain_each_round,
              fn(value) { edited(score.CounterGain(index, value)) },
            ),
          ],
        )
      })
    ]),
    html.div([attribute.class("actions")], [
      button("Add a counter", "button", edited(score.AddCounter)),
    ]),
    html.section([], [
      html.h2([], [html.text("Scoring")]),
      note(
        "What scores points in a round. A player's score for a round is the sum of these.",
      ),
      ..list.index_map(sheet.items, fn(item, index) {
        part_view(
          sheet,
          Items,
          index,
          list.length(sheet.items),
          item.name,
          asking(Items, index),
          item_fields(item, index, edited),
        )
      })
    ]),
    html.div([attribute.class("actions")], [
      button(
        "Add scored or not",
        "button",
        edited(score.AddItem(score.ToggleKind)),
      ),
      button("Add a count", "button", edited(score.AddItem(score.CountKind))),
      button(
        "Add typed points",
        "button",
        edited(score.AddItem(score.FreeKind)),
      ),
    ]),
    html.section([], [
      html.h2([], [html.text("Results")]),
      note(
        "With no results, a game ends in Win, Loss or Draw for the first player. With results, the winner gets the name of the highest one his lead reaches.",
      ),
      ..list.index_map(sheet.results, fn(band, index) {
        let id = "result-" <> int.to_string(index)
        part_view(
          sheet,
          Results,
          index,
          list.length(sheet.results),
          band.name,
          asking(Results, index),
          [
            input_field(
              id <> "-name",
              "Name",
              "text",
              band.name,
              on_text(fn(value) { edited(score.ResultName(index, value)) }),
            ),
            number_field(
              id <> "-lead",
              "Lead at least",
              band.lead_at_least,
              fn(value) { edited(score.ResultLead(index, value)) },
            ),
          ],
        )
      })
    ]),
    html.div([attribute.class("actions")], [
      button("Add a result", "button", edited(score.AddResult)),
    ]),
  ]
}

fn item_fields(
  item: Item,
  index: Int,
  edited: fn(Edit) -> Msg,
) -> List(Element(Msg)) {
  let id = "item-" <> int.to_string(index)
  let name =
    input_field(
      id <> "-name",
      "Name",
      "text",
      item.name,
      on_text(fn(value) { edited(score.ItemName(index, value)) }),
    )
  case item {
    Toggle(points:, ..) -> [
      note("Scored or not, once a round"),
      name,
      number_field(id <> "-points", "Points", points, fn(value) {
        edited(score.ItemPoints(index, value))
      }),
    ]
    Count(points_each:, most:, ..) -> [
      note("A count each round"),
      name,
      number_field(id <> "-points", "Points each", points_each, fn(value) {
        edited(score.ItemPoints(index, value))
      }),
      input_field(
        id <> "-most",
        "Most each round (empty for no limit)",
        "number",
        option.map(most, int.to_string) |> option.unwrap(""),
        event.on("change", {
          use text <- decode.subfield(["target", "value"], decode.string)
          case string.trim(text), int.parse(string.trim(text)) {
            "", _ -> decode.success(edited(score.ItemMost(index, None)))
            _, Ok(most) ->
              decode.success(edited(score.ItemMost(index, Some(most))))
            _, Error(Nil) ->
              decode.failure(edited(score.ItemMost(index, None)), "a number")
          }
        }),
      ),
    ]
    Free(..) -> [note("Points typed in each round"), name]
  }
}

/// One counter, scoring line or result: its fields, then Up, Down and
/// Remove, which asks first.
fn part_view(
  sheet: Sheet,
  part: Part,
  index: Int,
  length: Int,
  name: String,
  asking: Bool,
  fields: List(Element(Msg)),
) -> Element(Msg) {
  let move = fn(label, by, off) {
    html.button(
      [
        attribute.type_("button"),
        attribute.class("button"),
        attribute.disabled(off),
        event.on_click(Edited(sheet.id, score.Move(part, index, by))),
      ],
      [html.text(label)],
    )
  }
  html.div([attribute.class("part")], [
    element.fragment(fields),
    html.div([attribute.class("actions")], [
      move("Up", -1, index == 0),
      move("Down", 1, index == length - 1),
      ask(
        "Remove " <> name <> "?",
        "Remove",
        asking,
        RemoveClicked(sheet.id, part, index),
      ),
    ]),
  ])
}

/// A labelled box of the input `type_` that sends `changed` when the person
/// leaves it.
fn input_field(
  id: String,
  label: String,
  type_: String,
  value: String,
  changed: Attribute(Msg),
) -> Element(Msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    html.input([
      attribute.type_(type_),
      attribute.id(id),
      attribute.value(value),
      attribute.autocomplete("off"),
      changed,
    ]),
  ])
}

fn on_text(changed: fn(String) -> Msg) -> Attribute(Msg) {
  event.on_change(fn(text) { changed(string.trim(text)) })
}

/// A labelled number box. Anything that is not a whole number sends nothing.
fn number_field(
  id: String,
  label: String,
  value: Int,
  changed: fn(Int) -> Msg,
) -> Element(Msg) {
  input_field(id, label, "number", int.to_string(value), on_number(changed))
}

fn on_number(changed: fn(Int) -> msg) -> Attribute(msg) {
  event.on("change", {
    use text <- decode.subfield(["target", "value"], decode.string)
    case int.parse(string.trim(text)) {
      Ok(number) -> decode.success(changed(number))
      Error(Nil) -> decode.failure(changed(0), "a whole number")
    }
  })
}

// --- New game ---------------------------------------------------------------

/// Pick a sheet, type two names, pick one of `lists` or none, then Start.
/// The first name, the sheet and the list start as in the newest game.
pub fn new_game_page(
  state: State,
  lists: List(#(String, String)),
) -> List(Element(Msg)) {
  let back = sheet_view.back_link(route.Home, "Home")
  let last = newest_first(saved_games(state)) |> list.first
  case state.sheets {
    None -> [back, note("Opening the score sheets…")]
    Some(Error(error)) ->
      not_found(
        route.Home,
        "The saved score sheets could not be read. "
          <> sheet_view.describe_storage_error(error),
      )
    Some(Ok([])) -> [
      back,
      html.h1([], [html.text("New game")]),
      note("A game is kept on a score sheet. Make one first."),
      html.div([attribute.class("actions")], [
        link_button(route.SheetsPage, "button primary", "Score sheets"),
      ]),
    ]
    Some(Ok(sheets)) -> {
      let chosen =
        result.map(last, fn(game) { game.sheet.id }) |> result.unwrap("")
      let picked =
        result.try(last, fn(game) { option.to_result(game.list, Nil) })
        |> result.map(fn(picked) { picked.0 })
        |> result.unwrap("")
      [
        back,
        html.h1([], [html.text("New game")]),
        html.form([event.on_submit(StartSubmitted(lists, _))], [
          select_field(
            "game-sheet",
            "sheet",
            "Score sheet",
            list.sort(sheets, fn(a, b) { string.compare(a.name, b.name) })
              |> list.map(fn(sheet) { #(sheet.id, sheet_name(sheet)) }),
            chosen,
          ),
          text_field(
            "game-first",
            "first",
            "First player",
            result.map(last, fn(game) { game.players.0 }) |> result.unwrap(""),
          ),
          text_field("game-second", "second", "Second player", ""),
          select_field(
            "game-list",
            "list",
            "List",
            [#("", "(none)"), ..lists],
            picked,
          ),
          problem_view(state),
          html.button(
            [attribute.type_("submit"), attribute.class("button big")],
            [html.text("Start")],
          ),
        ]),
      ]
    }
  }
}

fn select_field(
  id: String,
  name: String,
  label: String,
  options: List(#(String, String)),
  chosen: String,
) -> Element(msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    html.select(
      [attribute.id(id), attribute.name(name)],
      list.map(options, fn(option) {
        html.option(
          [attribute.value(option.0), attribute.selected(option.0 == chosen)],
          option.1,
        )
      }),
    ),
  ])
}

// --- The game ---------------------------------------------------------------

/// One game: both names and totals and the result so far, the list he picked,
/// then the round on screen, then the bar that moves between rounds. An
/// ended game is read-only until Edit.
pub fn game_page(state: State, game_id: String) -> List(Element(Msg)) {
  case state.games {
    None -> [note("Opening…")]
    Some(Error(error)) ->
      not_found(
        route.Home,
        "The saved games could not be read. "
          <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(games)) ->
      case list.find(games, fn(game) { game.id == game_id }) {
        Error(Nil) -> not_found(route.Home, "This game is not on this device.")
        Ok(game) -> game_view(state, game)
      }
  }
}

fn game_view(state: State, game: Game) -> List(Element(Msg)) {
  let locked = game.ended != None && state.editing != Some(game.id)
  let played = fn(play) { Played(game.id, play) }
  let side = fn(name, player) {
    html.div([attribute.class("side")], [
      html.span([attribute.class("side-name")], [html.text(name)]),
      html.span([attribute.class("side-total")], [
        html.text(int.to_string(score.total(game, player))),
      ]),
    ])
  }
  [
    sheet_view.back_link(route.Home, "Home"),
    html.header([attribute.class("score-head")], [
      html.div([attribute.class("sides")], [
        side(game.players.0, One),
        side(game.players.1, Two),
      ]),
      html.p([attribute.class("result")], [
        html.text(
          case game.ended {
            None -> "Result so far: "
            Some(_) -> "Result: "
          }
          <> score.result(game),
        ),
      ]),
      case game.list {
        Some(#(list_id, name)) ->
          link_button(route.ListPage(list_id), "button", "List: " <> name)
        None -> element.none()
      },
    ]),
    problem_view(state),
    case game.ended, locked {
      Some(ended), True ->
        html.div([attribute.class("ended")], [
          note("This game ended on " <> browser.local_time(ended) <> "."),
          button("Edit", "button", EditClicked(game.id)),
        ])
      _, _ -> element.none()
    },
    html.h2([], [
      html.text(
        sheet_name(game.sheet)
        <> ", round "
        <> int.to_string(game.round)
        <> " of "
        <> int.to_string(game.sheet.rounds),
      ),
    ]),
    // A round of its own, so no box keeps what was typed in another round.
    keyed.fragment([
      #(
        int.to_string(game.round),
        element.fragment([
          case game.sheet.ask_first {
            True -> who_went_first(game, locked, played)
            False -> element.none()
          },
          player_view(game, One, locked, played),
          player_view(game, Two, locked, played),
        ]),
      ),
    ]),
    case locked {
      True ->
        case game.note {
          "" -> element.none()
          text ->
            html.section([], [
              html.h2([], [html.text("Note")]),
              html.p([attribute.class("prose")], [html.text(text)]),
            ])
        }
      False ->
        html.div([attribute.class("field")], [
          html.label([attribute.for("game-note")], [html.text("Note")]),
          html.textarea(
            [
              attribute.id("game-note"),
              attribute.rows(3),
              event.on_change(fn(text) { played(score.Note(text)) }),
            ],
            game.note,
          ),
        ])
    },
    round_bar(game, played),
  ]
}

fn who_went_first(
  game: Game,
  locked: Bool,
  played: fn(Play) -> Msg,
) -> Element(Msg) {
  let first = dict.get(game.first, game.round)
  let choice = fn(name, player) {
    case locked {
      True -> element.none()
      False ->
        toggle(
          name,
          first == Ok(player),
          played(score.WentFirst(game.round, player)),
        )
    }
  }
  html.section([attribute.class("who-first")], [
    html.h3([], [
      html.text(case first, locked {
        Ok(player), True -> "Went first: " <> name_of(game, player)
        Error(Nil), True -> "Who went first was not set."
        _, False -> "Who went first?"
      }),
    ]),
    html.div([attribute.class("pair")], [
      choice(game.players.0, One),
      choice(game.players.1, Two),
    ]),
  ])
}

fn name_of(game: Game, player: Player) -> String {
  case player {
    One -> game.players.0
    Two -> game.players.1
  }
}

/// A player's counters and scoring lines in the round on screen.
fn player_view(
  game: Game,
  player: Player,
  locked: Bool,
  played: fn(Play) -> Msg,
) -> Element(Msg) {
  let round = game.round
  let number = fn(label, mark) {
    stepper(
      name_of(game, player),
      label,
      score.value(game, mark),
      locked,
      fn(by) { played(score.Change(mark, by)) },
    )
  }
  let counters =
    list.map(game.sheet.counters, fn(counter) {
      html.div([attribute.class("counter")], [
        html.p([attribute.class("counter-head")], [
          html.span([], [html.text(counter.name)]),
          html.strong([], [
            html.text(
              int.to_string(score.left(game, player, round, counter)) <> " left",
            ),
          ]),
        ]),
        number("Gained", Gained(player, round, counter.id)),
        number("Spent", Spent(player, round, counter.id)),
      ])
    })
  let items =
    list.map(game.sheet.items, fn(item) {
      let mark = Scored(player, round, item.id)
      let value = score.value(game, mark)
      case item {
        Toggle(points:, ..) ->
          case locked {
            True ->
              line(item.name, case value > 0 {
                True -> "Scored, " <> int.to_string(points)
                False -> "Not scored"
              })
            False ->
              toggle(
                item.name <> " (" <> signed(points) <> ")",
                value > 0,
                played(score.Set(mark, 1 - value)),
              )
          }
        Count(..) -> number(item.name, mark)
        Free(..) ->
          case locked {
            True -> line(item.name, int.to_string(value))
            False -> {
              let id =
                "points-"
                <> int.to_string(player_number(player))
                <> "-"
                <> item.id
              html.div([attribute.class("stepper")], [
                html.label([attribute.for(id)], [html.text(item.name)]),
                html.input([
                  attribute.type_("number"),
                  attribute.id(id),
                  attribute.class("points"),
                  attribute.value(int.to_string(value)),
                  attribute.autocomplete("off"),
                  on_number(fn(to) { played(score.Set(mark, to)) }),
                ]),
              ])
            }
          }
      }
    })
  html.section([attribute.class("player")], [
    html.h3([], [
      html.text(name_of(game, player)),
      html.small([], [
        html.text(
          "This round: "
          <> int.to_string(score.round_score(game, player, round)),
        ),
      ]),
    ]),
    element.fragment(counters),
    element.fragment(items),
  ])
}

fn player_number(player: Player) -> Int {
  case player {
    One -> 1
    Two -> 2
  }
}

fn signed(points: Int) -> String {
  case points >= 0 {
    True -> "+" <> int.to_string(points)
    False -> int.to_string(points)
  }
}

/// A name and its number, read-only.
fn line(label: String, value: String) -> Element(msg) {
  html.p([attribute.class("stepper")], [
    html.span([], [html.text(label)]),
    html.strong([], [html.text(value)]),
  ])
}

/// A label, then a minus, the number and a plus. One tap changes the number
/// by one.
fn stepper(
  player: String,
  label: String,
  value: Int,
  locked: Bool,
  change: fn(Int) -> Msg,
) -> Element(Msg) {
  use <- lazy_when(locked, fn() { line(label, int.to_string(value)) })
  let tap = fn(text, by, words) {
    html.button(
      [
        attribute.type_("button"),
        attribute.class("tap"),
        attribute.aria_label(words <> " " <> label <> ", " <> player),
        event.on_click(change(by)),
      ],
      [html.text(text)],
    )
  }
  html.div([attribute.class("stepper")], [
    html.span([], [html.text(label)]),
    tap("−", -1, "One less"),
    html.output([attribute.aria_live("polite")], [
      html.text(int.to_string(value)),
    ]),
    tap("+", 1, "One more"),
  ])
}

fn lazy_when(
  condition: Bool,
  then: fn() -> Element(msg),
  otherwise: fn() -> Element(msg),
) -> Element(msg) {
  case condition {
    True -> then()
    False -> otherwise()
  }
}

/// A large button that is on or off.
fn toggle(label: String, on: Bool, clicked: Msg) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("toggle"),
      attribute.aria_pressed(case on {
        True -> "true"
        False -> "false"
      }),
      event.on_click(clicked),
    ],
    [html.text(label)],
  )
}

/// The bar at the end of the screen: a round back, the round, and a round
/// forward, or End game after the last round.
fn round_bar(game: Game, played: fn(Play) -> Msg) -> Element(Msg) {
  let last = game.round >= game.sheet.rounds
  html.nav([attribute.class("round-bar"), attribute.aria_label("Rounds")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("button"),
        attribute.disabled(game.round <= 1),
        event.on_click(played(score.ToRound(game.round - 1))),
      ],
      [html.text("← Back")],
    ),
    html.span([attribute.class("round-number")], [
      html.text("Round " <> int.to_string(game.round)),
    ]),
    case last, game.ended {
      False, _ ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button primary"),
            event.on_click(played(score.ToRound(game.round + 1))),
          ],
          [html.text("Next →")],
        )
      True, None -> button("End game", "button primary", EndClicked(game.id))
      True, Some(_) ->
        html.span([attribute.class("round-number")], [html.text("Ended")])
    },
  ])
}

// --- Shared -----------------------------------------------------------------

fn note(text: String) -> Element(msg) {
  html.p([attribute.class("note")], [html.text(text)])
}

fn count(number: Int, one: String, many: String) -> String {
  case number {
    1 -> "1 " <> one
    _ -> int.to_string(number) <> " " <> many
  }
}

fn problem_view(state: State) -> Element(msg) {
  case state.problem {
    None -> element.none()
    Some(problem) ->
      html.p([attribute.class("problem"), attribute.role("alert")], [
        html.text(describe_problem(problem)),
      ])
  }
}

fn describe_problem(problem: Problem) -> String {
  case problem {
    NotSaved(error) ->
      "The last change could not be saved. "
      <> sheet_view.describe_storage_error(error)
    NotDeleted(error) ->
      "The game could not be deleted. "
      <> sheet_view.describe_storage_error(error)
    NoStorage -> "Storage is not open on this device, so changes are not saved."
    NoSheet -> "Choose a score sheet."
  }
}
