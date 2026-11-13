import tabletop/route.{
  CataloguePage, DataSetPage, Home, ListPage, NodePage, RulePage, UnitPage,
}

pub fn parse_reads_each_screen_test() {
  assert route.parse("") == Home
  assert route.parse("#") == Home
  assert route.parse("#/") == Home
  assert route.parse("#/list/abc-1") == ListPage("abc-1")
  assert route.parse("#/list/abc-1/unit/u-2") == UnitPage("abc-1", "u-2")
  assert route.parse("#/list/abc-1/rule/Teatime")
    == RulePage("abc-1", "Teatime")
}

pub fn to_hash_writes_each_screen_test() {
  assert route.to_hash(Home) == "#/"
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
}
