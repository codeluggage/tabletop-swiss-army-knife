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
        roots: [EntryRoot("e-weather", "Weather", Upgrade, "")],
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
        roots: [LinkRoot("l-walker", "Sugar Bowl Walker", "e-walker", "")],
        shared: [
          SharedSummary("e-captain", Model, "Leader"),
          SharedSummary("e-walker", Model, ""),
          SharedSummary("e-sling", Upgrade, ""),
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
        LinkRoot("l-guest-captain", "Kettle Captain", "e-captain", "Line"),
        EntryRoot("e-brew", "Brew", Upgrade, ""),
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
          LinkRoot("l-captain", "Kettle Captain", "e-captain", ""),
          LinkRoot("l-squad", "Teacup Squad", "e-squad", ""),
        ],
        shared: [SharedSummary("e-squad", Unit, "Line")],
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
        SharedSummary("e", OtherKind(""), ""),
      ]),
    )
}

pub fn a_minimal_file_decodes_test() {
  assert catalogue.decode("{\"catalogue\": {\"id\": \"c\"}}")
    == Ok(Catalogue(False, "c", "", False, [], [], []))
  assert catalogue.decode("{\"gameSystem\": {\"id\": \"s\"}}")
    == Ok(Catalogue(True, "s", "", False, [], [], []))
}
