//// The text of a table file as rows of cells. The cells are split by tabs
//// when the first line holds a tab, else by commas. A cell in double quotes,
//// as in RFC 4180, may hold the delimiter, line breaks, and `""` for one
//// quote. The first row that is not empty is the header.

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
  let first_line = case string.split_once(text, "\n") {
    Ok(#(line, _)) -> line
    Error(Nil) -> text
  }
  let delimiter = case string.contains(first_line, "\t") {
    True -> "\t"
    False -> ","
  }
  let rows =
    read(string.to_graphemes(text), delimiter, False, [], [], [])
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
