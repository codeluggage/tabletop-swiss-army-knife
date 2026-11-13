import gleam/int
import gleam/json
import gleam/list
import simplifile
import tabletop/catalogue.{
  type Summary, EntryRoot, Link, LinkRoot, SharedSummary, Summary,
}
import tabletop/data_index.{
  type Index, type Root, CatalogueSummary, Hit, Index, NoGameSystem, Root,
}
import tabletop/sheet.{Model, OtherKind, Unit, Upgrade}

/// The fixture files as an import would hand them over: by their name in the
/// zip, in the zip's order.
fn fixture_files() -> List(#(String, Summary)) {
  ["crockery", "pantry", "picnic-system", "teapot"]
  |> list.map(fn(name) {
    let assert Ok(text) =
      simplifile.read("test/fixtures/data/" <> name <> ".json")
    let assert Ok(summary) = catalogue.summarise(text)
    #("picnic/" <> name <> ".json", summary)
  })
}

fn fixture() -> Index {
  let assert Ok(index) = data_index.build(fixture_files())
  index
}

fn ids(roots: List(Root)) -> List(String) {
  list.map(roots, fn(root) { root.id })
}

/// A catalogue with these links as (target id, import flag) and one root
/// entry per name, with the name as its id.
fn summary(
  id: String,
  links: List(#(String, Bool)),
  roots: List(String),
) -> #(String, Summary) {
  #(
    id <> ".json",
    Summary(
      game_system: False,
      id:,
      name: id,
      library: False,
      links: list.map(links, fn(link) { Link(link.0, link.1) }),
      roots: list.map(roots, fn(name) { EntryRoot(name, name, Unit, "") }),
      shared: [],
    ),
  )
}

fn system(roots: List(String)) -> #(String, Summary) {
  let #(file, summary) = summary("system", [], roots)
  #(file, Summary(..summary, game_system: True))
}

// --- Building ---------------------------------------------------------------

pub fn the_index_holds_one_summary_per_file_test() {
  assert fixture()
    == Index(
      version: 1,
      game_system_id: "sys-picnic",
      game_system_name: "Picnic Skirmish",
      catalogues: [
        CatalogueSummary(
          id: "cat-crockery",
          name: "Crockery",
          library: False,
          game_system: False,
          file: "picnic/crockery.json",
          links: [Link("cat-pantry", True)],
          roots: [
            // The link's own primary category wins over its target's.
            Root(
              "l-guest-captain",
              "Kettle Captain",
              "e-captain",
              Model,
              "Line",
            ),
            Root("e-brew", "Brew", "", Upgrade, ""),
          ],
        ),
        CatalogueSummary(
          id: "cat-pantry",
          name: "Pantry",
          library: True,
          game_system: False,
          file: "picnic/pantry.json",
          links: [],
          roots: [Root("l-walker", "Sugar Bowl Walker", "e-walker", Model, "")],
        ),
        CatalogueSummary(
          id: "sys-picnic",
          name: "Picnic Skirmish",
          library: False,
          game_system: True,
          file: "picnic/picnic-system.json",
          links: [],
          roots: [Root("e-weather", "Weather", "", Upgrade, "")],
        ),
        CatalogueSummary(
          id: "cat-teapot",
          name: "Teapot Golems",
          library: False,
          game_system: False,
          file: "picnic/teapot.json",
          links: [Link("cat-crockery", True)],
          roots: [
            // Kind and primary category come from a target in another file.
            Root("l-captain", "Kettle Captain", "e-captain", Model, "Leader"),
            Root("l-squad", "Teacup Squad", "e-squad", Unit, "Line"),
          ],
        ),
      ],
    )
  assert data_index.current_version == 1
}

pub fn a_link_to_nothing_keeps_what_it_has_test() {
  let #(file, lost) = summary("a", [], [])
  let lost =
    Summary(..lost, roots: [
      LinkRoot("l-1", "One", "gone", ""),
      LinkRoot("l-2", "Two", "gone", "Line"),
    ])
  let assert Ok(index) = data_index.build([system([]), #(file, lost)])
  assert data_index.roots(index, "a")
    == [
      Root("l-1", "One", "gone", OtherKind(""), ""),
      Root("l-2", "Two", "gone", OtherKind(""), "Line"),
    ]
}

pub fn the_first_file_to_define_a_shared_entry_wins_test() {
  let with_shared = fn(id, kind) {
    let #(file, summary) = summary(id, [], [])
    #(file, Summary(..summary, shared: [SharedSummary("e-1", kind, id)]))
  }
  let #(file, linking) = summary("c", [], [])
  let linking = Summary(..linking, roots: [LinkRoot("l-1", "One", "e-1", "")])
  let assert Ok(index) =
    data_index.build([
      system([]),
      with_shared("a", Model),
      with_shared("b", Upgrade),
      #(file, linking),
    ])
  assert data_index.roots(index, "c") == [Root("l-1", "One", "e-1", Model, "a")]
}

pub fn no_game_system_is_an_error_test() {
  assert data_index.build([]) == Error(NoGameSystem)
  assert data_index.build([summary("a", [], [])]) == Error(NoGameSystem)
}

pub fn the_first_of_two_game_systems_wins_test() {
  let #(file, second) = system(["late"])
  let second = Summary(..second, id: "second", name: "second")
  let assert Ok(index) =
    data_index.build([
      summary("a", [], ["own"]),
      system(["early"]),
      #(file, second),
    ])
  assert #(index.game_system_id, index.game_system_name)
    == #("system", "system")
  assert ids(data_index.roots(index, "a")) == ["own", "early"]
}

pub fn the_index_round_trips_through_json_test() {
  let index = fixture()
  let stored = json.to_string(data_index.encode(index))
  assert json.parse(stored, data_index.decoder()) == Ok(index)
  // A kind the code has no variant for comes back as it went in.
  let odd =
    Index(..index, catalogues: [
      CatalogueSummary("c", "C", True, False, "c.json", [Link("d", False)], [
        Root("r", "R", "t", OtherKind("crew"), ""),
      ]),
    ])
  assert json.parse(
      json.to_string(data_index.encode(odd)),
      data_index.decoder(),
    )
    == Ok(odd)
}

// --- Roots ------------------------------------------------------------------

pub fn roots_come_through_two_import_links_then_the_game_system_test() {
  assert ids(data_index.roots(fixture(), "cat-teapot"))
    == [
      "l-captain",
      "l-squad",
      "l-guest-captain",
      "e-brew",
      "l-walker",
      "e-weather",
    ]
  assert ids(data_index.roots(fixture(), "cat-crockery"))
    == ["l-guest-captain", "e-brew", "l-walker", "e-weather"]
  assert ids(data_index.roots(fixture(), "cat-pantry"))
    == ["l-walker", "e-weather"]
  assert ids(data_index.roots(fixture(), "sys-picnic")) == ["e-weather"]
  assert ids(data_index.roots(fixture(), "cat-unknown")) == ["e-weather"]
}

pub fn a_link_without_the_import_flag_brings_no_roots_test() {
  let assert Ok(index) =
    data_index.build([
      system(["weather"]),
      summary("a", [#("b", False), #("c", True)], ["a-1"]),
      summary("b", [], ["b-1"]),
      summary("c", [#("d", False), #("a", True)], ["c-1", "a-1"]),
      summary("d", [], ["d-1"]),
    ])
  // c imports a back: the loop ends, and a root id appears once.
  assert ids(data_index.roots(index, "a")) == ["a-1", "c-1", "weather"]
  assert data_index.scope_files(index, "a")
    == ["a.json", "b.json", "c.json", "d.json", "system.json"]
}

pub fn roots_group_by_primary_category_test() {
  let groups =
    data_index.by_primary(data_index.roots(fixture(), "cat-teapot"))
    |> list.map(fn(group) { #(group.0, ids(group.1)) })
  // Groups in first-seen order, names sorted inside, no category last.
  assert groups
    == [
      #("Leader", ["l-captain"]),
      #("Line", ["l-guest-captain", "l-squad"]),
      #("", ["e-brew", "l-walker", "e-weather"]),
    ]
  assert data_index.by_primary([]) == []
}

// --- Search -----------------------------------------------------------------

pub fn search_ignores_case_and_matches_anywhere_test() {
  let brew =
    Hit("cat-crockery", "Crockery", Root("e-brew", "Brew", "", Upgrade, ""))
  assert data_index.search(fixture(), "bRE") == [brew]
  assert data_index.search(fixture(), "ew") == [brew]
  // The game system's roots are searched too.
  assert data_index.search(fixture(), "weather")
    == [
      Hit(
        "sys-picnic",
        "Picnic Skirmish",
        Root("e-weather", "Weather", "", Upgrade, ""),
      ),
    ]
  assert data_index.search(fixture(), "marmalade") == []
}

pub fn search_gives_one_hit_per_target_test() {
  // Two catalogues link to the same captain; the first file's root is kept.
  assert data_index.search(fixture(), "KETTLE")
    == [
      Hit(
        "cat-crockery",
        "Crockery",
        Root("l-guest-captain", "Kettle Captain", "e-captain", Model, "Line"),
      ),
    ]
  // Roots without a target are told apart by their own id.
  let assert Ok(index) =
    data_index.build([system(["tea"]), summary("a", [], ["tea", "teapot"])])
  assert list.map(data_index.search(index, "tea"), fn(hit) {
      #(hit.catalogue_id, hit.root.id)
    })
    == [#("system", "tea"), #("a", "teapot")]
}

pub fn search_stops_at_fifty_hits_test() {
  let names =
    int.range(from: 60, to: 0, with: [], run: fn(names, n) {
      ["cup " <> int.to_string(n), ..names]
    })
  let assert Ok(index) = data_index.build([system([]), summary("a", [], names)])
  let hits = data_index.search(index, "cup")
  assert list.length(hits) == 50
  assert list.map(list.take(hits, 2), fn(hit) { hit.root.name })
    == ["cup 1", "cup 2"]
}

pub fn a_query_under_two_characters_finds_nothing_test() {
  assert data_index.search(fixture(), "k") == []
  assert data_index.search(fixture(), "") == []
}

// --- Scope files ------------------------------------------------------------

pub fn scope_files_follow_every_link_and_end_with_the_game_system_test() {
  assert data_index.scope_files(fixture(), "cat-teapot")
    == [
      "picnic/teapot.json", "picnic/crockery.json", "picnic/pantry.json",
      "picnic/picnic-system.json",
    ]
  assert data_index.scope_files(fixture(), "cat-pantry")
    == ["picnic/pantry.json", "picnic/picnic-system.json"]
  assert data_index.scope_files(fixture(), "sys-picnic")
    == ["picnic/picnic-system.json"]
}
