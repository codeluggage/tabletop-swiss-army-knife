//// The text of a table file as rows of cells. The delimiter is the tab,
//// comma, semicolon or pipe that the first line that is not blank holds most
//// often outside quotes, the first of them in that order on a tie. A cell in
//// double quotes, as in RFC 4180, may hold the delimiter, line breaks, and
//// `""` for one quote. The first row that is not empty is the header.

import gleam/list
import gleam/string

pub type Table {
  /// Every row has at least as many cells as the header.
  Table(header: List(String), rows: List(List(String)))
}

pub fn parse(text: String) -> Table {
  // A spreadsheet often starts the file with a byte order mark.
  let text = case text {
    "\u{FEFF}" <> rest -> rest
    _ -> text
  }
  let graphemes = string.to_graphemes(text)
  let rows =
    read(graphemes, delimiter(graphemes), False, [], [], [])
    |> list.filter(fn(row) {
      !list.all(row, fn(cell) { string.trim(cell) == "" })
    })
  case rows {
    [] -> Table(header: [], rows: [])
    [header, ..rows] -> {
      let width = list.length(header)
      Table(
        header:,
        rows: list.map(rows, fn(row) {
          list.append(row, list.repeat("", width - list.length(row)))
        }),
      )
    }
  }
}

const delimiters = ["\t", ",", ";", "|"]

fn delimiter(text: List(String)) -> String {
  let line = unquoted_first_line(text, False, [])
  let #(most, _) =
    list.fold(delimiters, #("\t", -1), fn(most, delimiter) {
      case list.count(line, fn(grapheme) { grapheme == delimiter }) {
        count if count > most.1 -> #(delimiter, count)
        _ -> most
      }
    })
  most
}

/// The graphemes outside quotes of the first line that is not blank. `kept`
/// is the line so far, newest first.
fn unquoted_first_line(
  text: List(String),
  quoted: Bool,
  kept: List(String),
) -> List(String) {
  case quoted, text {
    _, [] -> kept
    False, ["\n", ..rest] | False, ["\r\n", ..rest] ->
      case list.all(kept, fn(grapheme) { string.trim(grapheme) == "" }) {
        True -> unquoted_first_line(rest, False, [])
        False -> kept
      }
    _, ["\"", ..rest] -> unquoted_first_line(rest, !quoted, kept)
    True, [_, ..rest] -> unquoted_first_line(rest, True, kept)
    False, [grapheme, ..rest] ->
      unquoted_first_line(rest, False, [grapheme, ..kept])
  }
}

/// `cell` is the graphemes of the cell so far and `row` the cells so far,
/// both newest first. `"\r\n"` is one grapheme.
fn read(
  text: List(String),
  delimiter: String,
  quoted: Bool,
  cell: List(String),
  row: List(String),
  rows: List(List(String)),
) -> List(List(String)) {
  case quoted, text {
    _, [] -> list.reverse([end_row(cell, row), ..rows])
    True, ["\"", "\"", ..rest] ->
      read(rest, delimiter, True, ["\"", ..cell], row, rows)
    True, ["\"", ..rest] -> read(rest, delimiter, False, cell, row, rows)
    True, [grapheme, ..rest] ->
      read(rest, delimiter, True, [grapheme, ..cell], row, rows)
    False, ["\"", ..rest] if cell == [] ->
      read(rest, delimiter, True, cell, row, rows)
    False, ["\n", ..rest] | False, ["\r\n", ..rest] ->
      read(rest, delimiter, False, [], [], [end_row(cell, row), ..rows])
    False, [grapheme, ..rest] if grapheme == delimiter ->
      read(rest, delimiter, False, [], [end_cell(cell), ..row], rows)
    False, [grapheme, ..rest] ->
      read(rest, delimiter, False, [grapheme, ..cell], row, rows)
  }
}

fn end_cell(cell: List(String)) -> String {
  string.concat(list.reverse(cell))
}

fn end_row(cell: List(String), row: List(String)) -> List(String) {
  list.reverse([end_cell(cell), ..row])
}
