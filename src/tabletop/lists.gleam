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
    list_name: String,
    force_name: String,
    unit_name: String,
    unit_points: String,
    rule_name: String,
    rule_text: String,
    draft_units: List(DraftUnit),
    builder_problem: Option(String),
  )
}

pub type DraftUnit {
  DraftUnit(
    name: String,
    points: Int,
    rule_name: String,
    rule_text: String,
    preview_html: String,
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
  ListNameChanged(String)
  ForceNameChanged(String)
  UnitNameChanged(String)
  UnitPointsChanged(String)
  RuleNameChanged(String)
  RuleTextChanged(String)
  AddUnitClicked
  RemoveUnitClicked(index: Int)
  CreateListClicked
  ListCreated(Result(Saved, StorageError))
  BackClicked
}

pub fn init() -> State {
  State(
    lists: None,
    problem: None,
    confirming: None,
    list_name: "",
    force_name: "",
    unit_name: "",
    unit_points: "",
    rule_name: "",
    rule_text: "",
    draft_units: [],
    builder_problem: None,
  )
}

/// Add a locally imported web page to the list being built.
pub fn add_imported_entry(
  state: State,
  name: String,
  points: Int,
  details: String,
  preview_html: String,
) -> State {
  let rule_name = case details == "" {
    True -> ""
    False -> "Imported page details"
  }
  State(
    ..state,
    draft_units: list.append(state.draft_units, [
      DraftUnit(name:, points:, rule_name:, rule_text: details, preview_html:),
    ]),
    builder_problem: None,
  )
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
    ListNameChanged(value) -> #(
      State(..state, list_name: value, builder_problem: None),
      effect.none(),
    )
    ForceNameChanged(value) -> #(
      State(..state, force_name: value, builder_problem: None),
      effect.none(),
    )
    UnitNameChanged(value) -> #(
      State(..state, unit_name: value, builder_problem: None),
      effect.none(),
    )
    UnitPointsChanged(value) -> #(
      State(..state, unit_points: value, builder_problem: None),
      effect.none(),
    )
    RuleNameChanged(value) -> #(
      State(..state, rule_name: value, builder_problem: None),
      effect.none(),
    )
    RuleTextChanged(value) -> #(
      State(..state, rule_text: value, builder_problem: None),
      effect.none(),
    )
    AddUnitClicked -> #(add_draft_unit(state), effect.none())
    RemoveUnitClicked(index:) -> #(
      State(
        ..state,
        draft_units: remove_draft_unit(state.draft_units, index),
        builder_problem: None,
      ),
      effect.none(),
    )
    CreateListClicked -> create_list(state, db)
    ListCreated(Ok(saved)) -> #(
      State(
        ..state,
        lists: Some(Ok([saved, ..saved_lists(state)])),
        builder_problem: None,
      ),
      effect.from(fn(_) { route.go(route.ListPage(saved.id)) }),
    )
    ListCreated(Error(error)) -> #(
      State(
        ..state,
        builder_problem: Some(
          "The list could not be saved. "
          <> sheet_view.describe_storage_error(error),
        ),
      ),
      effect.none(),
    )
    BackClicked -> #(state, {
      use _ <- effect.from
      browser.history_back()
    })
  }
}

fn add_draft_unit(state: State) -> State {
  case int.parse(string.trim(state.unit_points)) {
    Error(Nil) ->
      State(..state, builder_problem: Some("Enter a whole number of points."))
    Ok(points) if points < 0 ->
      State(..state, builder_problem: Some("Points cannot be below zero."))
    Ok(points) ->
      case string.is_empty(string.trim(state.unit_name)) {
        True -> State(..state, builder_problem: Some("Enter an entry name."))
        False ->
          State(
            ..state,
            unit_name: "",
            unit_points: "",
            rule_name: "",
            rule_text: "",
            draft_units: list.append(state.draft_units, [
              DraftUnit(
                name: string.trim(state.unit_name),
                points:,
                rule_name: string.trim(state.rule_name),
                rule_text: string.trim(state.rule_text),
                preview_html: "",
              ),
            ]),
            builder_problem: None,
          )
      }
  }
}

fn remove_draft_unit(units: List(DraftUnit), index: Int) -> List(DraftUnit) {
  case units, index {
    [], _ -> []
    [_, ..rest], 0 -> rest
    [unit, ..rest], index -> [unit, ..remove_draft_unit(rest, index - 1)]
  }
}

fn create_list(
  state: State,
  db: Option(Result(Database, StorageError)),
) -> #(State, Effect(Msg)) {
  case
    string.is_empty(string.trim(state.list_name)),
    string.is_empty(string.trim(state.force_name)),
    state.draft_units,
    db
  {
    True, _, _, _ -> #(
      State(..state, builder_problem: Some("Enter a list name.")),
      effect.none(),
    )
    _, True, _, _ -> #(
      State(..state, builder_problem: Some("Enter a force name.")),
      effect.none(),
    )
    _, _, [], _ -> #(
      State(..state, builder_problem: Some("Add at least one entry.")),
      effect.none(),
    )
    _, _, _, Some(Ok(db)) -> {
      let text = built_list_text(state)
      case roster.decode(text) {
        Ok(decoded) -> #(
          state,
          effects.from_promise(
            fn() { save_list(db, "list.json", text, decoded) },
            ListCreated,
          ),
        )
        Error(_) -> #(
          State(
            ..state,
            builder_problem: Some("The list could not be prepared."),
          ),
          effect.none(),
        )
      }
    }
    _, _, _, _ -> #(
      State(
        ..state,
        builder_problem: Some("Storage is not open on this device."),
      ),
      effect.none(),
    )
  }
}

fn built_list_text(state: State) -> String {
  json.object([
    #(
      "roster",
      json.object([
        #("name", json.string(string.trim(state.list_name))),
        #(
          "forces",
          json.array([state], fn(_) {
            json.object([
              #("name", json.string(string.trim(state.force_name))),
              #("catalogueName", json.string(string.trim(state.force_name))),
              #(
                "selections",
                json.array(draft_unit_jsons(state.draft_units, 0), fn(unit) {
                  unit
                }),
              ),
            ])
          }),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

fn draft_unit_jsons(units: List(DraftUnit), index: Int) -> List(json.Json) {
  case units {
    [] -> []
    [unit, ..rest] -> [
      draft_unit_json(unit, index),
      ..draft_unit_jsons(rest, index + 1)
    ]
  }
}

fn draft_unit_json(unit: DraftUnit, index: Int) -> json.Json {
  let rules = case unit.rule_name, unit.rule_text {
    "", "" -> []
    "", description -> [
      json.object([
        #("name", json.string("Note")),
        #("description", json.string(description)),
      ]),
    ]
    name, description -> [
      json.object([
        #("name", json.string(name)),
        #("description", json.string(description)),
      ]),
    ]
  }
  json.object([
    #("id", json.string("entry-" <> int.to_string(index))),
    #("name", json.string(unit.name)),
    #("type", json.string("unit")),
    #("number", json.int(1)),
    #(
      "costs",
      json.array([unit.points], fn(points) {
        json.object([
          #("name", json.string("Points")),
          #("typeId", json.string("points")),
          #("value", json.int(points)),
        ])
      }),
    ),
    #("rules", json.array(rules, fn(rule) { rule })),
  ])
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

/// The id and title of every list that can be read, newest first, for a
/// picker in another feature.
pub fn names(state: State) -> List(#(String, String)) {
  saved_lists(state)
  |> list.filter(fn(saved) { result.is_ok(saved.roster) })
  |> list.sort(fn(a, b) { int.compare(b.imported, a.imported) })
  |> list.map(fn(saved) { #(saved.id, title(saved)) })
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
    html.div([attribute.class("actions")], [
      html.a(
        [
          attribute.class("button primary"),
          attribute.href(route.to_hash(route.NewListPage)),
        ],
        [html.text("Build a list")],
      ),
    ]),
    saved_lists_view(state),
  ]
}

/// A blank list form. Names, points and rule notes come from the person using
/// the app; the saved list stays in this device's browser storage.
pub fn new_list_page(state: State) -> List(Element(Msg)) {
  [
    sheet_view.back_link(route.Home, "All lists"),
    html.h1([], [html.text("Build a list")]),
    html.div([attribute.class("import")], [
      html.label(
        [attribute.for("import-file"), attribute.class("button primary")],
        [html.text("Import game data ZIP")],
      ),
      html.p([attribute.class("note")], [
        html.text(
          "Choose a game data ZIP saved on this device. Imported data appears below for reference while you build your list.",
        ),
      ]),
    ]),
    html.p([attribute.class("note")], [
      html.text("Your list and imported data stay on this device."),
    ]),
    case state.builder_problem {
      None -> element.none()
      Some(problem) ->
        html.p([attribute.class("problem"), attribute.role("alert")], [
          html.text(problem),
        ])
    },
    builder_text_field(
      "List name",
      "builder-list-name",
      state.list_name,
      ListNameChanged,
    ),
    builder_text_field(
      "Force name",
      "builder-force-name",
      state.force_name,
      ForceNameChanged,
    ),
    html.h2([], [html.text("Units in this list")]),
    case state.draft_units {
      [] ->
        html.p([attribute.class("note")], [
          html.text("No entries added yet."),
        ])
      units -> html.ul([attribute.class("rows")], draft_unit_rows(units, 0))
    },
    html.p([attribute.class("costs")], [
      html.text(
        "Total: " <> int.to_string(draft_total(state.draft_units)) <> " Points",
      ),
    ]),
    html.div([attribute.class("actions")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("button primary"),
          attribute.disabled(list.is_empty(state.draft_units)),
          event.on_click(CreateListClicked),
        ],
        [html.text("Save list")],
      ),
    ]),
  ]
}

fn builder_text_field(
  label: String,
  id: String,
  value: String,
  changed: fn(String) -> Msg,
) -> Element(Msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.id(id),
      attribute.value(value),
      attribute.autocomplete("off"),
      event.on_input(changed),
    ]),
  ])
}

fn draft_unit_rows(units: List(DraftUnit), index: Int) -> List(Element(Msg)) {
  case units {
    [] -> []
    [unit, ..rest] -> [
      html.li([attribute.class("saved")], [
        html.div([attribute.class("row-link")], [
          html.span([attribute.class("name")], [html.text(unit.name)]),
          sheet_view.meta(int.to_string(unit.points) <> " Points"),
          case unit.rule_name, unit.rule_text {
            "", "" -> element.none()
            "", _ -> sheet_view.meta("Rule note added")
            name, _ -> sheet_view.meta(name)
          },
        ]),
        case unit.rule_text {
          "" -> element.none()
          _ ->
            html.details([], [
              html.summary([], [html.text("View unit details")]),
              case unit.preview_html {
                "" ->
                  html.pre([attribute.class("unit-details")], [
                    html.text(unit.rule_text),
                  ])
                preview_html ->
                  html.iframe([
                    attribute.class("unit-details-frame"),
                    attribute.attribute("title", unit.name <> " details"),
                    attribute.attribute("sandbox", ""),
                    attribute.attribute("srcdoc", preview_html),
                  ])
              },
            ])
        },
        html.button(
          [
            attribute.type_("button"),
            attribute.class("button quiet"),
            event.on_click(RemoveUnitClicked(index:)),
          ],
          [html.text("Remove")],
        ),
      ]),
      ..draft_unit_rows(rest, index + 1)
    ]
  }
}

fn draft_total(units: List(DraftUnit)) -> Int {
  list.fold(units, 0, fn(total, unit) { total + unit.points })
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
          // The cards, one tap away and never several screens down.
          links.unit_cards(decoded.game_system_id, values, keywords),
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
