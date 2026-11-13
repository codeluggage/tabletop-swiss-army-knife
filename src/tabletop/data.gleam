//// The game data feature: the data sets saved on this device, importing a zip
//// of data files, deleting a data set, and the data set, catalogue and node
//// screens. The shell in `tabletop.gleam` holds its `State`, wraps its `Msg`,
//// hands it a chosen zip through `import_zip`, calls `enter` when the screen
//// changes and when the data sets have loaded, and sends it the data routes.
////
//// A data set is two records under its game system's id: the index, with the
//// zip's file name and when it was imported, and the zip's bytes, unchanged.

import gleam/bit_array
import gleam/dict.{type Dict}
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
import tabletop/bytes.{type UnpackError}
import tabletop/catalogue.{type Catalogue, type Summary}
import tabletop/data_index.{type Index}
import tabletop/effects
import tabletop/route.{type Route}
import tabletop/scope.{type CostLine, type Item, type Page, type Scope}
import tabletop/sheet
import tabletop/sheet_view
import tabletop/storage.{type Database, type StorageError}
import tabletop/text
import tabletop/zip

pub type State {
  State(
    /// `None` until the saved data sets are read.
    sets: Option(Result(List(DataSet), StorageError)),
    /// The zip being read into a data set.
    importing: Option(Import),
    /// Zips waiting for the one being read, oldest first.
    waiting: List(ZipFile),
    problem: Option(Problem),
    /// The id of the data set whose Delete was pressed and waits for Yes or No.
    confirming: Option(String),
    /// The text in the search or filter box.
    typed: Typed,
    /// The catalogue of the node screen, and what its scope is built from.
    open: Option(Open),
  )
}

/// A saved data set, keyed by its game system's id.
pub type DataSet {
  DataSet(id: String, file_name: String, imported: Int, index: Index)
}

/// A zip to read into a data set.
pub type ZipFile {
  ZipFile(name: String, imported: Int, bytes: BitArray)
}

/// A zip being read one `.json` entry at a time. `left` are the entries not
/// read yet, the one being read first, and `read` the name and summary of
/// each data file so far, newest first.
pub type Import {
  Import(
    file: ZipFile,
    left: List(zip.Entry),
    total: Int,
    read: List(#(String, Summary)),
  )
}

/// What went wrong with the last import or delete.
pub type Problem {
  NotAZip
  NoDataFiles
  NoGameSystem
  NotSaved(StorageError)
  NotDeleted(StorageError)
  /// A saved data set whose record or zip could not be read.
  NotReadAgain
  NoStorage
}

/// The text in the search or filter box, and the hash of the screen it was
/// typed on.
pub type Typed {
  Typed(on: String, text: String)
}

/// One catalogue's scope. `files` are its scope files in scope order, `zip`
/// the data set's zip once read, and `decoded` the scope files decoded so far,
/// by their name in the zip.
pub type Open {
  Open(
    set_id: String,
    catalogue_id: String,
    files: List(String),
    zip: Option(BitArray),
    decoded: Dict(String, Catalogue),
    scope: Opening,
  )
}

pub type Opening {
  /// The files left to decode, the next first, out of `total`.
  Decoding(left: List(String), total: Int)
  Built(scope: Scope, links: text.Links(String))
  Failed(OpenProblem)
}

pub type OpenProblem {
  /// The zip is not in storage, or storage could not read it.
  ZipNotRead(Option(StorageError))
  FileNotDecoded(file: String)
}

/// A saved index record as it was read.
pub type Stored {
  Current(DataSet)
  /// An index of an older version, to build again from its zip.
  Stale(ZipFile)
  Unreadable
}

pub type Msg {
  SetsLoaded(Result(List(Stored), StorageError))
  FileUnpacked(Result(BitArray, UnpackError))
  SetSaved(Result(DataSet, StorageError))
  DeleteClicked(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  SetDeleted(id: String, result: Result(Nil, StorageError))
  BoxTyped(on: String, text: String)
  ZipRead(set_id: String, result: Result(Option(BitArray), StorageError))
  ScopeFileUnpacked(
    set_id: String,
    file: String,
    result: Result(BitArray, UnpackError),
  )
}

pub fn init() -> State {
  State(
    sets: None,
    importing: None,
    waiting: [],
    problem: None,
    confirming: None,
    typed: Typed(on: "", text: ""),
    open: None,
  )
}

/// Read the saved data sets once storage has answered. When storage did not
/// open, the data sets show why.
pub fn load(db: Result(Database, StorageError)) -> Effect(Msg) {
  case db {
    Ok(db) -> effects.from_promise(fn() { load_sets(db) }, SetsLoaded)
    Error(error) -> {
      use dispatch <- effect.from
      dispatch(SetsLoaded(Error(error)))
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
    SetsLoaded(Error(error)) -> #(
      State(..state, sets: Some(Error(error))),
      effect.none(),
    )
    SetsLoaded(Ok(stored)) -> {
      let sets =
        list.filter_map(stored, fn(stored) {
          case stored {
            Current(set) -> Ok(set)
            Stale(_) | Unreadable -> Error(Nil)
          }
        })
      let stale =
        list.filter_map(stored, fn(stored) {
          case stored {
            Stale(file) -> Ok(file)
            Current(_) | Unreadable -> Error(Nil)
          }
        })
      let unreadable = list.any(stored, fn(stored) { stored == Unreadable })
      let problem = case unreadable {
        True -> Some(NotReadAgain)
        False -> state.problem
      }
      State(
        ..state,
        sets: Some(Ok(sets)),
        waiting: list.append(state.waiting, stale),
        problem:,
      )
      |> next_import
    }
    FileUnpacked(unpacked) ->
      case state.importing {
        Some(Import(left: [entry, ..left], ..) as job) -> {
          let read = case read_data(unpacked, catalogue.summarise) {
            Ok(summary) -> [#(entry.name, summary), ..job.read]
            Error(Nil) -> job.read
          }
          let job = Import(..job, left:, read:)
          case left {
            [next, ..] -> #(
              State(..state, importing: Some(job)),
              unpack_for_import(job.file.bytes, next),
            )
            [] -> finish_import(state, job, db)
          }
        }
        Some(Import(left: [], ..)) | None -> #(state, effect.none())
      }
    SetSaved(Ok(set)) -> {
      let sets = [
        set,
        ..list.filter(saved_sets(state), fn(old) { old.id != set.id })
      ]
      State(
        ..state,
        sets: Some(Ok(sets)),
        importing: None,
        open: close(state.open, set.id),
      )
      |> next_import
    }
    SetSaved(Error(error)) ->
      State(..state, importing: None, problem: Some(NotSaved(error)))
      |> next_import
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
            fn() {
              storage.write(db, [
                storage.Remove(storage.DataIndexes, id),
                storage.Remove(storage.DataZips, id),
              ])
            },
            SetDeleted(id, _),
          ),
        )
        _ -> #(
          State(..state, confirming: None, problem: Some(NoStorage)),
          effect.none(),
        )
      }
    SetDeleted(id:, result: Ok(Nil)) -> {
      let sets = list.filter(saved_sets(state), fn(set) { set.id != id })
      #(
        State(
          ..state,
          confirming: None,
          sets: Some(Ok(sets)),
          open: close(state.open, id),
        ),
        effect.none(),
      )
    }
    SetDeleted(result: Error(error), ..) -> #(
      State(..state, confirming: None, problem: Some(NotDeleted(error))),
      effect.none(),
    )
    BoxTyped(on:, text:) -> #(
      State(..state, typed: Typed(on:, text:)),
      effect.none(),
    )
    ZipRead(set_id:, result:) ->
      case state.open, result {
        Some(Open(zip: None, scope: Decoding(..), ..) as open), Ok(Some(bytes))
          if open.set_id == set_id
        -> decode_next(state, Open(..open, zip: Some(bytes)))
        Some(Open(zip: None, scope: Decoding(..), ..) as open), Ok(None)
          if open.set_id == set_id
        -> failed(state, open, ZipNotRead(None))
        Some(Open(zip: None, scope: Decoding(..), ..) as open), Error(error)
          if open.set_id == set_id
        -> failed(state, open, ZipNotRead(Some(error)))
        _, _ -> #(state, effect.none())
      }
    ScopeFileUnpacked(set_id:, file:, result:) ->
      case state.open {
        Some(Open(scope: Decoding(left: [next, ..left], total:), ..) as open)
          if open.set_id == set_id && next == file
        ->
          case read_data(result, catalogue.decode) {
            Ok(decoded) ->
              Open(
                ..open,
                decoded: dict.insert(open.decoded, file, decoded),
                scope: Decoding(left:, total:),
              )
              |> decode_next(state, _)
            Error(Nil) -> failed(state, open, FileNotDecoded(file))
          }
        _ -> #(state, effect.none())
      }
  }
}

/// What happens after the shell has read a chosen zip: it is read into a data
/// set when no other zip is being read, else it waits.
pub fn import_zip(
  state: State,
  file_name: String,
  bytes: BitArray,
) -> #(State, Effect(Msg)) {
  let file = ZipFile(name: file_name, imported: browser.now_ms(), bytes:)
  State(..state, waiting: list.append(state.waiting, [file])) |> next_import
}

/// The shell started reading a chosen file: the last problem goes.
pub fn file_chosen(state: State) -> State {
  State(..state, problem: None)
}

/// The screen changed: the last problem and an open delete question go.
pub fn screen_changed(state: State) -> State {
  State(..state, problem: None, confirming: None)
}

/// Whether a zip is being read, so the shell can turn the import control off.
pub fn importing(state: State) -> Bool {
  option.is_some(state.importing)
}

fn saved_sets(state: State) -> List(DataSet) {
  case state.sets {
    Some(Ok(sets)) -> sets
    Some(Error(_)) | None -> []
  }
}

// --- Importing --------------------------------------------------------------

/// Start reading the next waiting zip, when none is being read.
fn next_import(state: State) -> #(State, Effect(Msg)) {
  case state.importing, state.waiting {
    None, [file, ..waiting] -> start_import(State(..state, waiting:), file)
    _, _ -> #(state, effect.none())
  }
}

fn start_import(state: State, file: ZipFile) -> #(State, Effect(Msg)) {
  case zip.entries(file.bytes) {
    Error(_) -> State(..state, problem: Some(NotAZip)) |> next_import
    Ok(entries) ->
      case list.filter(entries, fn(entry) { is_json(entry.name) }) {
        [] -> State(..state, problem: Some(NoDataFiles)) |> next_import
        [first, ..] as left -> #(
          State(
            ..state,
            importing: Some(
              Import(file:, left:, total: list.length(left), read: []),
            ),
          ),
          unpack_for_import(file.bytes, first),
        )
      }
  }
}

fn is_json(name: String) -> Bool {
  string.ends_with(string.lowercase(name), ".json")
}

fn unpack_for_import(archive: BitArray, entry: zip.Entry) -> Effect(Msg) {
  effects.from_promise(fn() { bytes.unpack(archive, entry) }, FileUnpacked)
}

/// An unpacked entry as text, through `read`, when it is a data file.
fn read_data(
  unpacked: Result(BitArray, UnpackError),
  read: fn(String) -> Result(a, catalogue.FileError),
) -> Result(a, Nil) {
  use unpacked <- result.try(result.replace_error(unpacked, Nil))
  use text <- result.try(bit_array.to_string(unpacked))
  read(text) |> result.replace_error(Nil)
}

/// Every entry is read: build the index and save both records. The import
/// stays on while they are saved.
fn finish_import(
  state: State,
  job: Import,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  let done = State(..state, importing: None)
  case job.read, data_index.build(list.reverse(job.read)), db {
    [], _, _ -> State(..done, problem: Some(NoDataFiles)) |> next_import
    _, Error(data_index.NoGameSystem), _ ->
      State(..done, problem: Some(NoGameSystem)) |> next_import
    _, Ok(index), Some(Ok(db)) -> #(
      State(..state, importing: Some(job)),
      effects.from_promise(fn() { save_set(db, job.file, index) }, SetSaved),
    )
    _, Ok(_), _ -> State(..done, problem: Some(NoStorage)) |> next_import
  }
}

/// A data set with the same key is replaced.
fn save_set(
  db: Database,
  file: ZipFile,
  index: Index,
) -> Promise(Result(DataSet, StorageError)) {
  let id = index.game_system_id
  let record =
    json.object([
      #("file_name", json.string(file.name)),
      #("imported", json.int(file.imported)),
      #("index", data_index.encode(index)),
    ])
  storage.write(db, [
    storage.Put(storage.DataIndexes, id, storage.JsonValue(record)),
    storage.Put(storage.DataZips, id, storage.BytesValue(file.bytes)),
  ])
  |> promise.map(result.replace(
    _,
    DataSet(id:, file_name: file.name, imported: file.imported, index:),
  ))
}

/// The zip's file name, when it was imported, and the index, which is an
/// error when it does not decode.
fn record_decoder() -> decode.Decoder(#(String, Int, Result(Index, Nil))) {
  use file_name <- decode.field("file_name", decode.string)
  use imported <- decode.field("imported", decode.int)
  use index <- decode.field(
    "index",
    decode.one_of(decode.map(data_index.decoder(), Ok), [
      decode.success(Error(Nil)),
    ]),
  )
  decode.success(#(file_name, imported, index))
}

/// Each saved record. An index older than the current version, or one that
/// no longer decodes, comes back with its zip to be built again.
fn load_sets(db: Database) -> Promise(Result(List(Stored), StorageError)) {
  use records <- promise.try_await(storage.get_all(
    db,
    storage.DataIndexes,
    record_decoder(),
  ))
  list.map(records, fn(pair) {
    let #(id, record) = pair
    case record {
      Ok(#(file_name, imported, Ok(index)))
        if index.version >= data_index.current_version
      -> promise.resolve(Current(DataSet(id:, file_name:, imported:, index:)))
      Ok(#(file_name, imported, _)) -> {
        use stored <- promise.map(storage.get_bytes(db, storage.DataZips, id))
        case stored {
          Ok(Some(bytes)) -> Stale(ZipFile(name: file_name, imported:, bytes:))
          Ok(None) | Error(_) -> Unreadable
        }
      }
      Error(_) -> promise.resolve(Unreadable)
    }
  })
  |> promise.await_list
  |> promise.map(Ok)
}

// --- Opening a node ---------------------------------------------------------

/// Start building what the screen needs. A node screen needs the scope of
/// its catalogue: nothing happens when that is built or being built, or when
/// the data set is not loaded. The shell calls this when the screen changes
/// and when the data sets have loaded.
pub fn enter(
  state: State,
  route: Route,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case route {
    route.NodePage(set_id:, catalogue_id:, ..) ->
      case list.find(saved_sets(state), fn(set) { set.id == set_id }) {
        Ok(set) -> open(state, set, catalogue_id, db)
        Error(Nil) -> #(state, effect.none())
      }
    _ -> #(state, effect.none())
  }
}

fn open(
  state: State,
  set: DataSet,
  catalogue_id: String,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case state.open {
    Some(Open(scope: Built(..), ..) as open)
      | Some(Open(scope: Decoding(..), ..) as open)
      if open.set_id == set.id && open.catalogue_id == catalogue_id
    -> #(state, effect.none())
    _ -> {
      let #(zip, decoded) = case state.open {
        Some(open) if open.set_id == set.id -> #(open.zip, open.decoded)
        _ -> #(None, dict.new())
      }
      let files = data_index.scope_files(set.index, catalogue_id)
      let #(keep, left) = files_to_decode(files, dict.keys(decoded))
      // ponytail: only the open scope's decoded files are kept, so going back
      // to an earlier catalogue decodes the files it does not share again.
      // Keep the last few scopes' files if that wait bites.
      let open =
        Open(
          set_id: set.id,
          catalogue_id:,
          files:,
          zip:,
          decoded: dict.take(decoded, keep),
          scope: Decoding(left:, total: list.length(left)),
        )
      case zip, db {
        Some(_), _ -> decode_next(state, open)
        None, Some(Ok(db)) -> #(
          State(..state, open: Some(open)),
          effects.from_promise(
            fn() { storage.get_bytes(db, storage.DataZips, set.id) },
            ZipRead(set.id, _),
          ),
        )
        // Storage opens before the data sets load, so this waits for nothing.
        None, _ -> #(State(..state, open: Some(open)), effect.none())
      }
    }
  }
}

/// For a scope's files and the files decoded so far: the decoded files to
/// keep, and the files to decode, both in scope order.
pub fn files_to_decode(
  scope_files: List(String),
  decoded: List(String),
) -> #(List(String), List(String)) {
  list.partition(scope_files, list.contains(decoded, _))
}

/// Unpack the next file to decode, or build the scope when none is left.
fn decode_next(state: State, open: Open) -> #(State, Effect(Msg)) {
  case open.scope, open.zip {
    Decoding(left: [], ..), _ -> {
      let built =
        open.files
        |> list.filter_map(dict.get(open.decoded, _))
        |> scope.build
      let open = Open(..open, scope: Built(built, scope.rule_links(built)))
      #(State(..state, open: Some(open)), effect.none())
    }
    Decoding(left: [file, ..], ..), Some(archive) -> {
      let entry =
        zip.entries(archive)
        |> result.unwrap([])
        |> list.find(fn(entry) { entry.name == file })
      case entry {
        Ok(entry) -> #(
          State(..state, open: Some(open)),
          effects.from_promise(
            fn() { bytes.unpack(archive, entry) },
            ScopeFileUnpacked(open.set_id, file, _),
          ),
        )
        Error(Nil) -> failed(state, open, FileNotDecoded(file))
      }
    }
    _, _ -> #(State(..state, open: Some(open)), effect.none())
  }
}

fn failed(
  state: State,
  open: Open,
  problem: OpenProblem,
) -> #(State, Effect(Msg)) {
  #(
    State(..state, open: Some(Open(..open, scope: Failed(problem)))),
    effect.none(),
  )
}

/// Drop the open scope when it belongs to the data set that changed.
fn close(open: Option(Open), set_id: String) -> Option(Open) {
  case open {
    Some(open) if open.set_id == set_id -> None
    _ -> open
  }
}

// --- Links from a list ------------------------------------------------------

/// The node screen of a unit or a setting of a list: its first entry id, when
/// a loaded data set has the catalogue and that id is one of its roots.
pub fn entry_href(
  state: State,
  catalogue_id: String,
  entry_ids: List(String),
) -> Option(String) {
  {
    use set <- result.try(set_with(state, catalogue_id))
    use first <- result.try(list.first(entry_ids))
    let roots = data_index.roots(set.index, catalogue_id)
    use _ <- result.map(list.find(roots, fn(root) { root.id == first }))
    route.to_hash(route.NodePage(set.id, catalogue_id, first))
  }
  |> option.from_result
}

/// The node screen of a setting's chosen value: its last entry id, when a
/// loaded data set has the catalogue.
pub fn value_href(
  state: State,
  catalogue_id: String,
  entry_ids: List(String),
) -> Option(String) {
  {
    use set <- result.try(set_with(state, catalogue_id))
    use last <- result.map(list.last(entry_ids))
    route.to_hash(route.NodePage(set.id, catalogue_id, last))
  }
  |> option.from_result
}

fn set_with(state: State, catalogue_id: String) -> Result(DataSet, Nil) {
  use set <- list.find(saved_sets(state))
  list.any(set.index.catalogues, fn(catalogue) { catalogue.id == catalogue_id })
}

// --- Words ------------------------------------------------------------------

/// A cost line in words, such as `+12 abc when at least 6 × Name`.
pub fn cost_line_text(line: CostLine) -> String {
  let sign = case line.kind {
    catalogue.Increment -> "+"
    catalogue.Decrement -> "-"
    _ -> ""
  }
  let value = case line.value {
    catalogue.NumberValue(number) -> sheet.format_value(number)
    catalogue.TextValue(text) -> text
    catalogue.BoolValue(_) | catalogue.NoValue -> ""
  }
  let when = case line.conditions {
    scope.Grouped -> " in some cases"
    scope.All([]) -> ""
    scope.All(conditions) ->
      " when " <> string.join(list.map(conditions, condition_text), " and ")
  }
  sign <> value <> " " <> line.cost_name <> when
}

/// What an item needs in words, such as `Only with Abc or Def, and Ghi`: the
/// names of a requirement joined by "or", and the requirements by ", and".
/// Empty when it needs nothing.
pub fn only_with(needs: List(List(#(String, String)))) -> String {
  case needs {
    [] -> ""
    _ ->
      "Only with "
      <> list.map(needs, fn(names) {
        list.map(names, fn(named) { named.1 }) |> string.join(" or ")
      })
      |> string.join(", and ")
  }
}

/// The words for a condition kind are the data format's, not the game's.
fn condition_text(condition: scope.CostCondition) -> String {
  let count = " " <> sheet.format_value(condition.value)
  let #(words, count) = case condition.kind {
    catalogue.AtLeast -> #("at least", count)
    catalogue.AtMost -> #("at most", count)
    catalogue.GreaterThan -> #("more than", count)
    catalogue.LessThan -> #("fewer than", count)
    catalogue.EqualTo -> #("exactly", count)
    catalogue.NotEqualTo -> #("not", count)
    catalogue.InstanceOf -> #("is", "")
    catalogue.NotInstanceOf -> #("is not", "")
    catalogue.OtherCondition(kind) -> #(kind, count)
  }
  let name = case condition.child_name, count {
    "", _ -> ""
    name, "" -> " " <> name
    name, _ -> " × " <> name
  }
  words <> count <> name
}

fn describe_problem(problem: Problem) -> String {
  case problem {
    NotAZip -> "That zip file could not be read."
    NoDataFiles -> "That zip file has no data files in it."
    NoGameSystem ->
      "That zip file has data files, but no game system file among them."
    NotSaved(error) ->
      "The game data could not be saved. "
      <> sheet_view.describe_storage_error(error)
    NotDeleted(error) ->
      "The game data could not be deleted. "
      <> sheet_view.describe_storage_error(error)
    NotReadAgain ->
      "Some saved game data could not be read. Import its zip file again."
    NoStorage ->
      "Storage is not open on this device, so game data cannot change."
  }
}

fn describe_open_problem(problem: OpenProblem) -> String {
  case problem {
    ZipNotRead(None) -> "The zip of this game data is not on this device."
    ZipNotRead(Some(error)) ->
      "The zip of this game data could not be read. "
      <> sheet_view.describe_storage_error(error)
    FileNotDecoded(file:) ->
      "The data file " <> file <> " in this zip could not be read."
  }
}

fn count(number: Int, one: String, many: String) -> String {
  case number {
    1 -> "1 " <> one
    _ -> int.to_string(number) <> " " <> many
  }
}

fn reading(done: Int, total: Int) -> String {
  "Reading "
  <> int.to_string(done)
  <> " of "
  <> int.to_string(total)
  <> " files"
}

// --- Views ------------------------------------------------------------------

/// The import's progress and the last problem, for under the import control.
pub fn status(state: State) -> List(Element(Msg)) {
  [
    case state.importing {
      None -> element.none()
      Some(job) ->
        html.p([attribute.class("note"), attribute.role("status")], [
          html.text(case job.left {
            [] -> "Saving…"
            left -> reading(job.total - list.length(left) + 1, job.total)
          }),
        ])
    },
    case state.problem {
      None -> element.none()
      Some(problem) ->
        html.p([attribute.class("problem"), attribute.role("alert")], [
          html.text(describe_problem(problem)),
        ])
    },
  ]
}

/// The data feature's part of the home screen: the saved data sets.
pub fn home(state: State) -> List(Element(Msg)) {
  [
    html.section([], [
      html.h2([], [html.text("Game data")]),
      case state.sets {
        None ->
          html.p([attribute.class("note")], [
            html.text("Opening the game data…"),
          ])
        Some(Error(error)) ->
          html.p([attribute.class("note")], [
            html.text(
              "The saved game data could not be read. "
              <> sheet_view.describe_storage_error(error),
            ),
          ])
        Some(Ok([])) ->
          html.p([attribute.class("note")], [
            html.text(
              "No game data yet. Import a zip of data files to browse them here.",
            ),
          ])
        Some(Ok(sets)) ->
          html.ul(
            [attribute.class("rows")],
            sets
              |> list.sort(fn(a, b) { int.compare(b.imported, a.imported) })
              |> list.map(fn(set) {
                set_row(set, state.confirming == Some(set.id))
              }),
          )
      },
    ]),
  ]
}

fn set_row(set: DataSet, confirming: Bool) -> Element(Msg) {
  let catalogues =
    list.count(set.index.catalogues, fn(catalogue) { !catalogue.game_system })
  let summary =
    html.a(
      [
        attribute.class("row-link"),
        attribute.href(route.to_hash(route.DataSetPage(set.id))),
      ],
      [
        html.span([attribute.class("name")], [
          html.text(set.index.game_system_name),
        ]),
        sheet_view.meta(count(catalogues, "catalogue", "catalogues")),
        sheet_view.meta("Imported " <> browser.local_time(set.imported)),
      ],
    )
  let delete = case confirming {
    False ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("button quiet"),
          event.on_click(DeleteClicked(set.id)),
        ],
        [html.text("Delete")],
      )
    True ->
      html.div([attribute.class("confirm"), attribute.role("group")], [
        html.span([], [html.text("Delete this game data?")]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button danger"),
            event.on_click(DeleteConfirmed(set.id)),
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
  }
  html.li([attribute.class("saved")], [summary, delete])
}

/// The page for one data set, or a plain message when it is not there.
fn with_set(
  state: State,
  set_id: String,
  render: fn(DataSet) -> List(Element(Msg)),
) -> List(Element(Msg)) {
  case state.sets {
    None -> [html.p([attribute.class("note")], [html.text("Opening…")])]
    Some(Error(error)) ->
      gone(
        route.Home,
        "Home",
        "The saved game data could not be read. "
          <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(sets)) ->
      case list.find(sets, fn(set) { set.id == set_id }) {
        Ok(set) -> render(set)
        Error(Nil) ->
          gone(route.Home, "Home", "This game data is not on this device.")
      }
  }
}

fn with_catalogue(
  set: DataSet,
  catalogue_id: String,
  render: fn(data_index.CatalogueSummary) -> List(Element(Msg)),
) -> List(Element(Msg)) {
  case list.find(set.index.catalogues, fn(c) { c.id == catalogue_id }) {
    Ok(catalogue) -> render(catalogue)
    Error(Nil) ->
      gone(
        route.DataSetPage(set.id),
        set.index.game_system_name,
        "This catalogue is not in this game data.",
      )
  }
}

fn gone(back: Route, label: String, message: String) -> List(Element(Msg)) {
  [
    sheet_view.back_link(back, label),
    html.p([attribute.class("note")], [html.text(message)]),
  ]
}

/// The text typed on the screen with this hash, empty when it was typed on
/// another.
fn typed_on(state: State, hash: String) -> String {
  case state.typed {
    Typed(on:, text:) if on == hash -> text
    Typed(..) -> ""
  }
}

fn text_box(label: String, hash: String, value: String) -> Element(Msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for("box")], [html.text(label)]),
    html.input([
      attribute.type_("search"),
      attribute.id("box"),
      attribute.value(value),
      attribute.autocomplete("off"),
      attribute.spellcheck(False),
      event.on_input(BoxTyped(hash, _)),
    ]),
  ])
}

/// The data set screen: a search over its roots, or its catalogues.
pub fn set_page(state: State, set_id: String) -> List(Element(Msg)) {
  use set <- with_set(state, set_id)
  let hash = route.to_hash(route.DataSetPage(set_id))
  let typed = typed_on(state, hash)
  let query = string.trim(typed)
  [
    sheet_view.back_link(route.Home, "Home"),
    html.h1([], [html.text(set.index.game_system_name)]),
    text_box("Search", hash, typed),
    case string.length(query) >= 2 {
      True -> hits(set, data_index.search(set.index, query))
      False -> catalogues(set)
    },
  ]
}

fn hits(set: DataSet, hits: List(data_index.Hit)) -> Element(Msg) {
  case hits {
    [] -> html.p([attribute.class("note")], [html.text("Nothing found.")])
    _ ->
      html.ul(
        [attribute.class("rows")],
        list.map(hits, fn(hit) {
          let under = case hit.root.primary {
            "" -> hit.catalogue_name
            primary -> hit.catalogue_name <> " · " <> primary
          }
          html.li([], [
            row(
              route.NodePage(set.id, hit.catalogue_id, hit.root.id),
              hit.root.name,
              [under],
            ),
          ])
        }),
      )
  }
}

/// The game system first, then the other catalogues by name, then the
/// libraries by name under their own heading.
fn catalogues(set: DataSet) -> Element(Msg) {
  let by_name = list.sort(_, fn(a: data_index.CatalogueSummary, b) {
    string.compare(a.name, b.name)
  })
  let #(system, rest) =
    list.partition(set.index.catalogues, fn(catalogue) { catalogue.game_system })
  let #(libraries, others) =
    list.partition(rest, fn(catalogue) { catalogue.library })
  let rows = fn(catalogues) {
    html.ul(
      [attribute.class("rows")],
      list.map(catalogues, fn(catalogue: data_index.CatalogueSummary) {
        html.li([], [
          row(route.CataloguePage(set.id, catalogue.id), catalogue.name, []),
        ])
      }),
    )
  }
  element.fragment([
    rows(list.append(system, by_name(others))),
    case libraries {
      [] -> element.none()
      _ ->
        html.section([], [
          html.h2([], [html.text("Libraries")]),
          rows(by_name(libraries)),
        ])
    },
  ])
}

/// A row that opens a screen: a name, and a line under it for each of
/// `under` that is not empty.
fn row(to: Route, name: String, under: List(String)) -> Element(Msg) {
  html.a([attribute.class("row-link"), attribute.href(route.to_hash(to))], [
    html.span([attribute.class("name")], [html.text(name)]),
    ..under
    |> list.filter(fn(line) { line != "" })
    |> list.map(sheet_view.meta)
  ])
}

/// The catalogue screen: its roots under their primary category, narrowed by
/// the filter.
pub fn catalogue_page(
  state: State,
  set_id: String,
  catalogue_id: String,
) -> List(Element(Msg)) {
  use set <- with_set(state, set_id)
  use catalogue <- with_catalogue(set, catalogue_id)
  let hash = route.to_hash(route.CataloguePage(set_id, catalogue_id))
  let typed = typed_on(state, hash)
  let filter = string.lowercase(string.trim(typed))
  let roots =
    data_index.roots(set.index, catalogue_id)
    |> list.filter(fn(root) {
      string.contains(string.lowercase(root.name), filter)
    })
  [
    sheet_view.back_link(route.DataSetPage(set_id), set.index.game_system_name),
    html.h1([], [html.text(catalogue.name)]),
    text_box("Filter", hash, typed),
    ..case roots {
      [] -> [html.p([attribute.class("note")], [html.text("Nothing found.")])]
      _ ->
        list.map(data_index.by_primary(roots), fn(group) {
          let #(category, roots) = group
          html.section([], [
            html.h2([], [
              html.text(case category {
                "" -> "Other"
                category -> category
              }),
            ]),
            html.ul(
              [attribute.class("rows")],
              list.map(roots, fn(root) {
                html.li([], [
                  row(
                    route.NodePage(set_id, catalogue_id, root.id),
                    root.name,
                    [],
                  ),
                ])
              }),
            ),
          ])
        })
    }
  ]
}

/// The node screen: the page of the node in its catalogue's scope, once the
/// scope is built.
pub fn node_page(
  state: State,
  set_id: String,
  catalogue_id: String,
  node_id: String,
) -> List(Element(Msg)) {
  use set <- with_set(state, set_id)
  use catalogue <- with_catalogue(set, catalogue_id)
  let to_catalogue = route.CataloguePage(set_id, catalogue_id)
  let back = sheet_view.back_link(to_catalogue, catalogue.name)
  let note = fn(text) {
    [back, html.p([attribute.class("note")], [html.text(text)])]
  }
  case state.open {
    Some(Open(scope: Built(scope: built, links:), ..) as open)
      if open.set_id == set_id && open.catalogue_id == catalogue_id
    ->
      case scope.page(built, node_id) {
        Ok(page) -> node_view(page, links, set_id, catalogue_id, back)
        Error(Nil) -> note("This entry is not in this catalogue.")
      }
    Some(Open(scope: Decoding(left:, total:), zip: Some(_), ..) as open)
      if open.set_id == set_id && open.catalogue_id == catalogue_id
    -> note(reading(total - list.length(left) + 1, total))
    Some(Open(scope: Failed(problem), ..) as open)
      if open.set_id == set_id && open.catalogue_id == catalogue_id
    -> [
      back,
      html.p([attribute.class("problem"), attribute.role("alert")], [
        html.text(describe_open_problem(problem)),
      ]),
    ]
    _ -> note("Opening…")
  }
}

fn node_view(
  page: Page,
  links: text.Links(String),
  set_id: String,
  catalogue_id: String,
  to_catalogue: Element(Msg),
) -> List(Element(Msg)) {
  let node_route = route.NodePage(set_id, catalogue_id, _)
  let href = fn(id) { route.to_hash(node_route(id)) }
  let show_text = sheet_view.rich_text(_, links, href)
  let back = case list.last(page.path) {
    Ok(#(id, name)) -> sheet_view.back_link(node_route(id), name)
    Error(Nil) -> to_catalogue
  }
  let path = case page.path {
    [] -> element.none()
    path ->
      html.ul(
        [attribute.class("path")],
        list.map(path, fn(parent) {
          html.li([], [
            html.a([attribute.href(href(parent.0))], [html.text(parent.1)]),
          ])
        }),
      )
  }
  let is_group = case page.node {
    catalogue.Group(..)
    | catalogue.EntryLink(target_kind: catalogue.ToGroup, ..) -> True
    _ -> False
  }
  let contains =
    rows_section(
      "Contains",
      list.map(page.contains, item_row(node_route, _, [])),
      0,
    )
  list.flatten([
    [
      back,
      path,
      html.h1([], [html.text(catalogue.name(page.node))]),
      case page.needs {
        [] -> element.none()
        needs ->
          html.p([attribute.class("note")], [html.text(only_with(needs))])
      },
    ],
    case is_group {
      True -> [contains]
      False -> []
    },
    [sheet_view.costs(page.costs), cost_lines(page.cost_lines)],
    list.map(sheet.profile_groups(page.profiles), sheet_view.profile_group(
      _,
      show_text,
    )),
    [
      case page.own_rules {
        [] -> element.none()
        rules ->
          html.section([], [
            html.h2([], [html.text("Rules")]),
            ..list.map(rules, fn(rule) {
              html.div([attribute.class("rule")], [
                html.h3([], [html.text(rule.name)]),
                html.div(
                  [attribute.class("prose")],
                  show_text(rule.description),
                ),
              ])
            })
          ])
      },
      chips(
        "More rules",
        list.map(page.linked_rules, fn(rule) { #(rule.name, href(rule.id)) }),
      ),
      chips(
        "Keywords",
        list.map(page.keywords, fn(keyword) { #(keyword.1, href(keyword.0)) }),
      ),
      case is_group {
        True -> element.none()
        False -> contains
      },
      rows_section(
        "Conditional",
        list.map(page.conditional, conditional_row(node_route, _)),
        0,
      ),
      rows_section(
        "Unlocks",
        list.map(list.take(page.unlocks, max_unlocks), fn(unlock) {
          html.li([], [
            item_link(node_route, unlock.item, []),
            case unlock.children {
              [] -> element.none()
              children ->
                html.ul(
                  [attribute.class("rows children")],
                  list.map(children, conditional_row(node_route, _)),
                )
            },
          ])
        }),
        list.length(page.unlocks) - max_unlocks,
      ),
      rows_section(
        "Rules that name its keywords",
        list.map(page.keyword_rules, fn(keyword_rule) {
          let owner = case keyword_rule.owner {
            Some(owner) -> owner.name
            None -> ""
          }
          html.li([], [
            row(node_route(keyword_rule.rule.id), keyword_rule.rule.name, [
              owner,
            ]),
          ])
        }),
        0,
      ),
      rows_section(
        "Entries with this keyword",
        list.map(page.with_keyword, item_row(node_route, _, [])),
        page.with_keyword_count - list.length(page.with_keyword),
      ),
    ],
  ])
}

const max_unlocks = 100

fn cost_lines(lines: List(CostLine)) -> Element(Msg) {
  case lines {
    [] -> element.none()
    _ ->
      html.ul(
        [attribute.class("cost-lines")],
        list.map(lines, fn(line) {
          html.li([], [html.text(cost_line_text(line))])
        }),
      )
  }
}

/// Names that open a screen, as chips under a heading. Nothing when there are
/// none.
fn chips(title: String, links: List(#(String, String))) -> Element(Msg) {
  case links {
    [] -> element.none()
    _ ->
      html.section([], [
        html.h2([], [html.text(title)]),
        html.ul(
          [attribute.class("chips")],
          list.map(links, fn(link) {
            html.li([], [html.a([attribute.href(link.1)], [html.text(link.0)])])
          }),
        ),
      ])
  }
}

/// Rows under a heading, then "and N more" when `more` is above zero.
/// Nothing when there are no rows.
fn rows_section(
  title: String,
  rows: List(Element(Msg)),
  more: Int,
) -> Element(Msg) {
  case rows {
    [] -> element.none()
    _ ->
      html.section([], [
        html.h2([], [html.text(title)]),
        html.ul([attribute.class("rows")], rows),
        case more > 0 {
          True ->
            html.p([attribute.class("note")], [
              html.text("and " <> int.to_string(more) <> " more"),
            ])
          False -> element.none()
        },
      ])
  }
}

fn item_row(
  node_route: fn(String) -> Route,
  item: Item,
  under: List(String),
) -> Element(Msg) {
  html.li([], [item_link(node_route, item, under)])
}

/// An item with its "Only with" line, when it has one.
fn conditional_row(
  node_route: fn(String) -> Route,
  conditional: scope.Conditional,
) -> Element(Msg) {
  item_row(node_route, conditional.item, [only_with(conditional.needs)])
}

/// An item's name and costs, then the lines in `under`.
fn item_link(
  node_route: fn(String) -> Route,
  item: Item,
  under: List(String),
) -> Element(Msg) {
  row(node_route(item.id), item.name, [sheet.format_costs(item.costs), ..under])
}
