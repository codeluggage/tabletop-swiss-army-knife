//// Tabletop: the shell around the features. Opens storage, asks the browser
//// to keep it, records the first visit, follows the screen in the URL hash,
//// reads a chosen file and sends it to the feature for its kind, and offers a
//// reload when a newer build is out. Each feature keeps its own state,
//// messages and screens in its own module, and the shell sends it the routes
//// it owns. The list feature is `tabletop/lists`, the game data feature
//// `tabletop/data`, the cards feature `tabletop/cards`, the backup feature
//// `tabletop/backup`, the game tracker `tabletop/tracker`.

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
import tabletop/backup
import tabletop/browser
import tabletop/cards
import tabletop/data
import tabletop/effects
import tabletop/lists
import tabletop/route.{type Route}
import tabletop/sheet_view
import tabletop/storage.{type Database, type Persistence, type StorageError}
import tabletop/tracker
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
    local_source_url: String,
    lists: lists.State,
    data: data.State,
    cards: cards.State,
    backup: backup.State,
    tracker: tracker.State,
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
  /// JSON that says it is a backup: the backup, or why it cannot be one.
  BackupKind(Result(backup.Backup, backup.ReadError))
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
  LocalDataClicked
  LocalSourceUrlChanged(String)
  LocalPageFetched(Result(#(String, Int, String, String), String))
  ListsMsg(lists.Msg)
  DataMsg(data.Msg)
  CardsMsg(cards.Msg)
  BackupMsg(backup.Msg)
  TrackerMsg(tracker.Msg)
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
      local_source_url: "",
      lists: lists.init(),
      data: data.init(),
      cards: cards.init(),
      backup: backup.init(),
      tracker: tracker.init(),
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
        backup.load(Ok(db)) |> effect.map(BackupMsg),
        load_features(Ok(db)),
      ]),
    )
    StorageOpened(Error(error)) -> #(
      Model(
        ..model,
        storage: Some(Error(error)),
        first_opened: Some(Error(error)),
      ),
      effect.batch([
        backup.load(Error(error)) |> effect.map(BackupMsg),
        load_features(Error(error)),
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
          backup: backup.screen_changed(model.backup),
          tracker: tracker.screen_changed(model.tracker),
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
        backup: backup.screen_changed(model.backup),
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
        BackupKind(read) ->
          backup.file_read(model.backup, read, model.storage)
          |> from_backup(model)
        TextKind(text) ->
          lists.import_file(model.lists, model.storage, file_name, text)
          |> from_lists(model)
        NeitherKind -> #(
          Model(..model, file_problem: Some(NotAKnownKind)),
          effect.none(),
        )
      }
    LocalSourceUrlChanged(url) -> #(
      Model(..model, local_source_url: url),
      effect.none(),
    )
    LocalDataClicked -> #(
      Model(..model, file_problem: None),
      effects.from_promise(
        fn() { browser.fetch_local_page(model.local_source_url) },
        LocalPageFetched,
      ),
    )
    LocalPageFetched(Ok(#(name, points, details, preview_html))) -> #(
      Model(
        ..model,
        lists: lists.add_imported_entry(
          model.lists,
          name,
          points,
          details,
          preview_html,
        ),
      ),
      effect.none(),
    )
    LocalPageFetched(Error(reason)) -> #(
      Model(..model, file_problem: Some(FileNotRead(reason))),
      effect.none(),
    )
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
    TrackerMsg(msg) -> {
      let #(tracker, done) = tracker.update(model.tracker, msg, model.storage)
      #(Model(..model, tracker:), effect.map(done, TrackerMsg))
    }
    BackupMsg(msg) -> {
      let #(model, done) =
        backup.update(model.backup, msg, model.storage) |> from_backup(model)
      case msg, model.storage {
        // Every feature reads its stores again, so the restored records show.
        backup.Restored(Ok(Nil)), Some(db) -> #(
          Model(
            ..model,
            lists: lists.init(),
            data: data.init(),
            cards: cards.init(),
            tracker: tracker.init(),
          ),
          effect.batch([done, load_features(db)]),
        )
        _, _ -> #(model, done)
      }
    }
  }
}

/// Each feature reads what it keeps in storage, as when the app opens.
fn load_features(db: Result(Database, StorageError)) -> Effect(Msg) {
  effect.batch([
    lists.load(db) |> effect.map(ListsMsg),
    data.load(db) |> effect.map(DataMsg),
    cards.load(db) |> effect.map(CardsMsg),
    tracker.load(db) |> effect.map(TrackerMsg),
  ])
}

/// A zip by its signature, a backup by its `format`, other text when the
/// bytes are UTF-8, else neither.
pub fn file_kind(bytes: BitArray) -> FileKind {
  // A zip is never decoded as text.
  use <- bool.guard(zip.is_zip(bytes), ZipKind)
  case bit_array.to_string(bytes) {
    Ok(text) ->
      case backup.read(text, schema: storage.schema_version()) {
        Error(backup.NotABackup) -> TextKind(text)
        read -> BackupKind(read)
      }
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

/// The backup feature's new state into the model, its effect into the app's.
fn from_backup(
  step: #(backup.State, Effect(backup.Msg)),
  model: Model,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, backup: step.0), effect.map(step.1, BackupMsg))
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
    route.NewListPage ->
      list.flatten([
        local_data_button(model.local_source_url),
        lists_view(lists.new_list_page(model.lists)),
        [file_problem_view(model.file_problem)],
        data_view(data.status(model.data)),
        data_view(data.home(model.data)),
      ])
    // The way back to a game that picked this list comes first.
    route.ListPage(list_id:) ->
      list.append(
        tracker.back_to_game(model.tracker, list_id) |> tracker_view,
        lists.list_page(model.lists, list_id, data_links(model)) |> lists_view,
      )
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
    route.SheetsPage -> tracker.sheets_page(model.tracker) |> tracker_view
    route.SheetPage(sheet_id:) ->
      tracker.sheet_page(model.tracker, sheet_id) |> tracker_view
    route.GamesPage -> tracker.games_page(model.tracker) |> tracker_view
    route.NewGamePage ->
      tracker.new_game_page(model.tracker, lists.names(model.lists))
      |> tracker_view
    route.GamePage(game_id:) ->
      tracker.game_page(model.tracker, game_id) |> tracker_view
  }
  html.main(
    [attribute.class("page")],
    list.flatten([
      // First on every screen, so the person sees it without scrolling.
      [
        html.p([attribute.class("version-line")], [
          html.text("Version " <> model.running),
        ]),
        import_file_input(model),
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

fn backup_view(elements: List(Element(backup.Msg))) -> List(Element(Msg)) {
  list.map(elements, element.map(_, BackupMsg))
}

fn tracker_view(elements: List(Element(tracker.Msg))) -> List(Element(Msg)) {
  list.map(elements, element.map(_, TrackerMsg))
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

/// The home screen, or the question about a chosen backup file in its place.
fn home(model: Model) -> List(Element(Msg)) {
  use <- bool.lazy_guard(backup.asking(model.backup), fn() {
    backup.question_page(model.backup) |> backup_view
  })
  // Nothing on this screen can read or save, so one message stands in for
  // the import and every feature.
  use <- bool.lazy_guard(
    model.storage == Some(Error(storage.AppOlderThanData)),
    fn() {
      [
        html.h1([], [html.text("Tabletop")]),
        html.p([attribute.class("problem"), attribute.role("alert")], [
          html.text(
            "This is an older version of the app than the data saved on this device. Tap Reload below. If there is no Reload, close the app fully and open it again. Nothing saved on this device was lost.",
          ),
        ]),
        about(model),
      ]
    },
  )
  list.flatten([
    [
      html.h1([], [html.text("Tabletop")]),
      html.div([attribute.class("import")], [
        html.label(
          [attribute.for("import-file"), attribute.class("button big")],
          [html.text("Import a file")],
        ),
        html.p([attribute.class("note")], [
          html.text(
            "A list exported as JSON, game data as one zip file, or a backup file.",
          ),
        ]),
      ]),
      file_problem_view(model.file_problem),
    ],
    backup_view(backup.status(model.backup)),
    data_view(data.status(model.data)),
    lists_view(lists.home(model.lists)),
    data_view(data.home(model.data)),
    tracker_view(tracker.home(model.tracker)),
    backup_view(backup.section(model.backup)),
    [about(model)],
  ])
}

fn import_file_input(model: Model) -> Element(Msg) {
  let accepted = case model.route {
    route.NewListPage -> [".zip", "application/zip"]
    _ -> [".json", ".zip", "application/json", "application/zip"]
  }
  html.input([
    attribute.type_("file"),
    attribute.id("import-file"),
    attribute.class("visually-hidden"),
    attribute.accept(accepted),
    attribute.disabled(data.importing(model.data)),
    event.on(
      "change",
      decode.at(["target"], decode.dynamic) |> decode.map(FileChosen),
    ),
  ])
}

fn local_data_button(source_url: String) -> List(Element(Msg)) {
  case browser.is_local_development() {
    True -> [
      html.div([attribute.class("field")], [
        html.label([attribute.for("local-source-url")], [
          html.text("Unit page address (optional)"),
        ]),
        html.input([
          attribute.type_("url"),
          attribute.id("local-source-url"),
          attribute.value(source_url),
          attribute.placeholder("Leave blank for the local default"),
          attribute.autocomplete("url"),
          event.on_input(LocalSourceUrlChanged),
        ]),
      ]),
      html.button(
        [attribute.class("button big"), event.on_click(LocalDataClicked)],
        [html.text("Add unit from page")],
      ),
      html.p([attribute.class("note")], [
        html.text(
          "Loads the page name, first listed cost and unit details into the list. You can add units from more page addresses.",
        ),
      ]),
    ]
    False -> []
  }
}

fn file_problem_view(problem: Option(FileProblem)) -> Element(Msg) {
  case problem {
    None -> element.none()
    Some(problem) ->
      html.p([attribute.class("problem"), attribute.role("alert")], [
        html.text(describe_file_problem(problem)),
      ])
  }
}

fn about(model: Model) -> Element(Msg) {
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
  ])
}

fn describe_file_problem(problem: FileProblem) -> String {
  case problem {
    FileNotRead(reason) -> "That file could not be read. " <> reason
    NotAKnownKind ->
      "That file is not a JSON list, a zip file or a backup file."
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
