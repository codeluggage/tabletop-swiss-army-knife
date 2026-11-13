import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element.{type Element}
import lustre/element/html
import simplifile
import tabletop/cards.{
  type Card, Card, CardsLoaded, Cost, DeleteCancelled, DeleteClicked, Effect,
  FormSubmitted, Name, NoName, NoStorage, TableRead, When,
}
import tabletop/catalogue
import tabletop/route.{Game, Node}
import tabletop/scope
import tabletop/storage
import tabletop/text

fn card(id: String, name: String, target: String, place: route.Place) -> Card {
  Card(id:, name:, cost: "", when: "", target:, effect: "", place:, edited: 0)
}

fn loaded(saved: List(Card)) -> cards.State {
  let #(state, _) = cards.update(cards.init(), CardsLoaded(Ok(saved)), None)
  state
}

fn render(elements: List(Element(msg))) -> String {
  element.to_string(html.div([], elements))
}

fn form(name: String) -> List(#(String, String)) {
  [
    #("name", name),
    #("cost", "1"),
    #("when", ""),
    #("target", ""),
    #("effect", "Pour."),
  ]
}

// --- The form ---------------------------------------------------------------

pub fn a_card_needs_a_name_test() {
  let submit = fn(name) {
    cards.update(
      cards.init(),
      FormSubmitted(None, Game("sys-picnic"), form(name)),
      None,
    ).0
  }
  assert submit("").problem == Some(NoName)
  assert submit("   ").problem == Some(NoName)
  assert submit("Second Pour").problem == Some(NoStorage)
  let page = render(cards.new_card_page(cards.init(), Game("sys-picnic")))
  assert string.contains(page, "name=\"name\"")
  assert string.contains(page, " required")
}

pub fn editing_a_card_fills_the_form_test() {
  let saved =
    Card(
      id: "c1",
      name: "Second Pour",
      cost: "1 sugar",
      when: "Your turn",
      target: "One Teacup unit",
      effect: "It moves again.",
      place: Node("sys-picnic", "cat-teapot", "e-squad"),
      edited: 0,
    )
  let page = render(cards.card_page(loaded([saved]), "c1"))
  assert string.contains(page, "value=\"Second Pour\"")
  assert string.contains(page, "value=\"1 sugar\"")
  assert string.contains(page, ">Your turn</textarea>")
  assert string.contains(page, ">One Teacup unit</textarea>")
  assert string.contains(page, ">It moves again.</textarea>")
}

pub fn delete_asks_first_test() {
  let state = loaded([card("c1", "Second Pour", "", Game("sys-picnic"))])
  assert !string.contains(
    render(cards.card_page(state, "c1")),
    "Delete this card?",
  )
  let #(asking, _) = cards.update(state, DeleteClicked("c1"), None)
  assert asking.confirming == Some("c1")
  assert string.contains(
    render(cards.card_page(asking, "c1")),
    "Delete this card?",
  )
  let #(answered, _) = cards.update(asking, DeleteCancelled, None)
  assert answered.confirming == None
  assert answered.cards == state.cards
}

// --- Where a card shows ----------------------------------------------------

/// The scope of a catalogue, built from the invented data files `names`.
fn scope_of(names: List(String)) -> scope.Scope {
  list.map(names, fn(name) {
    let assert Ok(text) =
      simplifile.read("test/fixtures/data/" <> name <> ".json")
    let assert Ok(decoded) = catalogue.decode(text)
    decoded
  })
  |> scope.build
}

pub fn a_card_shows_on_its_node_from_any_catalogue_test() {
  // Placed while browsing one catalogue, opened from another that reaches
  // the same node.
  let state =
    loaded([
      card(
        "c1",
        "Second Pour",
        "",
        Node("sys-picnic", "cat-teapot", "e-captain"),
      ),
    ])
  let built = scope_of(["pantry", "picnic-system"])
  let assert Ok(page) = scope.page(built, "e-captain")
  let node =
    render(cards.node_sections(
      state,
      "sys-picnic",
      "cat-pantry",
      "e-captain",
      built,
      page,
      text.links([]),
    ))
  assert string.contains(node, "Second Pour")
  let place = Node("sys-picnic", "cat-pantry", "e-captain")
  assert string.contains(render(cards.place_page(state, place)), "Second Pour")
}

// --- The import -------------------------------------------------------------

fn pending() -> cards.Pending {
  let assert Ok(bytes) =
    simplifile.read_bits("test/fixtures/invented-cards.csv")
  let place = Node("sys-picnic", "cat-teapot", "e-squad")
  let #(state, _) =
    cards.update(
      cards.init(),
      TableRead(place, Ok(#("invented-cards.csv", bytes))),
      None,
    )
  let assert Some(pending) = state.pending
  pending
}

pub fn columns_are_chosen_by_header_test() {
  assert pending().columns
    == dict.from_list([#(Name, 0), #(Cost, 1), #(When, 2), #(Effect, 3)])
}

pub fn rows_with_no_name_are_skipped_test() {
  let pending = pending()
  let #(imported, skipped) = cards.import_cards(pending, fn() { "id" })
  assert list.map(imported, fn(card) { card.name })
    == ["Second Pour", "Lid Down", "Crumb Trail"]
  assert skipped == 1
  assert list.all(imported, fn(card) { card.place == pending.place })
  let assert [first, second, ..] = imported
  assert first.when == "Your turn, after moving"
  assert first.target == ""
  assert string.contains(second.effect, "The \"Kettle\" unit")
  assert string.contains(second.effect, "Then it boils.")
  let state = cards.State(..cards.init(), pending: Some(pending))
  let page = render(cards.import_page(state, pending.place))
  assert string.contains(page, "1 row has no name and will be skipped.")
  assert string.contains(page, "Import 3 cards")
}

pub fn an_import_is_one_write_of_every_card_test() {
  let #(imported, _) = cards.import_cards(pending(), fn() { "id" })
  let writes = cards.writes(imported, [])
  assert list.length(writes) == 3
  assert list.all(writes, fn(write) {
    case write {
      storage.Put(store: storage.Cards, ..) -> True
      _ -> False
    }
  })
}

pub fn only_the_rows_with_a_value_import_test() {
  let state = cards.State(..cards.init(), pending: Some(pending()))
  let step = fn(state, msg) { cards.update(state, msg, None).0 }
  // The When column starts at its first value.
  let state = step(state, cards.OnlyColumnChosen(Some(2)))
  let assert Some(pending) = state.pending
  assert pending.only == Some(#(2, "Your turn, after moving"))
  assert cards.values(pending.table, 2)
    == ["Your turn, after moving", "Any time", "Never", "End of turn"]
  let state = step(state, cards.OnlyValueChosen("Any time"))
  let assert Some(pending) = state.pending
  let #(imported, skipped) = cards.import_cards(pending, fn() { "id" })
  assert list.map(imported, fn(card) { card.name }) == ["Lid Down"]
  assert skipped == 0
  // The preview and the count follow.
  let page = render(cards.import_page(state, pending.place))
  assert string.contains(page, "Import 1 card<")
  assert !string.contains(page, "Second Pour")
  assert !string.contains(page, "will be skipped")
  // Every row again.
  let state = step(state, cards.OnlyColumnChosen(None))
  let assert Some(pending) = state.pending
  assert cards.import_cards(pending, fn() { "id" }).0 |> list.length == 3
}

pub fn replace_deletes_the_cards_of_the_place_in_the_same_write_test() {
  let place = pending().place
  let other_catalogue = Node("sys-picnic", "cat-pantry", "e-squad")
  let saved = [
    card("c1", "Old One", "", place),
    card("c2", "Old Two", "", other_catalogue),
    card("c3", "Elsewhere", "", Game("sys-picnic")),
  ]
  let state = cards.State(..loaded(saved), pending: Some(pending()))
  // Off by default: nothing is deleted.
  let assert Some(off) = state.pending
  assert off.replace == False
  assert cards.replaced(saved, off) == []
  assert !string.contains(render(cards.import_page(state, place)), "deleted")
  // On: the place's cards, from any catalogue, go in the import's write.
  let #(state, _) = cards.update(state, cards.ReplaceChecked(True), None)
  let assert Some(on) = state.pending
  let removed = cards.replaced(saved, on)
  assert removed == ["c1", "c2"]
  assert string.contains(
    render(cards.import_page(state, place)),
    "2 cards already here will be deleted.",
  )
  let #(imported, _) = cards.import_cards(on, fn() { "new" })
  let assert [
    storage.Remove(store: storage.Cards, key: "c1"),
    storage.Remove(store: storage.Cards, key: "c2"),
    ..puts
  ] = cards.writes(imported, removed)
  assert list.length(puts) == 3
  // Once saved, the deleted cards are gone and the rest stay.
  let #(state, _) =
    cards.update(state, cards.CardsSaved(removed, Ok(imported)), None)
  let assert [_, _, elsewhere] = saved
  assert state.cards == Some(Ok(list.append(imported, [elsewhere])))
}

/// The table a file of `bytes` opens on the import screen.
fn opened(bytes: BitArray) -> cards.Pending {
  let #(state, _) =
    cards.update(
      cards.init(),
      TableRead(Game("sys-picnic"), Ok(#("cards.csv", bytes))),
      None,
    )
  let assert Some(pending) = state.pending
  pending
}

pub fn a_byte_order_mark_still_picks_the_first_column_test() {
  let pending = opened(<<0xEF, 0xBB, 0xBF, "Name;Effect\nKettle;Pour":utf8>>)
  assert pending.columns == dict.from_list([#(Name, 0), #(Effect, 1)])
}

pub fn a_file_that_is_not_utf8_is_read_as_windows_1252_test() {
  // A curly quote on each side, and a dash.
  let bytes = <<
    "Name,Effect\r\nKettle,":utf8, 0x93, "Pour":utf8, 0x94, " ":utf8, 0x96,
    " then wait":utf8,
  >>
  assert opened(bytes).table.rows
    == [["Kettle", "\u{201C}Pour\u{201D} \u{2013} then wait"]]
}

// --- Cards for a unit -------------------------------------------------------

pub fn the_cards_for_a_unit_test() {
  let in_scope = fn(node_id) { node_id == "e-squad" }
  let keywords = ["Teacup", "Up"]
  let pick = fn(target, place) {
    cards.for_unit(
      [card("c", "A card", target, place)],
      "sys-picnic",
      in_scope,
      keywords,
    )
    != []
  }
  let game = Game("sys-picnic")
  // A match, and a match in another case.
  assert pick("One Teacup unit", game)
  assert pick("one TEACUP unit", game)
  // A keyword inside a longer word.
  assert !pick("All Teacups", game)
  // A keyword under three characters is not looked for.
  assert !pick("Up to two units", game)
  // A node in the scope counts, a node in another catalogue's scope does not,
  // and neither does another data set.
  assert pick("One Teacup unit", Node("sys-picnic", "cat-teapot", "e-squad"))
  assert !pick("One Teacup unit", Node("sys-picnic", "cat-pantry", "e-other"))
  assert !pick("One Teacup unit", Game("sys-other"))
}

pub fn a_list_groups_its_cards_by_node_then_the_whole_game_test() {
  let state =
    loaded([
      card("c1", "Crumb Trail", "", Game("sys-picnic")),
      card("c2", "Second Pour", "", Node("sys-picnic", "cat-teapot", "e-host")),
      card("c3", "Lid Down", "", Node("sys-picnic", "cat-teapot", "e-other")),
    ])
  let nodes = [#("e-host", "Sunday Picnic")]
  let page = render([cards.list_section(state, "sys-picnic", nodes)])
  let assert [_, after_node] = string.split(page, "<h3>Sunday Picnic</h3>")
  let assert [between, after_game] =
    string.split(after_node, "<h3>Whole game</h3>")
  assert string.contains(between, "Second Pour")
  assert string.contains(after_game, "Crumb Trail")
  assert !string.contains(page, "Lid Down")
}
