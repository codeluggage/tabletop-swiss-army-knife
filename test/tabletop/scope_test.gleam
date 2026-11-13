import gleam/int
import gleam/list
import gleam/option.{None, Some}
import simplifile
import tabletop/catalogue.{
  type Catalogue, type Condition, type Modifier, And, AtLeast, AtMost, BoolValue,
  Catalogue, CategoryNode, Condition, ConditionGroup, Decrement, Entry,
  EntryLink, EqualTo, ForceNode, GreaterThan, Group, Increment, InstanceOf,
  LessThan, Modifier, NotEqualTo, NotInstanceOf, NumberValue, Or, OtherCondition,
  OtherGroup, ProfileNode, RuleNode, Set, TextValue,
}
import tabletop/data_index
import tabletop/scope.{
  type Item, type Page, type Scope, All, Conditional, CostCondition, CostLine,
  EntryItem, GroupItem, Grouped, Item, KeywordRule, LinkItem, Unlock,
}
import tabletop/sheet.{
  type Rule, Category, Characteristic, Cost, Model, Profile, Rule, Unit, Upgrade,
}
import tabletop/text

/// The scope of the list's catalogue, built the way the app builds it: the
/// index says which files, and those are decoded in its order.
fn picnic() -> Scope {
  let files =
    ["crockery", "pantry", "picnic-system", "teapot"]
    |> list.map(fn(name) {
      let assert Ok(text) =
        simplifile.read("test/fixtures/data/" <> name <> ".json")
      #(name, text)
    })
  let summaries =
    list.map(files, fn(file) {
      let assert Ok(summary) = catalogue.summarise(file.1)
      #(file.0, summary)
    })
  let assert Ok(index) = data_index.build(summaries)
  data_index.scope_files(index, "cat-teapot")
  |> list.map(fn(file) {
    let assert Ok(text) = list.key_find(files, file)
    let assert Ok(decoded) = catalogue.decode(text)
    decoded
  })
  |> scope.build
}

fn page_of(id: String) -> Page {
  let assert Ok(page) = scope.page(picnic(), id)
  page
}

fn profile_names(page: Page) -> List(String) {
  list.map(page.profiles, fn(profile) { profile.name })
}

fn rule_names(rules: List(Rule)) -> List(String) {
  list.map(rules, fn(rule) { rule.name })
}

fn item_ids(items: List(Item)) -> List(String) {
  list.map(items, fn(item) { item.id })
}

fn upgrade(id: String, name: String) -> Item {
  Item(id, name, EntryItem(Upgrade), [])
}

// --- The fixture, case by case ----------------------------------------------

pub fn a_root_link_shows_its_target_from_another_file_test() {
  let assert Ok(link) = scope.find(picnic(), "l-captain")
  let assert Ok(target) = scope.find(picnic(), "e-captain")
  assert #(link.catalogue_id, target.catalogue_id)
    == #("cat-teapot", "cat-pantry")
  let page = page_of("l-captain")
  let assert EntryLink(target_id: "e-captain", ..) = page.node
  assert page.path == []
  assert page.costs == [Cost("acorns", "ct-acorns", 40.0)]
  // The captain's own profile, the shared one its info link points at, then
  // its child's.
  assert profile_names(page) == ["Kettle Captain", "Whistle", "Ladle"]
  assert rule_names(page.own_rules) == ["Steam Vent"]
  assert page.linked_rules == []
  assert page.keywords == [#("c-leader", "Leader"), #("c-kettle", "Kettle")]
  assert page.contains
    == [
      Item("e-ladle", "Ladle", EntryItem(Upgrade), [
        Cost("acorns", "ct-acorns", 5.0),
      ]),
    ]
}

pub fn a_links_own_costs_and_categories_come_first_test() {
  let page = page_of("l-guest-captain")
  assert page.costs == [Cost("acorns", "ct-acorns", 60.0)]
  assert page.keywords
    == [#("c-line", "Line"), #("c-leader", "Leader"), #("c-kettle", "Kettle")]
  // As an item, a link has its own name and costs, or its target's costs
  // when it has none.
  let assert Ok(item) =
    list.find(scope_items("c-line"), fn(item) { item.id == "l-guest-captain" })
  assert item
    == Item("l-guest-captain", "Kettle Captain", LinkItem, [
      Cost("acorns", "ct-acorns", 60.0),
    ])
}

fn scope_items(category_id: String) -> List(Item) {
  page_of(category_id).with_keyword
}

pub fn a_unit_gathers_profiles_from_itself_and_what_it_holds_test() {
  let page = page_of("e-squad")
  let assert Entry(kind: Unit, ..) = page.node
  assert profile_names(page)
    == [
      // Its own profile. The hidden one is left out.
      "Stacking",
      // The info link to a shared profile.
      "Whistle",
      // The info link to a shared info group: its profile, then its own
      // info link's.
      "Tray", "Lid",
      // Its own info group.
      "Stacking Drill",
      // The nested group's model entries. The hidden mascot is left out.
      "Teacup", "Teacup Sergeant",
      // The entry link to a shared entry.
      "Saucer Sling",
      // The two shared groups that link to each other, once each.
      "Crumb", "Jam Pot",
    ]
  // The info link to a rule, which the sling links to as well. The hidden
  // info link to another rule is left out.
  assert rule_names(page.linked_rules) == ["Glow 2"]
  assert page.own_rules == []
  assert page.costs == [Cost("acorns", "ct-acorns", 10.0)]
  assert page.keywords == [#("c-golem", "Golem"), #("c-line", "Line")]
  assert page.contains
    == [
      Item("g-cups", "Cups", GroupItem, []),
      Item("l-squad-sling", "Saucer Sling", LinkItem, []),
      Item("l-squad-crumbs", "Crumbs", LinkItem, []),
    ]
}

pub fn a_link_hidden_by_default_is_conditional_and_brings_no_profiles_test() {
  let page = page_of("e-squad")
  assert !list.contains(profile_names(page), "Banquet Fork")
  assert page.conditional
    == [
      Conditional(Item("l-squad-banquet", "Banquet Cutlery", LinkItem, []), [
        #("f-banquet", "Banquet Table"),
      ]),
    ]
  // The force entry, nested in another in its file, unlocks the link, and
  // the link's group lists its entries.
  let assert ForceNode(name: "Banquet Table", ..) = page_of("f-banquet").node
  assert page_of("f-banquet").unlocks
    == [
      Unlock(Item("l-squad-banquet", "Banquet Cutlery", LinkItem, []), [
        upgrade("e-fork", "Banquet Fork"),
      ]),
    ]
  // Asked for by itself, the hidden link still shows what it holds.
  assert profile_names(page_of("l-squad-banquet")) == ["Banquet Fork"]
}

pub fn a_root_upgrade_links_to_a_group_of_entries_with_rules_test() {
  let page = page_of("e-brew")
  let assert Entry(kind: Upgrade, ..) = page.node
  assert item_ids(page.contains) == ["l-brews", "l-favours"]
  assert page.own_rules == []
  assert rule_names(page.linked_rules)
    == ["Mint Breeze", "Chai Warmth", "Oolong Calm"]
  assert rule_names(page_of("e-chai").own_rules) == ["Chai Warmth"]
  assert page_of("e-chai").path == [#("g-brews", "Brews")]
}

pub fn each_child_group_needs_exactly_its_own_entry_test() {
  let favours = page_of("g-favours")
  assert favours.contains == []
  assert favours.conditional
    == [
      Conditional(Item("g-mint-favours", "Mint Favours", GroupItem, []), [
        #("e-mint", "Mint"),
      ]),
      Conditional(Item("g-chai-favours", "Chai Favours", GroupItem, []), [
        #("e-chai", "Chai"),
      ]),
      Conditional(Item("g-oolong-favours", "Oolong Favours", GroupItem, []), [
        #("e-oolong", "Oolong"),
      ]),
    ]
  // The link to the group gives the same page of children.
  assert page_of("l-favours").conditional == favours.conditional
}

pub fn each_entry_unlocks_exactly_its_own_child_group_test() {
  assert page_of("e-mint").unlocks
    == [
      Unlock(Item("g-mint-favours", "Mint Favours", GroupItem, []), [
        upgrade("e-mint-sprig", "Mint Sprig"),
        upgrade("e-mint-ice", "Mint Ice"),
      ]),
    ]
  assert page_of("e-chai").unlocks
    == [
      Unlock(Item("g-chai-favours", "Chai Favours", GroupItem, []), [
        upgrade("e-chai-spice", "Chai Spice"),
      ]),
    ]
}

pub fn a_hidden_modifier_inside_a_modifier_group_counts_test() {
  assert page_of("e-oolong").unlocks
    == [
      Unlock(Item("g-oolong-favours", "Oolong Favours", GroupItem, []), [
        upgrade("e-oolong-leaf", "Oolong Leaf"),
      ]),
    ]
}

pub fn a_hidden_child_that_a_modifier_shows_is_conditional_test() {
  let mascot = Item("e-mascot", "Sugar Cube Mascot", EntryItem(Model), [])
  let cups = page_of("g-cups")
  assert item_ids(cups.contains) == ["e-teacup", "e-sergeant"]
  assert cups.conditional
    == [Conditional(mascot, [#("e-sergeant", "Teacup Sergeant")])]
  assert page_of("e-sergeant").unlocks == [Unlock(mascot, [])]
  // The page of the hidden node itself still shows it.
  assert profile_names(page_of("e-mascot")) == ["Sugar Cube Mascot"]
  assert page_of("e-mascot").path
    == [#("e-squad", "Teacup Squad"), #("g-cups", "Cups")]
}

pub fn a_cost_modifier_gives_a_cost_line_test() {
  let line =
    CostLine(
      "acorns",
      Set,
      NumberValue(55.0),
      All([CostCondition(AtLeast, 1.0, "e-ladle", "Ladle")]),
    )
  assert page_of("e-captain").cost_lines == [line]
  // A link's page has its target's modifiers.
  assert page_of("l-captain").cost_lines == [line]
  assert page_of("l-guest-captain").cost_lines == [line]
  // A modifier with condition groups says so and lists no conditions.
  assert page_of("e-ladle").cost_lines
    == [CostLine("acorns", Decrement, NumberValue(2.0), Grouped)]
  assert page_of("e-squad").cost_lines == []
}

pub fn the_first_of_two_rules_with_a_name_is_the_link_test() {
  let assert Ok(first) = scope.find(picnic(), "r-steam-vent")
  let assert Ok(second) = scope.find(picnic(), "r-steam-vent-old")
  assert #(first.catalogue_id, first.parent_id) == #("cat-pantry", "e-captain")
  assert #(second.catalogue_id, second.parent_id) == #("sys-picnic", "")
  assert text.segments("Steam Vent or Glow 2", scope.rule_links(picnic()))
    == [
      text.Link("Steam Vent", "r-steam-vent", text.Regular),
      text.Text(" or ", text.Regular),
      text.Link("Glow 2", "r-glow", text.Regular),
    ]
  // Each has its own page.
  assert rule_names(page_of("r-steam-vent-old").own_rules) == ["Steam Vent"]
  let assert RuleNode(Rule(description: "An older wording: puff once.", ..)) =
    page_of("r-steam-vent-old").node
}

pub fn a_category_lists_the_entries_that_have_it_test() {
  let kettle = page_of("c-kettle")
  assert kettle.node == CategoryNode("c-kettle", "Kettle")
  assert kettle.with_keyword
    == [
      Item("e-captain", "Kettle Captain", EntryItem(Model), [
        Cost("acorns", "ct-acorns", 40.0),
      ]),
      // A float cost, and the cost of zero left out.
      Item("e-walker", "Sugar Bowl Walker", EntryItem(Model), [
        Cost("acorns", "ct-acorns", 30.0),
        Cost("favour", "ct-favour", 1.5),
      ]),
    ]
  assert kettle.with_keyword_count == 2
  assert page_of("c-leader").with_keyword_count == 1
  assert page_of("e-captain").with_keyword == []
}

pub fn rules_that_name_a_keyword_are_found_at_word_boundaries_test() {
  let rules = page_of("e-captain").keyword_rules
  // One rule is owned by an entry and one by nothing. The rule with the name
  // inside a longer word is not here.
  assert list.map(rules, fn(found) { #(found.rule.name, found.owner) })
    == [
      #("Mint Breeze", Some(upgrade("e-mint", "Mint"))),
      #("Boil Over", None),
    ]
  let assert [KeywordRule(Rule(id: "r-mint", ..), _), ..] = rules
  // "golem" in a rule's text does not match the keyword "Golem".
  assert page_of("e-squad").keyword_rules == []
  assert page_of("c-kettle").keyword_rules == []
}

pub fn ids_under_constraints_and_conditions_are_not_nodes_test() {
  assert scope.page(picnic(), "k-shared") == Error(Nil)
  assert scope.page(picnic(), "cl-captain-leader") == Error(Nil)
  assert scope.page(picnic(), "il-squad-glow") == Error(Nil)
  let assert Ok(captain) = scope.find(picnic(), "e-captain")
  let assert Entry(name: "Kettle Captain", ..) = captain.node
}

pub fn a_hidden_profile_a_null_text_and_a_float_cost_test() {
  assert !list.contains(profile_names(page_of("e-squad")), "Secret Recipe")
  // Asked for by itself, the hidden profile shows.
  assert profile_names(page_of("p-secret")) == ["Secret Recipe"]
  assert page_of("p-secret").path == [#("e-squad", "Teacup Squad")]
  assert page_of("e-teacup").profiles
    == [
      Profile("p-teacup", "Teacup", "Golem", False, [
        Characteristic("Stride", "6\""),
        Characteristic("Rivets", ""),
      ]),
    ]
  assert page_of("e-walker").costs
    == [Cost("acorns", "ct-acorns", 30.0), Cost("favour", "ct-favour", 1.5)]
  // The walker's hidden rule is left out.
  assert rule_names(page_of("e-walker").own_rules) == ["Steam Vent Burst"]
}

pub fn two_groups_that_link_to_each_other_end_test() {
  assert profile_names(page_of("g-crumbs")) == ["Crumb", "Jam Pot"]
  assert profile_names(page_of("g-jam")) == ["Jam Pot", "Crumb"]
  assert item_ids(page_of("g-jam").contains) == ["e-jam-pot", "l-jam-crumbs"]
}

pub fn the_first_file_to_define_an_id_wins_test() {
  // The library comes before the game system in scope order.
  let assert Ok(golem) = scope.find(picnic(), "c-golem")
  assert golem
    == scope.Placed(CategoryNode("c-golem", "Golem"), "", "cat-pantry")
}

pub fn info_groups_and_profiles_have_pages_test() {
  assert profile_names(page_of("ig-tea-service")) == ["Tray", "Lid"]
  assert profile_names(page_of("ig-drill")) == ["Stacking Drill"]
  let assert ProfileNode(Profile(name: "Whistle", ..)) =
    page_of("p-whistle").node
  assert profile_names(page_of("p-whistle")) == ["Whistle"]
}

pub fn an_unknown_id_has_no_page_test() {
  assert scope.page(picnic(), "e-marmalade") == Error(Nil)
  assert scope.page(picnic(), "") == Error(Nil)
  assert scope.page(scope.build([]), "e-squad") == Error(Nil)
}

// --- Hand-made scopes -------------------------------------------------------

fn entry(id: String, name: String) -> catalogue.Node {
  Entry(
    id:,
    name:,
    kind: Upgrade,
    hidden: False,
    costs: [],
    categories: [],
    profiles: [],
    rules: [],
    info_links: [],
    info_groups: [],
    children: [],
    modifiers: [],
  )
}

fn file(shared: List(catalogue.Node)) -> Catalogue {
  Catalogue(False, "cat-made", "Made", False, [], [], shared)
}

pub fn a_category_lists_a_hundred_items_and_counts_them_all_test() {
  let entries =
    int.range(from: 130, to: 0, with: [], run: fn(entries, n) {
      let name = "Cup " <> int.to_string(1000 - n)
      let assert Entry(..) as cup = entry("e-" <> int.to_string(n), name)
      [Entry(..cup, categories: [Category("c-cup", "Cup", False)]), ..entries]
    })
  let made = scope.build([file([CategoryNode("c-cup", "Cup"), ..entries])])
  let assert Ok(page) = scope.page(made, "c-cup")
  assert page.with_keyword_count == 130
  assert list.length(page.with_keyword) == 100
  // Sorted by name, so the highest numbers come first.
  assert list.map(list.take(page.with_keyword, 2), fn(item) { item.name })
    == ["Cup 870", "Cup 871"]
}

pub fn keyword_rules_leave_out_shown_hidden_and_short_named_test() {
  let rule = fn(id, description, hidden) {
    Rule(id, "Rule " <> id, description, hidden)
  }
  let assert Entry(..) as plain = entry("e-pot", "Pot")
  let pot =
    Entry(
      ..plain,
      categories: [
        Category("c-brass", "Brass", False),
        Category("c-up", "Up", False),
      ],
      rules: [rule("r-own", "Brass rings.", False)],
    )
  let made =
    scope.build([
      file([
        pot,
        RuleNode(rule("r-brass", "Polish the Brass.", False)),
        RuleNode(rule("r-hidden", "Brass, unseen.", True)),
        RuleNode(rule("r-up", "Up we go.", False)),
      ]),
    ])
  let assert Ok(page) = scope.page(made, "e-pot")
  assert rule_names(page.own_rules) == ["Rule r-own"]
  // The pot's own rule, the hidden rule and the rule that names only the
  // two-letter keyword are left out.
  assert page.keyword_rules
    == [KeywordRule(rule("r-brass", "Polish the Brass.", False), None)]
}

pub fn a_node_with_no_id_is_left_out_test() {
  let made =
    scope.build([
      file([RuleNode(Rule("", "Nameless", "", False)), entry("e-pot", "Pot")]),
    ])
  assert scope.page(made, "") == Error(Nil)
  let assert Ok(_) = scope.page(made, "e-pot")
}

pub fn a_link_to_nothing_still_has_a_page_test() {
  let lost =
    EntryLink(
      id: "l-lost",
      name: "Lost",
      target_id: "e-gone",
      target_kind: catalogue.ToEntry,
      hidden: False,
      costs: [Cost("acorns", "ct-acorns", 3.0)],
      categories: [],
      profiles: [Profile("p-lost", "Lost", "Gadget", False, [])],
      info_links: [catalogue.InfoLink("il-lost", "Gone", "p-gone", False)],
      children: [],
      modifiers: [],
    )
  let assert Ok(page) = scope.page(scope.build([file([lost])]), "l-lost")
  assert page.costs == [Cost("acorns", "ct-acorns", 3.0)]
  assert profile_names(page) == ["Lost"]
}

// --- Visibility when nothing is chosen --------------------------------------

fn when(kind: catalogue.ConditionKind, value: Float) -> Condition {
  Condition(kind, "selections", "roster", value, "e-any")
}

fn hide(conditions: List(Condition)) -> Modifier {
  Modifier(Set, "hidden", BoolValue(True), conditions, [])
}

fn show(conditions: List(Condition)) -> Modifier {
  Modifier(Set, "hidden", BoolValue(False), conditions, [])
}

/// Whether a condition holds for a count of zero: a visible node with one
/// modifier that hides it on this condition.
fn holds(kind: catalogue.ConditionKind, value: Float) -> Bool {
  scope.hidden_by_default(False, [hide([when(kind, value)])])
}

pub fn hidden_starts_from_the_nodes_own_flag_test() {
  assert !scope.hidden_by_default(False, [])
  assert scope.hidden_by_default(True, [])
}

pub fn each_condition_kind_is_checked_against_a_count_of_zero_test() {
  assert holds(LessThan, 1.0)
  assert !holds(LessThan, 0.0)
  assert holds(AtMost, 0.0)
  assert !holds(AtMost, -1.0)
  assert holds(AtLeast, 0.0)
  assert !holds(AtLeast, 1.0)
  assert holds(GreaterThan, -1.0)
  assert !holds(GreaterThan, 0.0)
  assert holds(EqualTo, 0.0)
  assert !holds(EqualTo, 1.0)
  assert holds(NotEqualTo, 1.0)
  assert !holds(NotEqualTo, 0.0)
  assert holds(NotInstanceOf, 1.0)
  assert !holds(InstanceOf, 0.0)
  assert !holds(OtherCondition("before"), 0.0)
}

pub fn a_modifier_holds_when_all_its_conditions_and_groups_hold_test() {
  let yes = when(LessThan, 1.0)
  let no = when(AtLeast, 1.0)
  let grouped = fn(kind, conditions, groups) {
    scope.hidden_by_default(False, [
      Modifier(Set, "hidden", BoolValue(True), [], [
        ConditionGroup(kind, conditions, groups),
      ]),
    ])
  }
  // A modifier with no condition holds.
  assert scope.hidden_by_default(False, [hide([])])
  assert scope.hidden_by_default(False, [hide([yes, yes])])
  assert !scope.hidden_by_default(False, [hide([yes, no])])
  // An and group needs every part, an or group any part.
  assert grouped(And, [yes, yes], [])
  assert !grouped(And, [yes, no], [])
  assert grouped(And, [], [])
  assert grouped(Or, [no, yes], [])
  assert !grouped(Or, [no, no], [])
  assert !grouped(Or, [], [])
  // Groups inside groups.
  assert grouped(And, [yes], [ConditionGroup(Or, [no, yes], [])])
  assert !grouped(And, [yes], [ConditionGroup(Or, [no], [])])
  assert grouped(Or, [no], [ConditionGroup(And, [yes], [])])
  // Any other kind of group never holds.
  assert !grouped(OtherGroup("count"), [yes], [])
  // Conditions and groups together: both must hold.
  let both = fn(condition, group_condition) {
    scope.hidden_by_default(False, [
      Modifier(Set, "hidden", BoolValue(True), [condition], [
        ConditionGroup(And, [group_condition], []),
      ]),
    ])
  }
  assert both(yes, yes)
  assert !both(yes, no)
  assert !both(no, yes)
}

pub fn modifiers_apply_in_order_and_only_those_that_set_hidden_test() {
  assert !scope.hidden_by_default(False, [hide([]), show([])])
  assert scope.hidden_by_default(False, [show([]), hide([])])
  assert !scope.hidden_by_default(True, [show([when(AtLeast, 0.0)])])
  assert scope.hidden_by_default(True, [show([when(AtLeast, 1.0)])])
  // Another kind, another field, or a value that is not a bool: ignored.
  assert !scope.hidden_by_default(False, [
    Modifier(Increment, "hidden", BoolValue(True), [], []),
    Modifier(Set, "name", BoolValue(True), [], []),
    Modifier(Set, "hidden", TextValue("true"), [], []),
    Modifier(Set, "hidden", NumberValue(1.0), [], []),
  ])
}

// --- Needs ------------------------------------------------------------------

fn on(kind: catalogue.ConditionKind, child_id: String) -> Condition {
  Condition(kind, "selections", "roster", 1.0, child_id)
}

fn every_kind() -> List(Condition) {
  [
    on(LessThan, "less"),
    on(AtMost, "most"),
    on(EqualTo, "equal"),
    on(NotInstanceOf, "not-instance"),
    on(AtLeast, "least"),
    on(GreaterThan, "greater"),
    on(NotEqualTo, "not-equal"),
    on(InstanceOf, "instance"),
    on(OtherCondition("before"), "other"),
  ]
}

pub fn a_modifier_that_hides_needs_what_would_stop_it_holding_test() {
  assert scope.needs([hide(every_kind())])
    == ["less", "most", "equal", "not-instance"]
}

pub fn a_modifier_that_shows_needs_what_would_make_it_hold_test() {
  assert scope.needs([show(every_kind())])
    == ["least", "greater", "not-equal", "instance"]
}

pub fn needs_look_into_groups_at_any_depth_test() {
  let deep =
    Modifier(Set, "hidden", BoolValue(True), [on(LessThan, "direct")], [
      ConditionGroup(Or, [on(AtMost, "in-or"), on(AtLeast, "not-this")], [
        ConditionGroup(And, [on(EqualTo, "in-and")], [
          ConditionGroup(OtherGroup("count"), [on(LessThan, "deepest")], []),
        ]),
      ]),
    ])
  assert scope.needs([deep]) == ["direct", "in-or", "in-and", "deepest"]
}

pub fn needs_have_no_repeats_and_skip_what_is_not_about_hidden_test() {
  assert scope.needs([
      hide([on(LessThan, "a"), on(LessThan, "")]),
      show([on(AtLeast, "b"), on(AtLeast, "a")]),
      Modifier(Set, "name", TextValue("New"), [on(LessThan, "c")], []),
      Modifier(Increment, "hidden", BoolValue(True), [on(LessThan, "d")], []),
      Modifier(Set, "hidden", TextValue("true"), [on(LessThan, "e")], []),
    ])
    == ["a", "b"]
  assert scope.needs([]) == []
}

pub fn unlocks_keep_only_ids_that_are_nodes_test() {
  let assert Entry(..) as plain = entry("e-jar", "Jar")
  let jar =
    Entry(..plain, modifiers: [
      hide([on(LessThan, "e-lid"), on(LessThan, "e-gone")]),
    ])
  let made = scope.build([file([jar, entry("e-lid", "Lid")])])
  let assert Ok(lid) = scope.page(made, "e-lid")
  assert lid.unlocks == [Unlock(upgrade("e-jar", "Jar"), [])]
  // At the top level the jar is nobody's child, so no page lists it as
  // conditional, and the id that is no node is dropped from its needs.
  let made = scope.build([file([Group("g-shelf", "Shelf", False, [jar], [])])])
  let assert Ok(shelf) = scope.page(made, "g-shelf")
  assert shelf.conditional == [Conditional(upgrade("e-jar", "Jar"), [])]
}
