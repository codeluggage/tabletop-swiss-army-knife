import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import tabletop/roster.{
  type Roster, type Selection, Bold, Cost, NoRoster, NotJson, Regular, Roster,
  Row, RuleLink, Table, Text, TextList, UnexpectedShape,
}

fn fixture() -> Roster {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let assert Ok(roster) = roster.decode(text)
  roster
}

fn unit(id: String) -> Selection {
  let assert Ok(unit) = roster.find_unit(fixture(), id)
  unit
}

fn names(selections: List(Selection)) -> List(String) {
  list.map(selections, fn(selection) { selection.name })
}

fn rule_names(rules: List(roster.Rule)) -> List(String) {
  list.map(rules, fn(rule) { rule.name })
}

// --- Decoding ---------------------------------------------------------------

pub fn decodes_the_fixture_test() {
  let roster = fixture()
  assert roster.name == "Sunday Picnic"
  let assert [force] = roster.forces
  assert force.name == "Picnic Host"
  assert force.catalogue_name == "Teapot Golems"
  assert rule_names(force.rules) == ["Teatime"]
}

pub fn text_that_is_not_json_is_not_json_test() {
  assert roster.decode("") == Error(NotJson)
  assert roster.decode("not json") == Error(NotJson)
  assert roster.decode("{\"roster\": ") == Error(NotJson)
}

pub fn json_without_a_roster_has_no_roster_test() {
  assert roster.decode("{\"list\": {}}") == Error(NoRoster)
  assert roster.decode("[1, 2]") == Error(NoRoster)
  assert roster.decode("{\"roster\": \"a list\"}") == Error(NoRoster)
  assert roster.decode("{\"roster\": null}") == Error(NoRoster)
}

pub fn a_roster_of_the_wrong_shape_says_where_test() {
  let no_id =
    "{\"roster\": {\"forces\": [{\"selections\": [{\"name\": \"A\"}]}]}}"
  assert roster.decode(no_id)
    == Error(UnexpectedShape(at: "roster.forces.0.selections.0.id"))
}

pub fn an_empty_roster_still_decodes_test() {
  assert roster.decode("{\"roster\": {}}") == Ok(Roster("", [], []))
  let only_settings =
    "{\"roster\": {\"forces\": [{\"selections\": [{\"id\": \"a\", \"name\": \"A\", \"type\": \"upgrade\"}]}]}}"
  let assert Ok(decoded) = roster.decode(only_settings)
  let assert [force] = decoded.forces
  assert roster.units(force) == []
}

pub fn costs_may_be_ints_or_floats_test() {
  let text =
    "{\"roster\": {\"costs\": [{\"name\": \"a\", \"value\": 2.5}, {\"name\": \"b\", \"value\": 3}]}}"
  let assert Ok(decoded) = roster.decode(text)
  assert decoded.costs == [Cost("a", 2.5), Cost("b", 3.0)]
}

// --- Units, settings, costs -------------------------------------------------

pub fn units_are_the_top_level_selections_that_are_not_settings_test() {
  let assert [force] = fixture().forces
  assert names(roster.units(force))
    == ["Kettle Captain", "Teacup Squad", "Sugar Bowl Walker"]
}

pub fn settings_are_the_top_level_upgrades_test() {
  let assert [force] = fixture().forces
  let assert [setting] = roster.settings(force)
  assert setting.name == "Weather"
  assert names(setting.selections) == ["Drizzle"]
}

pub fn find_unit_finds_only_top_level_units_test() {
  assert roster.find_unit(fixture(), "u-squad")
    |> option.from_result
    |> option.map(fn(unit) { unit.name })
    == Some("Teacup Squad")
  assert roster.find_unit(fixture(), "u-squad-cups") == Error(Nil)
  assert roster.find_unit(fixture(), "s-weather") == Error(Nil)
}

pub fn a_unit_costs_the_sum_over_everything_inside_it_test() {
  assert roster.unit_costs(unit("u-captain")) == [Cost("acorns", 45.0)]
  assert roster.unit_costs(unit("u-squad")) == [Cost("acorns", 45.0)]
}

pub fn a_zero_total_is_left_out_test() {
  let zero_and_two =
    roster.Selection(
      ..unit("u-walker"),
      costs: [Cost("a", 0.0), Cost("b", 2.0)],
      selections: [],
    )
  assert roster.unit_costs(zero_and_two) == [Cost("b", 2.0)]
  assert roster.unit_costs(unit("u-walker")) == [Cost("acorns", 30.0)]
}

pub fn unit_costs_keep_first_seen_order_test() {
  let child = roster.Selection(..unit("u-walker"), costs: [Cost("a", 3.0)])
  let parent =
    roster.Selection(
      ..unit("u-walker"),
      costs: [Cost("b", 1.0), Cost("a", 2.0)],
      selections: [child],
    )
  assert roster.unit_costs(parent) == [Cost("b", 1.0), Cost("a", 5.0)]
}

pub fn totals_come_from_the_file_when_it_has_them_test() {
  assert roster.totals(fixture()) == [Cost("acorns", 120.0)]
}

pub fn totals_are_the_sum_over_everything_otherwise_test() {
  let roster = Roster(..fixture(), costs: [])
  assert roster.totals(roster) == [Cost("favour", 3.0), Cost("acorns", 120.0)]
}

pub fn format_value_drops_the_point_on_whole_numbers_test() {
  assert roster.format_value(120.0) == "120"
  assert roster.format_value(0.0) == "0"
  assert roster.format_value(2.5) == "2.5"
  assert roster.format_value(0.1 +. 0.2) == "0.3"
  assert roster.format_costs([Cost("acorns", 45.0), Cost("favour", 1.5)])
    == "45 acorns, 1.5 favour"
  assert roster.format_costs([]) == ""
}

// --- Categories -------------------------------------------------------------

pub fn primary_category_is_the_first_marked_primary_test() {
  assert roster.primary_category(unit("u-captain")) == Some("Leader")
  assert roster.primary_category(unit("u-squad")) == Some("Line")
  assert roster.primary_category(unit("u-walker")) == None
}

pub fn units_group_by_primary_category_with_the_rest_last_test() {
  let assert [force] = fixture().forces
  let groups =
    roster.by_primary_category(roster.units(force))
    |> list.map(fn(group) { #(group.0, names(group.1)) })
  assert groups
    == [
      #(Some("Leader"), ["Kettle Captain"]),
      #(Some("Line"), ["Teacup Squad"]),
      #(None, ["Sugar Bowl Walker"]),
    ]
}

// --- Profiles ---------------------------------------------------------------

pub fn profiles_group_by_type_in_first_seen_order_test() {
  assert roster.profile_groups(unit("u-captain"))
    == [
      Table("Golem", ["Stride", "Grip", "Steam", "Rivets"], [
        Row("Kettle Captain", ["5\"", "3+", "4", "6"]),
      ]),
      TextList("Quirk", [
        #(
          "Whistle",
          "When the kettle whistles, allies with **Steam Vent** gain Glow 2.\nOnce per game.",
        ),
      ]),
      Table("Gadget", ["Reach", "Sparks", "Traits"], [
        Row("Ladle", ["1\"", "2", "Steam Vent-Fused 3+, Glow 2"]),
      ]),
    ]
}

pub fn same_profiles_show_once_and_missing_values_are_empty_test() {
  // Two models hold the same sling; the sergeant has no Steam and a Rivets
  // with no text; the teacup's Rivets is null; the hidden profile is skipped.
  assert roster.profile_groups(unit("u-squad"))
    == [
      Table("Golem", ["Stride", "Grip", "Steam", "Rivets"], [
        Row("Teacup", ["6\"", "4+", "2", ""]),
        Row("Teacup Sergeant", ["6\"", "3+", "", ""]),
      ]),
      Table("Gadget", ["Reach", "Sparks", "Traits"], [
        Row("Saucer Sling", ["12\"", "1", "Glow 2"]),
      ]),
    ]
}

// --- Rules ------------------------------------------------------------------

pub fn unit_rules_are_unique_and_visible_test() {
  assert rule_names(roster.unit_rules(unit("u-captain"))) == ["Steam Vent"]
  assert rule_names(roster.unit_rules(unit("u-squad"))) == ["Glow 2"]
  assert rule_names(roster.unit_rules(unit("u-walker"))) == ["Steam Vent Burst"]
}

pub fn every_rule_in_the_file_includes_force_rules_test() {
  assert rule_names(roster.all_rules(fixture()))
    == ["Teatime", "Steam Vent", "Glow 2", "Steam Vent Burst"]
  let assert Ok(rule) = roster.find_rule(fixture(), "Teatime")
  assert rule.description
    == "At **teatime** every golem may rest.\nRest mends one rivet."
  assert roster.find_rule(fixture(), "Sugar Rush") == Error(Nil)
}

// --- Segments ---------------------------------------------------------------

fn segments(text: String) -> List(roster.Segment) {
  let links =
    roster.links(["Steam Vent", "Steam Vent Burst", "Glow 2", "Teatime", "Ab\""])
  roster.segments(text, links)
}

pub fn the_longest_rule_name_wins_test() {
  assert segments("Steam Vent Burst also")
    == [RuleLink("Steam Vent Burst", Regular), Text(" also", Regular)]
  assert segments("Steam Vent, but louder")
    == [RuleLink("Steam Vent", Regular), Text(", but louder", Regular)]
}

pub fn a_hyphen_is_a_boundary_test() {
  assert segments("Steam Vent-Fused 3+, Glow 2")
    == [
      RuleLink("Steam Vent", Regular),
      Text("-Fused 3+, ", Regular),
      RuleLink("Glow 2", Regular),
    ]
}

pub fn a_name_needs_a_boundary_on_both_sides_test() {
  assert segments("Steam Ventilator") == [Text("Steam Ventilator", Regular)]
  assert segments("XSteam Vent") == [Text("XSteam Vent", Regular)]
  assert segments("Glow 23") == [Text("Glow 23", Regular)]
  assert segments("(Glow 2)")
    == [Text("(", Regular), RuleLink("Glow 2", Regular), Text(")", Regular)]
}

pub fn a_name_may_end_in_a_quote_mark_test() {
  assert segments("use Ab\" now")
    == [Text("use ", Regular), RuleLink("Ab\"", Regular), Text(" now", Regular)]
  assert segments("Ab\"c") == [Text("Ab\"c", Regular)]
}

pub fn names_match_case_test() {
  assert segments("at teatime, steam vent")
    == [
      Text("at teatime, steam vent", Regular),
    ]
}

pub fn bold_comes_from_double_stars_test() {
  assert segments("a **b** c")
    == [Text("a ", Regular), Text("b", Bold), Text(" c", Regular)]
  assert segments("a ** b") == [Text("a ** b", Regular)]
}

pub fn a_name_in_bold_is_a_bold_link_test() {
  assert segments("**Steam Vent Burst** also spills.\nTeatime")
    == [
      RuleLink("Steam Vent Burst", Bold),
      Text(" also spills.\n", Regular),
      RuleLink("Teatime", Regular),
    ]
}

pub fn text_with_no_rule_name_is_one_segment_test() {
  assert segments("plain words\nnew line")
    == [Text("plain words\nnew line", Regular)]
  assert segments("") == []
}

// --- The real files in local-data/, on this machine only --------------------

/// Every `.json` file in `local-data/` decodes and has a unit. Passes when the
/// folder is missing, as in CI. Prints nothing from the files.
pub fn local_data_files_decode_test() {
  let files = case simplifile.read_directory("local-data") {
    Ok(files) -> list.filter(files, string.ends_with(_, ".json"))
    Error(_) -> []
  }
  let failures =
    list.count(files, fn(file) {
      case simplifile.read("local-data/" <> file) {
        Ok(text) ->
          case roster.decode(text) {
            Ok(decoded) ->
              list.flat_map(decoded.forces, roster.units) |> list.is_empty
            Error(_) -> True
          }
        Error(_) -> True
      }
    })
  assert failures == 0
}
