import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import tabletop/score.{Change, Gained, Items, One, Scored, Two}
import tabletop/score_test
import tabletop/storage
import tabletop/tracker.{
  Confirmed, DeleteClicked, DeleteGame, DeleteSheet, DeleteSheetClicked,
  EditClicked, Edited, EndClicked, GamesLoaded, NewSheetClicked, NoSheet,
  NoStorage, NotConfirmed, Played, RemoveClicked, RemoveFromSheet, SheetDeleted,
  SheetNotDeleted, SheetsLoaded, SimpleSubmitted, StartSubmitted,
}

fn step(state: tracker.State, msg: tracker.Msg) -> tracker.State {
  tracker.update(state, msg, None).0
}

fn with_sheet() -> tracker.State {
  tracker.init()
  |> step(SheetsLoaded(Ok([score_test.picnic_sheet()])))
  |> step(GamesLoaded(Ok([])))
}

fn sheet(state: tracker.State) -> score.Sheet {
  let assert Some(Ok([sheet, ..])) = state.sheets
  sheet
}

fn game(state: tracker.State) -> score.Game {
  let assert Some(Ok([game, ..])) = state.games
  game
}

const sunday = [#("list-sunday", "Sunday Picnic")]

fn started() -> tracker.State {
  with_sheet()
  |> step(
    StartSubmitted(sunday, [
      #("sheet", "sheet-picnic"),
      #("first", " Ada "),
      #("second", "Bram"),
      #("list", "list-sunday"),
    ]),
  )
}

fn page(elements: List(element.Element(tracker.Msg))) -> String {
  element.fragment(elements) |> element.to_string
}

// --- Score sheets -------------------------------------------------------------

pub fn a_new_sheet_and_a_simple_sheet_test() {
  let state =
    tracker.init() |> step(SheetsLoaded(Ok([]))) |> step(NewSheetClicked)
  assert sheet(state).name == "New sheet"
  assert sheet(state).items == []
  let state =
    step(state, SimpleSubmitted([#("name", "Garden Games"), #("rounds", "4")]))
  let simple = sheet(state)
  assert simple.name == "Garden Games"
  assert simple.rounds == 4
  let assert [score.Free(name: "Score", ..)] = simple.items
  // Storage is closed in a test, so the change shows and says it was not
  // saved.
  assert state.problem == Some(NoStorage)
}

pub fn the_sheet_editor_changes_the_sheet_test() {
  let state =
    with_sheet()
    |> step(Edited("sheet-picnic", score.Rename("Rainy Picnic")))
    |> step(Edited("sheet-picnic", score.AddResult))
    |> step(Edited("sheet-picnic", score.Move(Items, 2, -1)))
  assert sheet(state).name == "Rainy Picnic"
  assert sheet(state).results == [score.ResultBand("New result", 1)]
  assert list.map(sheet(state).items, fn(item) { item.name })
    == ["Teatime", "Crumbs", "Teacups"]
  // Another sheet's id changes nothing.
  assert step(state, Edited("gone", score.Rename("x"))) == state
}

pub fn removing_asks_first_test() {
  let asking = with_sheet() |> step(RemoveClicked("sheet-picnic", Items, 0))
  assert asking.confirming == Some(RemoveFromSheet("sheet-picnic", Items, 0))
  assert list.length(sheet(asking).items) == 3
  let html = page(tracker.sheet_page(asking, "sheet-picnic"))
  assert string.contains(html, "Remove Teatime?")
  let kept = step(asking, NotConfirmed)
  assert kept.confirming == None
  assert list.length(sheet(kept).items) == 3
  let removed = step(asking, Confirmed)
  assert removed.confirming == None
  assert list.map(sheet(removed).items, fn(item) { item.name })
    == ["Teacups", "Crumbs"]
}

pub fn deleting_a_sheet_asks_first_and_games_keep_theirs_test() {
  let state = started()
  let html = page(tracker.sheet_page(state, "sheet-picnic"))
  assert string.contains(html, "Delete this sheet")
  assert !string.contains(html, "Games already played keep")
  let asking = step(state, DeleteSheetClicked("sheet-picnic"))
  assert asking.confirming == Some(DeleteSheet("sheet-picnic"))
  assert string.contains(
    page(tracker.sheet_page(asking, "sheet-picnic")),
    "Delete this sheet? Games already played keep their own copy of it.",
  )
  // No keeps the sheet.
  let kept = step(asking, NotConfirmed)
  assert kept.confirming == None
  assert sheet(kept).id == "sheet-picnic"
  // Storage is closed in a test, so Yes deletes nothing.
  let answered = step(asking, Confirmed)
  assert answered.problem == Some(NoStorage)
  assert sheet(answered).id == "sheet-picnic"
  // Once the delete is saved the sheet goes, and the game keeps its copy.
  let deleted = step(asking, SheetDeleted("sheet-picnic", Ok(Nil)))
  assert deleted.sheets == Some(Ok([]))
  assert deleted.confirming == None
  assert game(deleted).sheet == score_test.picnic_sheet()
  let failed =
    step(asking, SheetDeleted("sheet-picnic", Error(storage.DeleteFailed("x"))))
  assert failed.problem == Some(SheetNotDeleted(storage.DeleteFailed("x")))
  assert sheet(failed).id == "sheet-picnic"
}

pub fn the_sheets_screen_offers_the_simple_start_test() {
  let html =
    page(tracker.sheets_page(tracker.init() |> step(SheetsLoaded(Ok([])))))
  assert string.contains(html, "No score sheets yet.")
  assert string.contains(html, "New sheet")
  assert string.contains(html, "Start with a simple sheet")
}

// --- A game ---------------------------------------------------------------------

pub fn starting_a_game_test() {
  let new = game(started())
  assert new.players == #("Ada", "Bram")
  assert new.list == Some(#("list-sunday", "Sunday Picnic"))
  assert new.sheet == score_test.picnic_sheet()
  assert new.round == 1
  // Blank names and no list.
  let other =
    with_sheet()
    |> step(StartSubmitted(sunday, [#("sheet", "sheet-picnic"), #("list", "")]))
    |> game
  assert other.players == #("Player 1", "Player 2")
  assert other.list == None
}

pub fn a_game_needs_a_sheet_test() {
  let state = with_sheet() |> step(StartSubmitted(sunday, [#("sheet", "")]))
  assert state.problem == Some(NoSheet)
  assert state.games == Some(Ok([]))
}

pub fn the_new_game_screen_remembers_the_first_player_test() {
  let html = page(tracker.new_game_page(started(), sunday))
  assert string.contains(html, "name=\"first\" type=\"text\" value=\"Ada\"")
  assert string.contains(html, "name=\"second\" type=\"text\" value=\"\"")
  assert string.contains(
    html,
    "<option selected value=\"list-sunday\">Sunday Picnic</option>",
  )
}

pub fn the_game_keeps_its_own_sheet_when_the_sheet_changes_test() {
  let state =
    started()
    |> step(Edited("sheet-picnic", score.Remove(Items, 0)))
    |> step(Edited("sheet-picnic", score.SetRounds(9)))
  assert sheet(state).rounds == 9
  assert game(state).sheet == score_test.picnic_sheet()
}

pub fn the_game_changes_by_taps_test() {
  let state = started()
  let id = game(state).id
  let state =
    state
    |> step(Played(id, Change(Scored(One, 1, "teacups"), 1)))
    |> step(Played(id, Change(Gained(Two, 1, "acorns"), 1)))
    |> step(Played(id, score.ToRound(2)))
  let played = game(state)
  assert played.round == 2
  assert score.total(played, One) == 2
  assert score.value(played, Gained(Two, 1, "acorns")) == 2
  // A tap for a game that is gone changes nothing.
  assert step(state, Played("gone", score.ToRound(1))) == state
}

pub fn the_game_screen_shows_names_totals_and_the_result_test() {
  let state = started()
  let id = game(state).id
  let state = step(state, Played(id, score.Set(Scored(Two, 1, "crumbs"), 4)))
  let html = page(tracker.game_page(state, id))
  assert string.contains(
    html,
    "<span class=\"side-name\">Ada</span><span class=\"side-total\">0</span>",
  )
  assert string.contains(
    html,
    "<span class=\"side-name\">Bram</span><span class=\"side-total\">4</span>",
  )
  assert string.contains(html, "Result so far: Ada: Loss")
  assert string.contains(html, "List: Sunday Picnic")
  assert string.contains(html, "Who went first?")
  assert string.contains(html, "Round 1")
  assert string.contains(html, "Next →")
  assert !string.contains(html, "End game")
}

pub fn the_last_round_ends_the_game_and_an_ended_game_is_read_only_test() {
  let state = started()
  let id = game(state).id
  let last = step(state, Played(id, score.ToRound(3)))
  assert string.contains(page(tracker.game_page(last, id)), "End game")
  let ended = step(last, EndClicked(id))
  let assert Some(_) = game(ended).ended
  let html = page(tracker.game_page(ended, id))
  assert string.contains(html, "This game ended on")
  assert string.contains(html, "Result: Draw")
  assert !string.contains(html, "class=\"tap\"")
  let editing = step(ended, EditClicked(id))
  assert string.contains(page(tracker.game_page(editing, id)), "class=\"tap\"")
  // Leaving the screen locks it again.
  assert tracker.screen_changed(editing).editing == None
}

pub fn deleting_a_game_asks_first_test() {
  let state = started()
  let id = game(state).id
  let asking = step(state, DeleteClicked(id))
  assert asking.confirming == Some(DeleteGame(id))
  assert string.contains(page(tracker.games_page(asking)), "Delete this game?")
  // Storage is closed in a test, so nothing is deleted.
  let answered = step(asking, Confirmed)
  assert answered.problem == Some(NoStorage)
  assert game(answered).id == id
  let deleted = step(asking, tracker.GameDeleted(id, Ok(Nil)))
  assert deleted.games == Some(Ok([]))
}

// --- Home and the list ------------------------------------------------------------

pub fn home_shows_the_game_in_progress_test() {
  let html = page(tracker.home(with_sheet()))
  assert string.contains(html, "<h2>Games</h2>")
  assert string.contains(html, "New game")
  assert string.contains(html, "All games")
  assert string.contains(html, "Score sheets")
  assert !string.contains(html, "Ada")
  let state = started()
  let html = page(tracker.home(state))
  assert string.contains(html, "Ada 0 – 0 Bram")
  assert string.contains(html, "Round 1 of 3")
  let ended = step(state, EndClicked(game(state).id))
  assert !string.contains(page(tracker.home(ended)), "Ada 0 – 0 Bram")
}

pub fn the_picked_list_leads_back_to_the_game_test() {
  let state = started()
  let assert [back] = tracker.back_to_game(state, "list-sunday")
  assert string.contains(
    element.to_string(back),
    "href=\"#/game/" <> game(state).id <> "\"",
  )
  assert tracker.back_to_game(state, "list-other") == []
}
