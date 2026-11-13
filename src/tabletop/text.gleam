//// Text to segments for the view: `**bold**` runs and `^^keyword^^` runs,
//// both bold, and names that link to a target. Each feature picks what a
//// link points at.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub type Weight {
  Regular
  Bold
}

/// A run of text for the view: plain text, or a name that links to its target.
pub type Segment(target) {
  Text(text: String, weight: Weight)
  Link(name: String, target: target, weight: Weight)
}

/// The names that text can link to, each with its target, ready for
/// `segments`.
pub opaque type Links(target) {
  /// Names as graphemes with their targets, keyed by their first grapheme,
  /// longest first.
  Links(by_first: Dict(String, List(#(List(String), target))))
}

/// When a name appears twice, the first pair wins.
pub fn links(names: List(#(String, target))) -> Links(target) {
  // `dict.from_list` keeps the last pair for a key, so reverse first.
  names
  |> list.reverse
  |> dict.from_list
  |> dict.to_list
  |> list.map(fn(pair) { #(string.to_graphemes(pair.0), pair.1) })
  |> list.sort(fn(a, b) { int.compare(list.length(a.0), list.length(b.0)) })
  |> list.fold(dict.new(), fn(by_first, pair) {
    case pair.0 {
      [] -> by_first
      [first, ..] ->
        dict.upsert(by_first, first, fn(names) {
          [pair, ..option.unwrap(names, [])]
        })
    }
  })
  |> Links
}

/// Split `text` into runs. `**...**` and `^^...^^` are bold, and the
/// markers are not shown. A name links where it stands in the text with a
/// boundary on both sides: the start or end of the text, or a character that
/// is not a letter or digit. Names match case and all, and at one place the
/// longest name wins. Newlines stay in the text.
pub fn segments(text: String, links: Links(target)) -> List(Segment(target)) {
  bold_runs(text, "**", Regular)
  |> list.flat_map(fn(run) { bold_runs(run.0, "^^", run.1) })
  |> list.flat_map(fn(run) {
    link_run(string.to_graphemes(run.0), True, [], [], run.1, links)
  })
}

/// The text split at each pair of `marker`: inside a pair is bold, outside
/// is `weight`.
fn bold_runs(
  text: String,
  marker: String,
  weight: Weight,
) -> List(#(String, Weight)) {
  string.split(text, marker)
  |> pair_markers(marker)
  |> list.index_map(fn(run, index) {
    case int.is_odd(index) {
      True -> #(run, Bold)
      False -> #(run, weight)
    }
  })
}

/// A marker with no partner is plain text: join the last two runs back up.
fn pair_markers(runs: List(String), marker: String) -> List(String) {
  case int.is_even(list.length(runs)) {
    False -> runs
    True ->
      case list.reverse(runs) {
        [last, before, ..rest] ->
          list.reverse([before <> marker <> last, ..rest])
        _ -> runs
      }
  }
}

fn link_run(
  rest: List(String),
  at_boundary: Bool,
  plain: List(String),
  out: List(Segment(target)),
  weight: Weight,
  links: Links(target),
) -> List(Segment(target)) {
  case rest {
    [] -> list.reverse(flush(plain, weight, out))
    [grapheme, ..after] -> {
      let found = case at_boundary {
        True -> longest_name(rest, links)
        False -> Error(Nil)
      }
      case found {
        Ok(#(name, target, after_name)) -> {
          let out = [
            Link(name: string.concat(name), target:, weight:),
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
  out: List(Segment(target)),
) -> List(Segment(target)) {
  case plain {
    [] -> out
    _ -> [Text(text: string.concat(list.reverse(plain)), weight:), ..out]
  }
}

/// The longest name that starts `text` and ends at a boundary, its target,
/// and the text after it.
fn longest_name(
  text: List(String),
  links: Links(target),
) -> Result(#(List(String), target, List(String)), Nil) {
  use first <- result.try(list.first(text))
  use names <- result.try(dict.get(links.by_first, first))
  use #(name, target) <- list.find_map(names)
  use after <- result.try(strip_prefix(text, name))
  case after {
    [] -> Ok(#(name, target, after))
    [next, ..] ->
      case is_word(next) {
        True -> Error(Nil)
        False -> Ok(#(name, target, after))
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
// ever has names in such a script.
/// A letter or a digit.
fn is_word(grapheme: String) -> Bool {
  string.lowercase(grapheme) != string.uppercase(grapheme)
  || case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
