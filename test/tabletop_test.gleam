import gleeunit
import tabletop.{
  type Model, Applying, Available, Model, UpToDate, VersionFetched,
}

pub fn main() -> Nil {
  gleeunit.main()
}

const running = "2026-11-12.204107.aaaaaaa"

fn model(update: tabletop.Update) -> Model {
  let #(model, _) = tabletop.init(running)
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
  let #(unstamped, _) = tabletop.init("__VERSION__")
  let body = Ok("{\"version\":\"2026-11-13.080000.bbbbbbb\"}")
  assert fetched(unstamped, body) == UpToDate
}

pub fn a_reload_in_progress_stays_in_progress_test() {
  let body = Ok("{\"version\":\"2026-11-11.204107.ccccccc\"}")
  assert fetched(model(Applying), body) == Applying
}
