//// The list feature: the lists saved on this device, importing a list file,
//// deleting a list, and the list, unit and rule screens. The shell in
//// `tabletop.gleam` holds its `State`, wraps its `Msg`, reads a chosen file
//// and hands its text to `import_file`, sends it the list routes, and hands
//// the list screens their links into game data and their cards.

import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import tabletop/browser
import tabletop/effects
import tabletop/roster.{type Roster, type Selection}
import tabletop/route
import tabletop/sheet
import tabletop/sheet_view
import tabletop/storage.{type Database, type StorageError}
import tabletop/text

pub type State {
  State(
    /// `None` until the saved lists are read.
    lists: Option(Result(List(Saved), StorageError)),
    problem: Option(Problem),
    /// The id of the list whose Delete was pressed and waits for Yes or No.
    confirming: Option(String),
  )
}

/// A saved list. `roster` is an error when its file no longer decodes.
pub type Saved {
  Saved(id: String, name: String, imported: Int, roster: Result(Roster, Nil))
}

/// What went wrong with the last import or delete.
pub type Problem {
  NotAList(roster.FileError)
  NotSaved(StorageError)
  NotDeleted(StorageError)
  NoStorage
}

/// Links from a list into game data, and the cards that go with it, which
/// the shell makes. `entry` and `value` take a force's catalogue id and a
/// selection's entry ids, and give a link or nothing: `entry` for a unit or a
/// setting, `value` for a setting's chosen value. `cards` takes the list's
/// game system id and a force's chosen setting values, each a name and entry
/// ids, and gives the force's cards. `unit_cards` takes the same and a unit's
/// keywords, and gives the cards for that unit. The cards need no game data
/// loaded.
pub type DataLinks {
  DataLinks(
    entry: fn(String, List(String)) -> Option(String),
    value: fn(String, List(String)) -> Option(String),
    cards: fn(String, List(#(String, List(String)))) -> Element(Msg),
    unit_cards: fn(String, List(#(String, List(String))), List(String)) ->
      Element(Msg),
  )
}

pub type Msg {
  ListsLoaded(Result(List(Saved), StorageError))
  ListSaved(Result(Saved, StorageError))
  DeleteClicked(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  ListDeleted(id: String, result: Result(Nil, StorageError))
  BackClicked
}

pub fn init() -> State {
  State(lists: None, problem: None, confirming: None)
}

/// Read the saved lists once storage has answered. When storage did not open,
/// the lists show why.
pub fn load(db: Result(Database, StorageError)) -> Effect(Msg) {
  case db {
    Ok(db) -> effects.from_promise(fn() { load_lists(db) }, ListsLoaded)
    Error(error) -> {
      use dispatch <- effect.from
      dispatch(ListsLoaded(Error(error)))
    }
  }
}

/// `db` is the open database or the reason it is not open, and `None` while
/// it opens.
pub fn update(
  state: State,
  msg: Msg,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case msg {
    ListsLoaded(lists) -> #(State(..state, lists: Some(lists)), effect.none())
    ListSaved(Ok(saved)) -> #(
      State(..state, lists: Some(Ok([saved, ..saved_lists(state)]))),
      effect.none(),
    )
    ListSaved(Error(error)) -> #(
      State(..state, problem: Some(NotSaved(error))),
      effect.none(),
    )
    DeleteClicked(id:) -> #(
      State(..state, confirming: Some(id), problem: None),
      effect.none(),
    )
    DeleteCancelled -> #(State(..state, confirming: None), effect.none())
    DeleteConfirmed(id:) ->
      case db {
        Some(Ok(db)) -> #(
          state,
          effects.from_promise(
            fn() { storage.delete(db, storage.Lists, id) },
            fn(done) { ListDeleted(id:, result: done) },
          ),
        )
        _ -> #(
          State(..state, confirming: None, problem: Some(NoStorage)),
          effect.none(),
        )
      }
    ListDeleted(id:, result: Ok(Nil)) -> {
      let lists = list.filter(saved_lists(state), fn(saved) { saved.id != id })
      #(State(..state, confirming: None, lists: Some(Ok(lists))), effect.none())
    }
    ListDeleted(result: Error(error), ..) -> #(
      State(..state, confirming: None, problem: Some(NotDeleted(error))),
      effect.none(),
    )
    BackClicked -> #(state, {
      use _ <- effect.from
      browser.history_back()
    })
  }
}

/// What happens after the shell has read a chosen file: a list file is saved,
/// and anything else says why not.
pub fn import_file(
  state: State,
  db: Option(Result(Database, StorageError)),
  file_name: String,
  text: String,
) -> #(State, Effect(Msg)) {
  case roster.decode(text), db {
    Error(error), _ -> #(
      State(..state, problem: Some(NotAList(error))),
      effect.none(),
    )
    Ok(decoded), Some(Ok(db)) -> #(
      state,
      effects.from_promise(
        fn() { save_list(db, file_name, text, decoded) },
        ListSaved,
      ),
    )
    Ok(_), _ -> #(State(..state, problem: Some(NoStorage)), effect.none())
  }
}

/// The shell started reading a chosen file: the last problem goes.
pub fn file_chosen(state: State) -> State {
  State(..state, problem: None)
}

/// The screen changed: the last problem and an open delete question go.
pub fn screen_changed(state: State) -> State {
  State(..state, problem: None, confirming: None)
}

fn saved_lists(state: State) -> List(Saved) {
  case state.lists {
    Some(Ok(lists)) -> lists
    Some(Error(_)) | None -> []
  }
}

/// A saved list is stored as its name, when it was imported, and the file's
/// full text, unchanged, so a later version can read more from the same file.
fn record_decoder() -> decode.Decoder(#(String, Int, String)) {
  use name <- decode.field("name", decode.string)
  use imported <- decode.field("imported", decode.int)
  use file <- decode.field("file", decode.string)
  decode.success(#(name, imported, file))
}

fn load_lists(db: Database) -> Promise(Result(List(Saved), StorageError)) {
  use records <- promise.map(storage.get_all(
    db,
    storage.Lists,
    record_decoder(),
  ))
  use records <- result.map(records)
  use #(id, record) <- list.map(records)
  case record {
    Ok(#(name, imported, file)) ->
      Saved(
        id:,
        name:,
        imported:,
        roster: roster.decode(file) |> result.replace_error(Nil),
      )
    Error(_) -> Saved(id:, name: "", imported: 0, roster: Error(Nil))
  }
}

/// The list's own name, or the file's name when the list has none.
fn save_list(
  db: Database,
  file_name: String,
  text: String,
  decoded: Roster,
) -> Promise(Result(Saved, StorageError)) {
  let id = browser.random_id()
  let imported = browser.now_ms()
  let name = case string.trim(decoded.name) {
    "" -> file_name
    _ -> decoded.name
  }
  let record =
    json.object([
      #("name", json.string(name)),
      #("imported", json.int(imported)),
      #("file", json.string(text)),
    ])
  storage.put(db, storage.Lists, id, record)
  |> promise.map(result.replace(
    _,
    Saved(id:, name:, imported:, roster: Ok(decoded)),
  ))
}

// --- Views ------------------------------------------------------------------

/// The list feature's part of the home screen: the last problem, then the
/// saved lists.
pub fn home(state: State) -> List(Element(Msg)) {
  [
    case state.problem {
      None -> element.none()
      Some(problem) ->
        html.p([attribute.class("problem"), attribute.role("alert")], [
          html.text(describe_problem(problem)),
        ])
    },
    saved_lists_view(state),
  ]
}

fn saved_lists_view(state: State) -> Element(Msg) {
  case state.lists {
    None -> html.p([attribute.class("note")], [html.text("Opening the lists…")])
    Some(Error(error)) ->
      html.p([attribute.class("note")], [
        html.text(
          "The saved lists could not be read. "
          <> sheet_view.describe_storage_error(error),
        ),
      ])
    Some(Ok([])) ->
      html.p([attribute.class("note")], [
        html.text(
          "No lists yet. Export a list as a JSON file from your list builder, then import it here.",
        ),
      ])
    Some(Ok(lists)) ->
      html.ul(
        [attribute.class("rows")],
        lists
          |> list.sort(fn(a, b) { int.compare(b.imported, a.imported) })
          |> list.map(fn(saved) {
            saved_row(saved, state.confirming == Some(saved.id))
          }),
      )
  }
}

fn saved_row(saved: Saved, confirming: Bool) -> Element(Msg) {
  let name = html.span([attribute.class("name")], [html.text(title(saved))])
  let summary = case saved.roster {
    Ok(decoded) ->
      html.a(
        [
          attribute.class("row-link"),
          attribute.href(route.to_hash(route.ListPage(saved.id))),
        ],
        [
          name,
          sheet_view.meta(sheet.format_costs(roster.totals(decoded))),
          sheet_view.meta("Imported " <> browser.local_time(saved.imported)),
        ],
      )
    Error(Nil) ->
      html.div([attribute.class("row-link")], [
        name,
        sheet_view.meta("This list could not be read"),
      ])
  }
  let delete = case confirming {
    False ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("button quiet"),
          event.on_click(DeleteClicked(saved.id)),
        ],
        [html.text("Delete")],
      )
    True ->
      html.div([attribute.class("confirm"), attribute.role("group")], [
        html.span([], [html.text("Delete this list?")]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button danger"),
            event.on_click(DeleteConfirmed(saved.id)),
          ],
          [html.text("Yes")],
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button"),
            attribute.autofocus(True),
            event.on_click(DeleteCancelled),
          ],
          [html.text("No")],
        ),
      ])
  }
  html.li([attribute.class("saved")], [summary, delete])
}

/// The page for one saved list, or a plain message when it is not there.
fn with_list(
  state: State,
  list_id: String,
  render: fn(Saved, Roster) -> List(Element(Msg)),
) -> List(Element(Msg)) {
  case state.lists {
    None -> [html.p([attribute.class("note")], [html.text("Opening…")])]
    Some(Error(error)) ->
      sheet_view.not_found(
        "The saved lists could not be read. "
        <> sheet_view.describe_storage_error(error),
      )
    Some(Ok(lists)) ->
      case list.find(lists, fn(saved) { saved.id == list_id }) {
        Error(Nil) -> sheet_view.not_found("This list is not on this device.")
        Ok(Saved(roster: Error(Nil), ..)) ->
          sheet_view.not_found("This list could not be read.")
        Ok(Saved(roster: Ok(decoded), ..) as saved) -> render(saved, decoded)
      }
  }
}

/// The list screen: its settings, rules and units, per force.
pub fn list_page(
  state: State,
  list_id: String,
  links: DataLinks,
) -> List(Element(Msg)) {
  use saved, decoded <- with_list(state, list_id)
  let titled = list.length(decoded.forces) > 1
  [
    sheet_view.back_link(route.Home, "All lists"),
    html.h1([], [html.text(title(saved))]),
    sheet_view.costs(roster.totals(decoded)),
    ..list.map(decoded.forces, force_section(
      saved.id,
      decoded.game_system_id,
      _,
      titled,
      links,
    ))
  ]
}

fn force_section(
  list_id: String,
  game_system_id: String,
  force: roster.Force,
  titled: Bool,
  links: DataLinks,
) -> Element(Msg) {
  let #(title, heading) = case titled {
    True -> #(
      html.h2([], [
        html.text(force.name),
        html.small([], [html.text(force.catalogue_name)]),
      ]),
      html.h3,
    )
    False -> #(element.none(), html.h2)
  }
  let settings = case roster.settings(force) {
    [] -> element.none()
    settings ->
      html.ul(
        [attribute.class("settings")],
        list.map(settings, fn(setting) {
          let values =
            list.map(setting.selections, fn(value) {
              case links.value(force.catalogue_id, value.entry_ids) {
                Some(href) ->
                  html.a([attribute.href(href)], [html.text(value.name)])
                None -> html.text(value.name)
              }
            })
          html.li([], [
            html.span([attribute.class("setting-name")], [
              html.text(setting.name),
            ]),
            ..case values {
              [] -> []
              _ -> [
                html.text(": "),
                ..list.intersperse(values, html.text(", "))
              ]
            }
          ])
        }),
      )
  }
  let rules =
    sheet_view.rule_chips(
      list.filter(force.rules, fn(rule) { !rule.hidden }),
      rule_chip_href(list_id, _),
      heading,
    )
  let units =
    roster.by_primary_category(roster.units(force))
    |> list.map(fn(group) {
      let #(category, units) = group
      html.section([], [
        heading([], [html.text(option.unwrap(category, "Other"))]),
        html.ul(
          [attribute.class("rows")],
          list.map(units, unit_row(list_id, _)),
        ),
      ])
    })
  html.section([attribute.class("force")], [
    title,
    settings,
    links.cards(game_system_id, chosen_values(force)),
    rules,
    ..units
  ])
}

/// Each chosen value of the force's settings, as its name and entry ids.
fn chosen_values(force: roster.Force) -> List(#(String, List(String))) {
  roster.settings(force)
  |> list.flat_map(fn(setting) { setting.selections })
  |> list.map(fn(value) { #(value.name, value.entry_ids) })
}

fn unit_row(list_id: String, unit: Selection) -> Element(Msg) {
  html.li([], [
    html.a(
      [
        attribute.class("row-link"),
        attribute.href(route.to_hash(route.UnitPage(list_id, unit.id))),
      ],
      [
        html.span([attribute.class("name")], [html.text(unit.name)]),
        sheet_view.meta(sheet.format_costs(roster.unit_costs(unit))),
      ],
    ),
  ])
}

/// The unit screen: its datasheet, with rule names in the text linking to the
/// rule screen.
pub fn unit_page(
  state: State,
  list_id: String,
  unit_id: String,
  links: DataLinks,
) -> List(Element(Msg)) {
  use saved, decoded <- with_list(state, list_id)
  case roster.find_unit(decoded, unit_id) {
    Error(Nil) -> sheet_view.not_found("This unit is not in this list.")
    Ok(unit) -> {
      let href = rule_href(saved.id, _)
      let text = sheet_view.rich_text(_, rule_links(decoded), href)
      let keywords = list.map(unit.categories, fn(category) { category.name })
      let force =
        list.find(decoded.forces, fn(force) {
          list.any(roster.units(force), fn(other) { other.id == unit_id })
        })
      let catalogue_id =
        result.map(force, fn(force) { force.catalogue_id }) |> result.unwrap("")
      let values = result.map(force, chosen_values) |> result.unwrap([])
      list.flatten([
        [
          sheet_view.back_link(route.ListPage(saved.id), title(saved)),
          html.h1([], [html.text(unit.name)]),
          case links.entry(catalogue_id, unit.entry_ids) {
            Some(href) ->
              html.p([], [
                html.a([attribute.class("button"), attribute.href(href)], [
                  html.text("Open in game data"),
                ]),
              ])
            None -> element.none()
          },
          sheet_view.costs(roster.unit_costs(unit)),
        ],
        list.map(
          sheet.profile_groups(roster.unit_profiles(unit)),
          sheet_view.profile_group(_, text),
        ),
        [
          sheet_view.rule_chips(
            roster.unit_rules(unit),
            rule_chip_href(saved.id, _),
            html.h2,
          ),
          case keywords {
            [] -> element.none()
            _ ->
              html.section([], [
                html.h2([], [html.text("Keywords")]),
                html.p([attribute.class("keywords")], [
                  html.text(string.join(keywords, ", ")),
                ]),
              ])
          },
          links.unit_cards(decoded.game_system_id, values, keywords),
          case unit.selections {
            [] -> element.none()
            children ->
              html.section([], [
                html.h2([], [html.text("Includes")]),
                includes(children),
              ])
          },
        ],
      ])
    }
  }
}

fn includes(selections: List(Selection)) -> Element(Msg) {
  html.ul(
    [attribute.class("includes")],
    list.map(selections, fn(selection) {
      let label = case selection.number > 1 {
        True -> int.to_string(selection.number) <> "× " <> selection.name
        False -> selection.name
      }
      html.li([], [
        html.text(label),
        case selection.selections {
          [] -> element.none()
          children -> includes(children)
        },
      ])
    }),
  )
}

/// The rule screen: one rule's text, with a button back to where it was opened.
pub fn rule_page(
  state: State,
  list_id: String,
  rule_name: String,
) -> List(Element(Msg)) {
  use saved, decoded <- with_list(state, list_id)
  case roster.find_rule(decoded, rule_name) {
    Error(Nil) -> sheet_view.not_found("This rule is not in this list.")
    Ok(rule) -> {
      let href = rule_href(saved.id, _)
      [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("back"),
            event.on_click(BackClicked),
          ],
          [sheet_view.arrow(), html.text("Back")],
        ),
        html.h1([], [html.text(rule.name)]),
        html.div(
          [attribute.class("prose")],
          sheet_view.rich_text(rule.description, rule_links(decoded), href),
        ),
      ]
    }
  }
}

/// Every rule in the list a name can link to, the rule name as the target.
fn rule_links(decoded: Roster) -> text.Links(String) {
  roster.all_rules(decoded)
  |> list.map(fn(rule) { #(rule.name, rule.name) })
  |> text.links
}

fn rule_href(list_id: String, rule_name: String) -> String {
  route.to_hash(route.RulePage(list_id, rule_name))
}

fn rule_chip_href(list_id: String, rule: sheet.Rule) -> String {
  rule_href(list_id, rule.name)
}

fn title(saved: Saved) -> String {
  case string.trim(saved.name) {
    "" -> "Untitled list"
    _ -> saved.name
  }
}

fn describe_problem(problem: Problem) -> String {
  case problem {
    NotAList(roster.NotJson) ->
      "That file is not a list export. It is not JSON."
    NotAList(roster.NoRoster) ->
      "That file is JSON, but not a list export. It has no roster in it."
    NotAList(roster.UnexpectedShape(at:)) ->
      "That list file has something this app cannot read, at " <> at <> "."
    NotSaved(error) ->
      "The list could not be saved. "
      <> sheet_view.describe_storage_error(error)
    NotDeleted(error) ->
      "The list could not be deleted. "
      <> sheet_view.describe_storage_error(error)
    NoStorage -> "Storage is not open on this device, so lists cannot change."
  }
}
