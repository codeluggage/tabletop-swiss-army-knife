import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import lustre/element
import simplifile
import tabletop.{
  type Model, Applying, Available, BackupKind, BackupMsg, CardsMsg, FileNotRead,
  FileRead, Flags, HashChanged, ListsMsg, Model, NeitherKind, NotAKnownKind,
  TextKind, TrackerMsg, UpToDate, VersionFetched, ZipKind,
}
import tabletop/backup
import tabletop/cards
import tabletop/lists
import tabletop/roster
import tabletop/route
import tabletop/score_test
import tabletop/storage
import tabletop/tracker
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
  let game =
    tabletop.view(Model(..model(UpToDate), route: route.GamePage("gone")))
    |> element.to_string
  assert string.starts_with(game, line)
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

fn backup_file() -> BitArray {
  let assert Ok(bytes) =
    simplifile.read_bits("test/fixtures/invented-backup.json")
  bytes
}

pub fn a_backup_file_is_a_backup_test() {
  let assert BackupKind(Ok(_)) = tabletop.file_kind(backup_file())
  let broken = <<"{\"format\":\"tabletop-backup\"}":utf8>>
  assert tabletop.file_kind(broken) == BackupKind(Error(backup.Broken))
}

pub fn a_backup_file_asks_before_anything_is_written_test() {
  let #(model, _) =
    tabletop.update(
      model(UpToDate),
      FileRead(Ok(#("tabletop-backup-2026-11-13.json", backup_file()))),
    )
  assert model.lists.problem == None
  let page = tabletop.view(model) |> element.to_string
  assert string.starts_with(
    page,
    "<main class=\"page\"><p class=\"version-line\">Version 2026.11.12.2041</p>",
  )
  assert string.contains(page, "<h1>Restore this backup?</h1>")
  assert string.contains(
    page,
    "It holds 1 list, 1 game data set, 2 cards, 1 score sheet and 1 game.",
  )
  assert string.contains(page, "with version 2026.11.13.1542.")
  assert !string.contains(page, "About this device")
  // Leaving the screen closes the question.
  let #(model, _) = tabletop.update(model, HashChanged("#/", 0.0))
  let page = tabletop.view(model) |> element.to_string
  assert !string.contains(page, "Restore this backup?")
  assert string.contains(page, "<h2>Backup</h2>")
}

pub fn a_backup_from_a_newer_app_is_refused_on_the_home_screen_test() {
  let newer =
    "{\"format\":\"tabletop-backup\",\"made\":\"\",\"release\":\"\",\"schema\":99,\"stores\":{}}"
  let #(model, _) =
    tabletop.update(
      model(UpToDate),
      FileRead(Ok(#("backup.json", <<newer:utf8>>))),
    )
  let page = tabletop.view(model) |> element.to_string
  assert string.contains(
    page,
    "The app on this device is older than this backup and needs its update first.",
  )
  assert string.contains(page, "<h2>About this device</h2>")
}

pub fn a_restore_has_every_feature_read_its_stores_again_test() {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let assert Ok(decoded) = roster.decode(text)
  let saved = lists.Saved(id: "l1", name: "", imported: 0, roster: Ok(decoded))
  let #(model, _) =
    tabletop.update(model(UpToDate), ListsMsg(lists.ListsLoaded(Ok([saved]))))
  let model =
    Model(..model, storage: Some(Error(storage.OpenFailed("not in a test"))))
  let #(model, _) = tabletop.update(model, BackupMsg(backup.Restored(Ok(Nil))))
  // Back to "Opening…" until the stores are read again.
  assert model.lists.lists == None
  assert model.data.sets == None
  assert model.cards.cards == None
  assert model.tracker.sheets == None
  assert model.tracker.games == None
}

pub fn the_home_screen_has_games_and_a_list_leads_back_to_its_game_test() {
  let home = tabletop.view(model(UpToDate)) |> element.to_string
  let assert [_, after_data] = string.split(home, "<h2>Game data</h2>")
  let assert [_, after_games] = string.split(after_data, "<h2>Games</h2>")
  assert string.contains(after_games, "<h2>Backup</h2>")
  let #(model, _) =
    tabletop.update(
      model(UpToDate),
      TrackerMsg(tracker.SheetsLoaded(Ok([score_test.picnic_sheet()]))),
    )
  let #(model, _) =
    tabletop.update(
      model,
      TrackerMsg(
        tracker.StartSubmitted([#("l1", "Sunday Picnic")], [
          #("sheet", "sheet-picnic"),
          #("list", "l1"),
        ]),
      ),
    )
  let page =
    tabletop.view(Model(..model, route: route.ListPage("l1")))
    |> element.to_string
  assert string.contains(page, "Back to the game")
}

pub fn the_home_screen_has_a_backup_section_above_about_test() {
  let home = tabletop.view(model(UpToDate)) |> element.to_string
  let assert [_, after] = string.split(home, "<h2>Backup</h2>")
  assert string.contains(after, "Save a backup file")
  assert string.contains(after, "Last backup: reading…")
  assert string.contains(after, "<h2>About this device</h2>")
  let #(model, _) =
    tabletop.update(model(UpToDate), BackupMsg(backup.LastLoaded(Ok(None))))
  let home = tabletop.view(model) |> element.to_string
  assert string.contains(home, "Last backup: never")
}
