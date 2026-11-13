//// The cards feature: short pieces of game text that the user types in or
//// imports from a table file. A card belongs to the whole game of a data set
//// or to one node in it. It shows on its place's screen, on a list whose
//// settings link to its node, and on a unit whose keywords its target names.
//// The shell in `tabletop.gleam` holds its `State`, wraps its `Msg`, sends it
//// the card routes, and puts its sections on the data and list screens.

import gleam/bit_array
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
import lustre/attribute
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
  NotText
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
  CardsSaved(Result(List(Card), StorageError))
  DeleteClicked(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  CardDeleted(id: String, result: Result(Nil, StorageError))
  TableChosen(place: Place, input: Dynamic)
  TableRead(place: Place, result: Result(#(String, BitArray), String))
  ColumnChosen(field: Field, column: Option(Int))
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
            )
          }
          #(
            State(..state, problem: None),
            effects.from_promise(fn() { save(db, [card()]) }, CardsSaved),
          )
        }
        _, _ -> #(State(..state, problem: Some(NoStorage)), effect.none())
      }
    }
    CardsSaved(Ok(saved)) -> {
      let ids = list.map(saved, fn(card) { card.id })
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
    CardsSaved(Error(error)) -> #(
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
    TableRead(place:, result: Ok(#(file_name, bytes))) ->
      case result.map(bit_array.to_string(bytes), table.parse) {
        Error(Nil) -> #(State(..state, problem: Some(NotText)), effect.none())
        Ok(table.Table(header: [], ..)) -> #(
          State(..state, problem: Some(NoRows)),
          effect.none(),
        )
        Ok(read) -> {
          let pending =
            Pending(place:, file_name:, table: read, columns: columns(read))
          #(State(..state, pending: Some(pending)), {
            use _ <- effect.from
            route.go(route.ImportCardsPage(place))
          })
        }
      }
    ColumnChosen(field:, column:) ->
      case state.pending {
        Some(pending) -> {
          let columns = case column {
            Some(column) -> dict.insert(pending.columns, field, column)
            None -> dict.delete(pending.columns, field)
          }
          #(
            State(..state, pending: Some(Pending(..pending, columns:))),
            effect.none(),
          )
        }
        None -> #(state, effect.none())
      }
    ImportClicked ->
      case state.pending, db {
        Some(pending), Some(Ok(db)) -> #(
          State(..state, problem: None),
          effects.from_promise(
            fn() { save(db, import_cards(pending, browser.random_id).0) },
            CardsSaved,
          ),
        )
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

/// The cards the rows of an import become, each with an id from `new_id`,
/// and how many rows are skipped for having no name.
pub fn import_cards(
  pending: Pending,
  new_id: fn() -> String,
) -> #(List(Card), Int) {
  let cards =
    list.filter_map(pending.table.rows, fn(row) {
      let value = fn(field) {
        dict.get(pending.columns, field)
        |> result.try(fn(index) { list.drop(row, index) |> list.first })
        |> result.unwrap("")
        |> string.trim
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
          ))
      }
    })
  #(cards, list.length(pending.table.rows) - list.length(cards))
}

// --- Storage ----------------------------------------------------------------

/// The changes that save `cards`, all of them in one `storage.write`.
pub fn writes(cards: List(Card)) -> List(storage.Write) {
  use card <- list.map(cards)
  storage.Put(storage.Cards, card.id, storage.JsonValue(encode(card)))
}

fn save(
  db: Database,
  cards: List(Card),
) -> Promise(Result(List(Card), StorageError)) {
  storage.write(db, writes(cards)) |> promise.map(result.replace(_, cards))
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
  decode.success(fn(id) {
    Card(id:, name:, cost:, when:, target:, effect:, place:)
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

/// The cards for a unit: those that count, as in `counts`, whose target names
/// one of the unit's keywords as a word of its own, ignoring case. A keyword
/// shorter than three characters is too common a word to look for.
pub fn for_unit(
  cards: List(Card),
  set_id: String,
  in_scope: fn(String) -> Bool,
  keywords: List(String),
) -> List(Card) {
  let names =
    keywords
    |> list.map(fn(keyword) { string.lowercase(string.trim(keyword)) })
    |> list.filter(fn(name) { string.length(name) >= 3 })
  let links = text.links(list.map(names, fn(name) { #(name, Nil) }))
  use card <- list.filter(cards)
  counts(card, set_id, in_scope)
  && list.any(names, string.contains(string.lowercase(card.target), _))
  && list.any(text.segments(string.lowercase(card.target), links), fn(segment) {
    case segment {
      text.Link(..) -> True
      text.Text(..) -> False
    }
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

/// The name of the node with this id among `nodes`, places with their names.
fn node_name(
  nodes: List(#(Place, String)),
  node_id: String,
) -> Result(String, Nil) {
  use #(place, name) <- list.find_map(nodes)
  case place {
    Node(node_id: id, ..) if id == node_id -> Ok(name)
    _ -> Error(Nil)
  }
}

// --- Views ------------------------------------------------------------------

/// The card sections of a node screen: the node's own cards, then, when the
/// node has keywords, the cards for it as a unit. Rule names in the text link
/// to the rule nodes.
pub fn node_sections(
  state: State,
  set_id: String,
  catalogue_id: String,
  node_id: String,
  built: Scope,
  page: Page,
  links: text.Links(String),
) -> List(Element(Msg)) {
  let show_text = sheet_view.rich_text(_, links, fn(id) {
    route.to_hash(route.NodePage(set_id, catalogue_id, id))
  })
  let name_of = fn(id) {
    scope.find(built, id)
    |> result.map(fn(placed) { catalogue.name(placed.node) })
  }
  let keywords = list.map(page.keywords, fn(keyword) { keyword.1 })
  [
    place_section(
      state,
      Node(set_id:, catalogue_id:, node_id:),
      "Cards",
      show_text,
    ),
    case keywords {
      [] -> element.none()
      _ ->
        grouped(
          "Cards for this unit",
          for_unit(
            saved_cards(state),
            set_id,
            fn(id) { result.is_ok(name_of(id)) },
            keywords,
          ),
          fn(id) { name_of(id) |> result.unwrap("") },
          show_text,
        )
    },
  ]
}

/// The card section of a data set screen: the cards for the whole game.
pub fn game_section(state: State, set_id: String) -> List(Element(Msg)) {
  [place_section(state, Game(set_id:), "Cards for the whole game", plain)]
}

/// The cards section of a list's force: the cards of `nodes`, each the place
/// a chosen setting value links to with its name, then the whole game's
/// cards of the data set `set_id`. Nothing when there are none.
pub fn list_section(
  state: State,
  set_id: String,
  nodes: List(#(Place, String)),
) -> Element(msg) {
  let in_scope = fn(id) { result.is_ok(node_name(nodes, id)) }
  grouped(
    "Cards",
    list.filter(saved_cards(state), counts(_, set_id, in_scope)),
    fn(id) { node_name(nodes, id) |> result.unwrap("") },
    plain,
  )
}

/// The cards for a unit of a list: of the cards in `list_section`, those
/// whose target names one of the unit's keywords. Nothing when there are
/// none.
pub fn list_unit_section(
  state: State,
  set_id: String,
  nodes: List(#(Place, String)),
  keywords: List(String),
) -> Element(msg) {
  let in_scope = fn(id) { result.is_ok(node_name(nodes, id)) }
  grouped(
    "Cards for this unit",
    for_unit(saved_cards(state), set_id, in_scope, keywords),
    fn(id) { node_name(nodes, id) |> result.unwrap("") },
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
    case state.cards {
      None -> note("Opening the cards…")
      Some(Error(error)) ->
        note(
          "The saved cards could not be read. "
          <> sheet_view.describe_storage_error(error),
        )
      Some(Ok(cards)) ->
        case list.filter(cards, fn(card) { belongs(card.place, place) }) {
          [] -> note("No cards yet.")
          cards -> card_list(by_name(cards), True, show_text)
        }
    },
    problem_view(state),
    html.div([attribute.class("actions")], [
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
    ]),
  ])
}

/// Cards under headings, as in `groups`, in a section under `title`. Nothing
/// when there are no cards.
fn grouped(
  title: String,
  cards: List(Card),
  name_of: fn(String) -> String,
  show_text: fn(String) -> List(Element(msg)),
) -> Element(msg) {
  case cards {
    [] -> element.none()
    _ ->
      html.section([], [
        html.h2([], [html.text(title)]),
        ..list.map(groups(cards, name_of), fn(group) {
          element.fragment([
            html.h3([], [html.text(group.0)]),
            card_list(group.1, True, show_text),
          ])
        })
      ])
  }
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
    Card(id: "", name: "", cost: "", when: "", target: "", effect: "", place:)
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
          list.map(fields, column_select(pending, _)),
          [
            case dict.has_key(pending.columns, Name) {
              True -> element.none()
              False -> note("Choose the column that holds the name.")
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

fn column_select(pending: Pending, field: Field) -> Element(Msg) {
  let field_id = "column-" <> key(field)
  let chosen = dict.get(pending.columns, field) |> option.from_result
  html.div([attribute.class("field")], [
    html.label([attribute.for(field_id)], [html.text(label(field))]),
    html.select(
      [
        attribute.id(field_id),
        event.on_change(fn(value) {
          ColumnChosen(field, int.parse(value) |> option.from_result)
        }),
      ],
      [
        html.option(
          [attribute.value(""), attribute.selected(chosen == None)],
          "(none)",
        ),
        ..list.index_map(pending.table.header, fn(header, index) {
          let name = case string.trim(header) {
            "" -> "Column " <> int.to_string(index + 1)
            name -> name
          }
          html.option(
            [
              attribute.value(int.to_string(index)),
              attribute.selected(chosen == Some(index)),
            ],
            name,
          )
        })
      ],
    ),
  ])
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
    NotText ->
      "That file is not UTF-8 text. In a spreadsheet, save it as CSV UTF-8."
    NoRows -> "That file has no rows."
    NoStorage -> "Storage is not open on this device, so cards cannot change."
  }
}
