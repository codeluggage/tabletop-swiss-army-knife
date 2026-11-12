import gleam/dynamic/decode
import gleam/json
import simplifile
import tabletop/roster
import tabletop/sheet.{
  Category, Characteristic, Cost, Model, OtherKind, Profile, Row, Rule, Table,
  TextList, Unit, Upgrade,
}

fn unit_profiles(id: String) -> List(sheet.Profile) {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-list.json")
  let assert Ok(decoded) = roster.decode(text)
  let assert Ok(unit) = roster.find_unit(decoded, id)
  roster.unit_profiles(unit)
}

// --- Decoding ---------------------------------------------------------------

pub fn costs_may_be_ints_or_floats_test() {
  let text =
    "[{\"name\": \"a\", \"value\": 2.5}, {\"name\": \"b\", \"typeId\": \"t-b\", \"value\": 3}]"
  assert json.parse(text, decode.list(sheet.cost_decoder()))
    == Ok([Cost("a", "", 2.5), Cost("b", "t-b", 3.0)])
}

pub fn a_category_id_comes_from_the_key_given_test() {
  let text =
    "{\"entryId\": \"c-1\", \"targetId\": \"c-2\", \"name\": \"Line\", \"primary\": true}"
  assert json.parse(text, sheet.category_decoder("entryId"))
    == Ok(Category("c-1", "Line", True))
  assert json.parse(text, sheet.category_decoder("targetId"))
    == Ok(Category("c-2", "Line", True))
  assert json.parse("{\"name\": \"Line\"}", sheet.category_decoder("entryId"))
    == Ok(Category("", "Line", False))
}

pub fn profiles_and_rules_keep_their_ids_test() {
  let profile =
    "{\"id\": \"p-1\", \"name\": \"Ladle\", \"typeName\": \"Gadget\", \"characteristics\": [{\"name\": \"Reach\", \"$text\": \"1\"}]}"
  assert json.parse(profile, sheet.profile_decoder())
    == Ok(
      Profile("p-1", "Ladle", "Gadget", False, [Characteristic("Reach", "1")]),
    )
  assert json.parse("{\"name\": \"Ladle\"}", sheet.profile_decoder())
    == Ok(Profile("", "Ladle", "", False, []))
  let rule =
    "{\"id\": \"r-1\", \"name\": \"Teatime\", \"description\": \"Rest.\"}"
  assert json.parse(rule, sheet.rule_decoder())
    == Ok(Rule("r-1", "Teatime", "Rest.", False))
  assert json.parse("{\"name\": \"Teatime\"}", sheet.rule_decoder())
    == Ok(Rule("", "Teatime", "", False))
}

pub fn the_kind_is_read_from_the_type_string_test() {
  let kind = fn(text) { json.parse(text, sheet.entry_kind_decoder()) }
  assert kind("\"unit\"") == Ok(Unit)
  assert kind("\"model\"") == Ok(Model)
  assert kind("\"upgrade\"") == Ok(Upgrade)
  assert kind("\"crew\"") == Ok(OtherKind("crew"))
  assert kind("\"\"") == Ok(OtherKind(""))
}

// --- Costs ------------------------------------------------------------------

pub fn format_value_drops_the_point_on_whole_numbers_test() {
  assert sheet.format_value(120.0) == "120"
  assert sheet.format_value(0.0) == "0"
  assert sheet.format_value(2.5) == "2.5"
  assert sheet.format_value(0.1 +. 0.2) == "0.3"
  assert sheet.format_costs([Cost("acorns", "", 45.0), Cost("favour", "", 1.5)])
    == "45 acorns, 1.5 favour"
  assert sheet.format_costs([]) == ""
}

// --- Profiles ---------------------------------------------------------------

pub fn profiles_group_by_type_in_first_seen_order_test() {
  assert sheet.profile_groups(unit_profiles("u-captain"))
    == [
      Table("Golem", ["Stride", "Grip", "Steam", "Rivets"], [
        Row("Kettle Captain", ["5\"", "3+", "4", "6"], []),
      ]),
      TextList("Quirk", [
        #(
          "Whistle",
          "When the kettle whistles, allies with **Steam Vent** gain Glow 2.\nOnce per game.",
        ),
      ]),
      // Traits holds a long value, so it moves under the name as a note.
      Table("Gadget", ["Reach", "Sparks"], [
        Row("Ladle", ["1\"", "2"], [#("Traits", "Steam Vent-Fused 3+, Glow 2")]),
      ]),
    ]
}

pub fn same_profiles_show_once_and_missing_values_are_empty_test() {
  // Two models hold the same sling; the sergeant has no Steam and a Rivets
  // with no text; the teacup's Rivets is null; the hidden profile is skipped.
  // Rivets is empty in every row, so the column is left out. Traits holds a
  // space, so it is words and moves under the name.
  assert sheet.profile_groups(unit_profiles("u-squad"))
    == [
      Table("Golem", ["Stride", "Grip", "Steam"], [
        Row("Teacup", ["6\"", "4+", "2"], []),
        Row("Teacup Sergeant", ["6\"", "3+", ""], []),
      ]),
      Table("Gadget", ["Reach", "Sparks"], [
        Row("Saucer Sling", ["12\"", "1"], [#("Traits", "Glow 2")]),
      ]),
    ]
}

pub fn profiles_that_differ_only_by_id_show_once_test() {
  let sling = fn(id) {
    Profile(id, "Saucer Sling", "Gadget", False, [
      Characteristic("Reach", "12"),
      Characteristic("Sparks", "1"),
    ])
  }
  assert sheet.profile_groups([sling("p-1"), sling("p-2")])
    == [
      Table("Gadget", ["Reach", "Sparks"], [
        Row("Saucer Sling", ["12", "1"], []),
      ]),
    ]
}
