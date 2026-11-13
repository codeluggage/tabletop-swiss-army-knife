//// Tabletop: the shell around the features. Opens storage, asks the browser
//// to keep it, records the first visit, follows the screen in the URL hash,
//// reads a chosen file and sends it to the feature for its kind, and offers a
//// reload when a newer build is out. Each feature keeps its own state,
//// messages and screens in its own module, and the shell sends it the routes
//// it owns. The list feature is `tabletop/lists`, the game data feature
//// `tabletop/data`, the cards feature `tabletop/cards`.

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import tabletop/browser
import tabletop/cards
import tabletop/data
import tabletop/effects
import tabletop/lists
import tabletop/route.{type Route}
import tabletop/sheet_view
import tabletop/storage.{type Database, type Persistence, type StorageError}
import tabletop/version
import tabletop/zip

pub fn main() -> Nil {
  let flags =
    Flags(
      running: browser.running_version(),
      commit: browser.running_commit(),
      hash: route.current_hash(),
    )
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}

/// What the page knows at start: the stamped version and commit, and
/// `location.hash`.
pub type Flags {
  Flags(running: String, commit: String, hash: String)
}

/// Each `Option` is `None` until the browser answers.
pub type Model {
  Model(
    running: String,
    commit: String,
    route: Route,
    storage: Option(Result(Database, StorageError)),
    persistence: Option(Persistence),
    first_opened: Option(Result(Int, StorageError)),
    /// What went wrong with the last chosen file itself.
    file_problem: Option(FileProblem),
    lists: lists.State,
    data: data.State,
    cards: cards.State,
    /// How far down each screen was when it was left, keyed by its hash.
    scroll: Dict(String, Float),
    update: Update,
  )
}

pub type Update {
  UpToDate
  Available
  Applying
}

/// What a chosen file is, from its bytes.
pub type FileKind {
  ZipKind
  TextKind(String)
  NeitherKind
}

pub type FileProblem {
  FileNotRead(reason: String)
  NotAKnownKind
}

pub type Msg {
  StorageOpened(Result(Database, StorageError))
  FirstOpenedLoaded(Result(Int, StorageError))
  PersistAnswered(Persistence)
  VersionFetched(Result(String, String))
  VisibilityChanged(String)
  ReloadClicked
  WorkerActivated(Bool)
  ControllerChanged
  HashChanged(hash: String, left_at: Float)
  FileChosen(input: Dynamic)
  FileRead(Result(#(String, BitArray), String))
  ListsMsg(lists.Msg)
  DataMsg(data.Msg)
  CardsMsg(cards.Msg)
}

const first_opened_key = "first_opened"

pub fn init(flags: Flags) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      running: flags.running,
      commit: flags.commit,
      route: route.parse(flags.hash),
      storage: None,
      persistence: None,
      first_opened: None,
      file_problem: None,
      lists: lists.init(),
      data: data.init(),
      cards: cards.init(),
      scroll: dict.new(),
      update: UpToDate,
    )
  #(
    model,
    effect.batch([
      effects.from_promise(storage.open, StorageOpened),
      effects.from_promise(storage.persist, PersistAnswered),
      check_version(),
      listen(),
    ]),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    StorageOpened(Ok(db)) -> #(
      Model(..model, storage: Some(Ok(db))),
      effect.batch([
        effects.from_promise(fn() { load_first_opened(db) }, FirstOpenedLoaded),
        lists.load(Ok(db)) |> effect.map(ListsMsg),
        data.load(Ok(db)) |> effect.map(DataMsg),
        cards.load(Ok(db)) |> effect.map(CardsMsg),
      ]),
    )
    StorageOpened(Error(error)) -> #(
      Model(
        ..model,
        storage: Some(Error(error)),
        first_opened: Some(Error(error)),
      ),
      effect.batch([
        lists.load(Error(error)) |> effect.map(ListsMsg),
        data.load(Error(error)) |> effect.map(DataMsg),
        cards.load(Error(error)) |> effect.map(CardsMsg),
      ]),
    )
    FirstOpenedLoaded(result) -> #(
      Model(..model, first_opened: Some(result)),
      effect.none(),
    )
    PersistAnswered(answer) -> #(
      Model(..model, persistence: Some(answer)),
      effect.none(),
    )
    VersionFetched(fetched) -> #(
      Model(..model, update: update_after_fetch(model, fetched)),
      effect.none(),
    )
    VisibilityChanged("visible") -> #(model, check_version())
    VisibilityChanged(_) -> #(model, effect.none())
    ReloadClicked -> #(
      Model(..model, update: Applying),
      effects.from_promise(browser.activate_new_worker, WorkerActivated),
    )
    // The new worker takes over and fires ControllerChanged, which reloads.
    // ponytail: if its install fails nothing reloads; Reload stays on screen
    // and a second press tries again. Add a timeout if that ever bites.
    WorkerActivated(True) -> #(model, effect.none())
    WorkerActivated(False) -> #(model, reload())
    // A worker also takes over on the very first visit; reload only on request.
    ControllerChanged ->
      case model.update {
        Applying -> #(model, reload())
        UpToDate | Available -> #(model, effect.none())
      }
    // Remember where the screen being left was scrolled to, and go back to
    // where the next one was, or to its top.
    HashChanged(hash:, left_at:) -> {
      let scroll =
        dict.insert(model.scroll, route.to_hash(model.route), left_at)
      let next = route.parse(hash)
      let top = dict.get(scroll, route.to_hash(next)) |> result.unwrap(0.0)
      let #(model, entered) =
        Model(
          ..model,
          route: next,
          scroll:,
          file_problem: None,
          lists: lists.screen_changed(model.lists),
          data: data.screen_changed(model.data),
          cards: cards.screen_changed(model.cards),
        )
        |> enter_data
      #(model, effect.batch([scroll_to(top), entered]))
    }
    FileChosen(input:) -> #(
      Model(
        ..model,
        file_problem: None,
        lists: lists.file_chosen(model.lists),
        data: data.file_chosen(model.data),
      ),
      effects.from_promise(fn() { browser.read_chosen_file(input) }, FileRead),
    )
    FileRead(Error(reason)) -> #(
      Model(..model, file_problem: Some(FileNotRead(reason))),
      effect.none(),
    )
    FileRead(Ok(#(file_name, bytes))) ->
      case file_kind(bytes) {
        ZipKind ->
          data.import_zip(model.data, file_name, bytes) |> from_data(model)
        TextKind(text) ->
          lists.import_file(model.lists, model.storage, file_name, text)
          |> from_lists(model)
        NeitherKind -> #(
          Model(..model, file_problem: Some(NotAKnownKind)),
          effect.none(),
        )
      }
    ListsMsg(msg) ->
      lists.update(model.lists, msg, model.storage) |> from_lists(model)
    DataMsg(msg) -> {
      let #(model, done) =
        data.update(model.data, msg, model.storage) |> from_data(model)
      // A reload on a node screen opens its scope once the data sets are in.
      case msg {
        data.SetsLoaded(_) | data.SetSaved(_) -> {
          let #(model, entered) = enter_data(model)
          #(model, effect.batch([done, entered]))
        }
        _ -> #(model, done)
      }
    }
    CardsMsg(msg) ->
      cards.update(model.cards, msg, model.storage) |> from_cards(model)
  }
}

/// A zip by its signature, text when the bytes are UTF-8, else neither.
pub fn file_kind(bytes: BitArray) -> FileKind {
  // A zip is never decoded as text.
  use <- bool.guard(zip.is_zip(bytes), ZipKind)
  case bit_array.to_string(bytes) {
    Ok(text) -> TextKind(text)
    Error(Nil) -> NeitherKind
  }
}

fn enter_data(model: Model) -> #(Model, Effect(Msg)) {
  data.enter(model.data, model.route, model.storage) |> from_data(model)
}

/// The data feature's new state into the model, its effect into the app's.
fn from_data(
  step: #(data.State, Effect(data.Msg)),
  model: Model,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, data: step.0), effect.map(step.1, DataMsg))
}

/// The cards feature's new state into the model, its effect into the app's.
fn from_cards(
  step: #(cards.State, Effect(cards.Msg)),
  model: Model,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, cards: step.0), effect.map(step.1, CardsMsg))
}

/// The list feature's new state into the model, its effect into the app's.
fn from_lists(
  step: #(lists.State, Effect(lists.Msg)),
  model: Model,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, lists: step.0), effect.map(step.1, ListsMsg))
}

fn update_after_fetch(model: Model, fetched: Result(String, String)) -> Update {
  let running = version.parse(model.running)
  // The `release` key. An app from before releases reads the `version` key.
  let latest =
    result.try(fetched, fn(text) {
      version.from_json(text) |> result.replace_error("")
    })
  case model.update, running, latest {
    UpToDate, Ok(running), Ok(latest) ->
      case version.is_newer(latest, than: running) {
        True -> Available
        False -> UpToDate
      }
    current, _, _ -> current
  }
}

/// When this device first opened the app, recorded now if this is the first time.
fn load_first_opened(db: Database) -> Promise(Result(Int, StorageError)) {
  use stored <- promise.try_await(storage.get(
    db,
    storage.Meta,
    first_opened_key,
    decode.int,
  ))
  case stored {
    Some(ms) -> promise.resolve(Ok(ms))
    None -> {
      let now = browser.now_ms()
      storage.put(db, storage.Meta, first_opened_key, json.int(now))
      |> promise.map(result.replace(_, now))
    }
  }
}

fn check_version() -> Effect(Msg) {
  effects.from_promise(
    fn() { browser.fetch_no_store("version.json") },
    VersionFetched,
  )
}

fn listen() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.register_worker("sw.js")
  browser.on_visibility_change(fn(state) { dispatch(VisibilityChanged(state)) })
  browser.on_controller_change(fn() { dispatch(ControllerChanged) })
  browser.manual_scroll_restoration()
  route.on_hash_change(fn(hash) {
    dispatch(HashChanged(hash:, left_at: browser.scroll_y()))
  })
}

fn scroll_to(y: Float) -> Effect(Msg) {
  use _, _ <- effect.before_paint
  browser.scroll_to(y)
}

fn reload() -> Effect(Msg) {
  use _ <- effect.from
  browser.reload()
}

// --- Views ------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  let page = case model.route {
    route.Home -> home(model)
    route.ListPage(list_id:) ->
      lists.list_page(model.lists, list_id, data_links(model)) |> lists_view
    route.UnitPage(list_id:, unit_id:) ->
      lists.unit_page(model.lists, list_id, unit_id, data_links(model))
      |> lists_view
    route.RulePage(list_id:, rule_name:) ->
      lists.rule_page(model.lists, list_id, rule_name) |> lists_view
    route.DataSetPage(set_id:) ->
      data.set_page(
        model.data,
        set_id,
        DataMsg,
        cards.game_section(model.cards, set_id) |> cards_view,
      )
    route.CataloguePage(set_id:, catalogue_id:) ->
      data.catalogue_page(model.data, set_id, catalogue_id) |> data_view
    route.NodePage(set_id:, catalogue_id:, node_id:) ->
      data.node_page(
        model.data,
        set_id,
        catalogue_id,
        node_id,
        fn(built, page, links) {
          [
            cards.node_section(
              model.cards,
              set_id,
              catalogue_id,
              node_id,
              built,
              page,
              links,
            ),
          ]
          |> cards_view
        },
      )
    route.CardsPage(place:) ->
      cards.place_page(model.cards, place) |> cards_view
    route.NewCardPage(place:) ->
      cards.new_card_page(model.cards, place) |> cards_view
    route.CardPage(card_id:) ->
      cards.card_page(model.cards, card_id) |> cards_view
    route.ImportCardsPage(place:) ->
      cards.import_page(model.cards, place) |> cards_view
  }
  html.main(
    [attribute.class("page")],
    list.flatten([
      // First on every screen, so the person sees it without scrolling.
      [
        html.p([attribute.class("version-line")], [
          html.text("Version " <> model.running),
        ]),
      ],
      page,
      [update_bar(model.update)],
    ]),
  )
}

fn lists_view(elements: List(Element(lists.Msg))) -> List(Element(Msg)) {
  list.map(elements, element.map(_, ListsMsg))
}

fn data_view(elements: List(Element(data.Msg))) -> List(Element(Msg)) {
  list.map(elements, element.map(_, DataMsg))
}

fn cards_view(elements: List(Element(cards.Msg))) -> List(Element(Msg)) {
  list.map(elements, element.map(_, CardsMsg))
}

/// The list screens' links into game data and their cards. The list feature
/// never sees the data or cards features.
fn data_links(model: Model) -> lists.DataLinks {
  // The node of a chosen setting value is its last entry id, with the
  // value's name.
  let nodes = fn(values) {
    use value: #(String, List(String)) <- list.filter_map(values)
    list.last(value.1) |> result.map(fn(node_id) { #(node_id, value.0) })
  }
  lists.DataLinks(
    entry: fn(catalogue_id, entry_ids) {
      data.entry_href(model.data, catalogue_id, entry_ids)
    },
    value: fn(catalogue_id, entry_ids) {
      data.value_href(model.data, catalogue_id, entry_ids)
    },
    cards: fn(set_id, values) {
      cards.list_section(model.cards, set_id, nodes(values))
    },
    unit_cards: fn(set_id, values, keywords) {
      cards.list_unit_section(model.cards, set_id, nodes(values), keywords)
    },
  )
}

fn home(model: Model) -> List(Element(Msg)) {
  list.flatten([
    [
      html.h1([], [html.text("Tabletop")]),
      html.div([attribute.class("import")], [
        html.input([
          attribute.type_("file"),
          attribute.id("import-file"),
          attribute.class("visually-hidden"),
          attribute.accept([
            ".json", ".zip", "application/json", "application/zip",
          ]),
          attribute.disabled(data.importing(model.data)),
          event.on(
            "change",
            decode.at(["target"], decode.dynamic) |> decode.map(FileChosen),
          ),
        ]),
        html.label(
          [attribute.for("import-file"), attribute.class("button big")],
          [html.text("Import a file")],
        ),
        html.p([attribute.class("note")], [
          html.text("A list exported as JSON, or game data as one zip file."),
        ]),
      ]),
      case model.file_problem {
        None -> element.none()
        Some(problem) ->
          html.p([attribute.class("problem"), attribute.role("alert")], [
            html.text(describe_file_problem(problem)),
          ])
      },
    ],
    data_view(data.status(model.data)),
    lists_view(lists.home(model.lists)),
    data_view(data.home(model.data)),
    [
      html.section([attribute.class("about")], [
        html.h2([], [html.text("About this device")]),
        html.dl([], [
          fact("Version", model.running),
          fact("Commit", model.commit),
          fact("Storage", storage_label(model.storage)),
          fact("Persistent storage", persistence_label(model.persistence)),
          fact(
            "First opened on this device",
            first_opened_label(model.first_opened),
          ),
        ]),
      ]),
    ],
  ])
}

fn describe_file_problem(problem: FileProblem) -> String {
  case problem {
    FileNotRead(reason) -> "That file could not be read. " <> reason
    NotAKnownKind -> "That file is neither a JSON list nor a zip file."
  }
}

fn fact(term: String, detail: String) -> Element(Msg) {
  html.div([], [
    html.dt([], [html.text(term)]),
    html.dd([], [html.text(detail)]),
  ])
}

fn update_bar(update: Update) -> Element(Msg) {
  case update {
    UpToDate -> element.none()
    Available | Applying ->
      html.div([attribute.class("update-bar"), attribute.role("status")], [
        html.span([], [html.text("New version")]),
        html.button([attribute.type_("button"), event.on_click(ReloadClicked)], [
          html.text("Reload"),
        ]),
      ])
  }
}

fn storage_label(storage: Option(Result(Database, StorageError))) -> String {
  case storage {
    None -> "Opening…"
    Some(Ok(_)) -> "Open"
    Some(Error(error)) -> sheet_view.describe_storage_error(error)
  }
}

fn persistence_label(persistence: Option(Persistence)) -> String {
  case persistence {
    None -> "Asking the browser…"
    Some(storage.Persistent) -> "Granted"
    Some(storage.NotPersistent) ->
      "Not granted. The browser may clear saved data when space runs low."
    Some(storage.PersistUnavailable) -> "Not available in this browser"
  }
}

fn first_opened_label(
  first_opened: Option(Result(Int, StorageError)),
) -> String {
  case first_opened {
    None -> "Reading…"
    Some(Ok(ms)) -> browser.local_time(ms)
    Some(Error(error)) ->
      "Unknown. " <> sheet_view.describe_storage_error(error)
  }
}
