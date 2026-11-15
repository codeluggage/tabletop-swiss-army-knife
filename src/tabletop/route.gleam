//// The screen lives in the URL hash, so the back button steps through screens
//// and a reload keeps the screen. Links are plain `<a href="#/...">`, which
//// stay relative to the page wherever the site is served.

import gleam/list
import gleam/string
import gleam/uri

pub type Route {
  /// `#/`: the saved lists.
  Home
  /// `#/list/new`: make a list from details entered on this device.
  NewListPage
  /// `#/list/<list id>`
  ListPage(list_id: String)
  /// `#/list/<list id>/unit/<selection id>`
  UnitPage(list_id: String, unit_id: String)
  /// `#/list/<list id>/rule/<rule name>`
  RulePage(list_id: String, rule_name: String)
  /// `#/data/<set id>`: one data set.
  DataSetPage(set_id: String)
  /// `#/data/<set id>/<catalogue id>`
  CataloguePage(set_id: String, catalogue_id: String)
  /// `#/data/<set id>/<catalogue id>/<node id>`
  NodePage(set_id: String, catalogue_id: String, node_id: String)
  /// `#/cards/<place>`: the cards of one place.
  CardsPage(place: Place)
  /// `#/card/new/<place>`: a new card for that place.
  NewCardPage(place: Place)
  /// `#/card/<card id>`: one card to edit.
  CardPage(card_id: String)
  /// `#/cards/import/<place>`: the import screen, after a file was chosen.
  ImportCardsPage(place: Place)
  /// `#/sheets`: the score sheets.
  SheetsPage
  /// `#/sheet/<sheet id>`: one score sheet to edit.
  SheetPage(sheet_id: String)
  /// `#/games`: every game, newest first.
  GamesPage
  /// `#/games/new`: pick a sheet and the players, then start.
  NewGamePage
  /// `#/game/<game id>`: one game.
  GamePage(game_id: String)
}

/// Where a card belongs: the whole game of a data set, or one node in it. In
/// a hash it is the set id alone, or the set, catalogue and node ids, so the
/// number of parts says which. The catalogue id is only for links and for
/// which scope to open: a node is the same place from any catalogue.
pub type Place {
  Game(set_id: String)
  Node(set_id: String, catalogue_id: String, node_id: String)
}

/// The route for a `location.hash`. Anything unknown is `Home`.
pub fn parse(hash: String) -> Route {
  let path = case hash {
    "#/" <> path -> path
    "#" <> path -> path
    path -> path
  }
  let parts =
    string.split(path, "/")
    |> list.try_map(fn(part) {
      case uri.percent_decode(part) {
        Ok("") -> Error(Nil)
        decoded -> decoded
      }
    })
  case parts {
    Ok(["list", "new"]) -> NewListPage
    Ok(["list", list_id]) -> ListPage(list_id:)
    Ok(["list", list_id, "unit", unit_id]) -> UnitPage(list_id:, unit_id:)
    Ok(["list", list_id, "rule", rule_name]) -> RulePage(list_id:, rule_name:)
    Ok(["data", set_id]) -> DataSetPage(set_id:)
    Ok(["data", set_id, catalogue_id]) -> CataloguePage(set_id:, catalogue_id:)
    Ok(["data", set_id, catalogue_id, node_id]) ->
      NodePage(set_id:, catalogue_id:, node_id:)
    // A place is one part or three, so these never take each other's hash.
    Ok(["cards", "import", set_id]) -> ImportCardsPage(Game(set_id:))
    Ok(["cards", "import", set_id, catalogue_id, node_id]) ->
      ImportCardsPage(Node(set_id:, catalogue_id:, node_id:))
    Ok(["cards", set_id]) -> CardsPage(Game(set_id:))
    Ok(["cards", set_id, catalogue_id, node_id]) ->
      CardsPage(Node(set_id:, catalogue_id:, node_id:))
    Ok(["card", "new", set_id]) -> NewCardPage(Game(set_id:))
    Ok(["card", "new", set_id, catalogue_id, node_id]) ->
      NewCardPage(Node(set_id:, catalogue_id:, node_id:))
    Ok(["card", card_id]) -> CardPage(card_id:)
    Ok(["sheets"]) -> SheetsPage
    Ok(["sheet", sheet_id]) -> SheetPage(sheet_id:)
    Ok(["games"]) -> GamesPage
    Ok(["games", "new"]) -> NewGamePage
    Ok(["game", game_id]) -> GamePage(game_id:)
    _ -> Home
  }
}

fn place_parts(place: Place) -> List(String) {
  case place {
    Game(set_id:) -> [set_id]
    Node(set_id:, catalogue_id:, node_id:) -> [set_id, catalogue_id, node_id]
  }
}

/// The game data screen of a place: the data set, or the node.
pub fn place_page(place: Place) -> Route {
  case place {
    Game(set_id:) -> DataSetPage(set_id:)
    Node(set_id:, catalogue_id:, node_id:) ->
      NodePage(set_id:, catalogue_id:, node_id:)
  }
}

pub fn to_hash(route: Route) -> String {
  let parts = case route {
    Home -> []
    NewListPage -> ["list", "new"]
    ListPage(list_id:) -> ["list", list_id]
    UnitPage(list_id:, unit_id:) -> ["list", list_id, "unit", unit_id]
    RulePage(list_id:, rule_name:) -> ["list", list_id, "rule", rule_name]
    DataSetPage(set_id:) -> ["data", set_id]
    CataloguePage(set_id:, catalogue_id:) -> ["data", set_id, catalogue_id]
    NodePage(set_id:, catalogue_id:, node_id:) -> [
      "data",
      set_id,
      catalogue_id,
      node_id,
    ]
    CardsPage(place:) -> ["cards", ..place_parts(place)]
    NewCardPage(place:) -> ["card", "new", ..place_parts(place)]
    CardPage(card_id:) -> ["card", card_id]
    ImportCardsPage(place:) -> ["cards", "import", ..place_parts(place)]
    SheetsPage -> ["sheets"]
    SheetPage(sheet_id:) -> ["sheet", sheet_id]
    GamesPage -> ["games"]
    NewGamePage -> ["games", "new"]
    GamePage(game_id:) -> ["game", game_id]
  }
  "#/" <> { list.map(parts, uri.percent_encode) |> string.join("/") }
}

/// `location.hash` now.
@external(javascript, "./browser_ffi.mjs", "current_hash")
pub fn current_hash() -> String

/// Opens the screen of `route`, as following a link to it does.
pub fn go(to route: Route) -> Nil {
  set_hash(to_hash(route))
}

@external(javascript, "./browser_ffi.mjs", "set_hash")
fn set_hash(hash: String) -> Nil

/// Calls back with `location.hash` each time it changes.
@external(javascript, "./browser_ffi.mjs", "on_hash_change")
pub fn on_hash_change(callback: fn(String) -> Nil) -> Nil
