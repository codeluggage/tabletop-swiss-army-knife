//// The browser's IndexedDB behind promises of `Result`. Values go in and come
//// out as JSON that Gleam encodes and decodes; the database only sees strings.
////
//// The schema is `upgrades`: step n creates the stores that schema version n
//// adds. "Adding a store" in AGENTS.md says how to add one.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Database

pub type Store {
  /// App metadata, one record per key, such as when the app was first opened.
  Meta
}

pub type StorageError {
  OpenFailed(reason: String)
  ReadFailed(reason: String)
  WriteFailed(reason: String)
  Undecodable(key: String)
}

/// The browser's answer to "keep this site's data when space runs low".
pub type Persistence {
  Persistent
  NotPersistent
  PersistUnavailable
}

const database_name = "tabletop"

/// Oldest first. Step n moves a database from schema version n - 1 to n.
const upgrades: List(List(Store)) = [[Meta]]

pub fn schema_version() -> Int {
  list.length(upgrades)
}

/// The stores to create when a database at `old_version` opens: every store
/// that a later step adds. A database that does not exist yet is at 0.
pub fn stores_to_create(from old_version: Int) -> List(String) {
  upgrades
  |> list.drop(old_version)
  |> list.flatten
  |> list.map(store_name)
}

fn store_name(store: Store) -> String {
  case store {
    Meta -> "meta"
  }
}

pub fn open() -> Promise(Result(Database, StorageError)) {
  do_open(database_name, schema_version(), stores_to_create)
  |> promise.map(result.map_error(_, OpenFailed))
}

/// `Ok(None)` when nothing is stored under `key`.
pub fn get(
  db: Database,
  store: Store,
  key: String,
  decoder: decode.Decoder(a),
) -> Promise(Result(Option(a), StorageError)) {
  do_get(db, store_name(store), key)
  |> promise.map(fn(raw) {
    use raw <- result.try(result.map_error(raw, ReadFailed))
    decode_value(raw, key, decoder)
  })
}

/// Resolves once the write is committed.
pub fn put(
  db: Database,
  store: Store,
  key: String,
  value: json.Json,
) -> Promise(Result(Nil, StorageError)) {
  do_put(db, store_name(store), key, json.to_string(value))
  |> promise.map(result.map_error(_, WriteFailed))
}

pub fn persist() -> Promise(Persistence) {
  use answer <- promise.map(do_persist())
  case answer {
    Ok(True) -> Persistent
    Ok(False) -> NotPersistent
    Error(_) -> PersistUnavailable
  }
}

/// Decode what IndexedDB handed back for `key`: nothing, or a JSON string.
pub fn decode_value(
  raw: Dynamic,
  key: String,
  decoder: decode.Decoder(a),
) -> Result(Option(a), StorageError) {
  case decode.run(raw, decode.optional(decode.string)) {
    Ok(None) -> Ok(None)
    Ok(Some(text)) ->
      json.parse(text, decoder)
      |> result.map(Some)
      |> result.replace_error(Undecodable(key))
    Error(_) -> Error(Undecodable(key))
  }
}

@external(javascript, "./storage_ffi.mjs", "open")
fn do_open(
  name: String,
  version: Int,
  stores_to_create: fn(Int) -> List(String),
) -> Promise(Result(Database, String))

@external(javascript, "./storage_ffi.mjs", "get")
fn do_get(
  db: Database,
  store: String,
  key: String,
) -> Promise(Result(Dynamic, String))

@external(javascript, "./storage_ffi.mjs", "put")
fn do_put(
  db: Database,
  store: String,
  key: String,
  value: String,
) -> Promise(Result(Nil, String))

@external(javascript, "./storage_ffi.mjs", "persist")
fn do_persist() -> Promise(Result(Bool, String))
