//// A backup file: every record the person loaded or typed, in one JSON file
//// to save on one device and open on another, or on the same device after
//// the browser cleared it. `kind` says which stores go into it. Bytes go in
//// as base64 text.
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
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import tabletop/storage.{type Store, type Value, type Write}

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
