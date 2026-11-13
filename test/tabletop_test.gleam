import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import tabletop.{
  type Model, Applying, Available, FileRead, Flags, HashChanged, ListsMsg, Model,
  UpToDate, VersionFetched,
}
import tabletop/lists
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

pub fn a_screen_change_closes_the_delete_question_test() {
  let #(asking, _) =
    tabletop.update(model(UpToDate), ListsMsg(lists.DeleteClicked("abc")))
  assert asking.lists.confirming == Some("abc")
  let #(moved, _) = tabletop.update(asking, HashChanged("#/list/abc", 0.0))
  assert moved.lists.confirming == None
}

pub fn a_read_file_goes_to_the_lists_test() {
  let #(model, _) =
    tabletop.update(model(UpToDate), FileRead(Ok(#("notes.txt", "hello"))))
  assert model.lists.problem == Some(lists.NotAList(roster.NotJson))
  let #(model, _) = tabletop.update(model, FileRead(Error("gone")))
  assert model.lists.problem == Some(lists.FileNotRead("gone"))
}
