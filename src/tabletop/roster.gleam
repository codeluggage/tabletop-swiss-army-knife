//// A list file that a list-building app exported: its shape, a decoder from
//// the file's text, and the pure functions the screens use.
////
//// The code knows the shape only. Every name, cost name, column and rule on
//// screen comes from the file.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type Roster {
  Roster(name: String, costs: List(Cost), forces: List(Force))
}

pub type Cost {
  Cost(name: String, value: Float)
}

pub type Force {
  Force(
    name: String,
    catalogue_name: String,
    rules: List(Rule),
    selections: List(Selection),
  )
}

/// A unit, a model or an upgrade, as the file's `type` says, with what it
/// holds nested inside.
pub type Selection {
  Selection(
    id: String,
    name: String,
    kind: String,
    number: Int,
    costs: List(Cost),
    categories: List(Category),
    profiles: List(Profile),
    rules: List(Rule),
    selections: List(Selection),
  )
}

pub type Category {
  Category(name: String, primary: Bool)
}

pub type Profile {
  Profile(
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
  Rule(name: String, description: String, hidden: Bool)
}

pub type FileError {
  NotJson
  /// JSON, but no `roster` object.
  NoRoster
  /// A `roster` object with a value of the wrong kind at this path.
  UnexpectedShape(at: String)
}

// --- Decoding -------------------------------------------------------------

pub fn decode(text: String) -> Result(Roster, FileError) {
  use data <- result.try(
    json.parse(text, decode.dynamic) |> result.replace_error(NotJson),
  )
  let object = decode.dict(decode.string, decode.dynamic)
  use _ <- result.try(
    decode.run(data, decode.at(["roster"], object))
    |> result.replace_error(NoRoster),
  )
  decode.run(data, decode.at(["roster"], roster_decoder()))
  |> result.map_error(fn(errors) {
    let path = list.flat_map(list.take(errors, 1), fn(error) { error.path })
    UnexpectedShape(at: string.join(path, "."))
  })
}

fn roster_decoder() -> decode.Decoder(Roster) {
  use name <- decode.optional_field("name", "", decode.string)
  use costs <- decode.optional_field("costs", [], decode.list(cost_decoder()))
  use forces <- decode.optional_field(
    "forces",
    [],
    decode.list(force_decoder()),
  )
  decode.success(Roster(name:, costs:, forces:))
}

fn cost_decoder() -> decode.Decoder(Cost) {
  use name <- decode.optional_field("name", "", decode.string)
  use value <- decode.optional_field("value", 0.0, number())
  decode.success(Cost(name:, value:))
}

/// An int or a float, as a float.
fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn force_decoder() -> decode.Decoder(Force) {
  use name <- decode.optional_field("name", "", decode.string)
  use catalogue_name <- decode.optional_field(
    "catalogueName",
    "",
    decode.string,
  )
  use rules <- decode.optional_field("rules", [], decode.list(rule_decoder()))
  use selections <- decode.optional_field(
    "selections",
    [],
    decode.list(selection_decoder()),
  )
  decode.success(Force(name:, catalogue_name:, rules:, selections:))
}

fn selection_decoder() -> decode.Decoder(Selection) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.optional_field("type", "", decode.string)
  use number <- decode.optional_field("number", 1, decode.int)
  use costs <- decode.optional_field("costs", [], decode.list(cost_decoder()))
  use categories <- decode.optional_field(
    "categories",
    [],
    decode.list(category_decoder()),
  )
  use profiles <- decode.optional_field(
    "profiles",
    [],
    decode.list(profile_decoder()),
  )
  use rules <- decode.optional_field("rules", [], decode.list(rule_decoder()))
  use selections <- decode.optional_field(
    "selections",
    [],
    decode.list(decode.recursive(selection_decoder)),
  )
  decode.success(Selection(
    id:,
    name:,
    kind:,
    number:,
    costs:,
    categories:,
    profiles:,
    rules:,
    selections:,
  ))
}

fn category_decoder() -> decode.Decoder(Category) {
  use name <- decode.optional_field("name", "", decode.string)
  use primary <- decode.optional_field("primary", False, decode.bool)
  decode.success(Category(name:, primary:))
}

fn profile_decoder() -> decode.Decoder(Profile) {
  use name <- decode.optional_field("name", "", decode.string)
  use type_name <- decode.optional_field("typeName", "", decode.string)
  use hidden <- decode.optional_field("hidden", False, decode.bool)
  use characteristics <- decode.optional_field(
    "characteristics",
    [],
    decode.list(characteristic_decoder()),
  )
  decode.success(Profile(name:, type_name:, hidden:, characteristics:))
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

fn rule_decoder() -> decode.Decoder(Rule) {
  use name <- decode.optional_field("name", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use hidden <- decode.optional_field("hidden", False, decode.bool)
  decode.success(Rule(name:, description:, hidden:))
}

// --- Units, settings and costs --------------------------------------------

/// The force's top-level selections that are not settings.
pub fn units(force: Force) -> List(Selection) {
  list.filter(force.selections, fn(selection) { selection.kind != "upgrade" })
}

/// The force's top-level `upgrade` selections. Each child's name is a value
/// chosen for the setting.
pub fn settings(force: Force) -> List(Selection) {
  list.filter(force.selections, fn(selection) { selection.kind == "upgrade" })
}

pub fn find_unit(roster: Roster, id: String) -> Result(Selection, Nil) {
  roster.forces
  |> list.flat_map(units)
  |> list.find(fn(unit) { unit.id == id })
}

/// The selection and every selection inside it, the selection first.
fn with_descendants(selection: Selection) -> List(Selection) {
  [selection, ..list.flat_map(selection.selections, with_descendants)]
}

/// Per cost name, the sum over the unit and everything inside it, in
/// first-seen order. Totals of zero are left out.
pub fn unit_costs(unit: Selection) -> List(Cost) {
  sum_costs([unit])
}

/// The file's own totals when it has them, else the sum over every selection.
pub fn totals(roster: Roster) -> List(Cost) {
  case roster.costs {
    [] ->
      roster.forces
      |> list.flat_map(fn(force) { force.selections })
      |> sum_costs
    costs -> costs
  }
}

fn sum_costs(selections: List(Selection)) -> List(Cost) {
  let costs =
    selections
    |> list.flat_map(with_descendants)
    |> list.flat_map(fn(selection) { selection.costs })
  costs
  |> list.map(fn(cost) { cost.name })
  |> list.unique
  |> list.map(fn(name) {
    let value =
      costs
      |> list.filter(fn(cost) { cost.name == name })
      |> list.fold(0.0, fn(sum, cost) { sum +. cost.value })
    Cost(name:, value:)
  })
  |> list.filter(fn(cost) { cost.value != 0.0 })
}

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

/// The first category marked primary.
pub fn primary_category(unit: Selection) -> Option(String) {
  unit.categories
  |> list.find(fn(category) { category.primary })
  |> result.map(fn(category) { category.name })
  |> option.from_result
}

/// Units under their primary category, categories in first-seen order, and
/// the units with none last, under `None`.
pub fn by_primary_category(
  units: List(Selection),
) -> List(#(Option(String), List(Selection))) {
  let keyed = list.map(units, fn(unit) { #(primary_category(unit), unit) })
  let #(named, unnamed) =
    keyed
    |> list.map(fn(pair) { pair.0 })
    |> list.unique
    |> list.partition(option.is_some)
  list.append(named, unnamed)
  |> list.map(fn(category) {
    #(
      category,
      list.filter_map(keyed, fn(pair) {
        case pair.0 == category {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      }),
    )
  })
}

// --- Profiles ---------------------------------------------------------------

/// The profiles of one type on a unit, ready to show.
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

/// A column with any value longer than this many characters is a long column.
const long_text = 12

/// The visible profiles of the unit and everything inside it, grouped by type
/// in first-seen order. A profile identical to one already in its group
/// appears once.
pub fn profile_groups(unit: Selection) -> List(ProfileGroup) {
  let profiles =
    with_descendants(unit)
    |> list.flat_map(fn(selection) { selection.profiles })
    |> list.filter(fn(profile) { !profile.hidden })
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
          in_any_row(_, fn(text) { string.length(text) > long_text }),
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

/// The visible rules on the unit and everything inside it, unique by name, in
/// first-seen order.
pub fn unit_rules(unit: Selection) -> List(Rule) {
  with_descendants(unit)
  |> list.flat_map(fn(selection) { selection.rules })
  |> unique_rules
}

/// Every visible rule in the file, force rules included, unique by name. These
/// are the rules a link can point at.
pub fn all_rules(roster: Roster) -> List(Rule) {
  roster.forces
  |> list.flat_map(fn(force) {
    list.append(
      force.rules,
      force.selections
        |> list.flat_map(with_descendants)
        |> list.flat_map(fn(selection) { selection.rules }),
    )
  })
  |> unique_rules
}

fn unique_rules(rules: List(Rule)) -> List(Rule) {
  let visible = list.filter(rules, fn(rule) { !rule.hidden })
  visible
  |> list.map(fn(rule) { rule.name })
  |> list.unique
  |> list.filter_map(fn(name) {
    list.find(visible, fn(rule) { rule.name == name })
  })
}

pub fn find_rule(roster: Roster, name: String) -> Result(Rule, Nil) {
  list.find(all_rules(roster), fn(rule) { rule.name == name })
}

// --- Text to segments -------------------------------------------------------

pub type Weight {
  Regular
  Bold
}

/// A run of text for the view: plain text, or a rule name that links to it.
pub type Segment {
  Text(text: String, weight: Weight)
  RuleLink(name: String, weight: Weight)
}

/// The rule names that text can link to, ready for `segments`.
pub opaque type Links {
  /// Names as graphemes, keyed by their first grapheme, longest first.
  Links(by_first: Dict(String, List(List(String))))
}

pub fn links(names: List(String)) -> Links {
  names
  |> list.unique
  |> list.map(string.to_graphemes)
  |> list.sort(fn(a, b) { int.compare(list.length(a), list.length(b)) })
  |> list.fold(dict.new(), fn(by_first, name) {
    case name {
      [] -> by_first
      [first, ..] ->
        dict.upsert(by_first, first, fn(names) {
          [name, ..option.unwrap(names, [])]
        })
    }
  })
  |> Links
}

/// Split `text` into runs. `**...**` is bold. A rule name links where it
/// stands in the text with a boundary on both sides: the start or end of the
/// text, or a character that is not a letter or digit. Names match case and
/// all, and at one place the longest name wins. Newlines stay in the text.
pub fn segments(text: String, links: Links) -> List(Segment) {
  text
  |> string.split("**")
  |> pair_bold_markers
  |> list.index_map(fn(run, index) {
    let weight = case int.is_odd(index) {
      True -> Bold
      False -> Regular
    }
    link_run(string.to_graphemes(run), True, [], [], weight, links)
  })
  |> list.flatten
}

/// A `**` with no partner is plain text: join the last two runs back up.
fn pair_bold_markers(runs: List(String)) -> List(String) {
  case int.is_even(list.length(runs)) {
    False -> runs
    True ->
      case list.reverse(runs) {
        [last, before, ..rest] -> list.reverse([before <> "**" <> last, ..rest])
        _ -> runs
      }
  }
}

fn link_run(
  rest: List(String),
  at_boundary: Bool,
  plain: List(String),
  out: List(Segment),
  weight: Weight,
  links: Links,
) -> List(Segment) {
  case rest {
    [] -> list.reverse(flush(plain, weight, out))
    [grapheme, ..after] -> {
      let found = case at_boundary {
        True -> longest_name(rest, links)
        False -> Error(Nil)
      }
      case found {
        Ok(#(name, after_name)) -> {
          let out = [
            RuleLink(name: string.concat(name), weight:),
            ..flush(plain, weight, out)
          ]
          let ends_in_word = list.last(name) |> result.map(is_word) == Ok(True)
          link_run(after_name, !ends_in_word, [], out, weight, links)
        }
        Error(Nil) ->
          link_run(
            after,
            !is_word(grapheme),
            [grapheme, ..plain],
            out,
            weight,
            links,
          )
      }
    }
  }
}

fn flush(
  plain: List(String),
  weight: Weight,
  out: List(Segment),
) -> List(Segment) {
  case plain {
    [] -> out
    _ -> [Text(text: string.concat(list.reverse(plain)), weight:), ..out]
  }
}

/// The longest name that starts `text` and ends at a boundary, and the text
/// after it.
fn longest_name(
  text: List(String),
  links: Links,
) -> Result(#(List(String), List(String)), Nil) {
  use first <- result.try(list.first(text))
  use names <- result.try(dict.get(links.by_first, first))
  use name <- list.find_map(names)
  use after <- result.try(strip_prefix(text, name))
  case after {
    [] -> Ok(#(name, after))
    [next, ..] ->
      case is_word(next) {
        True -> Error(Nil)
        False -> Ok(#(name, after))
      }
  }
}

fn strip_prefix(
  text: List(String),
  prefix: List(String),
) -> Result(List(String), Nil) {
  case text, prefix {
    _, [] -> Ok(text)
    [a, ..text], [b, ..prefix] if a == b -> strip_prefix(text, prefix)
    _, _ -> Error(Nil)
  }
}

// ponytail: a letter is a grapheme with an upper and a lower case, so letters
// of scripts without case count as boundaries. Use a Unicode table if a file
// ever has rule names in such a script.
/// A letter or a digit.
fn is_word(grapheme: String) -> Bool {
  string.lowercase(grapheme) != string.uppercase(grapheme)
  || case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
