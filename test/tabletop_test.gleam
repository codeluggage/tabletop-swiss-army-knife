import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import simplifile
import tabletop.{
  type Model, Applying, Available, DeleteCancelled, DeleteClicked, FileRead,
  Flags, HashChanged, Model, NoStorage, NotAList, UpToDate, VersionFetched,
}
import tabletop/roster
import tabletop/route

pub fn main() -> Nil {
  gleeunit.main()
}

const running = "2026-11-12.204107.aaaaaaa"

fn model(update: tabletop.Update) -> Model {
  let #(model, _) = tabletop.init(Flags(running:, hash: ""))
  Model(..model, update:)
}

fn fetched(model: Model, body: Result(String, String)) -> tabletop.Update {
  let #(model, _) = tabletop.update(model, VersionFetched(body))
  model.update
}

pub fn newer_build_offers_a_reload_test() {
  let body = Ok("{\"version\":\"2026-11-13.080000.bbbbbbb\"}")
  assert fetched(model(UpToDate), body) == Available
}

pub fn same_or_older_build_offers_nothing_test() {
  let same = Ok("{\"version\":\"" <> running <> "\"}")
  let older = Ok("{\"version\":\"2026-11-11.204107.ccccccc\"}")
  assert fetched(model(UpToDate), same) == UpToDate
  assert fetched(model(UpToDate), older) == UpToDate
}

pub fn failed_or_foreign_fetch_offers_nothing_test() {
  assert fetched(model(UpToDate), Error("offline")) == UpToDate
  assert fetched(model(UpToDate), Ok("<!doctype html>Not found")) == UpToDate
}

pub fn unstamped_page_offers_nothing_test() {
  let #(unstamped, _) = tabletop.init(Flags(running: "__VERSION__", hash: ""))
  let body = Ok("{\"version\":\"2026-11-13.080000.bbbbbbb\"}")
  assert fetched(unstamped, body) == UpToDate
}

pub fn a_reload_in_progress_stays_in_progress_test() {
  let body = Ok("{\"version\":\"2026-11-11.204107.ccccccc\"}")
  assert fetched(model(Applying), body) == Applying
}

pub fn the_screen_starts_from_the_hash_test() {
  let #(model, _) = tabletop.init(Flags(running:, hash: "#/list/abc"))
  assert model.route == route.ListPage("abc")
}

pub fn a_hash_change_moves_screens_and_remembers_the_scroll_test() {
  let #(model, _) =
    tabletop.update(model(UpToDate), HashChanged("#/list/abc", 120.0))
  assert model.route == route.ListPage("abc")
  assert dict.get(model.scroll, "#/") == Ok(120.0)
}

pub fn delete_asks_first_test() {
  let #(asking, _) = tabletop.update(model(UpToDate), DeleteClicked("abc"))
  assert asking.confirming == Some("abc")
  let #(answered, _) = tabletop.update(asking, DeleteCancelled)
  assert answered.confirming == None
}

pub fn a_file_that_is_not_a_list_says_why_test() {
  let #(model, _) =
    tabletop.update(model(UpToDate), FileRead(Ok(#("notes.txt", "hello"))))
  assert model.problem == Some(NotAList(roster.NotJson))
}

pub fn a_list_with_storage_closed_says_so_test() {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let #(model, _) =
    tabletop.update(model(UpToDate), FileRead(Ok(#("list.json", text))))
  assert model.problem == Some(NoStorage)
}
