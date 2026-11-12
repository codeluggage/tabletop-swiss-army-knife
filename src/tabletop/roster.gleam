//// A list file that a list-building app exported: its shape, a decoder from
//// the file's text, and the pure functions the list screens use. The shapes a
//// datasheet shows are in `tabletop/sheet`.
////
//// The code knows the shape only. Every name, cost name, column and rule on
//// screen comes from the file.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import tabletop/sheet.{
  type Category, type Cost, type EntryKind, type Profile, type Rule, Cost,
}

pub type Roster {
  Roster(name: String, costs: List(Cost), forces: List(Force))
}

pub type Force {
  Force(
    name: String,
    /// Empty when the file has none.
    catalogue_id: String,
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
    /// The ids of the entries this selection was made from, empty when the
    /// file has none.
    entry_ids: List(String),
    name: String,
    kind: EntryKind,
    number: Int,
    costs: List(Cost),
    categories: List(Category),
    profiles: List(Profile),
    rules: List(Rule),
    selections: List(Selection),
  )
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
  use costs <- decode.optional_field(
    "costs",
    [],
    decode.list(sheet.cost_decoder()),
  )
  use forces <- decode.optional_field(
    "forces",
    [],
    decode.list(force_decoder()),
  )
  decode.success(Roster(name:, costs:, forces:))
}

fn force_decoder() -> decode.Decoder(Force) {
  use name <- decode.optional_field("name", "", decode.string)
  use catalogue_id <- decode.optional_field("catalogueId", "", decode.string)
  use catalogue_name <- decode.optional_field(
    "catalogueName",
    "",
    decode.string,
  )
  use rules <- decode.optional_field(
    "rules",
    [],
    decode.list(sheet.rule_decoder()),
  )
  use selections <- decode.optional_field(
    "selections",
    [],
    decode.list(selection_decoder()),
  )
  decode.success(Force(
    name:,
    catalogue_id:,
    catalogue_name:,
    rules:,
    selections:,
  ))
}

fn selection_decoder() -> decode.Decoder(Selection) {
  use id <- decode.field("id", decode.string)
  use entry_ids <- decode.optional_field(
    "entryId",
    [],
    decode.string |> decode.map(split_ids),
  )
  use name <- decode.field("name", decode.string)
  use kind <- decode.optional_field(
    "type",
    sheet.OtherKind(""),
    sheet.entry_kind_decoder(),
  )
  use number <- decode.optional_field("number", 1, decode.int)
  use costs <- decode.optional_field(
    "costs",
    [],
    decode.list(sheet.cost_decoder()),
  )
  use categories <- decode.optional_field(
    "categories",
    [],
    decode.list(sheet.category_decoder("entryId")),
  )
  use profiles <- decode.optional_field(
    "profiles",
    [],
    decode.list(sheet.profile_decoder()),
  )
  use rules <- decode.optional_field(
    "rules",
    [],
    decode.list(sheet.rule_decoder()),
  )
  use selections <- decode.optional_field(
    "selections",
    [],
    decode.list(decode.recursive(selection_decoder)),
  )
  decode.success(Selection(
    id:,
    entry_ids:,
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

/// The file joins a selection's entry ids with `::`.
fn split_ids(joined: String) -> List(String) {
  string.split(joined, "::") |> list.filter(fn(id) { id != "" })
}

// --- Units, settings and costs --------------------------------------------

/// The force's top-level selections that are not settings.
pub fn units(force: Force) -> List(Selection) {
  list.filter(force.selections, fn(selection) { !is_setting(selection) })
}

/// The force's top-level upgrade selections. Each child's name is a value
/// chosen for the setting.
pub fn settings(force: Force) -> List(Selection) {
  list.filter(force.selections, is_setting)
}

fn is_setting(selection: Selection) -> Bool {
  case selection.kind {
    sheet.Upgrade -> True
    sheet.Unit | sheet.Model | sheet.OtherKind(_) -> False
  }
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

/// Each sum keeps the type id of the first cost with its name.
fn sum_costs(selections: List(Selection)) -> List(Cost) {
  let costs =
    selections
    |> list.flat_map(with_descendants)
    |> list.flat_map(fn(selection) { selection.costs })
  costs
  |> list.map(fn(cost) { cost.name })
  |> list.unique
  |> list.filter_map(fn(name) {
    list.find(costs, fn(cost) { cost.name == name })
  })
  |> list.map(fn(first) {
    let value =
      costs
      |> list.filter(fn(cost) { cost.name == first.name })
      |> list.fold(0.0, fn(sum, cost) { sum +. cost.value })
    Cost(..first, value:)
  })
  |> list.filter(fn(cost) { cost.value != 0.0 })
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

// --- Profiles and rules -----------------------------------------------------

/// The profiles of the unit and everything inside it, the unit's first.
pub fn unit_profiles(unit: Selection) -> List(Profile) {
  with_descendants(unit)
  |> list.flat_map(fn(selection) { selection.profiles })
}

/// The visible rules on the unit and everything inside it, unique by name, in
/// first-seen order.
pub fn unit_rules(unit: Selection) -> List(Rule) {
  with_descendants(unit)
  |> list.flat_map(fn(selection) { selection.rules })
  |> sheet.unique_rules
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
  |> sheet.unique_rules
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
