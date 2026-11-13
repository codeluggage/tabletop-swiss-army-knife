//// The cards feature: short pieces of game text that the user types in or
//// imports from a table file. A card belongs to the whole game of a data set
//// or to one node in it, by the set and node ids, whichever catalogue it was
//// placed from. It shows on its place's screen, on a list whose settings
//// link to its node, and for a unit, first when its target names one of the
//// unit's keywords.
//// The shell in `tabletop.gleam` holds its `State`, wraps its `Msg`, sends it
//// the card routes, and puts its sections on the data and list screens.

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
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
import tabletop/catalogue
import tabletop/effects
import tabletop/route.{type Place, Game, Node}
import tabletop/scope.{type Page, type Scope}
import tabletop/sheet_view
import tabletop/storage.{type Database, type StorageError}
import tabletop/table.{type Table}
import tabletop/text

/// Every field but the name may be empty.
pub type Card {
  Card(
    id: String,
    name: String,
    cost: String,
    when: String,
    target: String,
    effect: String,
    place: Place,
    /// When it was last saved, in milliseconds since 1970 UTC, so a merge of
    /// two copies can keep the newer one.
    edited: Int,
  )
}

pub type State {
  State(
    /// `None` until the saved cards are read.
    cards: Option(Result(List(Card), StorageError)),
    problem: Option(Problem),
    /// The id of the card whose Delete was pressed and waits for Yes or No.
    confirming: Option(String),
    /// The table file read for the import screen.
    pending: Option(Pending),
  )
}

/// A table file to import into `place`, and the column chosen for each field.
pub type Pending {
  Pending(
    place: Place,
    file_name: String,
    table: Table,
    columns: Dict(Field, Int),
    /// A column and a value: only the rows whose cell in that column is the
    /// value import. `None` imports every row.
    only: Option(#(Int, String)),
    /// Whether the import deletes the cards already at `place`.
    replace: Bool,
  )
}

pub type Field {
  Name
  Cost
  When
  Target
  Effect
}

/// What went wrong with the last save, delete or chosen file.
pub type Problem {
  NoName
  NotSaved(StorageError)
  NotDeleted(StorageError)
  FileNotRead(reason: String)
  NoRows
  NoStorage
}

pub type Msg {
  CardsLoaded(Result(List(Card), StorageError))
  /// The card form's fields by name. `id` is `None` for a new card.
  FormSubmitted(
    id: Option(String),
    place: Place,
    fields: List(#(String, String)),
  )
  /// `removed` are the ids of the cards the same write deleted.
  CardsSaved(removed: List(String), result: Result(List(Card), StorageError))
  DeleteClicked(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  CardDeleted(id: String, result: Result(Nil, StorageError))
  TableChosen(place: Place, input: Dynamic)
  TableRead(place: Place, result: Result(#(String, BitArray), String))
  ColumnChosen(field: Field, column: Option(Int))
  OnlyColumnChosen(column: Option(Int))
  OnlyValueChosen(value: String)
  ReplaceChecked(replace: Bool)
  ImportClicked
  Cancelled
}

const fields = [Name, Cost, When, Target, Effect]

pub fn init() -> State {
  State(cards: None, problem: None, confirming: None, pending: None)
}

/// Read the saved cards once storage has answered. When storage did not
/// open, the cards show why.
pub fn load(db: Result(Database, StorageError)) -> Effect(Msg) {
  case db {
    Ok(db) -> effects.from_promise(fn() { load_cards(db) }, CardsLoaded)
    Error(error) -> {
      use dispatch <- effect.from
      dispatch(CardsLoaded(Error(error)))
    }
  }
}

/// `db` is the open database or the reason it is not open, and `None` while
/// it opens.
pub fn update(
  state: State,
  msg: Msg,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case msg {
    CardsLoaded(cards) -> #(State(..state, cards: Some(cards)), effect.none())
    FormSubmitted(id:, place:, fields:) -> {
      let value = fn(field) {
        list.key_find(fields, key(field)) |> result.unwrap("") |> string.trim
      }
      case value(Name), db {
        "", _ -> #(State(..state, problem: Some(NoName)), effect.none())
        name, Some(Ok(db)) -> {
          let card = fn() {
            Card(
              id: option.lazy_unwrap(id, browser.random_id),
              name:,
              cost: value(Cost),
              when: value(When),
              target: value(Target),
              effect: value(Effect),
              place:,
              edited: 0,
            )
          }
          #(
            State(..state, problem: None),
            effects.from_promise(fn() { save(db, [card()], []) }, CardsSaved(
              [],
              _,
            )),
          )
        }
        _, _ -> #(State(..state, problem: Some(NoStorage)), effect.none())
      }
    }
    CardsSaved(removed:, result: Ok(saved)) -> {
      let ids = list.append(list.map(saved, fn(card) { card.id }), removed)
      let kept =
        list.filter(saved_cards(state), fn(card) {
          !list.contains(ids, card.id)
        })
      #(
        State(
          ..state,
          cards: Some(Ok(list.append(saved, kept))),
          problem: None,
          pending: None,
        ),
        back(),
      )
    }
    CardsSaved(result: Error(error), ..) -> #(
      State(..state, problem: Some(NotSaved(error))),
      effect.none(),
    )
    DeleteClicked(id:) -> #(
      State(..state, confirming: Some(id), problem: None),
      effect.none(),
    )
    DeleteCancelled -> #(State(..state, confirming: None), effect.none())
    DeleteConfirmed(id:) ->
      case db {
        Some(Ok(db)) -> #(
          state,
          effects.from_promise(
            fn() { storage.delete(db, storage.Cards, id) },
            CardDeleted(id, _),
          ),
        )
        _ -> #(
          State(..state, confirming: None, problem: Some(NoStorage)),
          effect.none(),
        )
      }
    CardDeleted(id:, result: Ok(Nil)) -> {
      let cards = list.filter(saved_cards(state), fn(card) { card.id != id })
      #(State(..state, confirming: None, cards: Some(Ok(cards))), back())
    }
    CardDeleted(result: Error(error), ..) -> #(
      State(..state, confirming: None, problem: Some(NotDeleted(error))),
      effect.none(),
    )
    TableChosen(place:, input:) -> #(
      State(..state, problem: None),
      effects.from_promise(fn() { browser.read_chosen_file(input) }, TableRead(
        place,
        _,
      )),
    )
    TableRead(result: Error(reason), ..) -> #(
      State(..state, problem: Some(FileNotRead(reason))),
      effect.none(),
    )
    TableRead(place:, result: Ok(#(file_name, bytes))) -> {
      // Text that is not UTF-8 is most likely from a spreadsheet on Windows.
      let text = case bit_array.to_string(bytes) {
        Ok(text) -> text
        Error(Nil) -> browser.windows_1252_to_string(bytes)
      }
      case table.parse(text) {
        table.Table(header: [], ..) -> #(
          State(..state, problem: Some(NoRows)),
          effect.none(),
        )
        read -> {
          let pending =
            Pending(
              place:,
              file_name:,
              table: read,
              columns: columns(read),
              only: None,
              replace: False,
            )
          #(State(..state, pending: Some(pending)), {
            use _ <- effect.from
            route.go(route.ImportCardsPage(place))
          })
        }
      }
    }
    ColumnChosen(field:, column:) -> {
      use pending <- change_pending(state)
      let columns = case column {
        Some(column) -> dict.insert(pending.columns, field, column)
        None -> dict.delete(pending.columns, field)
      }
      Pending(..pending, columns:)
    }
    // A new column starts at its first value.
    OnlyColumnChosen(column:) -> {
      use pending <- change_pending(state)
      let only =
        option.map(column, fn(column) {
          #(
            column,
            values(pending.table, column) |> list.first |> result.unwrap(""),
          )
        })
      Pending(..pending, only:)
    }
    OnlyValueChosen(value:) -> {
      use pending <- change_pending(state)
      let only = option.map(pending.only, fn(only) { #(only.0, value) })
      Pending(..pending, only:)
    }
    ReplaceChecked(replace:) -> {
      use pending <- change_pending(state)
      Pending(..pending, replace:)
    }
    ImportClicked ->
      case state.pending, db {
        Some(pending), Some(Ok(db)) -> {
          let removed = replaced(saved_cards(state), pending)
          #(
            State(..state, problem: None),
            effects.from_promise(
              fn() {
                save(db, import_cards(pending, browser.random_id).0, removed)
              },
              CardsSaved(removed, _),
            ),
          )
        }
        Some(_), _ -> #(State(..state, problem: Some(NoStorage)), effect.none())
        None, _ -> #(state, effect.none())
      }
    Cancelled -> #(State(..state, pending: None), back())
  }
}

/// The screen changed: the last problem and an open delete question go. A
/// file waiting for the import screen stays, since that screen opens next.
pub fn screen_changed(state: State) -> State {
  State(..state, problem: None, confirming: None)
}

/// The file waiting for the import screen, changed by `change`.
fn change_pending(
  state: State,
  change: fn(Pending) -> Pending,
) -> #(State, Effect(Msg)) {
  #(State(..state, pending: option.map(state.pending, change)), effect.none())
}

fn back() -> Effect(Msg) {
  use _ <- effect.from
  browser.history_back()
}

fn saved_cards(state: State) -> List(Card) {
  case state.cards {
    Some(Ok(cards)) -> cards
    Some(Error(_)) | None -> []
  }
}

// --- Fields and the import --------------------------------------------------

fn label(field: Field) -> String {
  case field {
    Name -> "Name"
    Cost -> "Cost"
    When -> "When"
    Target -> "Target"
    Effect -> "Effect"
  }
}

/// The field's name in the form and in a saved record.
fn key(field: Field) -> String {
  string.lowercase(label(field))
}

/// For each field, the first column whose header is the field's label,
/// ignoring case and spaces around it.
pub fn columns(read: Table) -> Dict(Field, Int) {
  let headers =
    list.index_map(read.header, fn(header, index) {
      #(string.lowercase(string.trim(header)), index)
    })
  list.fold(fields, dict.new(), fn(columns, field) {
    case list.key_find(headers, key(field)) {
      Ok(index) -> dict.insert(columns, field, index)
      Error(Nil) -> columns
    }
  })
}

/// The cell of `row` in the column `index`, trimmed, and empty when the row
/// has none.
fn cell(row: List(String), index: Int) -> String {
  list.drop(row, index) |> list.first |> result.unwrap("") |> string.trim
}

/// Each value the column `index` holds, once, in the order of the rows.
pub fn values(read: Table, index: Int) -> List(String) {
  list.map(read.rows, cell(_, index)) |> list.unique
}

/// The cards the rows of an import become, each with an id from `new_id`,
/// and how many rows are skipped for having no name. With `only`, the other
/// rows are left out first.
pub fn import_cards(
  pending: Pending,
  new_id: fn() -> String,
) -> #(List(Card), Int) {
  let rows =
    list.filter(pending.table.rows, fn(row) {
      case pending.only {
        Some(#(index, value)) -> cell(row, index) == value
        None -> True
      }
    })
  let cards =
    list.filter_map(rows, fn(row) {
      let value = fn(field) {
        dict.get(pending.columns, field)
        |> result.map(cell(row, _))
        |> result.unwrap("")
      }
      case value(Name) {
        "" -> Error(Nil)
        name ->
          Ok(Card(
            id: new_id(),
            name:,
            cost: value(Cost),
            when: value(When),
            target: value(Target),
            effect: value(Effect),
            place: pending.place,
            edited: 0,
          ))
      }
    })
  #(cards, list.length(rows) - list.length(cards))
}

/// The ids of the saved `cards` an import deletes: the cards of its place
/// when Replace is on, and none when it is off.
pub fn replaced(cards: List(Card), pending: Pending) -> List(String) {
  use <- bool.guard(!pending.replace, [])
  use card <- list.filter_map(cards)
  case belongs(card.place, pending.place) {
    True -> Ok(card.id)
    False -> Error(Nil)
  }
}

// --- Storage ----------------------------------------------------------------

/// The changes that delete the cards `removed` and save `cards`, all of them
/// in one `storage.write`.
pub fn writes(cards: List(Card), removed: List(String)) -> List(storage.Write) {
  list.append(
    list.map(removed, storage.Remove(storage.Cards, _)),
    list.map(cards, fn(card) {
      storage.Put(storage.Cards, card.id, storage.JsonValue(encode(card)))
    }),
  )
}

/// Every save stamps the cards with the clock.
fn save(
  db: Database,
  cards: List(Card),
  removed: List(String),
) -> Promise(Result(List(Card), StorageError)) {
  let edited = browser.now_ms()
  let cards = list.map(cards, fn(card) { Card(..card, edited:) })
  storage.write(db, writes(cards, removed))
  |> promise.map(result.replace(_, cards))
}

fn encode(card: Card) -> json.Json {
  let place = case card.place {
    Game(set_id:) -> [#("set_id", json.string(set_id))]
    Node(set_id:, catalogue_id:, node_id:) -> [
      #("set_id", json.string(set_id)),
      #("catalogue_id", json.string(catalogue_id)),
      #("node_id", json.string(node_id)),
    ]
  }
  json.object([
    #("name", json.string(card.name)),
    #("cost", json.string(card.cost)),
    #("when", json.string(card.when)),
    #("target", json.string(card.target)),
    #("effect", json.string(card.effect)),
    #("place", json.object(place)),
    #("edited", json.int(card.edited)),
  ])
}

/// A saved card without its id, which is its key.
fn record_decoder() -> decode.Decoder(fn(String) -> Card) {
  use name <- decode.field("name", decode.string)
  use cost <- decode.field("cost", decode.string)
  use when <- decode.field("when", decode.string)
  use target <- decode.field("target", decode.string)
  use effect <- decode.field("effect", decode.string)
  use place <- decode.field("place", place_decoder())
  use edited <- decode.field("edited", decode.int)
  decode.success(fn(id) {
    Card(id:, name:, cost:, when:, target:, effect:, place:, edited:)
  })
}

fn place_decoder() -> decode.Decoder(Place) {
  use set_id <- decode.field("set_id", decode.string)
  use node_id <- decode.optional_field(
    "node_id",
    None,
    decode.map(decode.string, Some),
  )
  use catalogue_id <- decode.optional_field("catalogue_id", "", decode.string)
  decode.success(case node_id {
    Some(node_id) -> Node(set_id:, catalogue_id:, node_id:)
    None -> Game(set_id:)
  })
}

// ponytail: a record that no longer decodes is left out and stays saved.
// Show it as unreadable, as the lists do, if a card format ever changes.
fn load_cards(db: Database) -> Promise(Result(List(Card), StorageError)) {
  use records <- promise.map(storage.get_all(
    db,
    storage.Cards,
    record_decoder(),
  ))
  use records <- result.map(records)
  use #(id, record) <- list.filter_map(records)
  result.map(record, fn(card) { card(id) }) |> result.replace_error(Nil)
}

// --- Which cards show where -------------------------------------------------

/// Whether a card at `card` belongs to `place`. A node is the same node in
/// any catalogue's scope.
fn belongs(card: Place, place: Place) -> Bool {
  case card, place {
    Game(set_id: a), Game(set_id: b) -> a == b
    Node(set_id: a, node_id: x, ..), Node(set_id: b, node_id: y, ..) ->
      a == b && x == y
    _, _ -> False
  }
}

/// Whether a card counts on a screen of the data set `set_id`: it belongs to
/// the whole game, or to a node for which `in_scope` holds.
fn counts(card: Card, set_id: String, in_scope: fn(String) -> Bool) -> Bool {
  case card.place {
    Game(set_id: card_set) -> card_set == set_id
    Node(set_id: card_set, node_id:, ..) ->
      card_set == set_id && in_scope(node_id)
  }
}

/// The cards for a unit: of those that count, as in `counts`, the ones whose
/// target names one of the unit's keywords as a word of its own, ignoring
/// case, then the others. A keyword `Abc: Def` is looked for as `Def` too,
/// since card text leaves the prefix out. A name shorter than three
/// characters is too common a word to look for. Since a target can also
/// name a keyword to leave it out, a match is only likely.
pub fn for_unit(
  cards: List(Card),
  set_id: String,
  in_scope: fn(String) -> Bool,
  keywords: List(String),
) -> #(List(Card), List(Card)) {
  let names =
    keywords
    |> list.flat_map(fn(keyword) {
      case string.split_once(keyword, ":") {
        Ok(#(_, plain)) -> [keyword, plain]
        Error(Nil) -> [keyword]
      }
    })
    |> list.map(fn(name) { string.lowercase(string.trim(name)) })
    |> list.filter(fn(name) { string.length(name) >= 3 })
  let links = text.links(list.map(names, fn(name) { #(name, Nil) }))
  list.filter(cards, counts(_, set_id, in_scope))
  |> list.partition(fn(card) {
    let target = string.lowercase(card.target)
    list.any(names, string.contains(target, _))
    && list.any(text.segments(target, links), fn(segment) {
      case segment {
        text.Link(..) -> True
        text.Text(..) -> False
      }
    })
  })
}

/// Each node's cards under its name from `name_of`, the names in order, then
/// the whole game's cards under "Whole game".
fn groups(
  cards: List(Card),
  name_of: fn(String) -> String,
) -> List(#(String, List(Card))) {
  let #(game, nodes) =
    list.partition(cards, fn(card) {
      case card.place {
        Game(..) -> True
        Node(..) -> False
      }
    })
  let named =
    list.group(nodes, fn(card) {
      case card.place {
        Node(node_id:, ..) -> name_of(node_id)
        Game(..) -> ""
      }
    })
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(group) { #(group.0, by_name(group.1)) })
  case game {
    [] -> named
    _ -> list.append(named, [#("Whole game", by_name(game))])
  }
}

fn by_name(cards: List(Card)) -> List(Card) {
  list.sort(cards, fn(a, b) { string.compare(a.name, b.name) })
}

// --- Views ------------------------------------------------------------------

/// The one card section of a node screen: the node's own cards, then, when
/// the node has keywords, the other cards of the scope for it as a unit, then
/// "Add a card" and the import. Rule names in the text link to the rule
/// nodes.
pub fn node_section(
  state: State,
  set_id: String,
  catalogue_id: String,
  node_id: String,
  built: Scope,
  page: Page,
  links: text.Links(String),
) -> Element(Msg) {
  let place = Node(set_id:, catalogue_id:, node_id:)
  let show_text = sheet_view.rich_text(_, links, fn(id) {
    route.to_hash(route.NodePage(set_id, catalogue_id, id))
  })
  let name_of = fn(id) {
    scope.find(built, id)
    |> result.map(fn(placed) { catalogue.name(placed.node) })
  }
  let #(own, others) =
    list.partition(saved_cards(state), fn(card) { belongs(card.place, place) })
  html.section([], [
    html.h2([], [html.text("Cards")]),
    cards_status(state),
    case own {
      [] -> element.none()
      _ -> card_list(by_name(own), True, show_text)
    },
    case page.keywords {
      [] -> element.none()
      keywords -> {
        let #(likely, other) =
          for_unit(
            others,
            set_id,
            fn(id) { result.is_ok(name_of(id)) },
            list.map(keywords, fn(keyword) { keyword.1 }),
          )
        unit_cards(
          likely,
          other,
          fn(id) { name_of(id) |> result.unwrap("") },
          show_text,
        )
      }
    },
    problem_view(state),
    add_and_import(place, "actions small"),
  ])
}

/// The card section of a data set screen: the cards for the whole game.
pub fn game_section(state: State, set_id: String) -> List(Element(Msg)) {
  [place_section(state, Game(set_id:), "Cards for the whole game", plain)]
}

/// The cards section of a list's force: the cards of `nodes`, each the node
/// id a chosen setting value links to with the value's name, then the whole
/// game's cards of the data set `set_id`, the list's game system. Nothing
/// when there are none.
pub fn list_section(
  state: State,
  set_id: String,
  nodes: List(#(String, String)),
) -> Element(msg) {
  let in_scope = fn(id) { list.key_find(nodes, id) |> result.is_ok }
  case list.filter(saved_cards(state), counts(_, set_id, in_scope)) {
    [] -> element.none()
    cards ->
      html.section([], [
        html.h2([], [html.text("Cards")]),
        ..group_views(
          cards,
          fn(id) { list.key_find(nodes, id) |> result.unwrap("") },
          plain,
          html.h3,
        )
      ])
  }
}

/// The cards for a unit of a list, as in `unit_cards`, from the cards in
/// `list_section`. Nothing when there are none.
pub fn list_unit_section(
  state: State,
  set_id: String,
  nodes: List(#(String, String)),
  keywords: List(String),
) -> Element(msg) {
  let in_scope = fn(id) { list.key_find(nodes, id) |> result.is_ok }
  let #(likely, other) =
    for_unit(saved_cards(state), set_id, in_scope, keywords)
  unit_cards(
    likely,
    other,
    fn(id) { list.key_find(nodes, id) |> result.unwrap("") },
    plain,
  )
}

/// The cards screen of one place.
pub fn place_page(state: State, place: Place) -> List(Element(Msg)) {
  let title = case place {
    Game(..) -> "Cards for the whole game"
    Node(..) -> "Cards"
  }
  [
    sheet_view.back_link(route.place_page(place), "Back"),
    html.h1([], [html.text(title)]),
    place_section(state, place, "", plain),
  ]
}

/// Text with `**bold**`, and no links.
fn plain(content: String) -> List(Element(msg)) {
  sheet_view.rich_text(content, text.links([]), fn(target: String) { target })
}

/// The cards of a place under `title`, then "Add a card" and the import.
fn place_section(
  state: State,
  place: Place,
  title: String,
  show_text: fn(String) -> List(Element(Msg)),
) -> Element(Msg) {
  html.section([], [
    case title {
      "" -> element.none()
      _ -> html.h2([], [html.text(title)])
    },
    cards_status(state),
    case state.cards {
      Some(Ok(cards)) ->
        case list.filter(cards, fn(card) { belongs(card.place, place) }) {
          [] -> note("No cards yet.")
          cards -> card_list(by_name(cards), True, show_text)
        }
      Some(Error(_)) | None -> element.none()
    },
    problem_view(state),
    add_and_import(place, "actions"),
  ])
}

/// Why there are no cards to show yet: they are being read, or could not be.
fn cards_status(state: State) -> Element(msg) {
  case state.cards {
    None -> note("Opening the cards…")
    Some(Error(error)) ->
      note(
        "The saved cards could not be read. "
        <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(_)) -> element.none()
  }
}

/// "Add a card" and "Import cards from a table" for `place`, in a row of
/// the class `class`.
fn add_and_import(place: Place, class: String) -> Element(Msg) {
  html.div([attribute.class(class)], [
    html.a(
      [
        attribute.class("button"),
        attribute.href(route.to_hash(route.NewCardPage(place))),
      ],
      [html.text("Add a card")],
    ),
    html.input([
      attribute.type_("file"),
      attribute.id("import-cards"),
      attribute.class("visually-hidden"),
      attribute.accept([
        ".csv", ".tsv", ".txt", "text/csv", "text/tab-separated-values",
        "text/plain",
      ]),
      event.on(
        "change",
        decode.at(["target"], decode.dynamic)
          |> decode.map(TableChosen(place, _)),
      ),
    ]),
    html.label([attribute.for("import-cards"), attribute.class("button")], [
      html.text("Import cards from a table"),
    ]),
  ])
}

/// The cards for a unit, collapsed under "Cards (N)": the likely ones under
/// "Likely for this unit", then the others collapsed under "Other cards
/// (N)", so a card the unit might use is never left out. Each part groups
/// its cards as `groups` does. Nothing when there are none.
fn unit_cards(
  likely: List(Card),
  other: List(Card),
  name_of: fn(String) -> String,
  show_text: fn(String) -> List(Element(msg)),
) -> Element(msg) {
  let titled = fn(title, cards) {
    title <> " (" <> int.to_string(list.length(cards)) <> ")"
  }
  case list.append(likely, other) {
    [] -> element.none()
    all ->
      html.details([attribute.class("unit-cards")], [
        html.summary([], [html.text(titled("Cards", all))]),
        case likely {
          [] -> element.none()
          _ ->
            element.fragment([
              html.h3([], [html.text("Likely for this unit")]),
              ..group_views(likely, name_of, show_text, html.h4)
            ])
        },
        case other {
          [] -> element.none()
          _ ->
            html.details([], [
              html.summary([], [html.text(titled("Other cards", other))]),
              ..group_views(other, name_of, show_text, html.h4)
            ])
        },
      ])
  }
}

/// Cards under a `heading` per group, as in `groups`.
fn group_views(
  cards: List(Card),
  name_of: fn(String) -> String,
  show_text: fn(String) -> List(Element(msg)),
  heading: fn(List(Attribute(msg)), List(Element(msg))) -> Element(msg),
) -> List(Element(msg)) {
  use group <- list.map(groups(cards, name_of))
  element.fragment([
    heading([], [html.text(group.0)]),
    card_list(group.1, True, show_text),
  ])
}

fn card_list(
  cards: List(Card),
  linked: Bool,
  show_text: fn(String) -> List(Element(msg)),
) -> Element(msg) {
  html.ul(
    [attribute.class("cards")],
    list.map(cards, card_view(_, linked, show_text)),
  )
}

/// A card: its name in bold, a link to its screen when `linked`, its cost,
/// then When, Target and Effect, each through `show_text`. Empty fields are
/// left out.
fn card_view(
  card: Card,
  linked: Bool,
  show_text: fn(String) -> List(Element(msg)),
) -> Element(msg) {
  let name = html.strong([], [html.text(card.name)])
  let line = fn(field, value) {
    case value {
      "" -> element.none()
      _ ->
        html.div([attribute.class("prose")], [
          html.span([attribute.class("card-label")], [
            html.text(label(field) <> ": "),
          ]),
          ..show_text(value)
        ])
    }
  }
  html.li([attribute.class("card")], [
    case linked {
      True ->
        html.a(
          [
            attribute.class("card-name"),
            attribute.href(route.to_hash(route.CardPage(card.id))),
          ],
          [name],
        )
      False -> html.p([attribute.class("card-name")], [name])
    },
    case card.cost {
      "" -> element.none()
      cost -> html.p([attribute.class("card-cost")], [html.text(cost)])
    },
    line(When, card.when),
    line(Target, card.target),
    line(Effect, card.effect),
  ])
}

fn note(text: String) -> Element(msg) {
  html.p([attribute.class("note")], [html.text(text)])
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

/// The screen for a new card in `place`.
pub fn new_card_page(state: State, place: Place) -> List(Element(Msg)) {
  let card =
    Card(
      id: "",
      name: "",
      cost: "",
      when: "",
      target: "",
      effect: "",
      place:,
      edited: 0,
    )
  form_page(state, "New card", card, None)
}

/// The screen for one saved card: its form, and Delete.
pub fn card_page(state: State, card_id: String) -> List(Element(Msg)) {
  case state.cards {
    None -> [note("Opening…")]
    Some(Error(error)) ->
      sheet_view.not_found(
        "The saved cards could not be read. "
        <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(cards)) ->
      case list.find(cards, fn(card) { card.id == card_id }) {
        Error(Nil) -> sheet_view.not_found("This card is not on this device.")
        Ok(card) ->
          list.append(form_page(state, "Edit card", card, Some(card.id)), [
            delete_view(card.id, state.confirming == Some(card.id)),
          ])
      }
  }
}

/// The card form, filled in from `card`. The browser keeps what is typed
/// until Save, so the form is new for each card.
fn form_page(
  state: State,
  title: String,
  card: Card,
  id: Option(String),
) -> List(Element(Msg)) {
  let line = fn(field, value, required) {
    let field_id = "card-" <> key(field)
    html.div([attribute.class("field")], [
      html.label([attribute.for(field_id)], [html.text(label(field))]),
      html.input([
        attribute.type_("text"),
        attribute.id(field_id),
        attribute.name(key(field)),
        attribute.default_value(value),
        attribute.required(required),
        attribute.autocomplete("off"),
      ]),
    ])
  }
  let area = fn(field, value, rows) {
    let field_id = "card-" <> key(field)
    html.div([attribute.class("field")], [
      html.label([attribute.for(field_id)], [html.text(label(field))]),
      html.textarea(
        [
          attribute.id(field_id),
          attribute.name(key(field)),
          attribute.rows(rows),
        ],
        value,
      ),
    ])
  }
  [
    back_button(),
    html.h1([], [html.text(title)]),
    keyed.fragment([
      #(
        option.unwrap(id, "new"),
        html.form([event.on_submit(FormSubmitted(id, card.place, _))], [
          line(Name, card.name, True),
          line(Cost, card.cost, False),
          area(When, card.when, 2),
          area(Target, card.target, 2),
          area(Effect, card.effect, 6),
          problem_view(state),
          html.div([attribute.class("actions")], [
            html.button(
              [attribute.type_("submit"), attribute.class("button primary")],
              [html.text("Save")],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.class("button"),
                event.on_click(Cancelled),
              ],
              [html.text("Cancel")],
            ),
          ]),
        ]),
      ),
    ]),
  ]
}

/// Back to the screen the card or the import was opened from.
fn back_button() -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("back"),
      event.on_click(Cancelled),
    ],
    [sheet_view.arrow(), html.text("Back")],
  )
}

fn delete_view(id: String, confirming: Bool) -> Element(Msg) {
  html.div([attribute.class("delete")], [
    case confirming {
      False ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button quiet"),
            event.on_click(DeleteClicked(id)),
          ],
          [html.text("Delete")],
        )
      True ->
        html.div([attribute.class("confirm"), attribute.role("group")], [
          html.span([], [html.text("Delete this card?")]),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("button danger"),
              event.on_click(DeleteConfirmed(id)),
            ],
            [html.text("Yes")],
          ),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("button"),
              attribute.autofocus(True),
              event.on_click(DeleteCancelled),
            ],
            [html.text("No")],
          ),
        ])
    },
  ])
}

/// The import screen: a column for each field, a preview of the first three
/// cards, and the import.
pub fn import_page(state: State, place: Place) -> List(Element(Msg)) {
  let back = back_button()
  // A file opened for the same node from another catalogue is still its file.
  let pending =
    option.then(state.pending, fn(pending) {
      case belongs(pending.place, place) {
        True -> Some(pending)
        False -> None
      }
    })
  case pending {
    Some(pending) -> {
      let #(cards, skipped) = import_cards(pending, fn() { "" })
      let rows = list.length(pending.table.rows)
      [
        back,
        html.h1([], [html.text("Import cards")]),
        note(pending.file_name <> ": " <> count(rows, "row", "rows")),
        ..list.flatten([
          list.map(fields, fn(field) {
            column_select(
              pending.table,
              "column-" <> key(field),
              label(field),
              "(none)",
              dict.get(pending.columns, field) |> option.from_result,
              ColumnChosen(field, _),
            )
          }),
          [
            case dict.has_key(pending.columns, Name) {
              True -> element.none()
              False -> note("Choose the column that holds the name.")
            },
            column_select(
              pending.table,
              "only-column",
              "Only rows where",
              "(every row)",
              option.map(pending.only, fn(only) { only.0 }),
              OnlyColumnChosen,
            ),
            case pending.only {
              Some(#(column, value)) ->
                value_select(pending.table, column, value)
              None -> element.none()
            },
            html.label([attribute.class("check")], [
              html.input([
                attribute.type_("checkbox"),
                attribute.checked(pending.replace),
                event.on_check(ReplaceChecked),
              ]),
              html.text("Replace the cards already here"),
            ]),
            case replaced(saved_cards(state), pending) {
              [] -> element.none()
              ids ->
                note(
                  count(list.length(ids), "card", "cards")
                  <> " already here will be deleted.",
                )
            },
            case cards {
              [] -> element.none()
              _ ->
                html.section([], [
                  html.h2([], [html.text("Preview")]),
                  card_list(list.take(cards, 3), False, plain),
                ])
            },
            case skipped {
              0 -> element.none()
              _ ->
                note(
                  count(skipped, "row has", "rows have")
                  <> " no name and will be skipped.",
                )
            },
            problem_view(state),
            html.div([attribute.class("actions")], [
              html.button(
                [
                  attribute.type_("button"),
                  attribute.class("button primary"),
                  attribute.disabled(cards == []),
                  event.on_click(ImportClicked),
                ],
                [
                  html.text(
                    "Import " <> count(list.length(cards), "card", "cards"),
                  ),
                ],
              ),
              html.button(
                [
                  attribute.type_("button"),
                  attribute.class("button"),
                  event.on_click(Cancelled),
                ],
                [html.text("Cancel")],
              ),
            ]),
          ],
        ])
      ]
    }
    None -> [
      back,
      html.h1([], [html.text("Import cards")]),
      note("No table file is open. Choose one with Import cards from a table."),
    ]
  }
}

/// A select of the table's columns under `title`, `none` first for no
/// column.
fn column_select(
  read: Table,
  id: String,
  title: String,
  none: String,
  chosen: Option(Int),
  to_msg: fn(Option(Int)) -> Msg,
) -> Element(Msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for(id)], [html.text(title)]),
    html.select(
      [
        attribute.id(id),
        event.on_change(fn(value) {
          to_msg(int.parse(value) |> option.from_result)
        }),
      ],
      [
        html.option(
          [attribute.value(""), attribute.selected(chosen == None)],
          none,
        ),
        ..list.index_map(read.header, fn(_, index) {
          html.option(
            [
              attribute.value(int.to_string(index)),
              attribute.selected(chosen == Some(index)),
            ],
            header_name(read, index),
          )
        })
      ],
    ),
  ])
}

/// A select of the values the column `index` holds, for "Only rows where".
fn value_select(read: Table, index: Int, chosen: String) -> Element(Msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for("only-value")], [
      html.text(header_name(read, index) <> " is"),
    ]),
    html.select(
      [attribute.id("only-value"), event.on_change(OnlyValueChosen)],
      list.map(values(read, index), fn(value) {
        html.option(
          [attribute.value(value), attribute.selected(value == chosen)],
          case value {
            "" -> "(empty)"
            _ -> value
          },
        )
      }),
    ),
  ])
}

/// The header of the column `index`, or its number when the header is blank.
fn header_name(read: Table, index: Int) -> String {
  case cell(read.header, index) {
    "" -> "Column " <> int.to_string(index + 1)
    name -> name
  }
}

fn count(number: Int, one: String, many: String) -> String {
  case number {
    1 -> "1 " <> one
    _ -> int.to_string(number) <> " " <> many
  }
}

fn describe_problem(problem: Problem) -> String {
  case problem {
    NoName -> "A card needs a name."
    NotSaved(error) ->
      "The cards could not be saved. "
      <> sheet_view.describe_storage_error(error)
    NotDeleted(error) ->
      "The card could not be deleted. "
      <> sheet_view.describe_storage_error(error)
    FileNotRead(reason) -> "That file could not be read. " <> reason
    NoRows -> "That file has no rows."
    NoStorage -> "Storage is not open on this device, so cards cannot change."
  }
}
