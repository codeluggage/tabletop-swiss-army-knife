import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import tabletop/roster.{
  type Roster, type Selection, NoRoster, NotJson, Roster, UnexpectedShape,
}
import tabletop/sheet.{Cost}

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

fn rule_names(rules: List(sheet.Rule)) -> List(String) {
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
  assert roster.decode("{\"roster\": {}}") == Ok(Roster("", "", [], []))
  let only_settings =
    "{\"roster\": {\"forces\": [{\"selections\": [{\"id\": \"a\", \"name\": \"A\", \"type\": \"upgrade\"}]}]}}"
  let assert Ok(decoded) = roster.decode(only_settings)
  let assert [force] = decoded.forces
  assert roster.units(force) == []
}

pub fn ids_the_file_has_are_kept_test() {
  assert fixture().game_system_id == "sys-picnic"
  let assert [force] = fixture().forces
  assert force.catalogue_id == "cat-teapot"
  assert unit("u-captain").entry_ids == ["e-captain"]
  let assert [cups, ..] = unit("u-squad").selections
  assert cups.entry_ids == ["e-squad", "e-teacup"]
  let assert [leader, ..] = unit("u-captain").categories
  assert leader.id == "c-leader"
}

pub fn ids_the_file_lacks_are_empty_test() {
  let assert Ok(decoded) = roster.decode("{\"roster\": {\"forces\": [{}]}}")
  let assert [force] = decoded.forces
  assert force.catalogue_id == ""
  assert unit("u-walker").entry_ids == []
  let assert [_, kettle] = unit("u-captain").categories
  assert kettle.id == ""
}

pub fn the_kind_comes_from_the_type_test() {
  assert unit("u-captain").kind == sheet.Model
  assert unit("u-squad").kind == sheet.Unit
  let assert [setting] = list.flat_map(fixture().forces, roster.settings)
  assert setting.kind == sheet.Upgrade
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
  assert roster.unit_costs(unit("u-captain")) == [Cost("acorns", "", 45.0)]
  assert roster.unit_costs(unit("u-squad")) == [Cost("acorns", "", 45.0)]
}

pub fn a_zero_total_is_left_out_test() {
  let zero_and_two =
    roster.Selection(
      ..unit("u-walker"),
      costs: [Cost("a", "", 0.0), Cost("b", "", 2.0)],
      selections: [],
    )
  assert roster.unit_costs(zero_and_two) == [Cost("b", "", 2.0)]
  assert roster.unit_costs(unit("u-walker")) == [Cost("acorns", "", 30.0)]
}

pub fn unit_costs_keep_first_seen_order_test() {
  let child =
    roster.Selection(..unit("u-walker"), costs: [Cost("a", "t-other", 3.0)])
  let parent =
    roster.Selection(
      ..unit("u-walker"),
      costs: [Cost("b", "t-b", 1.0), Cost("a", "t-a", 2.0)],
      selections: [child],
    )
  // A sum keeps the type id of the first cost with its name.
  assert roster.unit_costs(parent)
    == [Cost("b", "t-b", 1.0), Cost("a", "t-a", 5.0)]
}

pub fn totals_come_from_the_file_when_it_has_them_test() {
  assert roster.totals(fixture()) == [Cost("acorns", "", 120.0)]
}

pub fn totals_are_the_sum_over_everything_otherwise_test() {
  let roster = Roster(..fixture(), costs: [])
  assert roster.totals(roster)
    == [Cost("favour", "", 3.0), Cost("acorns", "", 120.0)]
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

pub fn unit_profiles_are_the_unit_then_everything_inside_test() {
  let names = fn(id) {
    list.map(roster.unit_profiles(unit(id)), fn(profile) { profile.name })
  }
  assert names("u-captain") == ["Kettle Captain", "Whistle", "Ladle"]
  // Hidden profiles and repeats are still here; the sheet drops them.
  assert names("u-squad")
    == [
      "Teacup", "Saucer Sling", "Teacup Sergeant", "Secret Recipe",
      "Saucer Sling",
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
