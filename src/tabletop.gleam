//// Tabletop: the shell around the features. Opens storage, asks the browser
//// to keep it, records the first visit, follows the screen in the URL hash,
//// reads a chosen file, and offers a reload when a newer build is out. Each
//// feature keeps its own state, messages and screens in its own module, and
//// the shell sends it the routes it owns. The list feature is
//// `tabletop/lists`.

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
import tabletop/effects
import tabletop/lists
import tabletop/route.{type Route}
import tabletop/sheet_view
import tabletop/storage.{type Database, type Persistence, type StorageError}
import tabletop/version

pub fn main() -> Nil {
  let flags =
    Flags(running: browser.running_version(), hash: route.current_hash())
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}

/// What the page knows at start: the stamped version and `location.hash`.
pub type Flags {
  Flags(running: String, hash: String)
}

/// Each `Option` is `None` until the browser answers.
pub type Model {
  Model(
    running: String,
    route: Route,
    storage: Option(Result(Database, StorageError)),
    persistence: Option(Persistence),
    first_opened: Option(Result(Int, StorageError)),
    lists: lists.State,
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
  FileRead(Result(#(String, String), String))
  ListsMsg(lists.Msg)
}

const first_opened_key = "first_opened"

pub fn init(flags: Flags) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      running: flags.running,
      route: route.parse(flags.hash),
      storage: None,
      persistence: None,
      first_opened: None,
      lists: lists.init(),
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
      ]),
    )
    StorageOpened(Error(error)) -> #(
      Model(
        ..model,
        storage: Some(Error(error)),
        first_opened: Some(Error(error)),
      ),
      lists.load(Error(error)) |> effect.map(ListsMsg),
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
      #(
        Model(
          ..model,
          route: next,
          scroll:,
          lists: lists.screen_changed(model.lists),
        ),
        scroll_to(top),
      )
    }
    FileChosen(input:) -> #(
      Model(..model, lists: lists.file_chosen(model.lists)),
      effects.from_promise(fn() { browser.read_chosen_file(input) }, FileRead),
    )
    FileRead(Error(reason)) -> #(
      Model(..model, lists: lists.file_not_read(model.lists, reason)),
      effect.none(),
    )
    FileRead(Ok(#(file_name, text))) ->
      lists.import_file(model.lists, model.storage, file_name, text)
      |> from_lists(model)
    ListsMsg(msg) ->
      lists.update(model.lists, msg, model.storage) |> from_lists(model)
  }
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
      lists.list_page(model.lists, list_id) |> lists_view
    route.UnitPage(list_id:, unit_id:) ->
      lists.unit_page(model.lists, list_id, unit_id) |> lists_view
    route.RulePage(list_id:, rule_name:) ->
      lists.rule_page(model.lists, list_id, rule_name) |> lists_view
  }
  html.main(
    [attribute.class("page")],
    list.append(page, [update_bar(model.update)]),
  )
}

fn lists_view(elements: List(Element(lists.Msg))) -> List(Element(Msg)) {
  list.map(elements, element.map(_, ListsMsg))
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
          attribute.accept([".json", "application/json"]),
          event.on(
            "change",
            decode.at(["target"], decode.dynamic) |> decode.map(FileChosen),
          ),
        ]),
        html.label(
          [attribute.for("import-file"), attribute.class("button big")],
          [
            html.text("Import a list"),
          ],
        ),
      ]),
    ],
    lists_view(lists.home(model.lists)),
    [
      html.section([attribute.class("about")], [
        html.h2([], [html.text("About this device")]),
        html.dl([], [
          fact("Version", model.running),
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
