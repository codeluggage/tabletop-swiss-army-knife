//// The whole path from a zip of data files to the pages of a list's units:
//// on the invented data set, and on the real files in `local-data/` on this
//// machine only.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tabletop/browser
import tabletop/bytes
import tabletop/catalogue
import tabletop/data_index
import tabletop/roster.{type Roster}
import tabletop/scope.{type Scope}
import tabletop/zip
import tabletop/zip_writer.{Deflate, File, Store}

/// What one run found. Counts and milliseconds only.
type Run {
  Run(
    /// The `.json` entries of the zip, and their unpacked size.
    files: Int,
    bytes: Int,
    /// Entries that would not unpack to text, or that are not a data file.
    unread: Int,
    entries_ms: Int,
    unpack_ms: Int,
    summarise_ms: Int,
    index_ms: Int,
    forces: List(ForceRun),
  )
}

/// One force of a list against the scope of its catalogue.
type ForceRun {
  ForceRun(
    scope_files: Int,
    /// Scope files that did not decode in full.
    undecoded: Int,
    decode_ms: Int,
    scope_ms: Int,
    pages_ms: Int,
    units: Int,
    checked: List(Checked),
  )
}

/// One unit of a list against the page of its first entry id that is a node:
/// the unit's visible profiles, the page's profiles, and how many of the
/// unit's are not on the page by type name and name.
type Checked {
  Checked(listed: Int, on_page: Int, missing: Int)
}

fn timed(run: fn() -> a) -> #(a, Int) {
  let start = browser.now_ms()
  let value = run()
  #(value, browser.now_ms() - start)
}

/// Read the zip as the import will, then check each list against it.
fn run(archive: BitArray, lists: List(Roster)) -> Promise(Run) {
  let #(entries, entries_ms) =
    timed(fn() {
      let assert Ok(entries) = zip.entries(archive)
      list.filter(entries, fn(entry) {
        string.ends_with(string.lowercase(entry.name), ".json")
      })
    })
  let start = browser.now_ms()
  use unpacked <- promise.map(
    promise.await_list(list.map(entries, bytes.unpack(archive, _))),
  )
  let texts =
    list.zip(entries, unpacked)
    |> list.filter_map(fn(pair) {
      let #(entry, unpacked) = pair
      use bytes <- result.try(result.replace_error(unpacked, Nil))
      use text <- result.map(bit_array.to_string(bytes))
      #(entry.name, text)
    })
  let unpack_ms = browser.now_ms() - start
  let #(summaries, summarise_ms) =
    timed(fn() {
      list.filter_map(texts, fn(file) {
        use summary <- result.map(catalogue.summarise(file.1))
        #(file.0, summary)
      })
    })
  let #(index, index_ms) =
    timed(fn() {
      let assert Ok(index) = data_index.build(summaries)
      index
    })
  Run(
    files: list.length(entries),
    bytes: int.sum(list.map(entries, fn(entry) { entry.size })),
    unread: list.length(entries) - list.length(summaries),
    entries_ms:,
    unpack_ms:,
    summarise_ms:,
    index_ms:,
    forces: lists
      |> list.flat_map(fn(roster) { roster.forces })
      |> list.map(check_force(_, index, texts)),
  )
}

fn check_force(
  force: roster.Force,
  index: data_index.Index,
  texts: List(#(String, String)),
) -> ForceRun {
  let files = data_index.scope_files(index, force.catalogue_id)
  let #(catalogues, decode_ms) =
    timed(fn() {
      list.filter_map(files, fn(file) {
        use text <- result.try(list.key_find(texts, file))
        catalogue.decode(text) |> result.replace_error(Nil)
      })
    })
  let #(scope, scope_ms) = timed(fn() { scope.build(catalogues) })
  let units = roster.units(force)
  let #(checked, pages_ms) =
    timed(fn() { list.filter_map(units, check_unit(scope, _)) })
  ForceRun(
    scope_files: list.length(files),
    undecoded: list.length(files) - list.length(catalogues),
    decode_ms:,
    scope_ms:,
    pages_ms:,
    units: list.length(units),
    checked:,
  )
}

fn check_unit(scope: Scope, unit: roster.Selection) -> Result(Checked, Nil) {
  use page <- result.map(list.find_map(unit.entry_ids, scope.page(scope, _)))
  let on_page =
    list.map(page.profiles, fn(profile) { #(profile.type_name, profile.name) })
  let listed =
    roster.unit_profiles(unit)
    |> list.filter(fn(profile) { !profile.hidden })
    |> list.map(fn(profile) { #(profile.type_name, profile.name) })
  Checked(
    listed: list.length(listed),
    on_page: list.length(on_page),
    missing: list.count(listed, fn(profile) { !list.contains(on_page, profile) }),
  )
}

/// No profile of the list's unit is missing from the page, and the page has
/// at most three times the unit's profiles plus ten.
fn within_limits(checked: Checked) -> Bool {
  checked.missing == 0 && checked.on_page <= 3 * checked.listed + 10
}

// --- The invented data set --------------------------------------------------

fn fixture(path: String) -> String {
  let assert Ok(text) = simplifile.read("test/fixtures/" <> path)
  text
}

pub fn the_invented_zip_gives_the_pages_of_the_invented_list_test() -> Promise(
  Nil,
) {
  let data = fn(name, packing) {
    File(name, <<fixture("data/" <> name):utf8>>, packing)
  }
  let archive =
    zip_writer.write(
      "picnic",
      [
        File("readme.txt", <<"Bring a blanket.":utf8>>, Store),
        data("crockery.json", Deflate),
        data("pantry.json", Deflate),
        data("picnic-system.json", Store),
        data("teapot.json", Deflate),
        File("menu.json", <<"{\"scones\": 12}":utf8>>, Store),
      ],
      "packed for sunday",
    )
  let assert Ok(list) = roster.decode(fixture("invented-list.json"))
  use run <- promise.map(run(archive, [list]))
  // Five .json entries, and the one that is not a data file is left unread.
  assert #(run.files, run.unread) == #(5, 1)
  let assert [force] = run.forces
  assert #(force.scope_files, force.undecoded) == #(4, 0)
  // The list has three units, and two of them hold an entry id. The page of
  // the captain and of the squad has every visible profile the list gives
  // them: three for the captain, and four for the squad, one of them twice.
  assert force.units == 3
  assert force.checked == [Checked(3, 3, 0), Checked(4, 10, 0)]
  assert list.all(force.checked, within_limits)
}

// --- The real files in local-data/, on this machine only --------------------

/// Reads the zip in `local-data/` and checks every list beside it. Passes
/// when the folder or the zip is missing, as in CI. Prints counts and
/// milliseconds, and nothing from the files.
pub fn local_data_zip_gives_the_pages_of_the_local_lists_test() -> Promise(Nil) {
  let names = simplifile.read_directory("local-data") |> result.unwrap([])
  let lists =
    names
    |> list.filter(string.ends_with(_, ".json"))
    |> list.filter_map(fn(name) {
      use text <- result.try(
        simplifile.read("local-data/" <> name) |> result.replace_error(Nil),
      )
      roster.decode(text) |> result.replace_error(Nil)
    })
  let archive =
    list.find(names, string.ends_with(_, ".zip"))
    |> result.try(fn(name) {
      simplifile.read_bits("local-data/" <> name) |> result.replace_error(Nil)
    })
  case archive {
    Error(Nil) -> promise.resolve(Nil)
    Ok(archive) -> {
      use run <- promise.map(run(archive, lists))
      io.println("\n" <> describe(run))
      assert run.unread == 0
      assert list.all(run.forces, fn(force) { force.undecoded == 0 })
      let checked = list.flat_map(run.forces, fn(force) { force.checked })
      assert list.all(checked, within_limits)
    }
  }
}

fn describe(run: Run) -> String {
  let count = int.to_string
  let import_line =
    "local data: "
    <> count(run.files)
    <> " files, "
    <> count(run.bytes)
    <> " bytes, "
    <> count(run.unread)
    <> " unread. read entries "
    <> count(run.entries_ms)
    <> " ms, unpack all "
    <> count(run.unpack_ms)
    <> " ms, summarise all "
    <> count(run.summarise_ms)
    <> " ms, build the index "
    <> count(run.index_ms)
    <> " ms"
  let force_lines =
    list.map(run.forces, fn(force) {
      let sum = fn(pick) { count(int.sum(list.map(force.checked, pick))) }
      "local list: "
      <> count(force.scope_files)
      <> " scope files, "
      <> count(force.undecoded)
      <> " undecoded. decode the scope files "
      <> count(force.decode_ms)
      <> " ms, build the scope "
      <> count(force.scope_ms)
      <> " ms, all pages "
      <> count(force.pages_ms)
      <> " ms. "
      <> count(force.units)
      <> " units, "
      <> count(list.length(force.checked))
      <> " pages, "
      <> sum(fn(checked) { checked.listed })
      <> " list profiles, "
      <> sum(fn(checked) { checked.on_page })
      <> " page profiles, "
      <> sum(fn(checked) { checked.missing })
      <> " missing, "
      <> count(
        list.count(force.checked, fn(checked) { !within_limits(checked) }),
      )
      <> " units outside the limits"
    })
  string.join([import_line, ..force_lines], "\n")
}
