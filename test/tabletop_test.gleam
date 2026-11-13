import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import lustre/element
import simplifile
import tabletop.{
  type Model, Applying, Available, CardsMsg, FileNotRead, FileRead, Flags,
  HashChanged, ListsMsg, Model, NeitherKind, NotAKnownKind, TextKind, UpToDate,
  VersionFetched, ZipKind,
}
import tabletop/cards
import tabletop/lists
import tabletop/roster
import tabletop/route
import tabletop/zip_writer.{File, Store}

pub fn main() -> Nil {
  gleeunit.main()
}

const running = "2026.11.12.2041"

const commit = "aaaaaaa"

fn model(update: tabletop.Update) -> Model {
  let #(model, _) = tabletop.init(Flags(running:, commit:, hash: ""))
  Model(..model, update:)
}

fn fetched(model: Model, body: Result(String, String)) -> tabletop.Update {
  let #(model, _) = tabletop.update(model, VersionFetched(body))
  model.update
}

fn release(text: String) -> Result(String, String) {
  Ok(
    "{\"release\":\""
    <> text
    <> "\",\"commit\":\"bbbbbbb\",\"schema\":4,\"version\":\"2026-11-13.080000.bbbbbbb\"}",
  )
}

pub fn newer_release_offers_a_reload_test() {
  assert fetched(model(UpToDate), release("2026.11.12.2042")) == Available
}

pub fn same_or_older_release_offers_nothing_test() {
  assert fetched(model(UpToDate), release(running)) == UpToDate
  assert fetched(model(UpToDate), release("2026.11.11.2359")) == UpToDate
}

pub fn failed_or_foreign_fetch_offers_nothing_test() {
  assert fetched(model(UpToDate), Error("offline")) == UpToDate
  assert fetched(model(UpToDate), Ok("<!doctype html>Not found")) == UpToDate
  // A site from before releases has only the old key.
  let old = Ok("{\"version\":\"2026-11-13.080000.bbbbbbb\"}")
  assert fetched(model(UpToDate), old) == UpToDate
}

pub fn unstamped_page_offers_nothing_test() {
  let #(unstamped, _) =
    tabletop.init(Flags(running: "__VERSION__", commit: "__COMMIT__", hash: ""))
  assert fetched(unstamped, release("2026.11.13.0800")) == UpToDate
}

pub fn a_reload_in_progress_stays_in_progress_test() {
  assert fetched(model(Applying), release("2026.11.11.2041")) == Applying
}

pub fn every_screen_starts_with_the_version_test() {
  let line =
    "<main class=\"page\"><p class=\"version-line\">Version 2026.11.12.2041</p>"
  let home = tabletop.view(model(UpToDate)) |> element.to_string
  assert string.contains(home, line)
  let list =
    tabletop.view(Model(..model(UpToDate), route: route.ListPage("gone")))
    |> element.to_string
  assert string.contains(list, line)
}

pub fn about_this_device_shows_the_version_and_commit_test() {
  let home = tabletop.view(model(UpToDate)) |> element.to_string
  assert string.contains(home, "<dt>Version</dt><dd>2026.11.12.2041</dd>")
  assert string.contains(home, "<dt>Commit</dt><dd>aaaaaaa</dd>")
}

pub fn the_screen_starts_from_the_hash_test() {
  let #(model, _) = tabletop.init(Flags(running:, commit:, hash: "#/list/abc"))
  assert model.route == route.ListPage("abc")
}

pub fn a_hash_change_moves_screens_and_remembers_the_scroll_test() {
  let #(model, _) =
    tabletop.update(model(UpToDate), HashChanged("#/list/abc", 120.0))
  assert model.route == route.ListPage("abc")
  assert dict.get(model.scroll, "#/") == Ok(120.0)
}

pub fn a_screen_change_closes_the_delete_question_test() {
  let #(asking, _) =
    tabletop.update(model(UpToDate), ListsMsg(lists.DeleteClicked("abc")))
  assert asking.lists.confirming == Some("abc")
  let #(moved, _) = tabletop.update(asking, HashChanged("#/list/abc", 0.0))
  assert moved.lists.confirming == None
}

fn a_zip() -> BitArray {
  zip_writer.write("box", [File("a.json", <<"{}":utf8>>, Store)], "")
}

pub fn a_file_is_a_zip_text_or_neither_test() {
  assert tabletop.file_kind(a_zip()) == ZipKind
  assert tabletop.file_kind(<<"{\"roster\": {}}":utf8>>)
    == TextKind("{\"roster\": {}}")
  assert tabletop.file_kind(<<>>) == TextKind("")
  assert tabletop.file_kind(<<0xff, 0xfe, 0x00>>) == NeitherKind
}

pub fn a_text_file_goes_to_the_lists_test() {
  let #(model, _) =
    tabletop.update(
      model(UpToDate),
      FileRead(Ok(#("notes.txt", <<"hello":utf8>>))),
    )
  assert model.lists.problem == Some(lists.NotAList(roster.NotJson))
  assert model.data.importing == None
}

pub fn a_zip_goes_to_the_data_test() {
  let #(model, _) =
    tabletop.update(model(UpToDate), FileRead(Ok(#("box.zip", a_zip()))))
  assert model.lists.problem == None
  let assert Some(job) = model.data.importing
  assert job.file.name == "box.zip"
}

pub fn the_shell_owns_the_problems_of_the_file_itself_test() {
  let #(model, _) = tabletop.update(model(UpToDate), FileRead(Error("gone")))
  assert model.file_problem == Some(FileNotRead("gone"))
  let #(model, _) =
    tabletop.update(model, FileRead(Ok(#("photo.bin", <<0xff, 0xd8>>))))
  assert model.file_problem == Some(NotAKnownKind)
  assert model.lists.problem == None
  assert model.data.problem == None
}

pub fn a_list_shows_its_cards_without_the_game_data_test() {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let assert Ok(decoded) = roster.decode(text)
  let saved = lists.Saved(id: "l1", name: "", imported: 0, roster: Ok(decoded))
  let card = fn(id, name, place) {
    cards.Card(
      id:,
      name:,
      cost: "",
      when: "",
      target: "",
      effect: "",
      place:,
      edited: 0,
    )
  }
  let saved_cards = [
    card(
      "c1",
      "Second Pour",
      route.Node("sys-picnic", "cat-teapot", "e-drizzle"),
    ),
    card("c2", "Crumb Trail", route.Game("sys-picnic")),
    card("c3", "Lid Down", route.Node("sys-picnic", "cat-teapot", "e-sunshine")),
    card("c4", "Spilt Milk", route.Game("sys-other")),
  ]
  let #(model, _) =
    tabletop.update(model(UpToDate), ListsMsg(lists.ListsLoaded(Ok([saved]))))
  let #(model, _) =
    tabletop.update(model, CardsMsg(cards.CardsLoaded(Ok(saved_cards))))
  // No data set is loaded.
  assert model.data.sets == None
  let page =
    tabletop.view(Model(..model, route: route.ListPage("l1")))
    |> element.to_string
  // The chosen value's node first, under the value's name, then the game.
  let assert [_, after_value] = string.split(page, "<h3>Drizzle</h3>")
  let assert [value_cards, game_cards] =
    string.split(after_value, "<h3>Whole game</h3>")
  assert string.contains(value_cards, "Second Pour")
  assert string.contains(game_cards, "Crumb Trail")
  assert !string.contains(page, "Lid Down")
  assert !string.contains(page, "Spilt Milk")
}
