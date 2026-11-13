//// What the app keeps about a loaded data set: one summary per file, enough
//// to list, group and search the roots and to know which files a catalogue
//// needs, without reading a file again.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import tabletop/catalogue.{
  type Link, type RootSummary, type SharedSummary, type Summary, EntryRoot, Link,
  LinkRoot,
}
import tabletop/sheet.{type EntryKind}

/// The version a new index gets. Raise it when the shape of `Index` changes.
pub const current_version = 2

pub type Index {
  Index(
    version: Int,
    game_system_id: String,
    game_system_name: String,
    /// One per file, the game system's included, in the order given.
    catalogues: List(CatalogueSummary),
  )
}

pub type CatalogueSummary {
  CatalogueSummary(
    id: String,
    name: String,
    library: Bool,
    game_system: Bool,
    /// The file's name in the zip.
    file: String,
    links: List(Link),
    /// The roots this file defines itself.
    roots: List(Root),
  )
}

/// Something a list can start from. `target_id` is empty when the root is an
/// entry and not a link. `primary` is the name of its primary category, empty
/// when it has none. `shown` says whether it shows when nothing is chosen.
pub type Root {
  Root(
    id: String,
    name: String,
    target_id: String,
    kind: EntryKind,
    primary: String,
    shown: Bool,
  )
}

pub type IndexError {
  NoGameSystem
}

/// A root that a search found, with the catalogue that owns it.
pub type Hit {
  Hit(catalogue_id: String, catalogue_name: String, root: Root)
}

const max_hits = 50

/// The index of files given as name in the zip and summary. When two files
/// are a game system, the first is the game system.
pub fn build(files: List(#(String, Summary))) -> Result(Index, IndexError) {
  let summaries = list.map(files, fn(file) { file.1 })
  use system <- result.map(
    list.find(summaries, fn(summary) { summary.game_system })
    |> result.replace_error(NoGameSystem),
  )
  // `dict.from_list` keeps the last pair for a key, and the first file that
  // defines an id wins, so reverse first.
  let shared =
    summaries
    |> list.flat_map(fn(summary) { summary.shared })
    |> list.map(fn(entry) { #(entry.id, entry) })
    |> list.reverse
    |> dict.from_list
  let catalogues =
    list.map(files, fn(file) {
      let #(name, summary) = file
      CatalogueSummary(
        id: summary.id,
        name: summary.name,
        library: summary.library,
        game_system: summary.game_system,
        file: name,
        links: summary.links,
        roots: list.map(summary.roots, root(_, shared)),
      )
    })
  Index(
    version: current_version,
    game_system_id: system.id,
    game_system_name: system.name,
    catalogues:,
  )
}

/// A link takes its kind and primary category from the shared entry it
/// points at, in whichever file that is. Its own primary category wins. It
/// shows when it and that entry show, or when it shows and no file shares
/// the entry.
fn root(root: RootSummary, shared: Dict(String, SharedSummary)) -> Root {
  case root {
    EntryRoot(id:, name:, kind:, primary:, shown:) ->
      Root(id:, name:, target_id: "", kind:, primary:, shown:)
    LinkRoot(id:, name:, target_id:, primary: own, shown:) -> {
      let #(kind, primary, target_shown) = case
        dict.get(shared, target_id),
        own
      {
        Ok(target), "" -> #(target.kind, target.primary, target.shown)
        Ok(target), _ -> #(target.kind, own, target.shown)
        Error(Nil), _ -> #(sheet.OtherKind(""), own, True)
      }
      Root(
        id:,
        name:,
        target_id:,
        kind:,
        primary:,
        shown: shown && target_shown,
      )
    }
  }
}

// --- Asking the index -------------------------------------------------------

/// The catalogue's own roots, then the roots of every catalogue it imports,
/// through further imports too, then the game system's. Unique by id.
pub fn roots(index: Index, catalogue_id: String) -> List(Root) {
  reach(index, catalogue_id, fn(link) { link.import_roots })
  |> list.flat_map(fn(catalogue) { catalogue.roots })
  |> unique_by(fn(root) { root.id })
}

/// The files to decode for the catalogue: its own, then every file its links
/// reach, through further links too, then the game system's. No repeats.
pub fn scope_files(index: Index, catalogue_id: String) -> List(String) {
  reach(index, catalogue_id, fn(_) { True })
  |> list.map(fn(catalogue) { catalogue.file })
  |> list.unique
}

/// The catalogue, then the catalogues its links reach, following the links
/// that `follow` accepts, then the game system. No catalogue twice.
fn reach(
  index: Index,
  catalogue_id: String,
  follow: fn(Link) -> Bool,
) -> List(CatalogueSummary) {
  follow_links(index, [catalogue_id, index.game_system_id], follow, [])
  |> list.partition(fn(catalogue) { catalogue.id != index.game_system_id })
  |> fn(parts) { list.append(parts.0, parts.1) }
}

/// Each catalogue comes before the ones it links. `found` is newest first.
fn follow_links(
  index: Index,
  ids: List(String),
  follow: fn(Link) -> Bool,
  found: List(CatalogueSummary),
) -> List(CatalogueSummary) {
  case ids {
    [] -> list.reverse(found)
    [id, ..rest] -> {
      let known = list.any(found, fn(catalogue) { catalogue.id == id })
      let catalogue =
        list.find(index.catalogues, fn(catalogue) { catalogue.id == id })
      case known, catalogue {
        False, Ok(catalogue) -> {
          let linked =
            catalogue.links
            |> list.filter(follow)
            |> list.map(fn(link) { link.target_id })
          let found = [catalogue, ..found]
          follow_links(index, list.append(linked, rest), follow, found)
        }
        _, _ -> follow_links(index, rest, follow, found)
      }
    }
  }
}

/// Roots under the name of their primary category: groups in first-seen
/// order, the roots with no category last under an empty name, and each
/// group sorted by name.
pub fn by_primary(roots: List(Root)) -> List(#(String, List(Root))) {
  let #(named, unnamed) =
    roots
    |> list.map(fn(root) { root.primary })
    |> list.unique
    |> list.partition(fn(primary) { primary != "" })
  list.append(named, unnamed)
  |> list.map(fn(primary) {
    let group =
      roots
      |> list.filter(fn(root) { root.primary == primary })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    #(primary, group)
  })
}

/// The roots whose name holds `query`, ignoring case, over the roots each
/// file defines itself. One hit per target, or per root when it has no
/// target, 50 hits at most, and none for a query under two characters. Of
/// the catalogues that own a root for a target, the hit is the first whose
/// root is shown, or the first when none is.
pub fn search(index: Index, query: String) -> List(Hit) {
  let query = string.lowercase(query)
  use <- bool.guard(string.length(query) < 2, [])
  let hits =
    index.catalogues
    |> list.flat_map(fn(catalogue) {
      catalogue.roots
      |> list.filter(fn(root) {
        string.contains(string.lowercase(root.name), query)
      })
      |> list.map(Hit(catalogue.id, catalogue.name, _))
    })
  let target = fn(hit: Hit) {
    case hit.root.target_id {
      "" -> hit.root.id
      target_id -> target_id
    }
  }
  hits
  |> unique_by(target)
  |> list.take(max_hits)
  |> list.map(fn(first) {
    list.find(hits, fn(hit) { hit.root.shown && target(hit) == target(first) })
    |> result.unwrap(first)
  })
}

/// The first item for each key, in order.
fn unique_by(items: List(a), key: fn(a) -> String) -> List(a) {
  let #(_, kept) =
    list.fold(items, #(set.new(), []), fn(acc, item) {
      let #(seen, kept) = acc
      case set.contains(seen, key(item)) {
        True -> acc
        False -> #(set.insert(seen, key(item)), [item, ..kept])
      }
    })
  list.reverse(kept)
}

// --- Storing the index ------------------------------------------------------

pub fn encode(index: Index) -> Json {
  json.object([
    #("version", json.int(index.version)),
    #("game_system_id", json.string(index.game_system_id)),
    #("game_system_name", json.string(index.game_system_name)),
    #("catalogues", json.array(index.catalogues, encode_catalogue)),
  ])
}

fn encode_catalogue(catalogue: CatalogueSummary) -> Json {
  json.object([
    #("id", json.string(catalogue.id)),
    #("name", json.string(catalogue.name)),
    #("library", json.bool(catalogue.library)),
    #("game_system", json.bool(catalogue.game_system)),
    #("file", json.string(catalogue.file)),
    #(
      "links",
      json.array(catalogue.links, fn(link) {
        json.object([
          #("target_id", json.string(link.target_id)),
          #("import_roots", json.bool(link.import_roots)),
        ])
      }),
    ),
    #(
      "roots",
      json.array(catalogue.roots, fn(root) {
        json.object([
          #("id", json.string(root.id)),
          #("name", json.string(root.name)),
          #("target_id", json.string(root.target_id)),
          #("kind", json.string(kind_to_string(root.kind))),
          #("primary", json.string(root.primary)),
          #("shown", json.bool(root.shown)),
        ])
      }),
    ),
  ])
}

/// The string that `sheet.entry_kind_decoder` reads back as the same kind.
fn kind_to_string(kind: EntryKind) -> String {
  case kind {
    sheet.Unit -> "unit"
    sheet.Model -> "model"
    sheet.Upgrade -> "upgrade"
    sheet.OtherKind(other) -> other
  }
}

pub fn decoder() -> Decoder(Index) {
  use version <- decode.field("version", decode.int)
  use game_system_id <- decode.field("game_system_id", decode.string)
  use game_system_name <- decode.field("game_system_name", decode.string)
  use catalogues <- decode.field("catalogues", decode.list(catalogue_decoder()))
  decode.success(Index(
    version:,
    game_system_id:,
    game_system_name:,
    catalogues:,
  ))
}

fn catalogue_decoder() -> Decoder(CatalogueSummary) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use library <- decode.field("library", decode.bool)
  use game_system <- decode.field("game_system", decode.bool)
  use file <- decode.field("file", decode.string)
  use links <- decode.field("links", decode.list(link_decoder()))
  use roots <- decode.field("roots", decode.list(root_decoder()))
  decode.success(CatalogueSummary(
    id:,
    name:,
    library:,
    game_system:,
    file:,
    links:,
    roots:,
  ))
}

fn link_decoder() -> Decoder(Link) {
  use target_id <- decode.field("target_id", decode.string)
  use import_roots <- decode.field("import_roots", decode.bool)
  decode.success(Link(target_id:, import_roots:))
}

fn root_decoder() -> Decoder(Root) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use target_id <- decode.field("target_id", decode.string)
  use kind <- decode.field("kind", sheet.entry_kind_decoder())
  use primary <- decode.field("primary", decode.string)
  use shown <- decode.field("shown", decode.bool)
  decode.success(Root(id:, name:, target_id:, kind:, primary:, shown:))
}
