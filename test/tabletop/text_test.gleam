import gleam/list
import tabletop/text.{type Segment, type Weight, Bold, Link, Regular, Text}

/// The list feature's links: each rule name is its own target.
fn segments(input: String) -> List(Segment(String)) {
  let links =
    ["Steam Vent", "Steam Vent Burst", "Glow 2", "Teatime", "Ab\""]
    |> list.map(fn(name) { #(name, name) })
    |> text.links
  text.segments(input, links)
}

fn rule(name: String, weight: Weight) -> Segment(String) {
  Link(name:, target: name, weight:)
}

pub fn the_longest_rule_name_wins_test() {
  assert segments("Steam Vent Burst also")
    == [rule("Steam Vent Burst", Regular), Text(" also", Regular)]
  assert segments("Steam Vent, but louder")
    == [rule("Steam Vent", Regular), Text(", but louder", Regular)]
}

pub fn a_hyphen_is_a_boundary_test() {
  assert segments("Steam Vent-Fused 3+, Glow 2")
    == [
      rule("Steam Vent", Regular),
      Text("-Fused 3+, ", Regular),
      rule("Glow 2", Regular),
    ]
}

pub fn a_name_needs_a_boundary_on_both_sides_test() {
  assert segments("Steam Ventilator") == [Text("Steam Ventilator", Regular)]
  assert segments("XSteam Vent") == [Text("XSteam Vent", Regular)]
  assert segments("Glow 23") == [Text("Glow 23", Regular)]
  assert segments("(Glow 2)")
    == [Text("(", Regular), rule("Glow 2", Regular), Text(")", Regular)]
}

pub fn a_name_may_end_in_a_quote_mark_test() {
  assert segments("use Ab\" now")
    == [Text("use ", Regular), rule("Ab\"", Regular), Text(" now", Regular)]
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
      rule("Steam Vent Burst", Bold),
      Text(" also spills.\n", Regular),
      rule("Teatime", Regular),
    ]
}

pub fn keyword_markup_is_bold_without_its_carets_test() {
  assert segments("a ^^Abc^^ b")
    == [Text("a ", Regular), Text("Abc", Bold), Text(" b", Regular)]
  // Two pairs in one text.
  assert segments("^^Abc^^ and ^^Def^^.")
    == [
      Text("Abc", Bold),
      Text(" and ", Regular),
      Text("Def", Bold),
      Text(".", Regular),
    ]
  // A lone marker stays as text.
  assert segments("a ^^ b") == [Text("a ^^ b", Regular)]
  assert segments("^^Abc^^ ^^ b") == [Text("Abc", Bold), Text(" ^^ b", Regular)]
}

pub fn a_rule_name_in_keyword_markup_is_a_bold_link_test() {
  assert segments("use ^^Steam Vent^^ now")
    == [
      Text("use ", Regular),
      rule("Steam Vent", Bold),
      Text(" now", Regular),
    ]
}

pub fn bold_and_keyword_markup_in_one_text_test() {
  assert segments("**Abc** then ^^Glow 2^^")
    == [Text("Abc", Bold), Text(" then ", Regular), rule("Glow 2", Bold)]
  assert segments("**a ^^b^^ c**")
    == [Text("a ", Bold), Text("b", Bold), Text(" c", Bold)]
}

pub fn text_with_no_rule_name_is_one_segment_test() {
  assert segments("plain words\nnew line")
    == [Text("plain words\nnew line", Regular)]
  assert segments("") == []
}

pub fn the_first_target_for_a_name_wins_test() {
  let links = text.links([#("Teatime", 1), #("Glow 2", 2), #("Teatime", 3)])
  assert text.segments("Teatime, Glow 2", links)
    == [
      Link("Teatime", 1, Regular),
      Text(", ", Regular),
      Link("Glow 2", 2, Regular),
    ]
}
