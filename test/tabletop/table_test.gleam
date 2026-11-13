import tabletop/table.{Table}

pub fn commas_split_the_cells_test() {
  assert table.parse("name,cost\nKettle,1\nSpoon,2")
    == Table(header: ["name", "cost"], rows: [["Kettle", "1"], ["Spoon", "2"]])
}

pub fn a_tab_in_the_first_line_splits_by_tabs_test() {
  assert table.parse("name\tcost\nKettle, hot\t1")
    == Table(header: ["name", "cost"], rows: [["Kettle, hot", "1"]])
}

pub fn a_quoted_cell_holds_the_delimiter_test() {
  assert table.parse("name,effect\n\"Kettle, hot\",Pour")
    == Table(header: ["name", "effect"], rows: [["Kettle, hot", "Pour"]])
}

pub fn two_quotes_inside_quotes_are_one_quote_test() {
  assert table.parse("name\n\"The \"\"big\"\" spoon\"")
    == Table(header: ["name"], rows: [["The \"big\" spoon"]])
}

pub fn a_quoted_cell_holds_a_line_break_test() {
  assert table.parse("name,effect\nKettle,\"Pour.\nThen wait.\"\nSpoon,Stir")
    == Table(header: ["name", "effect"], rows: [
      ["Kettle", "Pour.\nThen wait."],
      ["Spoon", "Stir"],
    ])
}

pub fn carriage_return_and_line_feed_end_a_row_test() {
  assert table.parse("name,cost\r\nKettle,1\r\nSpoon,2\r\n")
    == Table(header: ["name", "cost"], rows: [["Kettle", "1"], ["Spoon", "2"]])
}

pub fn a_short_row_gets_empty_cells_test() {
  assert table.parse("name,cost,when\nKettle")
    == Table(header: ["name", "cost", "when"], rows: [["Kettle", "", ""]])
}

pub fn blank_lines_are_dropped_test() {
  assert table.parse("\nname,cost\n\nKettle,1\n,\n\n")
    == Table(header: ["name", "cost"], rows: [["Kettle", "1"]])
}

pub fn a_file_with_only_a_header_has_no_rows_test() {
  assert table.parse("name,cost\n") == Table(header: ["name", "cost"], rows: [])
  assert table.parse("") == Table(header: [], rows: [])
}

pub fn a_byte_order_mark_is_not_part_of_the_header_test() {
  assert table.parse("\u{FEFF}name\nKettle")
    == Table(header: ["name"], rows: [["Kettle"]])
}

pub fn semicolons_split_the_cells_test() {
  assert table.parse("name;effect\nKettle;Pour, then wait")
    == Table(header: ["name", "effect"], rows: [["Kettle", "Pour, then wait"]])
}

pub fn pipes_split_the_cells_test() {
  assert table.parse("name|effect\nKettle|Pour; wait")
    == Table(header: ["name", "effect"], rows: [["Kettle", "Pour; wait"]])
}

pub fn the_most_frequent_delimiter_outside_quotes_wins_test() {
  // Two semicolons outside quotes beat the commas inside them.
  assert table.parse("\"name, long\";\"cost, short\";when\nKettle;1;now")
    == Table(header: ["name, long", "cost, short", "when"], rows: [
      ["Kettle", "1", "now"],
    ])
  // A tie goes to tab, then comma, then semicolon, then pipe.
  assert table.parse("a,b;c\n").header == ["a", "b;c"]
  assert table.parse("a|b;c\n").header == ["a|b", "c"]
  assert table.parse("a\tb|c\n").header == ["a", "b|c"]
}
