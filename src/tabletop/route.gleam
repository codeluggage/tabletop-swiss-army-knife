//// The screen lives in the URL hash, so the back button steps through screens
//// and a reload keeps the screen. Links are plain `<a href="#/...">`, which
//// stay relative to the page wherever the site is served.

import gleam/list
import gleam/string
import gleam/uri

pub type Route {
  /// `#/`: the saved lists.
  Home
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
    Ok(["list", list_id]) -> ListPage(list_id:)
    Ok(["list", list_id, "unit", unit_id]) -> UnitPage(list_id:, unit_id:)
    Ok(["list", list_id, "rule", rule_name]) -> RulePage(list_id:, rule_name:)
    Ok(["data", set_id]) -> DataSetPage(set_id:)
    Ok(["data", set_id, catalogue_id]) -> CataloguePage(set_id:, catalogue_id:)
    Ok(["data", set_id, catalogue_id, node_id]) ->
      NodePage(set_id:, catalogue_id:, node_id:)
    _ -> Home
  }
}

pub fn to_hash(route: Route) -> String {
  let parts = case route {
    Home -> []
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
  }
  "#/" <> { list.map(parts, uri.percent_encode) |> string.join("/") }
}

/// `location.hash` now.
@external(javascript, "./browser_ffi.mjs", "current_hash")
pub fn current_hash() -> String

/// Calls back with `location.hash` each time it changes.
@external(javascript, "./browser_ffi.mjs", "on_hash_change")
pub fn on_hash_change(callback: fn(String) -> Nil) -> Nil
