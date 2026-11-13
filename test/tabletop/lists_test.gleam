import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import simplifile
import tabletop/lists.{DeleteCancelled, DeleteClicked, NoStorage, NotAList}
import tabletop/roster

pub fn delete_asks_first_test() {
  let #(asking, _) = lists.update(lists.init(), DeleteClicked("abc"), None)
  assert asking.confirming == Some("abc")
  let #(answered, _) = lists.update(asking, DeleteCancelled, None)
  assert answered.confirming == None
}

pub fn a_file_that_is_not_a_list_says_why_test() {
  let #(state, _) = lists.import_file(lists.init(), None, "notes.txt", "hello")
  assert state.problem == Some(NotAList(roster.NotJson))
}

pub fn a_list_with_storage_closed_says_so_test() {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let #(state, _) = lists.import_file(lists.init(), None, "list.json", text)
  assert state.problem == Some(NoStorage)
}

fn saved_list() -> lists.State {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let assert Ok(decoded) = roster.decode(text)
  let saved = lists.Saved(id: "l1", name: "", imported: 0, roster: Ok(decoded))
  let #(state, _) =
    lists.update(lists.init(), lists.ListsLoaded(Ok([saved])), None)
  state
}

fn links(href: Option(String)) -> lists.DataLinks {
  lists.DataLinks(
    entry: fn(_, _) { href },
    value: fn(_, _) { href },
    cards: fn(_, _) { element.none() },
    unit_cards: fn(_, _, _) { element.none() },
  )
}

fn render(elements: List(element.Element(lists.Msg))) -> String {
  element.to_string(html.div([], elements))
}

pub fn a_unit_opens_in_game_data_when_there_is_a_link_test() {
  let page = lists.unit_page(saved_list(), "l1", "u-squad", _)
  assert string.contains(
    render(page(links(Some("#/data/x")))),
    "Open in game data",
  )
  assert !string.contains(render(page(links(None))), "Open in game data")
}

pub fn a_chosen_value_is_a_link_when_there_is_one_test() {
  let page = lists.list_page(saved_list(), "l1", _)
  assert string.contains(
    render(page(links(Some("#/data/x")))),
    "<a href=\"#/data/x\">Drizzle</a>",
  )
  assert !string.contains(render(page(links(None))), "href=\"#/data/x\"")
}
