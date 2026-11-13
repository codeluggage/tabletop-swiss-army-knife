//// One data file of a game: the game system or a catalogue. Its shape, a
//// full decoder, and a shallow read that the import uses.
////
//// The code knows the shape only. Every name, cost, column and rule comes
//// from the file.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import tabletop/sheet.{
  type Category, type Cost, type EntryKind, type Profile, type Rule,
}

pub type Catalogue {
  Catalogue(
    game_system: Bool,
    id: String,
    name: String,
    library: Bool,
    links: List(Link),
    /// The file's root entry links, then its root entries.
    roots: List(Node),
    /// Every other node at the file's top level: shared entries, shared
    /// groups, shared profiles, shared rules and rules, shared info groups,
    /// categories, and force entries with the nested ones beside them.
    shared: List(Node),
  )
}

/// A link to another file. `import_roots` says whether that file's roots
/// count as this file's too.
pub type Link {
  Link(target_id: String, import_roots: Bool)
}

/// A thing in a file that has an id other things point at. `children` are the
/// node's entries, then its groups, then its entry links.
pub type Node {
  Entry(
    id: String,
    name: String,
    kind: EntryKind,
    hidden: Bool,
    costs: List(Cost),
    categories: List(Category),
    profiles: List(Profile),
    rules: List(Rule),
    info_links: List(InfoLink),
    info_groups: List(InfoGroup),
    children: List(Node),
    modifiers: List(Modifier),
  )
  Group(
    id: String,
    name: String,
    hidden: Bool,
    children: List(Node),
    modifiers: List(Modifier),
  )
  EntryLink(
    id: String,
    name: String,
    target_id: String,
    target_kind: TargetKind,
    hidden: Bool,
    costs: List(Cost),
    categories: List(Category),
    profiles: List(Profile),
    info_links: List(InfoLink),
    children: List(Node),
    modifiers: List(Modifier),
  )
  ProfileNode(profile: Profile)
  RuleNode(rule: Rule)
  InfoGroupNode(group: InfoGroup)
  CategoryNode(id: String, name: String)
  ForceNode(id: String, name: String)
}

/// What an entry link points at, from the file's `type`.
pub type TargetKind {
  ToEntry
  ToGroup
  OtherTarget(String)
}

/// A pointer to a profile, a rule or an info group.
pub type InfoLink {
  InfoLink(id: String, name: String, target_id: String, hidden: Bool)
}

pub type InfoGroup {
  InfoGroup(
    id: String,
    name: String,
    hidden: Bool,
    profiles: List(Profile),
    info_links: List(InfoLink),
  )
}

/// A change to one field of a node, made when every condition and every
/// group holds. `field` is `hidden`, `category`, `name`, or the id of a cost
/// type or a characteristic type.
pub type Modifier {
  Modifier(
    kind: ModifierKind,
    field: String,
    value: Value,
    conditions: List(Condition),
    groups: List(ConditionGroup),
  )
}

pub type ModifierKind {
  Set
  Increment
  Decrement
  Append
  Add
  Remove
  OtherModifier(String)
}

pub type Value {
  TextValue(String)
  NumberValue(Float)
  BoolValue(Bool)
  NoValue
}

/// A count of `child_id` within `scope`, compared with `value`.
pub type Condition {
  Condition(
    kind: ConditionKind,
    field: String,
    scope: String,
    value: Float,
    child_id: String,
  )
}

pub type ConditionKind {
  AtLeast
  AtMost
  GreaterThan
  LessThan
  EqualTo
  NotEqualTo
  InstanceOf
  NotInstanceOf
  OtherCondition(String)
}

pub type ConditionGroup {
  ConditionGroup(
    kind: GroupKind,
    conditions: List(Condition),
    groups: List(ConditionGroup),
  )
}

pub type GroupKind {
  And
  Or
  OtherGroup(String)
}

/// What the import reads from a file without walking into it.
pub type Summary {
  Summary(
    game_system: Bool,
    id: String,
    name: String,
    library: Bool,
    links: List(Link),
    /// The file's root entry links, then its root entries.
    roots: List(RootSummary),
    shared: List(SharedSummary),
  )
}

/// `primary` is the name of the root's primary category, empty when it has
/// none. `shown` says whether the root itself shows when nothing is chosen.
pub type RootSummary {
  LinkRoot(
    id: String,
    name: String,
    target_id: String,
    primary: String,
    shown: Bool,
  )
  EntryRoot(
    id: String,
    name: String,
    kind: EntryKind,
    primary: String,
    shown: Bool,
  )
}

/// A shared entry, as far as a root that links to it needs to know it.
pub type SharedSummary {
  SharedSummary(id: String, kind: EntryKind, primary: String, shown: Bool)
}

pub type FileError {
  NotJson
  /// JSON, but no `gameSystem` or `catalogue` object.
  NoCatalogue
  /// A value of the wrong kind at this path.
  UnexpectedShape(at: String)
}

pub fn id(node: Node) -> String {
  case node {
    Entry(id:, ..)
    | Group(id:, ..)
    | EntryLink(id:, ..)
    | CategoryNode(id:, ..)
    | ForceNode(id:, ..) -> id
    ProfileNode(profile) -> profile.id
    RuleNode(rule) -> rule.id
    InfoGroupNode(group) -> group.id
  }
}

pub fn name(node: Node) -> String {
  case node {
    Entry(name:, ..)
    | Group(name:, ..)
    | EntryLink(name:, ..)
    | CategoryNode(name:, ..)
    | ForceNode(name:, ..) -> name
    ProfileNode(profile) -> profile.name
    RuleNode(rule) -> rule.name
    InfoGroupNode(group) -> group.name
  }
}

// --- Visibility when nothing is chosen --------------------------------------
//
// Whether a node shows is worked out for a list with nothing in it, so every
// count a condition asks for is zero.

/// Whether a node shows as hidden before anything is chosen: `hidden`, then
/// each modifier that sets `hidden` and holds, in order.
pub fn hidden_by_default(hidden: Bool, modifiers: List(Modifier)) -> Bool {
  list.fold(modifiers, hidden, fn(hidden, modifier) {
    case modifier {
      Modifier(kind: Set, field: "hidden", value: BoolValue(value), ..) ->
        case all_hold(modifier.conditions, modifier.groups) {
          True -> value
          False -> hidden
        }
      _ -> hidden
    }
  })
}

/// Whether the condition holds for a count of zero.
fn holds(condition: Condition) -> Bool {
  let value = condition.value
  case condition.kind {
    LessThan -> 0.0 <. value
    AtMost -> 0.0 <=. value
    AtLeast -> 0.0 >=. value
    GreaterThan -> 0.0 >. value
    EqualTo -> value == 0.0
    NotEqualTo -> value != 0.0
    NotInstanceOf -> True
    InstanceOf | OtherCondition(_) -> False
  }
}

fn group_holds(group: ConditionGroup) -> Bool {
  case group.kind {
    And -> all_hold(group.conditions, group.groups)
    Or ->
      list.any(group.conditions, holds) || list.any(group.groups, group_holds)
    OtherGroup(_) -> False
  }
}

fn all_hold(conditions: List(Condition), groups: List(ConditionGroup)) -> Bool {
  list.all(conditions, holds) && list.all(groups, group_holds)
}

/// What a node needs before it shows, from each modifier that sets `hidden`.
/// The node needs every requirement, and a requirement is met by any one of
/// its ids. No empty requirement and no repeats, in order.
pub fn needs(modifiers: List(Modifier)) -> List(List(String)) {
  modifiers
  |> list.flat_map(fn(modifier) {
    case modifier {
      Modifier(kind: Set, field: "hidden", value: BoolValue(True), ..) ->
        hiding_needs(modifier.conditions, modifier.groups)
      Modifier(kind: Set, field: "hidden", value: BoolValue(False), ..) ->
        showing_needs(modifier.conditions, modifier.groups)
      _ -> []
    }
  })
  |> list.map(fn(ids) { list.filter(ids, fn(id) { id != "" }) |> list.unique })
  |> list.filter(fn(ids) { ids != [] })
  |> list.unique
}

/// A modifier that hides the node while every part holds. The node shows once
/// one part fails, so a modifier with a part that already fails needs
/// nothing, and the parts of an `or` group that is the only part are each
/// needed. Otherwise one choice of any of its presence conditions will do.
fn hiding_needs(
  conditions: List(Condition),
  groups: List(ConditionGroup),
) -> List(List(String)) {
  case all_hold(conditions, groups), conditions, groups {
    False, _, _ -> []
    True, [], [ConditionGroup(kind: Or, conditions:, groups:)] ->
      list.append(
        list.map(conditions, fn(condition) { hiding_ids([condition], []) }),
        list.map(groups, fn(group) { hiding_ids([], [group]) }),
      )
    True, _, _ -> [hiding_ids(conditions, groups)]
  }
}

/// The child ids of the presence conditions in the parts, at any depth, in
/// order. A part that already fails with nothing chosen keeps nothing hidden,
/// so it gives none.
fn hiding_ids(
  conditions: List(Condition),
  groups: List(ConditionGroup),
) -> List(String) {
  list.append(
    conditions
      |> list.filter(fn(condition) {
        holds(condition) && presence(condition.kind, True)
      })
      |> list.map(fn(condition) { condition.child_id }),
    groups
      |> list.filter(group_holds)
      |> list.flat_map(fn(group) { hiding_ids(group.conditions, group.groups) }),
  )
}

/// A modifier that shows the node when every part holds: each presence
/// condition is needed, an `and` group's parts each, and an `or` group's
/// presence conditions as one requirement.
fn showing_needs(
  conditions: List(Condition),
  groups: List(ConditionGroup),
) -> List(List(String)) {
  list.append(
    conditions
      |> list.filter(fn(condition) { presence(condition.kind, False) })
      |> list.map(fn(condition) { [condition.child_id] }),
    list.flat_map(groups, fn(group) {
      case group.kind {
        And -> showing_needs(group.conditions, group.groups)
        Or | OtherGroup(_) -> [showing_ids(group.conditions, group.groups)]
      }
    }),
  )
}

fn showing_ids(
  conditions: List(Condition),
  groups: List(ConditionGroup),
) -> List(String) {
  list.append(
    conditions
      |> list.filter(fn(condition) { presence(condition.kind, False) })
      |> list.map(fn(condition) { condition.child_id }),
    list.flat_map(groups, fn(group) {
      showing_ids(group.conditions, group.groups)
    }),
  )
}

/// A presence condition turns in the node's favour when its child is chosen.
/// For a modifier that hides, that is a `lessThan`, `atMost`, `equalTo` or
/// `notInstanceOf`, which stops holding. For a modifier that shows, an
/// `atLeast`, `greaterThan`, `notEqualTo` or `instanceOf`, which starts.
fn presence(kind: ConditionKind, hides: Bool) -> Bool {
  case hides, kind {
    True, LessThan | True, AtMost | True, EqualTo | True, NotInstanceOf -> True
    False, AtLeast
    | False, GreaterThan
    | False, NotEqualTo
    | False, InstanceOf
    -> True
    _, _ -> False
  }
}

// --- Reading a file ---------------------------------------------------------

/// The whole file, every node at every depth.
pub fn decode(text: String) -> Result(Catalogue, FileError) {
  read(text, catalogue_decoder)
}

/// The file's top level only: its roots and shared entries, none of their
/// children.
pub fn summarise(text: String) -> Result(Summary, FileError) {
  read(text, summary_decoder)
}

/// `decoder` is given whether the file is the game system.
fn read(text: String, decoder: fn(Bool) -> Decoder(a)) -> Result(a, FileError) {
  use data <- result.try(
    json.parse(text, decode.dynamic) |> result.replace_error(NotJson),
  )
  let has_object = fn(key) {
    decode.at([key], decode.dict(decode.string, decode.dynamic))
    |> decode.run(data, _)
    |> result.is_ok
  }
  use #(key, game_system) <- result.try(
    case has_object("gameSystem"), has_object("catalogue") {
      True, _ -> Ok(#("gameSystem", True))
      False, True -> Ok(#("catalogue", False))
      False, False -> Error(NoCatalogue)
    },
  )
  decode.run(data, decode.at([key], decoder(game_system)))
  |> result.map_error(fn(errors) {
    let path = list.flat_map(list.take(errors, 1), fn(error) { error.path })
    UnexpectedShape(at: string.join(path, "."))
  })
}

/// The array under `key`, empty when the object has none.
fn array(
  key: String,
  of item: fn() -> Decoder(a),
  next next: fn(List(a)) -> Decoder(b),
) -> Decoder(b) {
  decode.optional_field(key, [], decode.list(decode.recursive(item)), next)
}

fn text(key: String, next: fn(String) -> Decoder(a)) -> Decoder(a) {
  decode.optional_field(key, "", decode.string, next)
}

fn hidden(next: fn(Bool) -> Decoder(a)) -> Decoder(a) {
  decode.optional_field("hidden", False, decode.bool, next)
}

fn link_decoder() -> Decoder(Link) {
  use target_id <- text("targetId")
  use import_roots <- decode.optional_field(
    "importRootEntries",
    False,
    decode.optional(decode.bool) |> decode.map(option.unwrap(_, False)),
  )
  decode.success(Link(target_id:, import_roots:))
}

// --- The full decode --------------------------------------------------------

fn catalogue_decoder(game_system: Bool) -> Decoder(Catalogue) {
  use id <- decode.field("id", decode.string)
  use name <- text("name")
  use library <- decode.optional_field("library", False, decode.bool)
  use links <- array("catalogueLinks", link_decoder)
  use root_links <- array("entryLinks", entry_link_decoder)
  use root_entries <- array("selectionEntries", entry_decoder)
  use entries <- array("sharedSelectionEntries", entry_decoder)
  use groups <- array("sharedSelectionEntryGroups", group_decoder)
  use profiles <- array("sharedProfiles", sheet.profile_decoder)
  use shared_rules <- array("sharedRules", sheet.rule_decoder)
  use rules <- array("rules", sheet.rule_decoder)
  use info_groups <- array("sharedInfoGroups", info_group_decoder)
  use categories <- array("categoryEntries", category_decoder)
  use forces <- array("forceEntries", force_decoder)
  decode.success(Catalogue(
    game_system:,
    id:,
    name:,
    library:,
    links:,
    roots: list.append(root_links, root_entries),
    shared: list.flatten([
      entries,
      groups,
      list.map(profiles, ProfileNode),
      list.map(shared_rules, RuleNode),
      list.map(rules, RuleNode),
      list.map(info_groups, InfoGroupNode),
      categories,
      list.flatten(forces),
    ]),
  ))
}

fn entry_decoder() -> Decoder(Node) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.optional_field(
    "type",
    sheet.OtherKind(""),
    sheet.entry_kind_decoder(),
  )
  use hidden <- hidden()
  use costs <- array("costs", sheet.cost_decoder)
  use categories <- array("categoryLinks", category_link_decoder)
  use profiles <- array("profiles", sheet.profile_decoder)
  use rules <- array("rules", sheet.rule_decoder)
  use info_links <- array("infoLinks", info_link_decoder)
  use info_groups <- array("infoGroups", info_group_decoder)
  use children <- decode.then(children_decoder())
  use modifiers <- decode.then(modifiers_decoder())
  decode.success(Entry(
    id:,
    name:,
    kind:,
    hidden:,
    costs:,
    categories:,
    profiles:,
    rules:,
    info_links:,
    info_groups:,
    children:,
    modifiers:,
  ))
}

fn group_decoder() -> Decoder(Node) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use hidden <- hidden()
  use children <- decode.then(children_decoder())
  use modifiers <- decode.then(modifiers_decoder())
  decode.success(Group(id:, name:, hidden:, children:, modifiers:))
}

fn entry_link_decoder() -> Decoder(Node) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use target_id <- decode.field("targetId", decode.string)
  use target_kind <- decode.optional_field(
    "type",
    OtherTarget(""),
    decode.map(decode.string, fn(kind) {
      case kind {
        "selectionEntry" -> ToEntry
        "selectionEntryGroup" -> ToGroup
        other -> OtherTarget(other)
      }
    }),
  )
  use hidden <- hidden()
  use costs <- array("costs", sheet.cost_decoder)
  use categories <- array("categoryLinks", category_link_decoder)
  use profiles <- array("profiles", sheet.profile_decoder)
  use info_links <- array("infoLinks", info_link_decoder)
  use children <- decode.then(children_decoder())
  use modifiers <- decode.then(modifiers_decoder())
  decode.success(EntryLink(
    id:,
    name:,
    target_id:,
    target_kind:,
    hidden:,
    costs:,
    categories:,
    profiles:,
    info_links:,
    children:,
    modifiers:,
  ))
}

/// The object's entries, then its groups, then its entry links.
fn children_decoder() -> Decoder(List(Node)) {
  use entries <- array("selectionEntries", entry_decoder)
  use groups <- array("selectionEntryGroups", group_decoder)
  use links <- array("entryLinks", entry_link_decoder)
  decode.success(list.flatten([entries, groups, links]))
}

fn category_link_decoder() -> Decoder(Category) {
  sheet.category_decoder("targetId")
}

fn info_link_decoder() -> Decoder(InfoLink) {
  use id <- text("id")
  use name <- text("name")
  use target_id <- text("targetId")
  use hidden <- hidden()
  decode.success(InfoLink(id:, name:, target_id:, hidden:))
}

fn info_group_decoder() -> Decoder(InfoGroup) {
  use id <- text("id")
  use name <- text("name")
  use hidden <- hidden()
  use profiles <- array("profiles", sheet.profile_decoder)
  use info_links <- array("infoLinks", info_link_decoder)
  decode.success(InfoGroup(id:, name:, hidden:, profiles:, info_links:))
}

fn category_decoder() -> Decoder(Node) {
  use id <- text("id")
  use name <- text("name")
  decode.success(CategoryNode(id:, name:))
}

/// The force entry, then every force entry nested in it.
fn force_decoder() -> Decoder(List(Node)) {
  use id <- text("id")
  use name <- text("name")
  use nested <- array("forceEntries", force_decoder)
  decode.success([ForceNode(id:, name:), ..list.flatten(nested)])
}

// --- Modifiers --------------------------------------------------------------

/// The object's own modifiers, then the modifiers in its modifier groups.
fn modifiers_decoder() -> Decoder(List(Modifier)) {
  use own <- array("modifiers", modifier_decoder)
  use grouped <- array("modifierGroups", modifier_group_decoder)
  decode.success(list.append(own, list.flatten(grouped)))
}

/// The group's modifiers, those of the groups nested in it included, each
/// with the group's conditions and condition groups added to its own.
fn modifier_group_decoder() -> Decoder(List(Modifier)) {
  use modifiers <- decode.then(modifiers_decoder())
  use conditions <- array("conditions", condition_decoder)
  use groups <- array("conditionGroups", condition_group_decoder)
  decode.success(
    list.map(modifiers, fn(modifier) {
      Modifier(
        ..modifier,
        conditions: list.append(modifier.conditions, conditions),
        groups: list.append(modifier.groups, groups),
      )
    }),
  )
}

fn modifier_decoder() -> Decoder(Modifier) {
  use kind <- decode.optional_field(
    "type",
    OtherModifier(""),
    decode.map(decode.string, fn(kind) {
      case kind {
        "set" -> Set
        "increment" -> Increment
        "decrement" -> Decrement
        "append" -> Append
        "add" -> Add
        "remove" -> Remove
        other -> OtherModifier(other)
      }
    }),
  )
  use field <- text("field")
  use value <- decode.optional_field(
    "value",
    NoValue,
    decode.one_of(decode.map(decode.string, TextValue), [
      decode.map(sheet.number_decoder(), NumberValue),
      decode.map(decode.bool, BoolValue),
      decode.success(NoValue),
    ]),
  )
  use conditions <- array("conditions", condition_decoder)
  use groups <- array("conditionGroups", condition_group_decoder)
  decode.success(Modifier(kind:, field:, value:, conditions:, groups:))
}

fn condition_decoder() -> Decoder(Condition) {
  use kind <- decode.optional_field(
    "type",
    OtherCondition(""),
    decode.map(decode.string, fn(kind) {
      case kind {
        "atLeast" -> AtLeast
        "atMost" -> AtMost
        "greaterThan" -> GreaterThan
        "lessThan" -> LessThan
        "equalTo" -> EqualTo
        "notEqualTo" -> NotEqualTo
        "instanceOf" -> InstanceOf
        "notInstanceOf" -> NotInstanceOf
        other -> OtherCondition(other)
      }
    }),
  )
  use field <- text("field")
  use scope <- text("scope")
  use value <- decode.optional_field("value", 0.0, sheet.number_decoder())
  use child_id <- text("childId")
  decode.success(Condition(kind:, field:, scope:, value:, child_id:))
}

fn condition_group_decoder() -> Decoder(ConditionGroup) {
  use kind <- decode.optional_field(
    "type",
    OtherGroup(""),
    decode.map(decode.string, fn(kind) {
      case kind {
        "and" -> And
        "or" -> Or
        other -> OtherGroup(other)
      }
    }),
  )
  use conditions <- array("conditions", condition_decoder)
  use groups <- array("conditionGroups", condition_group_decoder)
  decode.success(ConditionGroup(kind:, conditions:, groups:))
}

// --- The shallow read -------------------------------------------------------

fn summary_decoder(game_system: Bool) -> Decoder(Summary) {
  use id <- decode.field("id", decode.string)
  use name <- text("name")
  use library <- decode.optional_field("library", False, decode.bool)
  use links <- array("catalogueLinks", link_decoder)
  use root_links <- array("entryLinks", link_root_decoder)
  use root_entries <- array("selectionEntries", entry_root_decoder)
  use shared <- array("sharedSelectionEntries", shared_decoder)
  decode.success(Summary(
    game_system:,
    id:,
    name:,
    library:,
    links:,
    roots: list.append(root_links, root_entries),
    shared:,
  ))
}

fn link_root_decoder() -> Decoder(RootSummary) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use target_id <- decode.field("targetId", decode.string)
  use primary <- decode.then(primary_decoder())
  use shown <- decode.then(shown_decoder())
  decode.success(LinkRoot(id:, name:, target_id:, primary:, shown:))
}

fn entry_root_decoder() -> Decoder(RootSummary) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.then(kind_decoder())
  use primary <- decode.then(primary_decoder())
  use shown <- decode.then(shown_decoder())
  decode.success(EntryRoot(id:, name:, kind:, primary:, shown:))
}

fn shared_decoder() -> Decoder(SharedSummary) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.then(kind_decoder())
  use primary <- decode.then(primary_decoder())
  use shown <- decode.then(shown_decoder())
  decode.success(SharedSummary(id:, kind:, primary:, shown:))
}

/// Whether the object shows when nothing is chosen, from its `hidden` and
/// its modifiers.
fn shown_decoder() -> Decoder(Bool) {
  use hidden <- hidden()
  use modifiers <- decode.then(modifiers_decoder())
  decode.success(!hidden_by_default(hidden, modifiers))
}

fn kind_decoder() -> Decoder(EntryKind) {
  use kind <- decode.optional_field(
    "type",
    sheet.OtherKind(""),
    sheet.entry_kind_decoder(),
  )
  decode.success(kind)
}

/// The name of the object's first category link marked primary, empty when
/// it has none.
fn primary_decoder() -> Decoder(String) {
  use categories <- array("categoryLinks", category_link_decoder)
  list.find(categories, fn(category) { category.primary })
  |> result.map(fn(category) { category.name })
  |> result.unwrap("")
  |> decode.success
}
