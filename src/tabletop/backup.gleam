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

/// What a backup holds, in counts and plain words, such as
/// `2 lists, 1 game data set and 14 cards`.
pub fn holds(backup: Backup) -> String {
  let count = fn(store, one, many) {
    case list.key_find(backup.stores, store) |> result.unwrap([]) {
      [] -> Error(Nil)
      [_] -> Ok("1 " <> one)
      records -> Ok(int.to_string(list.length(records)) <> " " <> many)
    }
  }
  let parts =
    result.values([
      count(storage.Lists, "list", "lists"),
      count(storage.DataIndexes, "game data set", "game data sets"),
      count(storage.Cards, "card", "cards"),
    ])
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
  /// No file was made, and why.
  SaveFailed(StorageError)
}

/// Where restoring a chosen backup file is.
pub type Restore {
  NoRestore
  /// The file is read, and the question waits for Restore or Cancel.
  Asking(Backup)
  /// Restore was pressed and the records are being written.
  Writing(Backup)
  /// Every record was written. `holds` says what they were.
  Done(holds: String)
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
  Saved(Result(Int, StorageError))
  RestoreClicked
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
    Saved(Ok(ms)) -> #(
      State(..state, save: NotSaving, last: Some(Ok(Some(ms)))),
      effect.none(),
    )
    Saved(Error(error)) -> #(
      State(..state, save: SaveFailed(error)),
      effect.none(),
    )
    RestoreClicked ->
      case state.restore, db {
        Asking(backup), Some(Ok(db)) -> #(
          State(..state, restore: Writing(backup)),
          effects.from_promise(
            fn() { storage.write(db, writes(backup)) },
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
        NoRestore, _ | Writing(_), _ | Done(_), _ | Failed(_), _ -> #(
          state,
          effect.none(),
        )
      }
    CancelClicked -> #(State(..state, restore: NoRestore), effect.none())
    Restored(Ok(Nil)) -> {
      let restore = case state.restore {
        Writing(backup) -> Done(holds(backup))
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

/// What happens after the shell has read a chosen backup file: the question,
/// or why it cannot be restored.
pub fn file_read(state: State, read: Result(Backup, ReadError)) -> State {
  case read {
    Ok(backup) -> State(..state, restore: Asking(backup))
    Error(error) -> State(..state, restore: Failed(CannotRead(error)))
  }
}

/// The screen changed or another file was chosen: an open question and the
/// last message go. A restore being written goes on.
pub fn screen_changed(state: State) -> State {
  let save = case state.save {
    Saving -> Saving
    NotSaving | SaveFailed(_) -> NotSaving
  }
  let restore = case state.restore {
    Writing(_) -> state.restore
    NoRestore | Asking(_) | Done(_) | Failed(_) -> NoRestore
  }
  State(..state, save:, restore:)
}

/// Whether the question about a backup file is open, so the shell shows it in
/// place of the home screen.
pub fn asking(state: State) -> Bool {
  case state.restore {
    Asking(_) | Writing(_) -> True
    NoRestore | Done(_) | Failed(_) -> False
  }
}

/// Read every store that goes into a backup, keep the time on this device,
/// then hand the file to the browser. Resolves to that time.
fn save(db: Database) -> Promise(Result(Int, StorageError)) {
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
  browser.download(file_name(browser.local_date(now)), encode(backup))
  Ok(now)
}

// --- Views ------------------------------------------------------------------

/// What a restore did, or why it did not, for under the import control.
pub fn status(state: State) -> List(Element(Msg)) {
  case state.restore {
    Done(holds:) -> [
      html.p([attribute.role("status")], [
        html.text("Restored " <> holds <> " from the backup file."),
      ]),
    ]
    Failed(problem) -> [
      html.p([attribute.class("problem"), attribute.role("alert")], [
        html.text(describe_problem(problem)),
      ]),
    ]
    NoRestore | Asking(_) | Writing(_) -> []
  }
}

/// The backup section of the home screen.
pub fn section(state: State) -> List(Element(Msg)) {
  let last = case state.save, state.last {
    Saving, _ -> "Making the backup file…"
    _, None -> "Last backup: reading…"
    _, Some(Ok(None)) -> "Last backup: never"
    _, Some(Ok(Some(ms))) -> "Last backup: " <> browser.local_time(ms)
    _, Some(Error(error)) ->
      "Last backup: unknown. " <> sheet_view.describe_storage_error(error)
  }
  [
    html.section([], [
      html.h2([], [html.text("Backup")]),
      html.p([], [
        html.text(
          "A backup file holds your lists, game data and cards: open it with Import a file to bring them back after this browser clears them, or to move them to another device.",
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
/// with which version it was made, and what restoring does.
pub fn question_page(state: State) -> List(Element(Msg)) {
  let #(backup, writing) = case state.restore {
    Asking(backup) -> #(Some(backup), False)
    Writing(backup) -> #(Some(backup), True)
    NoRestore | Done(_) | Failed(_) -> #(None, False)
  }
  case backup {
    None -> []
    Some(backup) -> [
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
      html.p([], [
        html.text(
          "Anything in this file that is already on this device is replaced by the copy in the file, and nothing else on this device is deleted.",
        ),
      ]),
      html.div([attribute.class("actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button primary"),
            attribute.disabled(writing),
            event.on_click(RestoreClicked),
          ],
          [html.text("Restore")],
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button"),
            attribute.disabled(writing),
            event.on_click(CancelClicked),
          ],
          [html.text("Cancel")],
        ),
      ]),
      case writing {
        True ->
          html.p([attribute.class("note"), attribute.role("status")], [
            html.text("Restoring…"),
          ])
        False -> element.none()
      },
    ]
  }
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
