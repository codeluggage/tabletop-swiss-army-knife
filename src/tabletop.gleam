//// Tabletop: the home screen, and the start-up work behind it. Opens storage,
//// asks the browser to keep it, records the first visit, and offers a reload
//// when a newer build is out.

import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import tabletop/browser
import tabletop/storage.{type Database, type Persistence, type StorageError}
import tabletop/version

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", browser.running_version())
  Nil
}

/// Each `Option` is `None` until the browser answers.
pub type Model {
  Model(
    running: String,
    storage: Option(Result(Nil, StorageError)),
    persistence: Option(Persistence),
    first_opened: Option(Result(Int, StorageError)),
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
}

const first_opened_key = "first_opened"

pub fn init(running: String) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      running:,
      storage: None,
      persistence: None,
      first_opened: None,
      update: UpToDate,
    )
  #(
    model,
    effect.batch([
      from_promise(storage.open, StorageOpened),
      from_promise(storage.persist, PersistAnswered),
      check_version(),
      listen(),
    ]),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    StorageOpened(Ok(db)) -> #(
      Model(..model, storage: Some(Ok(Nil))),
      from_promise(fn() { load_first_opened(db) }, FirstOpenedLoaded),
    )
    StorageOpened(Error(error)) -> #(
      Model(
        ..model,
        storage: Some(Error(error)),
        first_opened: Some(Error(error)),
      ),
      effect.none(),
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
      from_promise(browser.activate_new_worker, WorkerActivated),
    )
    // The new worker takes over and fires ControllerChanged, which reloads.
    WorkerActivated(True) -> #(model, effect.none())
    WorkerActivated(False) -> #(model, reload())
    // A worker also takes over on the very first visit; reload only on request.
    ControllerChanged ->
      case model.update {
        Applying -> #(model, reload())
        UpToDate | Available -> #(model, effect.none())
      }
  }
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

fn from_promise(run: fn() -> Promise(a), to_msg: fn(a) -> Msg) -> Effect(Msg) {
  use dispatch <- effect.from
  let _ = promise.tap(run(), fn(value) { dispatch(to_msg(value)) })
  Nil
}

fn check_version() -> Effect(Msg) {
  from_promise(fn() { browser.fetch_no_store("version.json") }, VersionFetched)
}

fn listen() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.register_worker("sw.js")
  browser.on_visibility_change(fn(state) { dispatch(VisibilityChanged(state)) })
  browser.on_controller_change(fn() { dispatch(ControllerChanged) })
}

fn reload() -> Effect(Msg) {
  use _ <- effect.from
  browser.reload()
}

pub fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("home")], [
    html.h1([], [html.text("Tabletop")]),
    html.dl([], [
      fact("Version", model.running),
      fact("Storage", storage_label(model.storage)),
      fact("Persistent storage", persistence_label(model.persistence)),
      fact(
        "First opened on this device",
        first_opened_label(model.first_opened),
      ),
    ]),
    update_bar(model.update),
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

fn storage_label(storage: Option(Result(Nil, StorageError))) -> String {
  case storage {
    None -> "Opening…"
    Some(Ok(Nil)) -> "Open"
    Some(Error(error)) -> describe(error)
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
    Some(Error(error)) -> "Unknown. " <> describe(error)
  }
}

fn describe(error: StorageError) -> String {
  case error {
    storage.OpenFailed(reason) -> "Could not open. " <> reason
    storage.ReadFailed(reason) -> "Could not read. " <> reason
    storage.WriteFailed(reason) -> "Could not save. " <> reason
    storage.Undecodable(key) -> "The saved " <> key <> " could not be read."
  }
}
