import tabletop/route.{Home, ListPage, RulePage, UnitPage}

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

pub fn unknown_hashes_are_home_test() {
  assert route.parse("#/nowhere") == Home
  assert route.parse("#/list") == Home
  assert route.parse("#/list/") == Home
  assert route.parse("#/list/abc/unit") == Home
  assert route.parse("#/list/abc/unit/") == Home
  assert route.parse("#/list/abc/table/x") == Home
  assert route.parse("#/list/%E0%A4%A") == Home
}
