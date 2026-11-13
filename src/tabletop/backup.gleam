//// The backup feature: a backup file holds every record the person loaded
//// or typed, in one JSON file to save on one device and open on another, or
//// on the same device after the browser cleared it. `kind` says which stores
//// go into it. Bytes go in as base64 text. The shell in `tabletop.gleam`
//// holds its `State`, wraps its `Msg`, hands it a chosen backup file through
//// `file_read`, shows the question in place of the home screen while it is
//// open, and has every feature read its stores again after a restore.
////
//// ```json
//// {"format":"tabletop-backup","made":"2026-11-13T15:42:00.000Z",
////  "release":"2026.11.13.1542","schema":4,
////  "stores":{"lists":[{"key":"…","json":{}}],
////            "data_zips":[{"key":"…","base64":"…"}]}}
//// ```

import gleam/bit_array
import gleam/bool
import gleam/dict
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
import lustre/event
import tabletop/browser
import tabletop/effects
import tabletop/sheet_view
import tabletop/storage.{
  type Database, type StorageError, type Store, type Value, type Write,
}

/// The `format` of every backup file.
pub const format = "tabletop-backup"

/// How a store goes into a backup.
pub type Kind {
  /// The person's own records: a backup holds every one, as it is stored.
  Source
  /// Built again from a source store, so a backup leaves it out.
  Made
  /// Only the keys named go into a backup. The rest belong to this device.
  SomeKeys(List(String))
}

/// Which stores a backup holds. No catch-all, so a new store does not
/// compile until it is placed here.
pub fn kind(store: Store) -> Kind {
  case store {
    // `first_opened` and `last_backup` say when this device did something.
    storage.Meta -> SomeKeys([])
    storage.Lists -> Source
    // The zip's file name and when it was imported live only here, and the
    // app finds its data sets by these records. The index inside is made
    // from the zip: it holds a version and is built again when older.
    storage.DataIndexes -> Source
    storage.DataZips -> Source
    storage.Cards -> Source
    storage.Sheets -> Source
    // A game holds its own copy of its sheet, so it is a source too.
    storage.Games -> Source
  }
}

/// A backup's contents. `stores` holds every store that goes into a backup,
/// in schema order, each with its records by key.
pub type Backup {
  Backup(
    made: String,
    release: String,
    schema: Int,
    stores: List(#(Store, List(#(String, Value)))),
  )
}

pub type ReadError {
  /// Not a backup file, so it goes on to the list import.
  NotABackup
  /// It says it is a backup, but part of it cannot be read.
  Broken
  /// Made by an app whose storage schema is later than this one's.
  TooNew(schema: Int)
}

/// The stores that go into a backup, in schema order.
pub fn stores() -> List(Store) {
  list.filter(storage.stores(), fn(store) { kind(store) != Made })
}

/// The records of `store` that go into a backup.
pub fn keep(
  records: List(#(String, Value)),
  store: Store,
) -> List(#(String, Value)) {
  case kind(store) {
    SomeKeys(keys) ->
      list.filter(records, fn(record) { list.contains(keys, record.0) })
    Source | Made -> records
  }
}

pub fn encode(backup: Backup) -> String {
  json.object([
    #("format", json.string(format)),
    #("made", json.string(backup.made)),
    #("release", json.string(backup.release)),
    #("schema", json.int(backup.schema)),
    #(
      "stores",
      json.object(
        list.map(backup.stores, fn(store) {
          #(storage.store_name(store.0), json.array(store.1, encode_record))
        }),
      ),
    ),
  ])
  |> json.to_string
}

fn encode_record(record: #(String, Value)) -> json.Json {
  let value = case record.1 {
    storage.JsonValue(value) -> #("json", value)
    storage.BytesValue(bytes) -> #(
      "base64",
      json.string(bit_array.base64_encode(bytes, True)),
    )
  }
  json.object([#("key", json.string(record.0)), value])
}

/// A chosen file's text as a backup for an app at storage schema
/// `app_schema`. A backup from an older schema reads as it is, since records
/// keep their shape between schema versions.
pub fn read(text: String, schema app_schema: Int) -> Result(Backup, ReadError) {
  use data <- result.try(
    json.parse(text, decode.dynamic) |> result.replace_error(NotABackup),
  )
  let found = decode.run(data, decode.at(["format"], decode.string))
  use <- bool.guard(found != Ok(format), Error(NotABackup))
  use #(made, release, schema) <- result.try(
    decode.run(data, header_decoder()) |> result.replace_error(Broken),
  )
  use <- bool.guard(schema > app_schema, Error(TooNew(schema)))
  use found <- result.map(
    decode.run(
      data,
      decode.at(
        ["stores"],
        decode.dict(decode.string, decode.list(record_decoder())),
      ),
    )
    |> result.replace_error(Broken),
  )
  let stores =
    list.map(stores(), fn(store) {
      let records =
        dict.get(found, storage.store_name(store)) |> result.unwrap([])
      #(store, keep(records, store))
    })
  Backup(made:, release:, schema:, stores:)
}

fn header_decoder() -> decode.Decoder(#(String, String, Int)) {
  use made <- decode.field("made", decode.string)
  use release <- decode.field("release", decode.string)
  use schema <- decode.field("schema", decode.int)
  decode.success(#(made, release, schema))
}

fn record_decoder() -> decode.Decoder(#(String, Value)) {
  use key <- decode.field("key", decode.string)
  use value <- decode.then(
    decode.one_of(
      decode.at(["json"], storage.json_decoder())
        |> decode.map(storage.JsonValue),
      [decode.at(["base64"], base64()) |> decode.map(storage.BytesValue)],
    ),
  )
  decode.success(#(key, value))
}

fn base64() -> decode.Decoder(BitArray) {
  use text <- decode.then(decode.string)
  case bit_array.base64_decode(text) {
    Ok(bytes) -> decode.success(bytes)
    Error(Nil) -> decode.failure(<<>>, "base64")
  }
}

/// Every record of the backup as one change, for one `storage.write`: a
/// record replaces the one saved under its key, and nothing else is deleted.
pub fn writes(backup: Backup) -> List(Write) {
  use #(store, records) <- list.flat_map(backup.stores)
  use #(key, value) <- list.map(records)
  storage.Put(store, key, value)
}

/// A backup and its records split by whether this device already has a
/// record under the same key. `missing` and `present` keep its header.
pub type Split {
  Split(backup: Backup, missing: Backup, present: Backup)
}

/// Split `backup` by the keys this device has, store by store.
pub fn split(backup: Backup, on_device: List(#(Store, List(String)))) -> Split {
  let part = fn(here) {
    let stores =
      list.map(backup.stores, fn(store) {
        let keys = list.key_find(on_device, store.0) |> result.unwrap([])
        #(
          store.0,
          list.filter(store.1, fn(record) {
            list.contains(keys, record.0) == here
          }),
        )
      })
    Backup(..backup, stores:)
  }
  Split(backup:, missing: part(False), present: part(True))
}

/// What a restore does with a record this device already has.
pub type Choice {
  /// Write only the records whose keys are not on this device.
  AddMissing
  /// Write every record, over the copy on this device.
  ReplaceAll
}

/// The writes of a restore, for one `storage.write`.
pub fn restore_writes(split: Split, choice: Choice) -> List(Write) {
  case choice {
    AddMissing -> writes(split.missing)
    ReplaceAll -> writes(split.backup)
  }
}

/// The sentence that says what of the file this device already has, such as
/// `2 games in this file are already on this device.`, or `None` when it has
/// none of it.
pub fn already_here(split: Split) -> Option(String) {
  let here = holds(split.present) <> " in this file "
  case count(split.present) {
    0 -> None
    1 -> Some(here <> "is already on this device.")
    _ -> Some(here <> "are already on this device.")
  }
}

/// What a restore did: what it added, and what it replaced or kept.
pub fn restored(split: Split, choice: Choice) -> String {
  let added = "Added " <> holds(split.missing) <> " from the backup file."
  let here = holds(split.present)
  case count(split.present), choice {
    0, _ -> added
    _, AddMissing -> added <> " Kept this device's copies of " <> here <> "."
    _, ReplaceAll ->
      added
      <> " Replaced this device's copies of "
      <> here
      <> " with the copies in the file."
  }
}

/// The stores a backup counts in words, each with its word for one and many.
const counted = [
  #(storage.Lists, "list", "lists"),
  #(storage.DataIndexes, "game data set", "game data sets"),
  #(storage.Cards, "card", "cards"),
  #(storage.Sheets, "score sheet", "score sheets"),
  #(storage.Games, "game", "games"),
]

fn records(backup: Backup, store: Store) -> List(#(String, Value)) {
  list.key_find(backup.stores, store) |> result.unwrap([])
}

/// How many things `holds` counts.
fn count(backup: Backup) -> Int {
  use sum, store <- list.fold(counted, 0)
  sum + list.length(records(backup, store.0))
}

/// What a backup holds, in counts and plain words, such as
/// `2 lists, 1 game data set, 14 cards, 1 score sheet and 3 games`.
pub fn holds(backup: Backup) -> String {
  let parts =
    list.filter_map(counted, fn(store) {
      case records(backup, store.0) {
        [] -> Error(Nil)
        [_] -> Ok("1 " <> store.1)
        records -> Ok(int.to_string(list.length(records)) <> " " <> store.2)
      }
    })
  case list.reverse(parts) {
    [] -> "nothing"
    [one] -> one
    [last, ..rest] -> string.join(list.reverse(rest), ", ") <> " and " <> last
  }
}

/// `tabletop-backup-2026-11-13.json`, from a year, month and day.
pub fn file_name(date: #(Int, Int, Int)) -> String {
  let two = fn(number) { string.pad_start(int.to_string(number), 2, "0") }
  "tabletop-backup-"
  <> int.to_string(date.0)
  <> "-"
  <> two(date.1)
  <> "-"
  <> two(date.2)
  <> ".json"
}

// --- The feature --------------------------------------------------------------

pub type State {
  State(
    /// When this device last saved a backup: `None` until read, `Ok(None)`
    /// when it never did.
    last: Option(Result(Option(Int), StorageError)),
    save: Save,
    restore: Restore,
  )
}

pub type Save {
  NotSaving
  Saving
  /// The browser was handed the file with this name. A browser never says
  /// whether it saved it.
  Handed(file: String)
  /// No file was made, and why.
  SaveFailed(StorageError)
}

/// Where restoring a chosen backup file is.
pub type Restore {
  NoRestore
  /// The file is read, and the app reads which of its keys this device has.
  Checking(Backup)
  /// The question waits for an answer.
  Asking(Split)
  /// An answer was pressed and the records are being written.
  Writing(Split, Choice)
  /// The records were written. `said` says what was added, and what was
  /// replaced or kept.
  Done(said: String)
  /// Nothing was written, and why.
  Failed(Problem)
}

pub type Problem {
  CannotRead(ReadError)
  NotWritten(StorageError)
  NoStorage
}

pub type Msg {
  LastLoaded(Result(Option(Int), StorageError))
  SaveClicked
  /// When the file was made, and its name.
  Saved(Result(#(Int, String), StorageError))
  /// The keys this device has, in each store that goes into a backup.
  KeysRead(Result(List(#(Store, List(String))), StorageError))
  RestoreClicked(Choice)
  CancelClicked
  Restored(Result(Nil, StorageError))
}

/// The `Meta` key of when this device last saved a backup.
const last_backup_key = "last_backup"

pub fn init() -> State {
  State(last: None, save: NotSaving, restore: NoRestore)
}

/// Read when this device last saved a backup, once storage has answered.
pub fn load(db: Result(Database, StorageError)) -> Effect(Msg) {
  case db {
    Ok(db) ->
      effects.from_promise(
        fn() { storage.get(db, storage.Meta, last_backup_key, decode.int) },
        LastLoaded,
      )
    Error(error) -> {
      use dispatch <- effect.from
      dispatch(LastLoaded(Error(error)))
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
    LastLoaded(last) -> #(State(..state, last: Some(last)), effect.none())
    SaveClicked ->
      case db {
        Some(Ok(db)) -> #(
          State(..state, save: Saving),
          effects.from_promise(fn() { save(db) }, Saved),
        )
        Some(Error(error)) -> #(
          State(..state, save: SaveFailed(error)),
          effect.none(),
        )
        // The button is off until storage has answered.
        None -> #(state, effect.none())
      }
    Saved(Ok(#(ms, file))) -> #(
      State(..state, save: Handed(file), last: Some(Ok(Some(ms)))),
      effect.none(),
    )
    Saved(Error(error)) -> #(
      State(..state, save: SaveFailed(error)),
      effect.none(),
    )
    KeysRead(keys) -> {
      let restore = case state.restore, keys {
        Checking(backup), Ok(keys) -> Asking(split(backup, keys))
        Checking(_), Error(error) -> Failed(NotWritten(error))
        other, _ -> other
      }
      #(State(..state, restore:), effect.none())
    }
    RestoreClicked(choice) ->
      case state.restore, db {
        Asking(split), Some(Ok(db)) -> #(
          State(..state, restore: Writing(split, choice)),
          effects.from_promise(
            fn() { storage.write(db, restore_writes(split, choice)) },
            Restored,
          ),
        )
        Asking(_), Some(Error(error)) -> #(
          State(..state, restore: Failed(NotWritten(error))),
          effect.none(),
        )
        Asking(_), None -> #(
          State(..state, restore: Failed(NoStorage)),
          effect.none(),
        )
        NoRestore, _
        | Checking(_), _
        | Writing(..), _
        | Done(_), _
        | Failed(_), _
        -> #(state, effect.none())
      }
    CancelClicked -> #(State(..state, restore: NoRestore), effect.none())
    Restored(Ok(Nil)) -> {
      let restore = case state.restore {
        Writing(split, choice) -> Done(restored(split, choice))
        other -> other
      }
      #(State(..state, restore:), effect.none())
    }
    Restored(Error(error)) -> #(
      State(..state, restore: Failed(NotWritten(error))),
      effect.none(),
    )
  }
}

/// What happens after the shell has read a chosen backup file: read which of
/// its keys this device has before the question, or say why it cannot be
/// restored.
pub fn file_read(
  state: State,
  read: Result(Backup, ReadError),
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case read, db {
    Error(error), _ -> #(
      State(..state, restore: Failed(CannotRead(error))),
      effect.none(),
    )
    Ok(backup), Some(Ok(db)) -> #(
      State(..state, restore: Checking(backup)),
      effects.from_promise(fn() { device_keys(db) }, KeysRead),
    )
    Ok(_), Some(Error(error)) -> #(
      State(..state, restore: Failed(NotWritten(error))),
      effect.none(),
    )
    Ok(_), None -> #(State(..state, restore: Failed(NoStorage)), effect.none())
  }
}

/// The keys this device has in each store that goes into a backup.
fn device_keys(
  db: Database,
) -> Promise(Result(List(#(Store, List(String))), StorageError)) {
  stores()
  |> list.map(fn(store) {
    storage.keys(db, store)
    |> promise.map(result.map(_, fn(keys) { #(store, keys) }))
  })
  |> promise.await_list
  |> promise.map(result.all)
}

/// The screen changed or another file was chosen: an open question and the
/// last message go. A restore being written goes on.
pub fn screen_changed(state: State) -> State {
  let save = case state.save {
    Saving -> Saving
    NotSaving | Handed(_) | SaveFailed(_) -> NotSaving
  }
  let restore = case state.restore {
    Writing(..) -> state.restore
    NoRestore | Checking(_) | Asking(_) | Done(_) | Failed(_) -> NoRestore
  }
  State(..state, save:, restore:)
}

/// Whether the question about a backup file is open, so the shell shows it in
/// place of the home screen.
pub fn asking(state: State) -> Bool {
  case state.restore {
    Checking(_) | Asking(_) | Writing(..) -> True
    NoRestore | Done(_) | Failed(_) -> False
  }
}

/// Read every store that goes into a backup, keep the time on this device,
/// then hand the file to the browser. Resolves to that time and the file's
/// name.
fn save(db: Database) -> Promise(Result(#(Int, String), StorageError)) {
  let now = browser.now_ms()
  use stores <- promise.try_await(
    stores()
    |> list.map(fn(store) {
      storage.get_all_values(db, store)
      |> promise.map(
        result.map(_, fn(records) { #(store, keep(records, store)) }),
      )
    })
    |> promise.await_list
    |> promise.map(result.all),
  )
  let backup =
    Backup(
      made: browser.iso_time(now),
      release: browser.running_version(),
      schema: storage.schema_version(),
      stores:,
    )
  use Nil <- promise.map_try(storage.put(
    db,
    storage.Meta,
    last_backup_key,
    json.int(now),
  ))
  let file = file_name(browser.local_date(now))
  browser.download(file, encode(backup))
  Ok(#(now, file))
}

// --- Views ------------------------------------------------------------------

/// What a restore did, or why it did not, for under the import control.
pub fn status(state: State) -> List(Element(Msg)) {
  case state.restore {
    Done(said:) -> [html.p([attribute.role("status")], [html.text(said)])]
    Failed(problem) -> [
      html.p([attribute.class("problem"), attribute.role("alert")], [
        html.text(describe_problem(problem)),
      ]),
    ]
    NoRestore | Checking(_) | Asking(_) | Writing(..) -> []
  }
}

/// The backup section of the home screen.
pub fn section(state: State) -> List(Element(Msg)) {
  let last = case state.save, state.last {
    Saving, _ -> "Making the backup file…"
    _, None -> "Last backup file made: reading…"
    _, Some(Ok(None)) -> "Last backup file made: never"
    _, Some(Ok(Some(ms))) -> "Last backup file made: " <> browser.local_time(ms)
    _, Some(Error(error)) ->
      "Last backup file made: unknown. "
      <> sheet_view.describe_storage_error(error)
  }
  [
    html.section([], [
      html.h2([], [html.text("Backup")]),
      html.p([], [
        html.text(
          "A backup file holds your lists, game data, cards, score sheets and games: open it with Import a file to bring them back after this browser clears them, or to move them to another device.",
        ),
      ]),
      html.div([attribute.class("actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button primary"),
            attribute.disabled(state.save == Saving || state.last == None),
            event.on_click(SaveClicked),
          ],
          [html.text("Save a backup file")],
        ),
      ]),
      html.p([attribute.class("note"), attribute.role("status")], [
        html.text(last),
      ]),
      case state.save {
        Handed(file) ->
          html.p([attribute.class("note"), attribute.role("status")], [
            html.text(
              "Look for the file "
              <> file
              <> " in your downloads, and keep it somewhere safe.",
            ),
          ])
        SaveFailed(error) ->
          html.p([attribute.class("problem"), attribute.role("alert")], [
            html.text(
              "The backup file could not be made. "
              <> sheet_view.describe_storage_error(error),
            ),
          ])
        NotSaving | Saving -> element.none()
      },
    ]),
  ]
}

/// The question before anything is written: what the file holds, when and
/// with which version it was made, what of it this device already has, and
/// what each answer does.
pub fn question_page(state: State) -> List(Element(Msg)) {
  case state.restore {
    Checking(backup) ->
      question(backup, [note("Looking at what is already on this device…")])
    Asking(split) -> question(split.backup, answers(split, False))
    Writing(split, _) ->
      question(
        split.backup,
        list.append(answers(split, True), [note("Restoring…")]),
      )
    NoRestore | Done(_) | Failed(_) -> []
  }
}

fn question(backup: Backup, rest: List(Element(Msg))) -> List(Element(Msg)) {
  [
    html.h1([], [html.text("Restore this backup?")]),
    html.p([], [html.text("It holds " <> holds(backup) <> ".")]),
    html.p([], [
      html.text(
        "It was made on "
        <> browser.local_time_of_iso(backup.made)
        <> " with version "
        <> backup.release
        <> ".",
      ),
    ]),
    ..rest
  ]
}

/// What each answer does, and its buttons: Restore when this device has none
/// of the file, else a choice about the copies it has.
fn answers(split: Split, writing: Bool) -> List(Element(Msg)) {
  let button = fn(label, class, msg) {
    html.button(
      [
        attribute.type_("button"),
        attribute.class(class),
        attribute.disabled(writing),
        event.on_click(msg),
      ],
      [html.text(label)],
    )
  }
  let cancel = button("Cancel", "button", CancelClicked)
  let #(said, buttons) = case already_here(split) {
    None -> #(
      [
        "Anything in this file that is already on this device is replaced by the copy in the file, and nothing else on this device is deleted.",
      ],
      [button("Restore", "button primary", RestoreClicked(ReplaceAll)), cancel],
    )
    Some(here) -> #(
      [
        here,
        "\"Add only what is missing\" keeps this device's copies as they are. \"Replace with the copies in the file\" writes the file's copies over them.",
      ],
      [
        button(
          "Add only what is missing",
          "button primary",
          RestoreClicked(AddMissing),
        ),
        button(
          "Replace with the copies in the file",
          "button",
          RestoreClicked(ReplaceAll),
        ),
        cancel,
      ],
    )
  }
  list.append(list.map(said, fn(line) { html.p([], [html.text(line)]) }), [
    html.div([attribute.class("actions")], buttons),
  ])
}

fn note(said: String) -> Element(Msg) {
  html.p([attribute.class("note"), attribute.role("status")], [
    html.text(said),
  ])
}

fn describe_problem(problem: Problem) -> String {
  case problem {
    CannotRead(NotABackup) -> "That file is not a backup file."
    CannotRead(Broken) ->
      "That file is a backup file, but part of it cannot be read, so nothing was restored."
    CannotRead(TooNew(_)) ->
      "The app on this device is older than this backup and needs its update first. Close the app and open it again, tap Reload when it shows New version, then import the file again."
    NotWritten(error) ->
      "The backup was not restored, and nothing on this device changed. "
      <> sheet_view.describe_storage_error(error)
    NoStorage ->
      "Storage is not open on this device, so the backup cannot be restored."
  }
}
