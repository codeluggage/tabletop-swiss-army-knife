//// A decoded scope: the files one catalogue reaches, with every node by id,
//// and the page of a node as data for the node screen.
////
//// Nothing is chosen here. Whether a node shows is worked out for a list with
//// nothing in it, so every count a condition asks for is zero.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import tabletop/catalogue.{
  type Catalogue, type Condition, type ConditionGroup, type ConditionKind,
  type InfoGroup, type InfoLink, type Modifier, type ModifierKind, type Node,
  type Value, And, AtLeast, AtMost, BoolValue, CategoryNode, Decrement, Entry,
  EntryLink, EqualTo, ForceNode, GreaterThan, Group, Increment, InfoGroupNode,
  InstanceOf, LessThan, Modifier, NotEqualTo, NotInstanceOf, Or, OtherCondition,
  OtherGroup, ProfileNode, RuleNode,
}
import tabletop/sheet.{type Cost, type EntryKind, type Profile, type Rule}
import tabletop/text

pub opaque type Scope {
  Scope(
    nodes: Dict(String, Placed),
    /// For an id, the ids of the nodes that need it before they show.
    unlocks: Dict(String, List(String)),
    /// For a category id, the ids of the entries and links that have it.
    with_category: Dict(String, List(String)),
    /// Every rule with the id of the node that owns it, empty for a rule at
    /// the top level of a file.
    rules: List(#(Rule, String)),
  )
}

/// A node where it sits. `parent_id` is empty at the top level of a file.
pub type Placed {
  Placed(node: Node, parent_id: String, catalogue_id: String)
}

/// Everything the node screen shows. For an entry link, the page covers the
/// link and its target together.
pub type Page {
  Page(
    node: Node,
    /// The parents as id and name, outermost first.
    path: List(#(String, String)),
    costs: List(Cost),
    cost_lines: List(CostLine),
    profiles: List(Profile),
    own_rules: List(Rule),
    linked_rules: List(Rule),
    /// The node's categories as id and name.
    keywords: List(#(String, String)),
    contains: List(Item),
    conditional: List(Conditional),
    unlocks: List(Unlock),
    /// For a category: the first of the entries and links that have it, by
    /// name, and how many there are in all.
    with_keyword: List(Item),
    with_keyword_count: Int,
    keyword_rules: List(KeywordRule),
  )
}

/// An entry, a group or an entry link in a list on the page. `costs` leaves
/// out the zeros.
pub type Item {
  Item(id: String, name: String, kind: ItemKind, costs: List(Cost))
}

pub type ItemKind {
  EntryItem(EntryKind)
  GroupItem
  LinkItem
}

/// A change to one of the node's costs.
pub type CostLine {
  CostLine(
    cost_name: String,
    kind: ModifierKind,
    value: Value,
    conditions: CostConditions,
  )
}

pub type CostConditions {
  /// The change applies when all of these hold, and always when there are
  /// none.
  All(List(CostCondition))
  /// The modifier has condition groups, which the page does not spell out.
  Grouped
}

/// `child_name` is empty when the child is not a node in scope.
pub type CostCondition {
  CostCondition(
    kind: ConditionKind,
    value: Float,
    child_id: String,
    child_name: String,
  )
}

/// A child that is hidden until the nodes in `needs`, as id and name, are
/// chosen.
pub type Conditional {
  Conditional(item: Item, needs: List(#(String, String)))
}

/// A node that needs this page's node. `children` are the visible children
/// when it is a group or a link to a group.
pub type Unlock {
  Unlock(item: Item, children: List(Item))
}

/// A rule whose text names one of the node's keywords, and the node that owns
/// the rule.
pub type KeywordRule {
  KeywordRule(rule: Rule, owner: Option(Item))
}

const max_with_keyword = 100

/// A keyword name shorter than this is too common a word to look for.
const min_keyword_length = 3

// --- Building ---------------------------------------------------------------

/// The scope of catalogues given in `data_index.scope_files` order. The first
/// definition of an id wins, and a node with no id is left out.
pub fn build(catalogues: List(Catalogue)) -> Scope {
  let #(nodes, placed) =
    list.fold(catalogues, #(dict.new(), []), fn(found, catalogue) {
      list.append(catalogue.roots, catalogue.shared)
      |> list.fold(found, fn(found, node) {
        place(found, node, "", catalogue.id)
      })
    })
  // `placed` is newest first, so prepending while folding over it leaves each
  // list below in scope order.
  let rules =
    list.fold(placed, [], fn(rules, placed) {
      case placed.node {
        RuleNode(rule) -> [#(rule, placed.parent_id), ..rules]
        _ -> rules
      }
    })
  let with_category =
    list.fold(placed, dict.new(), fn(found, placed) {
      case placed.node {
        Entry(id:, categories:, ..) | EntryLink(id:, categories:, ..) ->
          list.fold(categories, found, fn(found, category) {
            prepend(found, category.id, id)
          })
        _ -> found
      }
    })
  let unlocks =
    list.fold(placed, dict.new(), fn(found, placed) {
      needs(modifiers(placed.node))
      |> list.filter(dict.has_key(nodes, _))
      |> list.fold(found, fn(found, need) {
        prepend(found, need, catalogue.id(placed.node))
      })
    })
  Scope(nodes:, unlocks:, with_category:, rules:)
}

/// Add the node, then the nodes inside it. `found` is the nodes by id, and
/// the same nodes newest first.
fn place(
  found: #(Dict(String, Placed), List(Placed)),
  node: Node,
  parent_id: String,
  catalogue_id: String,
) -> #(Dict(String, Placed), List(Placed)) {
  let #(nodes, placed) = found
  let id = catalogue.id(node)
  case id == "" || dict.has_key(nodes, id) {
    True -> found
    False -> {
      let here = Placed(node:, parent_id:, catalogue_id:)
      let found = #(dict.insert(nodes, id, here), [here, ..placed])
      list.fold(inside(node), found, fn(found, child) {
        place(found, child, id, catalogue_id)
      })
    }
  }
}

/// The nodes a node holds: its profiles, rules and info groups, then its
/// children.
fn inside(node: Node) -> List(Node) {
  case node {
    Entry(profiles:, rules:, info_groups:, children:, ..) ->
      list.flatten([
        list.map(profiles, ProfileNode),
        list.map(rules, RuleNode),
        list.map(info_groups, InfoGroupNode),
        children,
      ])
    Group(children:, ..) -> children
    EntryLink(profiles:, children:, ..) ->
      list.append(list.map(profiles, ProfileNode), children)
    InfoGroupNode(group) -> list.map(group.profiles, ProfileNode)
    ProfileNode(_) | RuleNode(_) | CategoryNode(..) | ForceNode(..) -> []
  }
}

fn prepend(
  found: Dict(String, List(String)),
  key: String,
  id: String,
) -> Dict(String, List(String)) {
  dict.upsert(found, key, fn(ids) { [id, ..option.unwrap(ids, [])] })
}

pub fn find(scope: Scope, id: String) -> Result(Placed, Nil) {
  dict.get(scope.nodes, id)
}

/// Every rule name in scope with its rule's id as the target. The first rule
/// with a name wins.
pub fn rule_links(scope: Scope) -> text.Links(String) {
  scope.rules
  |> list.map(fn(owned) {
    let #(rule, _) = owned
    #(rule.name, rule.id)
  })
  |> text.links
}

// --- Visibility when nothing is chosen --------------------------------------

/// Whether a node shows as hidden before anything is chosen: `hidden`, then
/// each modifier that sets `hidden` and holds, in order.
pub fn hidden_by_default(hidden: Bool, modifiers: List(Modifier)) -> Bool {
  list.fold(modifiers, hidden, fn(hidden, modifier) {
    case modifier {
      Modifier(
        kind: catalogue.Set,
        field: "hidden",
        value: BoolValue(value),
        conditions:,
        groups:,
      ) ->
        case list.all(conditions, holds) && list.all(groups, group_holds) {
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
    And ->
      list.all(group.conditions, holds) && list.all(group.groups, group_holds)
    Or ->
      list.any(group.conditions, holds) || list.any(group.groups, group_holds)
    OtherGroup(_) -> False
  }
}

/// The ids of the children a node needs before it shows: from each modifier
/// that sets `hidden`, the conditions at any depth that choosing the child
/// turns in the node's favour. No repeats, in order.
pub fn needs(modifiers: List(Modifier)) -> List(String) {
  modifiers
  |> list.flat_map(fn(modifier) {
    case modifier {
      Modifier(
        kind: catalogue.Set,
        field: "hidden",
        value: BoolValue(hides),
        conditions:,
        groups:,
      ) ->
        list.append(conditions, list.flat_map(groups, group_conditions))
        |> list.filter(fn(condition) { lifts(condition.kind, hides) })
        |> list.map(fn(condition) { condition.child_id })
      _ -> []
    }
  })
  |> list.filter(fn(id) { id != "" })
  |> list.unique
}

fn group_conditions(group: ConditionGroup) -> List(Condition) {
  list.append(group.conditions, list.flat_map(group.groups, group_conditions))
}

/// A modifier that hides stops holding when a count goes up past a
/// `lessThan`, `atMost`, `equalTo` or `notInstanceOf`. A modifier that shows
/// starts holding when it goes up to an `atLeast`, `greaterThan`,
/// `notEqualTo` or `instanceOf`.
fn lifts(kind: ConditionKind, hides: Bool) -> Bool {
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

fn modifiers(node: Node) -> List(Modifier) {
  case node {
    Entry(modifiers:, ..) | Group(modifiers:, ..) | EntryLink(modifiers:, ..) ->
      modifiers
    _ -> []
  }
}

fn children(node: Node) -> List(Node) {
  case node {
    Entry(children:, ..) | Group(children:, ..) | EntryLink(children:, ..) ->
      children
    _ -> []
  }
}

/// The node an entry link points at, when it is in scope.
fn target(scope: Scope, node: Node) -> Result(Node, Nil) {
  case node {
    EntryLink(target_id:, ..) ->
      find(scope, target_id) |> result.map(fn(placed) { placed.node })
    _ -> Error(Nil)
  }
}

/// The node, and the target with it when the node is an entry link.
fn with_target(scope: Scope, node: Node) -> List(Node) {
  [node, ..result.values([target(scope, node)])]
}

/// Whether a child is hidden when nothing is chosen. An entry link is hidden
/// when it or its target is.
fn hidden(scope: Scope, node: Node) -> Bool {
  list.any(with_target(scope, node), fn(part) {
    case part {
      Entry(hidden:, modifiers:, ..)
      | Group(hidden:, modifiers:, ..)
      | EntryLink(hidden:, modifiers:, ..) ->
        hidden_by_default(hidden, modifiers)
      _ -> False
    }
  })
}

// --- The page ---------------------------------------------------------------

pub fn page(scope: Scope, id: String) -> Result(Page, Nil) {
  use placed <- result.map(find(scope, id))
  let node = placed.node
  let parts = with_target(scope, node)
  let walk = enter(scope, Walk(set.new(), [], []), node, True)
  let own_rules = case node {
    RuleNode(rule) -> [rule]
    _ ->
      list.flat_map(parts, fn(part) {
        case part {
          Entry(rules:, ..) -> rules
          _ -> []
        }
      })
      |> list.filter(fn(rule) { !rule.hidden })
  }
  let own_rule_ids = list.map(own_rules, fn(rule) { rule.id })
  let linked_rules =
    list.reverse(walk.rules)
    |> list.filter(fn(rule) { !list.contains(own_rule_ids, rule.id) })
  let costs = costs(scope, node)
  let keywords =
    list.flat_map(parts, fn(part) {
      case part {
        Entry(categories:, ..) | EntryLink(categories:, ..) -> categories
        _ -> []
      }
    })
    |> list.map(fn(category) { #(category.id, category.name) })
    |> list.unique
  let #(conditional, contains) =
    list.flat_map(parts, children) |> list.partition(hidden(scope, _))
  let unlocks =
    list.flat_map(parts, fn(part) {
      dict.get(scope.unlocks, catalogue.id(part)) |> result.unwrap([])
    })
    |> list.unique
  let having = case node {
    CategoryNode(id:, ..) ->
      dict.get(scope.with_category, id)
      |> result.unwrap([])
      |> list.unique
      |> list.filter_map(item_by_id(scope, _))
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    _ -> []
  }
  Page(
    node:,
    path: path(scope, placed.parent_id, []),
    costs: without_zeros(costs),
    cost_lines: cost_lines(scope, costs, list.flat_map(parts, modifiers)),
    profiles: list.reverse(walk.profiles),
    own_rules:,
    linked_rules:,
    keywords:,
    contains: items(scope, contains),
    conditional: list.filter_map(conditional, fn(child) {
      use item <- result.map(item(scope, child))
      let needs =
        with_target(scope, child)
        |> list.flat_map(modifiers)
        |> needs
        |> list.filter_map(named(scope, _))
      Conditional(item:, needs:)
    }),
    unlocks: list.filter_map(unlocks, fn(id) {
      use placed <- result.try(find(scope, id))
      use item <- result.map(item(scope, placed.node))
      let group = case placed.node, target(scope, placed.node) {
        Group(children:, ..), _ | EntryLink(..), Ok(Group(children:, ..)) ->
          children
        _, _ -> []
      }
      let visible = list.filter(group, fn(child) { !hidden(scope, child) })
      Unlock(item:, children: items(scope, visible))
    }),
    with_keyword: list.take(having, max_with_keyword),
    with_keyword_count: list.length(having),
    keyword_rules: keyword_rules(
      scope,
      keywords,
      list.append(own_rules, linked_rules),
    ),
  )
}

/// The parents of the node whose parent is `parent_id`, outermost first.
fn path(
  scope: Scope,
  parent_id: String,
  found: List(#(String, String)),
) -> List(#(String, String)) {
  case find(scope, parent_id) {
    Ok(parent) ->
      path(scope, parent.parent_id, [
        #(parent_id, catalogue.name(parent.node)),
        ..found
      ])
    Error(Nil) -> found
  }
}

/// The id with the name of its node, when it is a node in scope.
fn named(scope: Scope, id: String) -> Result(#(String, String), Nil) {
  use placed <- result.map(find(scope, id))
  #(id, catalogue.name(placed.node))
}

// --- Costs and items --------------------------------------------------------

/// The node's costs. An entry link's own costs win over its target's.
fn costs(scope: Scope, node: Node) -> List(Cost) {
  case node, target(scope, node) {
    Entry(costs:, ..), _ -> costs
    EntryLink(costs: [], ..), Ok(Entry(costs:, ..)) -> costs
    EntryLink(costs:, ..), _ -> costs
    _, _ -> []
  }
}

fn without_zeros(costs: List(Cost)) -> List(Cost) {
  list.filter(costs, fn(cost) { cost.value != 0.0 })
}

/// One line per modifier that sets, raises or lowers one of `costs`.
fn cost_lines(
  scope: Scope,
  costs: List(Cost),
  modifiers: List(Modifier),
) -> List(CostLine) {
  use modifier <- list.filter_map(modifiers)
  use cost <- result.try(
    list.find(costs, fn(cost) { cost.type_id == modifier.field }),
  )
  let conditions = case modifier.groups {
    [] ->
      All(
        list.map(modifier.conditions, fn(condition) {
          CostCondition(
            kind: condition.kind,
            value: condition.value,
            child_id: condition.child_id,
            child_name: named(scope, condition.child_id)
              |> result.map(fn(pair) { pair.1 })
              |> result.unwrap(""),
          )
        }),
      )
    _ -> Grouped
  }
  case modifier.kind {
    catalogue.Set | Increment | Decrement ->
      Ok(CostLine(
        cost_name: cost.name,
        kind: modifier.kind,
        value: modifier.value,
        conditions:,
      ))
    _ -> Error(Nil)
  }
}

/// An entry, a group or an entry link as an item. No other node is one.
fn item(scope: Scope, node: Node) -> Result(Item, Nil) {
  let costs = without_zeros(costs(scope, node))
  case node {
    Entry(id:, name:, kind:, ..) ->
      Ok(Item(id:, name:, kind: EntryItem(kind), costs:))
    Group(id:, name:, ..) -> Ok(Item(id:, name:, kind: GroupItem, costs:))
    EntryLink(id:, name:, ..) -> Ok(Item(id:, name:, kind: LinkItem, costs:))
    ProfileNode(_)
    | RuleNode(_)
    | InfoGroupNode(_)
    | CategoryNode(..)
    | ForceNode(..) -> Error(Nil)
  }
}

fn items(scope: Scope, nodes: List(Node)) -> List(Item) {
  list.filter_map(nodes, item(scope, _))
}

fn item_by_id(scope: Scope, id: String) -> Result(Item, Nil) {
  use placed <- result.try(find(scope, id))
  item(scope, placed.node)
}

// --- Profiles and linked rules ----------------------------------------------

/// What one walk from the page's node has gathered, newest first. `visited`
/// holds the id of every node, profile and rule seen, so each shows once and
/// a loop of links ends.
type Walk {
  Walk(visited: Set(String), profiles: List(Profile), rules: List(Rule))
}

/// Run `then` unless `id` was seen before.
fn once(walk: Walk, id: String, then: fn(Walk) -> Walk) -> Walk {
  case set.contains(walk.visited, id) {
    True -> walk
    False -> then(Walk(..walk, visited: set.insert(walk.visited, id)))
  }
}

/// Gather from the node: its own profiles, what its info links point at, its
/// info groups, then the same from each child that is visible by default. An
/// entry link continues into its target. `top` is true for the page's own
/// node, whose rules are not linked rules and which is never skipped.
fn enter(scope: Scope, walk: Walk, node: Node, top: Bool) -> Walk {
  use walk <- once(walk, catalogue.id(node))
  case node {
    Entry(profiles:, rules:, info_links:, info_groups:, children:, ..) -> {
      let walk = add_profiles(walk, profiles)
      let walk = case top {
        True -> walk
        False -> add_rules(walk, rules)
      }
      let walk = follow(scope, walk, info_links)
      list.fold(info_groups, walk, fn(walk, group) {
        enter_info_group(scope, walk, group)
      })
      |> enter_children(scope, _, children)
    }
    Group(children:, ..) -> enter_children(scope, walk, children)
    EntryLink(profiles:, info_links:, children:, ..) -> {
      let walk = add_profiles(walk, profiles) |> follow(scope, _, info_links)
      case target(scope, node) {
        Ok(target) -> enter(scope, walk, target, top)
        Error(Nil) -> walk
      }
      |> enter_children(scope, _, children)
    }
    ProfileNode(profile) -> Walk(..walk, profiles: [profile, ..walk.profiles])
    InfoGroupNode(group) ->
      add_profiles(walk, group.profiles) |> follow(scope, _, group.info_links)
    RuleNode(_) | CategoryNode(..) | ForceNode(..) -> walk
  }
}

fn enter_children(scope: Scope, walk: Walk, children: List(Node)) -> Walk {
  list.fold(children, walk, fn(walk, child) {
    case hidden(scope, child) {
      True -> walk
      False -> enter(scope, walk, child, False)
    }
  })
}

/// A visible info group's profiles, and what its info links point at.
fn enter_info_group(scope: Scope, walk: Walk, group: InfoGroup) -> Walk {
  use <- bool.guard(group.hidden, walk)
  use walk <- once(walk, group.id)
  add_profiles(walk, group.profiles) |> follow(scope, _, group.info_links)
}

/// What each visible info link points at: a profile, a rule, or an info
/// group with everything in it.
fn follow(scope: Scope, walk: Walk, info_links: List(InfoLink)) -> Walk {
  use walk, link <- list.fold(info_links, walk)
  use <- bool.guard(link.hidden, walk)
  case find(scope, link.target_id) {
    Ok(Placed(node: ProfileNode(profile), ..)) -> add_profiles(walk, [profile])
    Ok(Placed(node: RuleNode(rule), ..)) -> add_rules(walk, [rule])
    Ok(Placed(node: InfoGroupNode(group), ..)) ->
      enter_info_group(scope, walk, group)
    _ -> walk
  }
}

fn add_profiles(walk: Walk, profiles: List(Profile)) -> Walk {
  use walk, profile <- list.fold(profiles, walk)
  use walk <- once(walk, profile.id)
  case profile.hidden {
    True -> walk
    False -> Walk(..walk, profiles: [profile, ..walk.profiles])
  }
}

fn add_rules(walk: Walk, rules: List(Rule)) -> Walk {
  use walk, rule <- list.fold(rules, walk)
  use walk <- once(walk, rule.id)
  case rule.hidden {
    True -> walk
    False -> Walk(..walk, rules: [rule, ..walk.rules])
  }
}

// --- Keyword rules ----------------------------------------------------------

/// The visible rules in scope whose text names one of the keywords, where
/// the name stands as a word of its own and matches case. `shown` are the
/// rules the page already has, which are left out.
fn keyword_rules(
  scope: Scope,
  keywords: List(#(String, String)),
  shown: List(Rule),
) -> List(KeywordRule) {
  let names =
    list.map(keywords, fn(keyword) { keyword.1 })
    |> list.filter(fn(name) { string.length(name) >= min_keyword_length })
  use <- bool.guard(names == [], [])
  let links = text.links(list.map(names, fn(name) { #(name, Nil) }))
  let shown = list.map(shown, fn(rule) { rule.id })
  use #(rule, owner_id) <- list.filter_map(scope.rules)
  // `segments` is slow on a long text, so it only gets the texts that hold a
  // name at all.
  let skipped =
    rule.hidden
    || list.contains(shown, rule.id)
    || !list.any(names, string.contains(rule.description, _))
  use <- bool.guard(skipped, Error(Nil))
  let names_a_keyword =
    list.any(text.segments(rule.description, links), fn(segment) {
      case segment {
        text.Link(..) -> True
        text.Text(..) -> False
      }
    })
  case names_a_keyword {
    True ->
      Ok(KeywordRule(
        rule:,
        owner: item_by_id(scope, owner_id) |> option.from_result,
      ))
    False -> Error(Nil)
  }
}
