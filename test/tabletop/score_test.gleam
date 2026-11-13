import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import tabletop/score.{
  AddCounter, AddItem, AddResult, Change, Count, CountKind, Counter, CounterGain,
  CounterName, CounterStart, Counters, End, Free, FreeKind, Gained, ItemMost,
  ItemName, ItemPoints, Items, Move, Note, One, Remove, Rename, ResultBand,
  ResultLead, ResultName, Results, Scored, Set, SetAskFirst, SetRounds, Sheet,
  Spent, ToRound, Toggle, ToggleKind, Two, WentFirst,
}

/// The invented picnic game's sheet: acorns to gain and spend, a teatime to
/// score once a round, teacups to count, and crumbs typed in.
pub fn picnic_sheet() -> score.Sheet {
  Sheet(
    id: "sheet-picnic",
    name: "Sunday Picnic",
    rounds: 3,
    ask_first: True,
    counters: [
      Counter(id: "acorns", name: "Acorns", start: 2, gain_each_round: 1),
    ],
    items: [
      Toggle(id: "teatime", name: "Teatime", points: 3),
      Count(id: "teacups", name: "Teacups", points_each: 2, most: Some(3)),
      Free(id: "crumbs", name: "Crumbs"),
    ],
    results: [],
  )
}

fn picnic() -> score.Game {
  score.start(
    id: "game-picnic",
    sheet: picnic_sheet(),
    started: 1_762_980_000_000,
    players: #("Ada", "Bram"),
    list: Some(#("list-sunday", "Sunday Picnic")),
  )
}

fn plays(game: score.Game, changes: List(score.Play)) -> score.Game {
  list.fold(changes, game, score.play)
}

// --- Scoring ------------------------------------------------------------------

pub fn each_item_kind_scores_test() {
  assert score.points(Toggle("t", "Teatime", 3), 1) == 3
  assert score.points(Toggle("t", "Teatime", 3), 0) == 0
  assert score.points(Count("c", "Teacups", 2, None), 4) == 8
  assert score.points(Free("f", "Crumbs"), -2) == -2
}

pub fn a_round_is_the_sum_of_its_items_test() {
  let game =
    plays(picnic(), [
      Set(Scored(One, 1, "teatime"), 1),
      Change(Scored(One, 1, "teacups"), 1),
      Change(Scored(One, 1, "teacups"), 1),
      Set(Scored(One, 1, "crumbs"), 5),
    ])
  assert score.round_score(game, One, 1) == 3 + 4 + 5
  assert score.round_score(game, Two, 1) == 0
  assert score.round_score(game, One, 2) == 0
}

pub fn a_toggle_is_on_or_off_test() {
  let game = plays(picnic(), [Set(Scored(One, 1, "teatime"), 7)])
  assert score.value(game, Scored(One, 1, "teatime")) == 1
  let game = plays(game, [Change(Scored(One, 1, "teatime"), -5)])
  assert score.value(game, Scored(One, 1, "teatime")) == 0
}

pub fn a_count_stops_at_its_most_and_at_zero_test() {
  let cups = Scored(One, 1, "teacups")
  let game = plays(picnic(), list.repeat(Change(cups, 1), 5))
  assert score.value(game, cups) == 3
  assert score.round_score(game, One, 1) == 6
  let game = plays(game, [Set(cups, -4)])
  assert score.value(game, cups) == 0
}

pub fn the_total_is_the_sum_over_the_rounds_test() {
  let game =
    plays(picnic(), [
      Set(Scored(One, 1, "crumbs"), 5),
      Set(Scored(One, 3, "crumbs"), 2),
      Set(Scored(Two, 2, "teatime"), 1),
      // A round past the last is not in the total.
      Set(Scored(One, 4, "crumbs"), 100),
    ])
  assert score.total(game, One) == 7
  assert score.total(game, Two) == 3
}

pub fn a_counter_gains_each_round_by_itself_test() {
  let acorns =
    Counter(id: "acorns", name: "Acorns", start: 2, gain_each_round: 1)
  let game = picnic()
  // The start and the first round's gain.
  assert score.left(game, One, 1, acorns) == 3
  assert score.left(game, One, 3, acorns) == 5
  let game =
    plays(game, [
      Change(Spent(One, 1, "acorns"), 1),
      Change(Spent(One, 1, "acorns"), 1),
      Change(Gained(One, 2, "acorns"), 2),
      Change(Spent(Two, 1, "acorns"), 1),
    ])
  assert score.value(game, Gained(One, 2, "acorns")) == 3
  assert score.left(game, One, 1, acorns) == 1
  assert score.left(game, One, 2, acorns) == 4
  assert score.left(game, Two, 2, acorns) == 3
  // Gained and spent never go below 0.
  let game = plays(game, [Change(Gained(One, 3, "acorns"), -4)])
  assert score.value(game, Gained(One, 3, "acorns")) == 0
}

pub fn a_counter_with_no_gain_keeps_its_start_test() {
  let kettles =
    Counter(id: "kettles", name: "Kettles", start: 4, gain_each_round: 0)
  let sheet = Sheet(..picnic_sheet(), counters: [kettles])
  let game = score.Game(..picnic(), sheet:)
  assert score.left(game, Two, 3, kettles) == 4
}

pub fn the_result_with_no_bands_is_for_the_first_player_test() {
  let ahead = plays(picnic(), [Set(Scored(One, 1, "crumbs"), 2)])
  assert score.result(ahead) == "Ada: Win"
  let behind = plays(picnic(), [Set(Scored(Two, 1, "crumbs"), 2)])
  assert score.result(behind) == "Ada: Loss"
}

pub fn a_draw_test() {
  assert score.result(picnic()) == "Draw"
  let level =
    plays(picnic(), [
      Set(Scored(One, 1, "crumbs"), 3),
      Set(Scored(Two, 2, "teatime"), 1),
    ])
  assert score.result(level) == "Draw"
}

pub fn the_winner_gets_the_highest_band_the_lead_reaches_test() {
  let sheet =
    Sheet(..picnic_sheet(), results: [
      ResultBand(name: "Picnic Rout", lead_at_least: 10),
      ResultBand(name: "Crumb Win", lead_at_least: 1),
    ])
  let game = score.Game(..picnic(), sheet:)
  let by = fn(player, crumbs) {
    plays(game, [Set(Scored(player, 1, "crumbs"), crumbs)]) |> score.result
  }
  assert by(One, 4) == "Ada: Crumb Win"
  assert by(Two, 10) == "Bram: Picnic Rout"
  assert by(One, 25) == "Ada: Picnic Rout"
  assert score.result(game) == "Draw"
  // A lead that reaches no band is a plain win.
  let high =
    score.Game(
      ..game,
      sheet: Sheet(..sheet, results: [ResultBand("Picnic Rout", 10)]),
    )
  assert score.result(plays(high, [Set(Scored(Two, 1, "crumbs"), 3)]))
    == "Bram: Win"
}

// --- The game's changes ---------------------------------------------------------

pub fn the_round_stays_within_the_sheet_test() {
  let game = plays(picnic(), [ToRound(2)])
  assert game.round == 2
  assert plays(game, [ToRound(9)]).round == 3
  assert plays(game, [ToRound(0)]).round == 1
}

pub fn who_went_first_is_kept_per_round_test() {
  let game = plays(picnic(), [WentFirst(1, Two), WentFirst(2, One)])
  assert dict.get(game.first, 1) == Ok(Two)
  assert dict.get(game.first, 2) == Ok(One)
  assert dict.get(game.first, 3) == Error(Nil)
}

pub fn ending_and_the_note_test() {
  let game = plays(picnic(), [Note("Rain at teatime"), End(1_762_990_000_000)])
  assert game.note == "Rain at teatime"
  assert game.ended == Some(1_762_990_000_000)
}

// --- The sheet editor's changes ---------------------------------------------------

fn ids() -> fn() -> String {
  fn() { "new-id" }
}

fn edits(changes: List(score.Edit)) -> score.Sheet {
  list.fold(changes, picnic_sheet(), fn(sheet, change) {
    score.edit(sheet, change, ids())
  })
}

pub fn the_sheet_fields_change_test() {
  let sheet = edits([Rename("Rainy Picnic"), SetRounds(0), SetAskFirst(False)])
  assert sheet.name == "Rainy Picnic"
  assert sheet.rounds == 1
  assert !sheet.ask_first
  assert edits([SetRounds(6)]).rounds == 6
}

pub fn adding_puts_a_new_one_last_test() {
  let sheet =
    edits([
      AddCounter,
      AddItem(ToggleKind),
      AddItem(CountKind),
      AddItem(FreeKind),
      AddResult,
    ])
  assert list.last(sheet.counters) == Ok(Counter("new-id", "New counter", 0, 0))
  assert list.drop(sheet.items, 3)
    == [
      Toggle("new-id", "New item", 1),
      Count("new-id", "New item", 1, None),
      Free("new-id", "New item"),
    ]
  assert sheet.results == [ResultBand("New result", 1)]
}

pub fn a_counter_changes_test() {
  let sheet =
    edits([CounterName(0, "Pinecones"), CounterStart(0, 5), CounterGain(0, 2)])
  assert sheet.counters == [Counter("acorns", "Pinecones", 5, 2)]
}

pub fn an_item_changes_by_its_kind_test() {
  let sheet =
    edits([
      ItemName(0, "High Tea"),
      ItemPoints(0, 4),
      ItemPoints(1, 5),
      ItemMost(1, None),
      ItemName(2, "Crumbs Left"),
      ItemPoints(2, 9),
      ItemMost(0, Some(2)),
    ])
  assert sheet.items
    == [
      Toggle("teatime", "High Tea", 4),
      Count("teacups", "Teacups", 5, None),
      Free("crumbs", "Crumbs Left"),
    ]
}

pub fn a_result_band_changes_test() {
  let sheet = edits([AddResult, ResultName(0, "Crumb Win"), ResultLead(0, 2)])
  assert sheet.results == [ResultBand("Crumb Win", 2)]
}

pub fn moving_up_and_down_and_removing_test() {
  let names = fn(sheet: score.Sheet) {
    list.map(sheet.items, fn(item) { item.name })
  }
  assert names(edits([Move(Items, 1, -1)])) == ["Teacups", "Teatime", "Crumbs"]
  assert names(edits([Move(Items, 1, 1)])) == ["Teatime", "Crumbs", "Teacups"]
  // The first cannot go up and the last cannot go down.
  assert names(edits([Move(Items, 0, -1)])) == names(picnic_sheet())
  assert names(edits([Move(Items, 2, 1)])) == names(picnic_sheet())
  assert names(edits([Remove(Items, 1)])) == ["Teatime", "Crumbs"]
  assert edits([Remove(Counters, 0)]).counters == []
  let bands =
    edits([
      AddResult,
      AddResult,
      ResultName(1, "Crumb Win"),
      Move(Results, 1, -1),
    ])
  assert list.map(bands.results, fn(band) { band.name })
    == ["Crumb Win", "New result"]
  assert edits([AddResult, Remove(Results, 0)]).results == []
}

pub fn the_simple_sheet_has_one_typed_score_test() {
  assert score.simple("s1", "Garden Games", 4, "i1")
    == Sheet(
      id: "s1",
      name: "Garden Games",
      rounds: 4,
      ask_first: False,
      counters: [],
      items: [Free("i1", "Score")],
      results: [],
    )
}

// --- JSON -------------------------------------------------------------------------

pub fn a_sheet_round_trips_test() {
  let sheet = Sheet(..picnic_sheet(), results: [ResultBand("Crumb Win", 1)])
  assert json.parse(
      json.to_string(score.encode_sheet(sheet)),
      score.sheet_decoder(),
    )
    == Ok(sheet)
}

pub fn a_game_round_trips_test() {
  let game =
    plays(picnic(), [
      WentFirst(1, Two),
      Change(Gained(One, 1, "acorns"), 1),
      Change(Spent(Two, 2, "acorns"), 1),
      Set(Scored(One, 2, "teatime"), 1),
      Set(Scored(Two, 1, "crumbs"), -3),
      ToRound(2),
      Note("Rain at teatime"),
      End(1_762_990_000_000),
    ])
  assert json.parse(
      json.to_string(score.encode_game(game)),
      score.game_decoder(),
    )
    == Ok(game)
  let no_list = score.Game(..picnic(), list: None)
  assert json.parse(
      json.to_string(score.encode_game(no_list)),
      score.game_decoder(),
    )
    == Ok(no_list)
}
