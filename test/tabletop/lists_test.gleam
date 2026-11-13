import gleam/option.{None, Some}
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
