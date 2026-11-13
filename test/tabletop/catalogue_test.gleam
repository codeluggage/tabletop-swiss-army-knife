import gleam/list
import simplifile
import tabletop/catalogue.{
  type Catalogue, type Node, Add, And, Append, AtLeast, AtMost, BoolValue,
  Catalogue, CategoryNode, Condition, ConditionGroup, Decrement, Entry,
  EntryLink, EntryRoot, EqualTo, ForceNode, GreaterThan, Group, Increment,
  InfoGroup, InfoGroupNode, InfoLink, InstanceOf, LessThan, Link, LinkRoot,
  Modifier, NoCatalogue, NoValue, NotEqualTo, NotInstanceOf, NotJson,
  NumberValue, Or, OtherCondition, OtherGroup, OtherModifier, OtherTarget,
  ProfileNode, Remove, RuleNode, Set, SharedSummary, Summary, TextValue, ToEntry,
  ToGroup, UnexpectedShape,
}
import tabletop/sheet.{
  Category, Characteristic, Cost, Model, OtherKind, Profile, Rule, Unit, Upgrade,
}

fn read(file: String) -> String {
  let assert Ok(text) = simplifile.read("test/fixtures/" <> file)
  text
}

fn decoded(file: String) -> Catalogue {
  let assert Ok(catalogue) = catalogue.decode(read(file))
  catalogue
}

fn ids(nodes: List(Node)) -> List(String) {
  list.map(nodes, catalogue.id)
}

/// The node with this id, at any depth of the file.
fn node(file: String, id: String) -> Node {
  let catalogue = decoded(file)
  let assert Ok(node) = find(list.append(catalogue.roots, catalogue.shared), id)
  node
}

fn find(nodes: List(Node), id: String) -> Result(Node, Nil) {
  list.find_map(nodes, fn(node) {
    case catalogue.id(node) == id, node {
      True, _ -> Ok(node)
      False, Entry(children:, ..)
      | False, Group(children:, ..)
      | False, EntryLink(children:, ..)
      -> find(children, id)
      False, _ -> Error(Nil)
    }
  })
}

fn modifiers(file: String, id: String) -> List(catalogue.Modifier) {
  case node(file, id) {
    Entry(modifiers:, ..) | Group(modifiers:, ..) | EntryLink(modifiers:, ..) ->
      modifiers
    _ -> []
  }
}

fn hides(conditions: List(catalogue.Condition)) -> catalogue.Modifier {
  Modifier(Set, "hidden", BoolValue(True), conditions, [])
}

fn count(
  kind: catalogue.ConditionKind,
  child_id: String,
) -> catalogue.Condition {
  Condition(kind, "selections", "roster", 1.0, child_id)
}

// --- The game system --------------------------------------------------------

pub fn the_game_system_decodes_test() {
  let system = decoded("data/picnic-system.json")
  assert Catalogue(..system, roots: [], shared: [])
    == Catalogue(True, "sys-picnic", "Picnic Skirmish", False, [], [], [])
  let assert [Entry(name: "Weather", kind: Upgrade, children:, ..)] =
    system.roots
  assert ids(children) == ["e-drizzle", "e-sunshine"]
  // Shared rules, then rules, then categories, then force entries with the
  // nested one beside its parent.
  assert ids(system.shared)
    == [
      "r-steam-vent-old", "r-boil-over", "r-drums", "r-teatime", "c-leader",
      "c-line", "c-kettle", "c-golem", "f-picnic", "f-banquet",
    ]
  assert node("data/picnic-system.json", "c-kettle")
    == CategoryNode("c-kettle", "Kettle")
  assert node("data/picnic-system.json", "f-banquet")
    == ForceNode("f-banquet", "Banquet Table")
  assert node("data/picnic-system.json", "r-drums")
    == RuleNode(Rule(
      "r-drums",
      "Morning Drums",
      "Kettledrums sound at dawn.",
      False,
    ))
}

pub fn the_game_system_summarises_test() {
  assert catalogue.summarise(read("data/picnic-system.json"))
    == Ok(
      Summary(
        game_system: True,
        id: "sys-picnic",
        name: "Picnic Skirmish",
        library: False,
        links: [],
        roots: [EntryRoot("e-weather", "Weather", Upgrade, "", True)],
        shared: [],
      ),
    )
}

// --- The library ------------------------------------------------------------

pub fn the_library_decodes_test() {
  let pantry = decoded("data/pantry.json")
  assert Catalogue(..pantry, roots: [], shared: [])
    == Catalogue(False, "cat-pantry", "Pantry", True, [], [], [])
  assert pantry.roots
    == [
      EntryLink(
        id: "l-walker",
        name: "Sugar Bowl Walker",
        target_id: "e-walker",
        target_kind: ToEntry,
        hidden: False,
        costs: [],
        categories: [],
        profiles: [],
        info_links: [],
        children: [],
        modifiers: [],
      ),
    ]
  // Shared entries, groups, profiles, rules, info groups, then categories.
  assert ids(pantry.shared)
    == [
      "e-captain", "e-walker", "e-sling", "g-banquet", "g-crumbs", "g-jam",
      "p-whistle", "p-lid", "r-glow", "ig-tea-service", "c-golem",
    ]
}

pub fn an_entry_holds_everything_the_file_gives_it_test() {
  let assert Entry(
    name: "Kettle Captain",
    kind: Model,
    hidden: False,
    costs:,
    categories:,
    profiles:,
    rules:,
    info_links:,
    info_groups: [],
    children:,
    modifiers:,
    ..,
  ) = node("data/pantry.json", "e-captain")
  assert costs == [Cost("acorns", "ct-acorns", 40.0)]
  assert categories
    == [
      Category("c-leader", "Leader", True),
      Category("c-kettle", "Kettle", False),
    ]
  assert profiles
    == [
      Profile("p-captain", "Kettle Captain", "Golem", False, [
        Characteristic("Stride", "5\""),
        Characteristic("Grip", "3+"),
      ]),
    ]
  assert rules
    == [
      Rule(
        "r-steam-vent",
        "Steam Vent",
        "Puff once.\nThen **puff again**.",
        False,
      ),
    ]
  assert info_links
    == [InfoLink("il-captain-whistle", "Whistle", "p-whistle", False)]
  assert ids(children) == ["e-ladle"]
  // The cost type's id is the field, and the constraints beside the modifier
  // are not read.
  assert modifiers
    == [
      Modifier(
        Set,
        "ct-acorns",
        NumberValue(55.0),
        [Condition(AtLeast, "selections", "self", 1.0, "e-ladle")],
        [],
      ),
    ]
}

pub fn a_cost_value_may_be_a_float_test() {
  let assert Entry(costs:, ..) = node("data/pantry.json", "e-walker")
  assert costs
    == [
      Cost("acorns", "ct-acorns", 30.0),
      Cost("favour", "ct-favour", 1.5),
      Cost("crumbs", "ct-crumbs", 0.0),
    ]
}

pub fn a_condition_group_keeps_its_kind_and_parts_test() {
  assert modifiers("data/pantry.json", "e-ladle")
    == [
      Modifier(Decrement, "ct-acorns", NumberValue(2.0), [], [
        ConditionGroup(
          And,
          [Condition(AtLeast, "selections", "roster", 2.0, "e-captain")],
          [],
        ),
      ]),
    ]
  let assert [Modifier(groups: [ConditionGroup(Or, [_], [])], ..), _] =
    modifiers("data/crockery.json", "g-chai-favours")
}

pub fn an_info_group_holds_profiles_and_info_links_test() {
  assert node("data/pantry.json", "ig-tea-service")
    == InfoGroupNode(
      InfoGroup(
        "ig-tea-service",
        "Tea Service",
        False,
        [
          Profile("p-tray", "Tray", "Gadget", False, [
            Characteristic("Reach", "0\""),
          ]),
        ],
        [InfoLink("il-service-lid", "Lid", "p-lid", False)],
      ),
    )
  let assert ProfileNode(Profile(name: "Lid", ..)) =
    node("data/pantry.json", "p-lid")
}

pub fn the_library_summarises_test() {
  assert catalogue.summarise(read("data/pantry.json"))
    == Ok(
      Summary(
        game_system: False,
        id: "cat-pantry",
        name: "Pantry",
        library: True,
        links: [],
        roots: [LinkRoot("l-walker", "Sugar Bowl Walker", "e-walker", "", True)],
        shared: [
          SharedSummary("e-captain", Model, "Leader", True),
          SharedSummary("e-walker", Model, "", True),
          SharedSummary("e-sling", Upgrade, "", True),
        ],
      ),
    )
}

// --- The catalogue that imports the library ---------------------------------

pub fn the_importing_catalogue_decodes_test() {
  let crockery = decoded("data/crockery.json")
  assert Catalogue(..crockery, roots: [], shared: [])
    == Catalogue(
      False,
      "cat-crockery",
      "Crockery",
      False,
      [Link("cat-pantry", True)],
      [],
      [],
    )
  // Root entry links come before root entries.
  assert ids(crockery.roots) == ["l-guest-captain", "e-brew"]
  assert ids(crockery.shared) == ["g-brews", "g-favours"]
  let assert EntryLink(costs:, categories:, target_kind: ToEntry, ..) =
    node("data/crockery.json", "l-guest-captain")
  assert costs == [Cost("acorns", "ct-acorns", 60.0)]
  assert categories == [Category("c-line", "Line", True)]
  let assert Group(children:, ..) = node("data/crockery.json", "g-favours")
  assert ids(children)
    == ["g-mint-favours", "g-chai-favours", "g-oolong-favours"]
}

pub fn a_modifier_group_folds_into_the_nodes_modifiers_test() {
  assert modifiers("data/crockery.json", "g-mint-favours")
    == [hides([count(LessThan, "e-mint")]), hides([count(AtLeast, "e-chai")])]
  // The node's own modifier first, then the one from the modifier group with
  // the group's condition.
  assert modifiers("data/crockery.json", "g-oolong-favours")
    == [hides([count(AtLeast, "e-mint")]), hides([count(LessThan, "e-oolong")])]
}

pub fn a_nested_modifier_group_adds_every_group_around_it_test() {
  let condition = fn(kind, value, child_id) {
    Condition(kind, "", "", value, child_id)
  }
  let outer = condition(AtLeast, 1.0, "outer")
  assert modifiers("every-kind.json", "e-grouped")
    == [
      Modifier(Add, "category", TextValue("c-own"), [], []),
      Modifier(
        Set,
        "hidden",
        BoolValue(True),
        [condition(LessThan, 1.0, "own"), outer],
        [ConditionGroup(Or, [], [])],
      ),
      Modifier(
        Set,
        "hidden",
        BoolValue(False),
        [condition(AtMost, 0.0, "inner"), outer],
        [ConditionGroup(Or, [], [])],
      ),
    ]
}

pub fn the_importing_catalogue_summarises_test() {
  assert catalogue.summarise(read("data/crockery.json"))
    == Ok(Summary(
      game_system: False,
      id: "cat-crockery",
      name: "Crockery",
      library: False,
      links: [Link("cat-pantry", True)],
      // The link's own primary category.
      roots: [
        LinkRoot("l-guest-captain", "Kettle Captain", "e-captain", "Line", True),
        EntryRoot("e-brew", "Brew", Upgrade, "", True),
      ],
      shared: [],
    ))
}

// --- The catalogue the list uses --------------------------------------------

pub fn the_lists_catalogue_decodes_test() {
  let teapot = decoded("data/teapot.json")
  assert Catalogue(..teapot, roots: [], shared: [])
    == Catalogue(
      False,
      "cat-teapot",
      "Teapot Golems",
      False,
      [Link("cat-crockery", True)],
      [],
      [],
    )
  assert ids(teapot.roots) == ["l-captain", "l-squad"]
  assert ids(teapot.shared) == ["e-squad"]
}

pub fn children_are_entries_then_groups_then_links_test() {
  let assert Entry(
    kind: Unit,
    children:,
    info_links:,
    info_groups:,
    profiles:,
    ..,
  ) = node("data/teapot.json", "e-squad")
  assert ids(children)
    == ["g-cups", "l-squad-sling", "l-squad-banquet", "l-squad-crumbs"]
  assert list.map(info_links, fn(link) { #(link.target_id, link.hidden) })
    == [
      #("p-whistle", False),
      #("r-glow", False),
      #("ig-tea-service", False),
      #("r-teatime", True),
    ]
  let assert [InfoGroup(id: "ig-drill", name: "Drill", profiles: [_], ..)] =
    info_groups
  assert list.map(profiles, fn(profile) { #(profile.name, profile.hidden) })
    == [#("Stacking", False), #("Secret Recipe", True)]
  let assert Group(name: "Cups", children: cups, ..) =
    node("data/teapot.json", "g-cups")
  assert ids(cups) == ["e-teacup", "e-sergeant", "e-mascot"]
}

pub fn a_null_text_is_empty_test() {
  let assert Entry(profiles: [profile], ..) =
    node("data/teapot.json", "e-teacup")
  assert profile.characteristics
    == [Characteristic("Stride", "6\""), Characteristic("Rivets", "")]
}

pub fn hidden_and_its_modifiers_are_read_test() {
  let assert Entry(hidden: True, modifiers:, ..) =
    node("data/teapot.json", "e-mascot")
  assert modifiers
    == [
      Modifier(
        Set,
        "hidden",
        BoolValue(False),
        [Condition(AtLeast, "selections", "parent", 1.0, "e-sergeant")],
        [],
      ),
    ]
  let assert EntryLink(
    target_id: "g-banquet",
    target_kind: ToGroup,
    modifiers:,
    ..,
  ) = node("data/teapot.json", "l-squad-banquet")
  assert modifiers
    == [hides([Condition(LessThan, "forces", "roster", 1.0, "f-banquet")])]
}

pub fn the_lists_catalogue_summarises_test() {
  assert catalogue.summarise(read("data/teapot.json"))
    == Ok(
      Summary(
        game_system: False,
        id: "cat-teapot",
        name: "Teapot Golems",
        library: False,
        links: [Link("cat-crockery", True)],
        roots: [
          LinkRoot("l-captain", "Kettle Captain", "e-captain", "", True),
          LinkRoot("l-squad", "Teacup Squad", "e-squad", "", True),
        ],
        shared: [SharedSummary("e-squad", Unit, "Line", True)],
      ),
    )
}

// --- Kinds ------------------------------------------------------------------

pub fn an_import_flag_that_is_null_or_missing_is_false_test() {
  assert decoded("every-kind.json").links
    == [
      Link("cat-a", False),
      Link("cat-b", False),
      Link("cat-c", False),
      Link("cat-d", True),
    ]
}

pub fn every_kind_has_a_variant_and_the_rest_keep_their_string_test() {
  let kinds =
    list.map(decoded("every-kind.json").shared, fn(node) {
      let assert Entry(kind:, ..) = node
      kind
    })
  assert kinds
    == [Unit, Model, Upgrade, OtherKind("crew"), OtherKind(""), OtherKind("")]

  let assert Entry(children:, modifiers:, ..) =
    node("every-kind.json", "e-plain")
  let targets =
    list.map(children, fn(child) {
      let assert EntryLink(target_kind:, ..) = child
      target_kind
    })
  assert targets == [ToEntry, ToGroup, OtherTarget("shortcut"), OtherTarget("")]

  assert list.map(modifiers, fn(modifier) { #(modifier.kind, modifier.value) })
    == [
      #(Set, TextValue("Renamed")),
      #(Increment, NumberValue(2.0)),
      #(Decrement, NumberValue(0.5)),
      #(Append, TextValue(" (old)")),
      #(Add, TextValue("c-line")),
      #(Remove, TextValue("c-line")),
      #(OtherModifier("multiply"), NumberValue(2.0)),
      #(OtherModifier(""), NoValue),
      #(Set, BoolValue(True)),
    ]

  let assert Ok(Modifier(conditions:, groups:, ..)) = list.last(modifiers)
  let assert [first, second, ..] = conditions
  assert first == Condition(AtLeast, "selections", "self", 1.0, "a")
  assert second == Condition(AtMost, "", "", 2.5, "")
  assert list.map(conditions, fn(condition) { condition.kind })
    == [
      AtLeast,
      AtMost,
      GreaterThan,
      LessThan,
      EqualTo,
      NotEqualTo,
      InstanceOf,
      NotInstanceOf,
      OtherCondition("before"),
      OtherCondition(""),
    ]
  assert groups
    == [
      ConditionGroup(And, [], [ConditionGroup(Or, [], [])]),
      ConditionGroup(OtherGroup("count"), [], []),
      ConditionGroup(OtherGroup(""), [], []),
    ]
}

// --- Errors -----------------------------------------------------------------

pub fn text_that_is_not_json_is_not_json_test() {
  assert catalogue.decode("") == Error(NotJson)
  assert catalogue.decode("{\"catalogue\": ") == Error(NotJson)
  assert catalogue.summarise("not json") == Error(NotJson)
}

pub fn json_without_a_catalogue_has_no_catalogue_test() {
  let list_file = read("invented-list.json")
  assert catalogue.decode(list_file) == Error(NoCatalogue)
  assert catalogue.summarise(list_file) == Error(NoCatalogue)
  assert catalogue.decode("[1, 2]") == Error(NoCatalogue)
  assert catalogue.decode("{\"catalogue\": \"a name\"}") == Error(NoCatalogue)
  assert catalogue.summarise("{\"gameSystem\": null}") == Error(NoCatalogue)
}

pub fn a_file_of_the_wrong_shape_says_where_test() {
  assert catalogue.decode("{\"catalogue\": {}}")
    == Error(UnexpectedShape(at: "catalogue.id"))
  assert catalogue.summarise("{\"gameSystem\": {\"id\": 4}}")
    == Error(UnexpectedShape(at: "gameSystem.id"))
  assert catalogue.summarise(
      "{\"catalogue\": {\"id\": \"c\", \"entryLinks\": [{\"id\": \"l\", \"name\": \"L\"}]}}",
    )
    == Error(UnexpectedShape(at: "catalogue.entryLinks.0.targetId"))
}

pub fn the_shallow_read_does_not_walk_into_children_test() {
  // The nested entry has no id: the full decode says so, and the shallow read
  // never looks at it.
  let text =
    "{\"catalogue\": {\"id\": \"c\", \"sharedSelectionEntries\": [{\"id\": \"e\", \"name\": \"E\", \"selectionEntries\": [{\"name\": \"no id\"}]}]}}"
  assert catalogue.decode(text)
    == Error(UnexpectedShape(
      at: "catalogue.sharedSelectionEntries.0.selectionEntries.0.id",
    ))
  assert catalogue.summarise(text)
    == Ok(
      Summary(False, "c", "", False, [], [], [
        SharedSummary("e", OtherKind(""), "", True),
      ]),
    )
}

pub fn the_shallow_read_records_whether_a_root_shows_test() {
  let hidden_without_jug =
    "\"modifiers\": [{\"type\": \"set\", \"field\": \"hidden\", \"value\": true, \"conditions\": [{\"type\": \"lessThan\", \"value\": 1, \"field\": \"selections\", \"scope\": \"roster\", \"childId\": \"e-jug\"}]}]"
  let shown_again =
    "\"modifierGroups\": [{\"modifiers\": [{\"type\": \"set\", \"field\": \"hidden\", \"value\": false}]}]"
  let text =
    "{\"catalogue\": {\"id\": \"c\", \"entryLinks\": [{\"id\": \"l-jug\", \"name\": \"Jug\", \"targetId\": \"e-jug\"}, {\"id\": \"l-cup\", \"name\": \"Cup\", \"targetId\": \"e-cup\", "
    <> hidden_without_jug
    <> "}], \"selectionEntries\": [{\"id\": \"e-mug\", \"name\": \"Mug\"}, {\"id\": \"e-urn\", \"name\": \"Urn\", \"hidden\": true}, {\"id\": \"e-pot\", \"name\": \"Pot\", \"hidden\": true, "
    <> shown_again
    <> "}], \"sharedSelectionEntries\": [{\"id\": \"e-jug\", \"name\": \"Jug\", \"hidden\": true}]}}"
  let assert Ok(summary) = catalogue.summarise(text)
  assert summary.roots
    == [
      LinkRoot("l-jug", "Jug", "e-jug", "", True),
      // A modifier hides the link when nothing is chosen.
      LinkRoot("l-cup", "Cup", "e-cup", "", False),
      EntryRoot("e-mug", "Mug", OtherKind(""), "", True),
      EntryRoot("e-urn", "Urn", OtherKind(""), "", False),
      // A modifier in a modifier group shows it again.
      EntryRoot("e-pot", "Pot", OtherKind(""), "", True),
    ]
  assert summary.shared == [SharedSummary("e-jug", OtherKind(""), "", False)]
}

pub fn a_minimal_file_decodes_test() {
  assert catalogue.decode("{\"catalogue\": {\"id\": \"c\"}}")
    == Ok(Catalogue(False, "c", "", False, [], [], []))
  assert catalogue.decode("{\"gameSystem\": {\"id\": \"s\"}}")
    == Ok(Catalogue(True, "s", "", False, [], [], []))
}

// --- Visibility when nothing is chosen --------------------------------------

fn when(kind: catalogue.ConditionKind, value: Float) -> catalogue.Condition {
  Condition(kind, "selections", "roster", value, "e-any")
}

fn shows(conditions: List(catalogue.Condition)) -> catalogue.Modifier {
  Modifier(Set, "hidden", BoolValue(False), conditions, [])
}

/// Whether a condition holds for a count of zero: a visible node with one
/// modifier that hides it on this condition.
fn holds(kind: catalogue.ConditionKind, value: Float) -> Bool {
  catalogue.hidden_by_default(False, [hides([when(kind, value)])])
}

pub fn hidden_starts_from_the_nodes_own_flag_test() {
  assert !catalogue.hidden_by_default(False, [])
  assert catalogue.hidden_by_default(True, [])
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
    catalogue.hidden_by_default(False, [
      Modifier(Set, "hidden", BoolValue(True), [], [
        ConditionGroup(kind, conditions, groups),
      ]),
    ])
  }
  // A modifier with no condition holds.
  assert catalogue.hidden_by_default(False, [hides([])])
  assert catalogue.hidden_by_default(False, [hides([yes, yes])])
  assert !catalogue.hidden_by_default(False, [hides([yes, no])])
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
    catalogue.hidden_by_default(False, [
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
  assert !catalogue.hidden_by_default(False, [hides([]), shows([])])
  assert catalogue.hidden_by_default(False, [shows([]), hides([])])
  assert !catalogue.hidden_by_default(True, [shows([when(AtLeast, 0.0)])])
  assert catalogue.hidden_by_default(True, [shows([when(AtLeast, 1.0)])])
  // Another kind, another field, or a value that is not a bool: ignored.
  assert !catalogue.hidden_by_default(False, [
    Modifier(Increment, "hidden", BoolValue(True), [], []),
    Modifier(Set, "name", BoolValue(True), [], []),
    Modifier(Set, "hidden", TextValue("true"), [], []),
    Modifier(Set, "hidden", NumberValue(1.0), [], []),
  ])
}

// --- Needs ------------------------------------------------------------------

fn at(
  kind: catalogue.ConditionKind,
  value: Float,
  child_id: String,
) -> catalogue.Condition {
  Condition(kind, "selections", "roster", value, child_id)
}

fn group(
  kind: catalogue.GroupKind,
  conditions: List(catalogue.Condition),
) -> catalogue.ConditionGroup {
  ConditionGroup(kind, conditions, [])
}

fn hides_when(groups: List(catalogue.ConditionGroup)) -> catalogue.Modifier {
  Modifier(Set, "hidden", BoolValue(True), [], groups)
}

pub fn a_modifier_that_hides_needs_any_one_that_stops_it_holding_test() {
  // Every condition holds with nothing chosen, and choosing any one child of
  // a presence condition makes it fail.
  assert catalogue.needs([
      hides([
        at(LessThan, 1.0, "less"),
        at(AtMost, 0.0, "most"),
        at(EqualTo, 0.0, "equal"),
        at(NotInstanceOf, 1.0, "not-instance"),
        at(AtLeast, 0.0, "least"),
        at(GreaterThan, -1.0, "greater"),
        at(NotEqualTo, 1.0, "not-equal"),
      ]),
    ])
    == [["less", "most", "equal", "not-instance"]]
}

pub fn a_modifier_that_shows_needs_each_that_makes_it_hold_test() {
  assert catalogue.needs([
      shows([
        count(LessThan, "less"),
        count(AtMost, "most"),
        count(EqualTo, "equal"),
        count(NotInstanceOf, "not-instance"),
        count(AtLeast, "least"),
        count(GreaterThan, "greater"),
        count(NotEqualTo, "not-equal"),
        count(InstanceOf, "instance"),
        count(OtherCondition("before"), "other"),
      ]),
    ])
    == [["least"], ["greater"], ["not-equal"], ["instance"]]
}

pub fn an_and_of_two_fewer_than_one_and_a_not_instance_of_test() {
  // The node shows with a or b, and with c.
  assert catalogue.needs([
      hides_when([group(And, [count(LessThan, "a"), count(LessThan, "b")])]),
      hides([count(NotInstanceOf, "c")]),
    ])
    == [["a", "b"], ["c"]]
}

pub fn the_parts_of_an_or_group_that_is_the_only_part_are_each_needed_test() {
  let or =
    ConditionGroup(Or, [count(LessThan, "a"), count(NotInstanceOf, "b")], [
      group(And, [count(LessThan, "c"), count(LessThan, "d")]),
      // A part that fails with nothing chosen keeps nothing hidden.
      group(And, [count(AtLeast, "e"), count(LessThan, "f")]),
    ])
  assert catalogue.needs([hides_when([or])]) == [["a"], ["b"], ["c", "d"]]
  // Beside a condition, the or group is one part of many: any one will do.
  assert catalogue.needs([
      Modifier(Set, "hidden", BoolValue(True), [count(LessThan, "g")], [or]),
    ])
    == [["g", "a", "b", "c", "d"]]
}

pub fn a_modifier_that_shows_needs_every_part_test() {
  let modifier =
    Modifier(Set, "hidden", BoolValue(False), [count(AtLeast, "a")], [
      ConditionGroup(And, [count(InstanceOf, "b"), count(LessThan, "x")], [
        group(Or, [count(InstanceOf, "c"), count(InstanceOf, "d")]),
      ]),
      group(Or, [count(InstanceOf, "e"), count(AtLeast, "f")]),
    ])
  assert catalogue.needs([modifier]) == [["a"], ["b"], ["c", "d"], ["e", "f"]]
}

pub fn a_part_that_fails_with_nothing_chosen_needs_nothing_test() {
  assert catalogue.needs([hides([count(LessThan, "a"), count(AtLeast, "b")])])
    == []
  assert catalogue.needs([
      hides_when([
        group(And, [count(LessThan, "a")]),
        group(Or, [count(InstanceOf, "b")]),
      ]),
    ])
    == []
}

pub fn needs_look_into_groups_at_any_depth_test() {
  let deep =
    Modifier(Set, "hidden", BoolValue(True), [count(LessThan, "direct")], [
      ConditionGroup(Or, [count(AtMost, "in-or"), count(AtLeast, "not-this")], [
        ConditionGroup(And, [count(LessThan, "in-and")], [
          group(Or, [count(NotInstanceOf, "deepest")]),
        ]),
        group(And, [count(LessThan, "failing"), count(AtLeast, "not-this")]),
      ]),
    ])
  assert catalogue.needs([deep]) == [["direct", "in-or", "in-and", "deepest"]]
}

pub fn needs_have_no_repeats_and_skip_what_is_not_about_hidden_test() {
  assert catalogue.needs([
      hides([count(LessThan, "a"), count(LessThan, ""), count(LessThan, "a")]),
      hides([count(LessThan, "")]),
      shows([count(AtLeast, "b"), count(AtLeast, "a")]),
      Modifier(Set, "name", TextValue("New"), [count(LessThan, "c")], []),
      Modifier(Increment, "hidden", BoolValue(True), [count(LessThan, "d")], []),
      Modifier(Set, "hidden", TextValue("true"), [count(LessThan, "e")], []),
    ])
    == [["a"], ["b"]]
  assert catalogue.needs([]) == []
}
