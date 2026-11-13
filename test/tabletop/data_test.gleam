import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import simplifile
import tabletop/catalogue
import tabletop/data.{
  type State, BoxTyped, Built, Current, DataSet, Decoding, DeleteCancelled,
  DeleteClicked, DeleteConfirmed, FileUnpacked, NoDataFiles, NoGameSystem,
  NoStorage, NotAZip, NotReadAgain, NotSaved, ScopeFileUnpacked, SetDeleted,
  SetSaved, SetsLoaded, Stale, Typed, Unreadable, ZipFile, ZipRead,
}
import tabletop/data_index
import tabletop/route
import tabletop/scope.{All, CostCondition, CostLine, Grouped}
import tabletop/storage
import tabletop/zip_writer.{Deflate, File, Store}

const names = ["crockery", "pantry", "picnic-system", "teapot"]

fn fixture(name: String) -> BitArray {
  let assert Ok(bytes) =
    simplifile.read_bits("test/fixtures/data/" <> name <> ".json")
  bytes
}

/// The invented data set as a zip, with a file that is not a data file
/// last, and the bytes of each `.json` entry in the zip's order.
fn picnic_zip() -> #(BitArray, List(BitArray)) {
  let menu = <<"{\"scones\": 12}":utf8>>
  let files =
    list.map(names, fn(name) { File(name <> ".json", fixture(name), Deflate) })
  let zip =
    zip_writer.write(
      "picnic",
      [
        File("readme.txt", <<"Bring a blanket.":utf8>>, Store),
        ..list.append(files, [File("menu.json", menu, Store)])
      ],
      "",
    )
  #(zip, list.append(list.map(names, fixture), [menu]))
}

fn picnic_set() -> data.DataSet {
  let files =
    list.map(names, fn(name) {
      let assert Ok(text) =
        simplifile.read("test/fixtures/data/" <> name <> ".json")
      let assert Ok(summary) = catalogue.summarise(text)
      #("picnic/" <> name <> ".json", summary)
    })
  let assert Ok(index) = data_index.build(files)
  DataSet(
    id: index.game_system_id,
    file_name: "picnic.zip",
    imported: 0,
    index:,
  )
}

fn loaded() -> State {
  step(data.init(), SetsLoaded(Ok([Current(picnic_set())])))
}

fn step(state: State, msg: data.Msg) -> State {
  let #(state, _) = data.update(state, msg, None)
  state
}

fn render(elements: List(element.Element(data.Msg))) -> String {
  element.to_string(html.div([], elements))
}

// --- Importing --------------------------------------------------------------

pub fn an_import_reads_one_data_file_at_a_time_test() {
  let #(zip, contents) = picnic_zip()
  let #(state, _) = data.import_zip(data.init(), "picnic.zip", zip)
  let assert Some(job) = state.importing
  // Five `.json` entries; the text file is not one.
  assert #(job.total, list.length(job.left), job.read) == #(5, 5, [])
  assert string.contains(render(data.status(state)), "Reading 1 of 5 files")
  let assert [first, ..rest] = contents
  let state = step(state, FileUnpacked(Ok(first)))
  let assert Some(job) = state.importing
  assert #(list.length(job.left), list.length(job.read)) == #(4, 1)
  assert string.contains(render(data.status(state)), "Reading 2 of 5 files")
  // The last entry is not a data file and is skipped. With storage closed,
  // the import ends there.
  let state =
    list.fold(rest, state, fn(state, bytes) {
      step(state, FileUnpacked(Ok(bytes)))
    })
  assert state.importing == None
  assert state.problem == Some(NoStorage)
}

pub fn a_saved_data_set_replaces_one_with_the_same_key_test() {
  let older = DataSet(..picnic_set(), file_name: "old.zip")
  let state = step(data.init(), SetsLoaded(Ok([Current(older)])))
  let state = step(state, SetSaved(Ok(picnic_set())))
  assert state.importing == None
  assert state.sets == Some(Ok([picnic_set()]))
}

pub fn a_file_that_is_not_a_zip_says_so_test() {
  let #(state, _) =
    data.import_zip(data.init(), "x.zip", <<0x50, 0x4b, 0x03, 0x04, 1, 2, 3>>)
  assert state.importing == None
  assert state.problem == Some(NotAZip)
}

pub fn a_zip_with_no_data_files_says_so_test() {
  let text = File("readme.txt", <<"Bring a blanket.":utf8>>, Store)
  let #(state, _) =
    data.import_zip(data.init(), "x.zip", zip_writer.write("x", [text], ""))
  assert state.problem == Some(NoDataFiles)
  let menu = <<"{\"scones\": 12}":utf8>>
  let zip = zip_writer.write("x", [File("menu.json", menu, Store)], "")
  let #(state, _) = data.import_zip(data.init(), "x.zip", zip)
  let state = step(state, FileUnpacked(Ok(menu)))
  assert state.importing == None
  assert state.problem == Some(NoDataFiles)
}

pub fn a_zip_with_no_game_system_says_so_test() {
  let zip =
    zip_writer.write("x", [File("a.json", fixture("crockery"), Store)], "")
  let #(state, _) = data.import_zip(data.init(), "x.zip", zip)
  let state = step(state, FileUnpacked(Ok(fixture("crockery"))))
  assert state.problem == Some(NoGameSystem)
}

pub fn a_data_set_that_was_not_saved_says_so_test() {
  let state = step(data.init(), SetSaved(Error(storage.WriteFailed("full"))))
  assert state.problem == Some(NotSaved(storage.WriteFailed("full")))
}

pub fn an_older_index_is_built_again_from_its_zip_test() {
  let #(zip, _) = picnic_zip()
  let stale = ZipFile(name: "picnic.zip", imported: 5, bytes: zip)
  let state =
    step(data.init(), SetsLoaded(Ok([Current(picnic_set()), Stale(stale)])))
  assert state.sets == Some(Ok([picnic_set()]))
  let assert Some(job) = state.importing
  assert job.file == stale
  let state = step(data.init(), SetsLoaded(Ok([Unreadable])))
  assert state.problem == Some(NotReadAgain)
}

// --- Opening a node ---------------------------------------------------------

pub fn the_files_to_decode_test() {
  // A cold start decodes every file.
  assert data.files_to_decode(["t", "c", "p", "s"], [])
    == #([], ["t", "c", "p", "s"])
  // Another node in the same catalogue decodes none.
  assert data.files_to_decode(["t", "c", "p", "s"], ["t", "c", "p", "s"])
    == #(["t", "c", "p", "s"], [])
  // Another catalogue keeps the files it shares and decodes the rest, in
  // scope order. A file it does not use is dropped.
  assert data.files_to_decode(["t", "c", "p", "s"], ["x", "s", "p"])
    == #(["p", "s"], ["t", "c"])
}

fn file(name: String) -> String {
  "picnic/" <> name <> ".json"
}

pub fn a_node_screen_builds_its_scope_one_file_at_a_time_test() {
  let #(zip, _) = picnic_zip()
  let node = route.NodePage("sys-picnic", "cat-teapot", "l-captain")
  let #(state, _) = data.enter(loaded(), node, None)
  let assert Some(open) = state.open
  let order = list.map(["teapot", "crockery", "pantry", "picnic-system"], file)
  assert open.scope == Decoding(left: order, total: 4)
  assert open.zip == None
  let state = step(state, ZipRead("sys-picnic", Ok(Some(zip))))
  let state =
    list.fold(
      ["teapot", "crockery", "pantry", "picnic-system"],
      state,
      fn(state, name) {
        step(
          state,
          ScopeFileUnpacked("sys-picnic", file(name), Ok(fixture(name))),
        )
      },
    )
  let assert Some(open) = state.open
  let assert Built(..) = open.scope
  assert string.contains(
    render(data.node_page(state, "sys-picnic", "cat-teapot", "l-captain")),
    "Kettle Captain",
  )
  // A node hidden by default says what it needs under its title.
  assert string.contains(
    render(data.node_page(state, "sys-picnic", "cat-teapot", "e-mascot")),
    "Only with Teacup Sergeant",
  )
  // A second node in the same catalogue starts nothing.
  let other = route.NodePage("sys-picnic", "cat-teapot", "l-squad")
  let #(again, _) = data.enter(state, other, None)
  assert again == state
  // Another catalogue keeps the files it shares, so it needs none decoded.
  let pantry = route.NodePage("sys-picnic", "cat-pantry", "l-walker")
  let #(state, _) = data.enter(state, pantry, None)
  let assert Some(open) = state.open
  assert dict.keys(open.decoded) |> list.sort(string.compare)
    == [file("pantry"), file("picnic-system")]
  let assert Built(..) = open.scope
}

pub fn a_file_that_does_not_decode_is_named_on_the_node_screen_test() {
  let #(zip, _) = picnic_zip()
  let node = route.NodePage("sys-picnic", "cat-pantry", "l-walker")
  let #(state, _) = data.enter(loaded(), node, None)
  let state = step(state, ZipRead("sys-picnic", Ok(Some(zip))))
  let state =
    step(
      state,
      ScopeFileUnpacked("sys-picnic", file("pantry"), Ok(<<"{":utf8>>)),
    )
  let page =
    render(data.node_page(state, "sys-picnic", "cat-pantry", "l-walker"))
  assert string.contains(page, "picnic/pantry.json")
  // The catalogue screen keeps working.
  let catalogue = render(data.catalogue_page(state, "sys-picnic", "cat-pantry"))
  assert string.contains(catalogue, "Sugar Bowl Walker")
}

// --- Screens ----------------------------------------------------------------

pub fn the_search_box_keeps_its_text_per_screen_test() {
  let hash = route.to_hash(route.DataSetPage("sys-picnic"))
  let state = step(loaded(), BoxTyped(hash, "k"))
  assert state.typed == Typed(on: hash, text: "k")
  // Under two characters, the catalogues show.
  let page = render(data.set_page(state, "sys-picnic"))
  assert string.contains(page, "Libraries")
  assert !string.contains(page, "Kettle Captain")
  // From two, the hits do.
  let state = step(state, BoxTyped(hash, "ke"))
  let page = render(data.set_page(state, "sys-picnic"))
  assert string.contains(page, "Kettle Captain")
  assert !string.contains(page, "Libraries")
  // The text stays on its own screen.
  let catalogue = render(data.catalogue_page(state, "sys-picnic", "cat-teapot"))
  assert !string.contains(catalogue, "value=\"ke\"")
}

pub fn delete_asks_first_test() {
  let state = step(loaded(), DeleteClicked("sys-picnic"))
  assert state.confirming == Some("sys-picnic")
  assert step(state, DeleteCancelled).confirming == None
  let closed = step(state, DeleteConfirmed("sys-picnic"))
  assert #(closed.confirming, closed.problem) == #(None, Some(NoStorage))
  let deleted = step(state, SetDeleted("sys-picnic", Ok(Nil)))
  assert deleted.sets == Some(Ok([]))
}

pub fn the_words_for_a_cost_line_test() {
  let at_least = CostCondition(catalogue.AtLeast, 6.0, "x-1", "Name")
  let line =
    CostLine("abc", catalogue.Set, catalogue.NumberValue(12.0), All([]))
  assert data.cost_line_text(line) == "12 abc"
  assert data.cost_line_text(CostLine(..line, conditions: All([at_least])))
    == "12 abc when at least 6 × Name"
  assert data.cost_line_text(CostLine(..line, kind: catalogue.Increment))
    == "+12 abc"
  assert data.cost_line_text(CostLine(..line, kind: catalogue.Decrement))
    == "-12 abc"
  let unnamed = CostCondition(..at_least, child_name: "")
  assert data.cost_line_text(CostLine(..line, conditions: All([unnamed])))
    == "12 abc when at least 6"
  let instance = CostCondition(..at_least, kind: catalogue.InstanceOf)
  assert data.cost_line_text(CostLine(..line, conditions: All([instance])))
    == "12 abc when is Name"
  assert data.cost_line_text(CostLine(..line, conditions: Grouped))
    == "12 abc in some cases"
}

pub fn the_words_for_what_an_item_needs_test() {
  let abc = #("x-1", "Abc")
  let def = #("x-2", "Def")
  let ghi = #("x-3", "Ghi")
  assert data.only_with([]) == ""
  assert data.only_with([[abc]]) == "Only with Abc"
  assert data.only_with([[abc, def], [ghi]]) == "Only with Abc or Def, and Ghi"
  assert data.only_with([[abc], [def, ghi], [abc]])
    == "Only with Abc, and Def or Ghi, and Abc"
}

// --- Links from a list ------------------------------------------------------

pub fn a_unit_or_setting_links_to_its_root_test() {
  let state = loaded()
  assert data.entry_href(state, "cat-teapot", ["l-squad", "e-squad"])
    == Some("#/data/sys-picnic/cat-teapot/l-squad")
  // A root of the game system counts, as a setting's does.
  assert data.entry_href(state, "cat-teapot", ["e-weather"])
    == Some("#/data/sys-picnic/cat-teapot/e-weather")
  // An id that is not a root, an unknown catalogue, and no ids give nothing.
  assert data.entry_href(state, "cat-teapot", ["e-captain"]) == None
  assert data.entry_href(state, "cat-elsewhere", ["l-squad"]) == None
  assert data.entry_href(state, "cat-teapot", []) == None
  assert data.entry_href(data.init(), "cat-teapot", ["l-squad"]) == None
}

pub fn a_chosen_value_links_to_its_last_entry_id_test() {
  let state = loaded()
  assert data.value_href(state, "cat-teapot", ["e-weather", "e-drizzle"])
    == Some("#/data/sys-picnic/cat-teapot/e-drizzle")
  assert data.value_href(state, "cat-elsewhere", ["e-drizzle"]) == None
  assert data.value_href(state, "cat-teapot", []) == None
}
