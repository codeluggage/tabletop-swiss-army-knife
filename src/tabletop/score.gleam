//// A score sheet and a game kept on one: the shapes, the scoring, the
//// changes the sheet editor and the game screen make, and their JSON. The
//// code knows shapes only. What a game counts and what scores points is a
//// sheet the person sets up and saves.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Sheet {
  Sheet(
    id: String,
    name: String,
    /// How many rounds a game has, at least 1.
    rounds: Int,
    /// Whether the game asks each round who went first.
    ask_first: Bool,
    counters: List(Counter),
    items: List(Item),
    results: List(ResultBand),
  )
}

/// Something a player gains and spends. `gain_each_round` comes by itself
/// at the start of every round, the first included, and may be 0.
pub type Counter {
  Counter(id: String, name: String, start: Int, gain_each_round: Int)
}

/// Something that scores points in a round. Every kind has its `id` and
/// `name` first.
pub type Item {
  /// Scored or not, once a round.
  Toggle(id: String, name: String, points: Int)
  /// A number a round, each worth `points_each`, up to `most` when it is set.
  Count(id: String, name: String, points_each: Int, most: Option(Int))
  /// The person types the points.
  Free(id: String, name: String)
}

/// A name for how a game ended: the winner gets the name of the highest band
/// the lead reaches.
pub type ResultBand {
  ResultBand(name: String, lead_at_least: Int)
}

pub type Player {
  One
  Two
}

/// One number of a game: a player's counter or item in a round.
pub type Mark {
  Gained(player: Player, round: Int, counter: String)
  Spent(player: Player, round: Int, counter: String)
  Scored(player: Player, round: Int, item: String)
}

pub type Game {
  Game(
    id: String,
    /// A copy of the sheet as it was when the game started, so a later edit
    /// of the sheet never changes this game.
    sheet: Sheet,
    /// When it started, in milliseconds since 1970 UTC.
    started: Int,
    players: #(String, String),
    /// The id and name of one of the person's lists, when he picked one.
    list: Option(#(String, String)),
    /// The round on screen, from 1.
    round: Int,
    /// Who went first, for each round that has an answer.
    first: Dict(Int, Player),
    /// Every number that was set. A mark never set has its `default`.
    marks: Dict(Mark, Int),
    note: String,
    ended: Option(Int),
  )
}

// --- Scoring ------------------------------------------------------------------

/// A new game on `sheet`, at its first round with nothing scored.
pub fn start(
  id id: String,
  sheet sheet: Sheet,
  started started: Int,
  players players: #(String, String),
  list picked: Option(#(String, String)),
) -> Game {
  Game(
    id:,
    sheet:,
    started:,
    players:,
    list: picked,
    round: 1,
    first: dict.new(),
    marks: dict.new(),
    note: "",
    ended: None,
  )
}

/// A mark's number: what was set, or the counter's gain each round for what
/// was gained, and 0 for the rest.
pub fn value(game: Game, mark: Mark) -> Int {
  use <- result.lazy_unwrap(dict.get(game.marks, mark))
  case mark {
    Gained(counter:, ..) ->
      list.find(game.sheet.counters, fn(found) { found.id == counter })
      |> result.map(fn(found) { found.gain_each_round })
      |> result.unwrap(0)
    Spent(..) | Scored(..) -> 0
  }
}

/// The points an item scores for its number.
pub fn points(item: Item, value: Int) -> Int {
  case item {
    Toggle(points:, ..) ->
      case value > 0 {
        True -> points
        False -> 0
      }
    Count(points_each:, ..) -> points_each * value
    Free(..) -> value
  }
}

/// A player's score for a round: the sum of the items.
pub fn round_score(game: Game, player: Player, round: Int) -> Int {
  use sum, item <- list.fold(game.sheet.items, 0)
  sum + points(item, value(game, Scored(player, round, item.id)))
}

/// A player's total: the sum over the rounds.
pub fn total(game: Game, player: Player) -> Int {
  use sum, round <- int.range(1, game.sheet.rounds + 1, 0)
  sum + round_score(game, player, round)
}

/// What a player has left of a counter at the end of `round`: the start, and
/// what was gained less what was spent in that round and every one before.
pub fn left(game: Game, player: Player, round: Int, counter: Counter) -> Int {
  use sum, round <- int.range(1, round + 1, counter.start)
  sum
  + value(game, Gained(player, round, counter.id))
  - value(game, Spent(player, round, counter.id))
}

/// How the game stands, from the totals: "Draw", or the winner's name and
/// the highest result band his lead reaches. With no bands, the first player
/// has a Win or a Loss. A lead that reaches no band is a Win.
pub fn result(game: Game) -> String {
  let #(one, two) = game.players
  let lead = total(game, One) - total(game, Two)
  let winner = case lead > 0 {
    True -> one
    False -> two
  }
  case game.sheet.results, lead {
    _, 0 -> "Draw"
    [], _ if lead > 0 -> one <> ": Win"
    [], _ -> one <> ": Loss"
    bands, _ ->
      winner
      <> ": "
      <> {
        list.filter(bands, fn(band) {
          band.lead_at_least <= int.absolute_value(lead)
        })
        |> list.max(fn(a, b) { int.compare(a.lead_at_least, b.lead_at_least) })
        |> result.map(fn(band) { band.name })
        |> result.unwrap("Win")
      }
  }
}

// --- The game screen's changes -----------------------------------------------

/// One change from the game screen.
pub type Play {
  /// One tap on a minus or a plus.
  Change(mark: Mark, by: Int)
  /// A typed number, or a toggle on or off.
  Set(mark: Mark, to: Int)
  WentFirst(round: Int, player: Player)
  ToRound(round: Int)
  End(at: Int)
  Note(text: String)
}

pub fn play(game: Game, change: Play) -> Game {
  case change {
    Change(mark:, by:) -> set(game, mark, value(game, mark) + by)
    Set(mark:, to:) -> set(game, mark, to)
    WentFirst(round:, player:) ->
      Game(..game, first: dict.insert(game.first, round, player))
    ToRound(round:) ->
      Game(..game, round: int.clamp(round, 1, game.sheet.rounds))
    End(at:) -> Game(..game, ended: Some(at))
    Note(text:) -> Game(..game, note: text)
  }
}

/// A mark set to `to`, held to what it can be: gained and spent at least 0,
/// a toggle 0 or 1, a count from 0 to its most. Typed points are anything.
fn set(game: Game, mark: Mark, to: Int) -> Game {
  let held = case mark {
    Gained(..) | Spent(..) -> int.max(to, 0)
    Scored(item:, ..) ->
      case list.find(game.sheet.items, fn(found) { found.id == item }) {
        Ok(Toggle(..)) -> int.clamp(to, 0, 1)
        Ok(Count(most: Some(most), ..)) -> int.clamp(to, 0, most)
        Ok(Count(most: None, ..)) -> int.max(to, 0)
        Ok(Free(..)) | Error(Nil) -> to
      }
  }
  Game(..game, marks: dict.insert(game.marks, mark, held))
}

// --- The sheet editor's changes ------------------------------------------------

/// The three lists of a sheet the editor adds to, reorders and removes from.
pub type Part {
  Counters
  Items
  Results
}

pub type ItemKind {
  ToggleKind
  CountKind
  FreeKind
}

/// One change from the sheet editor. `index` is a place in its part.
pub type Edit {
  Rename(name: String)
  SetRounds(rounds: Int)
  SetAskFirst(ask: Bool)
  AddCounter
  AddItem(kind: ItemKind)
  AddResult
  /// One place up when `by` is -1, one down when it is 1.
  Move(part: Part, index: Int, by: Int)
  Remove(part: Part, index: Int)
  CounterName(index: Int, name: String)
  CounterStart(index: Int, start: Int)
  CounterGain(index: Int, gain: Int)
  ItemName(index: Int, name: String)
  /// A toggle's points, or what each of a count is worth.
  ItemPoints(index: Int, points: Int)
  ItemMost(index: Int, most: Option(Int))
  ResultName(index: Int, name: String)
  ResultLead(index: Int, lead: Int)
}

/// A new counter or item gets its id from `new_id`.
pub fn edit(sheet: Sheet, change: Edit, new_id: fn() -> String) -> Sheet {
  case change {
    Rename(name:) -> Sheet(..sheet, name:)
    SetRounds(rounds:) -> Sheet(..sheet, rounds: int.max(rounds, 1))
    SetAskFirst(ask:) -> Sheet(..sheet, ask_first: ask)
    AddCounter ->
      Sheet(
        ..sheet,
        counters: list.append(sheet.counters, [
          Counter(
            id: new_id(),
            name: "New counter",
            start: 0,
            gain_each_round: 0,
          ),
        ]),
      )
    AddItem(kind:) -> {
      let item = case kind {
        ToggleKind -> Toggle(id: new_id(), name: "New item", points: 1)
        CountKind ->
          Count(id: new_id(), name: "New item", points_each: 1, most: None)
        FreeKind -> Free(id: new_id(), name: "New item")
      }
      Sheet(..sheet, items: list.append(sheet.items, [item]))
    }
    AddResult ->
      Sheet(
        ..sheet,
        results: list.append(sheet.results, [
          ResultBand(name: "New result", lead_at_least: 1),
        ]),
      )
    Move(part:, index:, by:) -> rearrange(sheet, part, Swap(index, index + by))
    Remove(part:, index:) -> rearrange(sheet, part, Without(index))
    CounterName(index:, name:) ->
      counter_at(sheet, index, fn(counter) { Counter(..counter, name:) })
    CounterStart(index:, start:) ->
      counter_at(sheet, index, fn(counter) { Counter(..counter, start:) })
    CounterGain(index:, gain:) ->
      counter_at(sheet, index, fn(counter) {
        Counter(..counter, gain_each_round: gain)
      })
    ItemName(index:, name:) ->
      item_at(sheet, index, fn(item) {
        case item {
          Toggle(..) -> Toggle(..item, name:)
          Count(..) -> Count(..item, name:)
          Free(..) -> Free(..item, name:)
        }
      })
    ItemPoints(index:, points:) ->
      item_at(sheet, index, fn(item) {
        case item {
          Toggle(..) -> Toggle(..item, points:)
          Count(..) -> Count(..item, points_each: points)
          Free(..) -> item
        }
      })
    ItemMost(index:, most:) ->
      item_at(sheet, index, fn(item) {
        case item {
          Count(..) -> Count(..item, most: option.map(most, int.max(_, 0)))
          Toggle(..) | Free(..) -> item
        }
      })
    ResultName(index:, name:) ->
      result_at(sheet, index, fn(band) { ResultBand(..band, name:) })
    ResultLead(index:, lead:) ->
      result_at(sheet, index, fn(band) {
        ResultBand(..band, lead_at_least: lead)
      })
  }
}

/// A sheet to start from: a name, the rounds, and one typed item, "Score".
pub fn simple(id: String, name: String, rounds: Int, item_id: String) -> Sheet {
  Sheet(
    id:,
    name:,
    rounds: int.max(rounds, 1),
    ask_first: False,
    counters: [],
    items: [Free(id: item_id, name: "Score")],
    results: [],
  )
}

type Rearrange {
  Swap(index: Int, with: Int)
  Without(index: Int)
}

fn rearrange(sheet: Sheet, part: Part, change: Rearrange) -> Sheet {
  case part {
    Counters -> Sheet(..sheet, counters: reorder(sheet.counters, change))
    Items -> Sheet(..sheet, items: reorder(sheet.items, change))
    Results -> Sheet(..sheet, results: reorder(sheet.results, change))
  }
}

/// A swap with a place outside the list changes nothing.
fn reorder(items: List(a), change: Rearrange) -> List(a) {
  let at = fn(index) {
    case index < 0 {
      True -> Error(Nil)
      False -> list.drop(items, index) |> list.first
    }
  }
  case change {
    Without(index:) ->
      list.append(list.take(items, index), list.drop(items, index + 1))
    Swap(index:, with:) ->
      case at(index), at(with) {
        Ok(a), Ok(b) ->
          list.index_map(items, fn(item, place) {
            case place {
              _ if place == index -> b
              _ if place == with -> a
              _ -> item
            }
          })
        _, _ -> items
      }
  }
}

fn change_at(items: List(a), index: Int, change: fn(a) -> a) -> List(a) {
  use item, place <- list.index_map(items)
  case place == index {
    True -> change(item)
    False -> item
  }
}

fn counter_at(
  sheet: Sheet,
  index: Int,
  change: fn(Counter) -> Counter,
) -> Sheet {
  Sheet(..sheet, counters: change_at(sheet.counters, index, change))
}

fn item_at(sheet: Sheet, index: Int, change: fn(Item) -> Item) -> Sheet {
  Sheet(..sheet, items: change_at(sheet.items, index, change))
}

fn result_at(
  sheet: Sheet,
  index: Int,
  change: fn(ResultBand) -> ResultBand,
) -> Sheet {
  Sheet(..sheet, results: change_at(sheet.results, index, change))
}

// --- JSON ---------------------------------------------------------------------

pub fn encode_sheet(sheet: Sheet) -> json.Json {
  json.object([
    #("id", json.string(sheet.id)),
    #("name", json.string(sheet.name)),
    #("rounds", json.int(sheet.rounds)),
    #("ask_first", json.bool(sheet.ask_first)),
    #(
      "counters",
      json.array(sheet.counters, fn(counter) {
        json.object([
          #("id", json.string(counter.id)),
          #("name", json.string(counter.name)),
          #("start", json.int(counter.start)),
          #("gain_each_round", json.int(counter.gain_each_round)),
        ])
      }),
    ),
    #("items", json.array(sheet.items, encode_item)),
    #(
      "results",
      json.array(sheet.results, fn(band) {
        json.object([
          #("name", json.string(band.name)),
          #("lead_at_least", json.int(band.lead_at_least)),
        ])
      }),
    ),
  ])
}

fn encode_item(item: Item) -> json.Json {
  let fields = case item {
    Toggle(points:, ..) -> [
      #("kind", json.string("toggle")),
      #("points", json.int(points)),
    ]
    Count(points_each:, most:, ..) -> [
      #("kind", json.string("count")),
      #("points_each", json.int(points_each)),
      #("most", json.nullable(most, json.int)),
    ]
    Free(..) -> [#("kind", json.string("free"))]
  }
  json.object([
    #("id", json.string(item.id)),
    #("name", json.string(item.name)),
    ..fields
  ])
}

pub fn sheet_decoder() -> decode.Decoder(Sheet) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use rounds <- decode.field("rounds", decode.int)
  use ask_first <- decode.field("ask_first", decode.bool)
  use counters <- decode.field("counters", decode.list(counter_decoder()))
  use items <- decode.field("items", decode.list(item_decoder()))
  use results <- decode.field("results", decode.list(band_decoder()))
  decode.success(Sheet(
    id:,
    name:,
    rounds:,
    ask_first:,
    counters:,
    items:,
    results:,
  ))
}

fn counter_decoder() -> decode.Decoder(Counter) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use start <- decode.field("start", decode.int)
  use gain_each_round <- decode.field("gain_each_round", decode.int)
  decode.success(Counter(id:, name:, start:, gain_each_round:))
}

fn item_decoder() -> decode.Decoder(Item) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string)
  case kind {
    "toggle" -> {
      use points <- decode.field("points", decode.int)
      decode.success(Toggle(id:, name:, points:))
    }
    "count" -> {
      use points_each <- decode.field("points_each", decode.int)
      use most <- decode.field("most", decode.optional(decode.int))
      decode.success(Count(id:, name:, points_each:, most:))
    }
    "free" -> decode.success(Free(id:, name:))
    _ -> decode.failure(Free(id:, name:), "an item kind")
  }
}

fn band_decoder() -> decode.Decoder(ResultBand) {
  use name <- decode.field("name", decode.string)
  use lead_at_least <- decode.field("lead_at_least", decode.int)
  decode.success(ResultBand(name:, lead_at_least:))
}

pub fn encode_game(game: Game) -> json.Json {
  json.object([
    #("id", json.string(game.id)),
    #("sheet", encode_sheet(game.sheet)),
    #("started", json.int(game.started)),
    #("players", json.array([game.players.0, game.players.1], json.string)),
    #(
      "list",
      json.nullable(game.list, fn(picked) {
        json.object([
          #("id", json.string(picked.0)),
          #("name", json.string(picked.1)),
        ])
      }),
    ),
    #("round", json.int(game.round)),
    #(
      "first",
      json.array(dict.to_list(game.first), fn(first) {
        json.object([
          #("round", json.int(first.0)),
          #("player", encode_player(first.1)),
        ])
      }),
    ),
    #("marks", json.array(dict.to_list(game.marks), encode_mark)),
    #("note", json.string(game.note)),
    #("ended", json.nullable(game.ended, json.int)),
  ])
}

fn encode_player(player: Player) -> json.Json {
  case player {
    One -> json.int(1)
    Two -> json.int(2)
  }
}

fn encode_mark(mark: #(Mark, Int)) -> json.Json {
  let #(kind, id) = case mark.0 {
    Gained(counter:, ..) -> #("gained", counter)
    Spent(counter:, ..) -> #("spent", counter)
    Scored(item:, ..) -> #("scored", item)
  }
  json.object([
    #("mark", json.string(kind)),
    #("player", encode_player({ mark.0 }.player)),
    #("round", json.int({ mark.0 }.round)),
    #("id", json.string(id)),
    #("value", json.int(mark.1)),
  ])
}

pub fn game_decoder() -> decode.Decoder(Game) {
  use id <- decode.field("id", decode.string)
  use sheet <- decode.field("sheet", sheet_decoder())
  use started <- decode.field("started", decode.int)
  use players <- decode.field("players", {
    use one <- decode.field(0, decode.string)
    use two <- decode.field(1, decode.string)
    decode.success(#(one, two))
  })
  use picked <- decode.field(
    "list",
    decode.optional({
      use list_id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      decode.success(#(list_id, name))
    }),
  )
  use round <- decode.field("round", decode.int)
  use first <- decode.field(
    "first",
    decode.list({
      use round <- decode.field("round", decode.int)
      use player <- decode.field("player", player_decoder())
      decode.success(#(round, player))
    }),
  )
  use marks <- decode.field("marks", decode.list(mark_decoder()))
  use note <- decode.field("note", decode.string)
  use ended <- decode.field("ended", decode.optional(decode.int))
  decode.success(Game(
    id:,
    sheet:,
    started:,
    players:,
    list: picked,
    round:,
    first: dict.from_list(first),
    marks: dict.from_list(marks),
    note:,
    ended:,
  ))
}

fn player_decoder() -> decode.Decoder(Player) {
  use number <- decode.then(decode.int)
  case number {
    1 -> decode.success(One)
    2 -> decode.success(Two)
    _ -> decode.failure(One, "player 1 or 2")
  }
}

fn mark_decoder() -> decode.Decoder(#(Mark, Int)) {
  use kind <- decode.field("mark", decode.string)
  use player <- decode.field("player", player_decoder())
  use round <- decode.field("round", decode.int)
  use id <- decode.field("id", decode.string)
  use value <- decode.field("value", decode.int)
  case kind {
    "gained" -> decode.success(#(Gained(player, round, id), value))
    "spent" -> decode.success(#(Spent(player, round, id), value))
    "scored" -> decode.success(#(Scored(player, round, id), value))
    _ -> decode.failure(#(Scored(player, round, id), value), "a mark")
  }
}
