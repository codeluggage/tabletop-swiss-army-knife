//// The shapes a datasheet shows, whichever file they come from: costs,
//// categories, profiles, rules and the kind of an entry, their decoders, and
//// the profile tables the screens draw.
////
//// The code knows the shape only. Every name, cost name, column and rule on
//// screen comes from a file.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub type Cost {
  Cost(name: String, type_id: String, value: Float)
}

pub type Category {
  Category(id: String, name: String, primary: Bool)
}

pub type Profile {
  Profile(
    id: String,
    name: String,
    type_name: String,
    hidden: Bool,
    characteristics: List(Characteristic),
  )
}

/// `text` is empty when the file has no value.
pub type Characteristic {
  Characteristic(name: String, text: String)
}

pub type Rule {
  Rule(id: String, name: String, description: String, hidden: Bool)
}

/// What an entry is, from the file's `type`.
pub type EntryKind {
  Unit
  Model
  Upgrade
  OtherKind(String)
}

// --- Decoding -------------------------------------------------------------

pub fn cost_decoder() -> decode.Decoder(Cost) {
  use name <- decode.optional_field("name", "", decode.string)
  use type_id <- decode.optional_field("typeId", "", decode.string)
  use value <- decode.optional_field("value", 0.0, number_decoder())
  decode.success(Cost(name:, type_id:, value:))
}

/// An int or a float, as a float.
pub fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

/// `id_key` is the key that holds the category's id, which differs by file.
pub fn category_decoder(id_key: String) -> decode.Decoder(Category) {
  use id <- decode.optional_field(id_key, "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use primary <- decode.optional_field("primary", False, decode.bool)
  decode.success(Category(id:, name:, primary:))
}

pub fn profile_decoder() -> decode.Decoder(Profile) {
  use id <- decode.optional_field("id", "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use type_name <- decode.optional_field("typeName", "", decode.string)
  use hidden <- decode.optional_field("hidden", False, decode.bool)
  use characteristics <- decode.optional_field(
    "characteristics",
    [],
    decode.list(characteristic_decoder()),
  )
  decode.success(Profile(id:, name:, type_name:, hidden:, characteristics:))
}

fn characteristic_decoder() -> decode.Decoder(Characteristic) {
  use name <- decode.optional_field("name", "", decode.string)
  use text <- decode.optional_field(
    "$text",
    "",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  decode.success(Characteristic(name:, text:))
}

pub fn rule_decoder() -> decode.Decoder(Rule) {
  use id <- decode.optional_field("id", "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use hidden <- decode.optional_field("hidden", False, decode.bool)
  decode.success(Rule(id:, name:, description:, hidden:))
}

/// The file's `type` string as an `EntryKind`.
pub fn entry_kind_decoder() -> decode.Decoder(EntryKind) {
  use kind <- decode.map(decode.string)
  case kind {
    "unit" -> Unit
    "model" -> Model
    "upgrade" -> Upgrade
    other -> OtherKind(other)
  }
}

// --- Costs ------------------------------------------------------------------

/// A whole number without a decimal point, anything else to two places at most.
pub fn format_value(value: Float) -> String {
  let rounded = float.to_precision(value, 2)
  case rounded == float.floor(rounded) {
    True -> int.to_string(float.truncate(rounded))
    False -> float.to_string(rounded)
  }
}

/// Each cost as its value then its name, such as `12 abc, 3 xyz`.
pub fn format_costs(costs: List(Cost)) -> String {
  costs
  |> list.map(fn(cost) { format_value(cost.value) <> " " <> cost.name })
  |> string.join(", ")
}

// --- Profiles ---------------------------------------------------------------

/// The profiles of one type, ready to show.
pub type ProfileGroup {
  /// Every profile of the type has exactly one characteristic: each item is
  /// the profile name and that characteristic's text.
  TextList(type_name: String, items: List(#(String, String)))
  /// One column per characteristic name, in first-seen order, leaving out a
  /// column with no value in any row and a column with long text. Each row's
  /// cells line up with the columns, empty where the profile has no value.
  Table(type_name: String, columns: List(String), rows: List(Row))
}

/// `notes` holds the row's text in the long columns, as column name and text,
/// leaving out empty ones. The view shows them under the name, so a phone
/// screen fits the short columns without scrolling sideways.
pub type Row {
  Row(name: String, cells: List(String), notes: List(#(String, String)))
}

/// A column is long when any of its values holds a space (words, not a
/// number) or is longer than this many characters.
const long_text = 8

/// The visible profiles, grouped by type in first-seen order. A profile with
/// the same name, type and characteristics as one before it appears once,
/// whatever its id.
pub fn profile_groups(profiles: List(Profile)) -> List(ProfileGroup) {
  let profiles =
    profiles
    |> list.filter(fn(profile) { !profile.hidden })
    |> list.map(fn(profile) { Profile(..profile, id: "") })
    |> list.unique
  profiles
  |> list.map(fn(profile) { profile.type_name })
  |> list.unique
  |> list.map(fn(type_name) {
    list.filter(profiles, fn(profile) { profile.type_name == type_name })
    |> group(type_name, _)
  })
}

fn group(type_name: String, profiles: List(Profile)) -> ProfileGroup {
  let single =
    list.all(profiles, fn(profile) { list.length(profile.characteristics) == 1 })
  case single {
    True ->
      TextList(
        type_name:,
        items: list.flat_map(profiles, fn(profile) {
          list.map(profile.characteristics, fn(characteristic) {
            #(profile.name, characteristic.text)
          })
        }),
      )
    False -> {
      let in_any_row = fn(column, check) {
        list.any(profiles, fn(profile) { check(value(profile, column)) })
      }
      let #(long, columns) =
        profiles
        |> list.flat_map(fn(profile) { profile.characteristics })
        |> list.map(fn(characteristic) { characteristic.name })
        |> list.unique
        |> list.filter(in_any_row(_, fn(text) { text != "" }))
        |> list.partition(
          in_any_row(_, fn(text) {
            string.length(text) > long_text || string.contains(text, " ")
          }),
        )
      let rows =
        list.map(profiles, fn(profile) {
          Row(
            name: profile.name,
            cells: list.map(columns, value(profile, _)),
            notes: long
              |> list.map(fn(column) { #(column, value(profile, column)) })
              |> list.filter(fn(note) { note.1 != "" }),
          )
        })
      Table(type_name:, columns:, rows:)
    }
  }
}

/// The profile's text for the characteristic `column`, empty when it has none.
fn value(profile: Profile, column: String) -> String {
  profile.characteristics
  |> list.find(fn(characteristic) { characteristic.name == column })
  |> result.map(fn(characteristic) { characteristic.text })
  |> result.unwrap("")
}

// --- Rules ------------------------------------------------------------------

/// The visible rules, unique by name, each name's first rule in first-seen
/// order.
pub fn unique_rules(rules: List(Rule)) -> List(Rule) {
  let visible = list.filter(rules, fn(rule) { !rule.hidden })
  visible
  |> list.map(fn(rule) { rule.name })
  |> list.unique
  |> list.filter_map(fn(name) {
    list.find(visible, fn(rule) { rule.name == name })
  })
}
