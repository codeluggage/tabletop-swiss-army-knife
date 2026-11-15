import gleam/list
import tabletop/route.{
  CardPage, CardsPage, CataloguePage, DataSetPage, Game, GamePage, GamesPage,
  Home, ImportCardsPage, ListPage, NewCardPage, NewGamePage, NewListPage, Node,
  NodePage, RulePage, SheetPage, SheetsPage, UnitPage,
}

pub fn parse_reads_each_screen_test() {
  assert route.parse("") == Home
  assert route.parse("#") == Home
  assert route.parse("#/") == Home
  assert route.parse("#/list/new") == NewListPage
  assert route.parse("#/list/abc-1") == ListPage("abc-1")
  assert route.parse("#/list/abc-1/unit/u-2") == UnitPage("abc-1", "u-2")
  assert route.parse("#/list/abc-1/rule/Teatime")
    == RulePage("abc-1", "Teatime")
}

pub fn to_hash_writes_each_screen_test() {
  assert route.to_hash(Home) == "#/"
  assert route.to_hash(NewListPage) == "#/list/new"
  assert route.to_hash(ListPage("abc-1")) == "#/list/abc-1"
  assert route.to_hash(UnitPage("abc-1", "u-2")) == "#/list/abc-1/unit/u-2"
  assert route.to_hash(RulePage("abc-1", "Teatime"))
    == "#/list/abc-1/rule/Teatime"
}

pub fn a_rule_name_with_spaces_and_quote_marks_round_trips_test() {
  let rule = RulePage("abc-1", "Glow 2+ \"Bright\" / Kettle's")
  let hash = route.to_hash(rule)
  assert hash == "#/list/abc-1/rule/Glow%202+%20%22Bright%22%20%2F%20Kettle's"
  assert route.parse(hash) == rule
}

pub fn the_data_screens_round_trip_test() {
  let set = DataSetPage("sys-1")
  let catalogue = CataloguePage("sys-1", "cat-2")
  let node = NodePage("sys-1", "cat-2", "e-3")
  assert route.to_hash(set) == "#/data/sys-1"
  assert route.to_hash(catalogue) == "#/data/sys-1/cat-2"
  assert route.to_hash(node) == "#/data/sys-1/cat-2/e-3"
  assert route.parse("#/data/sys-1") == set
  assert route.parse("#/data/sys-1/cat-2") == catalogue
  assert route.parse("#/data/sys-1/cat-2/e-3") == node
}

pub fn a_data_id_that_needs_encoding_round_trips_test() {
  let node = NodePage("sys 1", "cat/2", "e#3?")
  let hash = route.to_hash(node)
  assert hash == "#/data/sys%201/cat%2F2/e%233%3F"
  assert route.parse(hash) == node
}

pub fn the_card_screens_round_trip_test() {
  let game = Game("sys-1")
  let node = Node("sys-1", "cat-2", "e-3")
  let screens = [
    #(CardsPage(game), "#/cards/sys-1"),
    #(CardsPage(node), "#/cards/sys-1/cat-2/e-3"),
    #(NewCardPage(game), "#/card/new/sys-1"),
    #(NewCardPage(node), "#/card/new/sys-1/cat-2/e-3"),
    #(CardPage("c-4"), "#/card/c-4"),
    #(ImportCardsPage(game), "#/cards/import/sys-1"),
    #(ImportCardsPage(node), "#/cards/import/sys-1/cat-2/e-3"),
  ]
  assert list.map(screens, fn(screen) { route.to_hash(screen.0) })
    == list.map(screens, fn(screen) { screen.1 })
  assert list.map(screens, fn(screen) { route.parse(screen.1) })
    == list.map(screens, fn(screen) { screen.0 })
}

pub fn a_place_whose_ids_need_encoding_round_trips_test() {
  let screens = [
    CardsPage(Node("import", "cat/2", "e#3?")),
    CardsPage(Game("import")),
    NewCardPage(Node("new", "a b", "c")),
    ImportCardsPage(Game("import")),
    ImportCardsPage(Node("sys 1", "import", "new")),
    CardPage("new"),
  ]
  assert list.map(screens, fn(screen) { route.parse(route.to_hash(screen)) })
    == screens
}

pub fn the_tracker_screens_round_trip_test() {
  let screens = [
    #(SheetsPage, "#/sheets"),
    #(SheetPage("s-1"), "#/sheet/s-1"),
    #(GamesPage, "#/games"),
    #(NewGamePage, "#/games/new"),
    #(GamePage("g-2"), "#/game/g-2"),
    // A game whose id is the word new is still a game.
    #(GamePage("new"), "#/game/new"),
  ]
  assert list.map(screens, fn(screen) { route.to_hash(screen.0) })
    == list.map(screens, fn(screen) { screen.1 })
  assert list.map(screens, fn(screen) { route.parse(screen.1) })
    == list.map(screens, fn(screen) { screen.0 })
}

pub fn unknown_hashes_are_home_test() {
  assert route.parse("#/nowhere") == Home
  assert route.parse("#/list") == Home
  assert route.parse("#/list/") == Home
  assert route.parse("#/list/abc/unit") == Home
  assert route.parse("#/list/abc/unit/") == Home
  assert route.parse("#/list/abc/table/x") == Home
  assert route.parse("#/list/%E0%A4%A") == Home
  assert route.parse("#/data") == Home
  assert route.parse("#/data/a/b/c/d") == Home
  assert route.parse("#/cards") == Home
  assert route.parse("#/cards/a/b") == Home
  assert route.parse("#/cards/a/b/c/d/e/f") == Home
  assert route.parse("#/card/a/b") == Home
  assert route.parse("#/card/new/a/b") == Home
  assert route.parse("#/card") == Home
  assert route.parse("#/sheet") == Home
  assert route.parse("#/sheets/a") == Home
  assert route.parse("#/game") == Home
  assert route.parse("#/games/old") == Home
  assert route.parse("#/game/a/b") == Home
}
