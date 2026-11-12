//// Tabletop: the screens and the start-up work behind them. Opens storage,
//// asks the browser to keep it, records the first visit, loads the saved
//// lists, follows the screen in the URL hash, and offers a reload when a
//// newer build is out.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import tabletop/browser
import tabletop/roster.{type Roster, type Selection}
import tabletop/route.{type Route}
import tabletop/sheet
import tabletop/storage.{type Database, type Persistence, type StorageError}
import tabletop/text
import tabletop/version

pub fn main() -> Nil {
  let flags =
    Flags(running: browser.running_version(), hash: route.current_hash())
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}

/// What the page knows at start: the stamped version and `location.hash`.
pub type Flags {
  Flags(running: String, hash: String)
}

/// Each `Option` is `None` until the browser answers.
pub type Model {
  Model(
    running: String,
    route: Route,
    storage: Option(Result(Database, StorageError)),
    persistence: Option(Persistence),
    first_opened: Option(Result(Int, StorageError)),
    lists: Option(Result(List(Saved), StorageError)),
    problem: Option(Problem),
    /// The id of the list whose Delete was pressed and waits for Yes or No.
    confirming: Option(String),
    /// How far down each screen was when it was left, keyed by its hash.
    scroll: Dict(String, Float),
    update: Update,
  )
}

/// A saved list. `roster` is an error when its file no longer decodes.
pub type Saved {
  Saved(id: String, name: String, imported: Int, roster: Result(Roster, Nil))
}

/// What went wrong with the last import or delete.
pub type Problem {
  FileNotRead(reason: String)
  NotAList(roster.FileError)
  NotSaved(StorageError)
  NotDeleted(StorageError)
  NoStorage
}

pub type Update {
  UpToDate
  Available
  Applying
}

pub type Msg {
  StorageOpened(Result(Database, StorageError))
  FirstOpenedLoaded(Result(Int, StorageError))
  ListsLoaded(Result(List(Saved), StorageError))
  PersistAnswered(Persistence)
  VersionFetched(Result(String, String))
  VisibilityChanged(String)
  ReloadClicked
  WorkerActivated(Bool)
  ControllerChanged
  HashChanged(hash: String, left_at: Float)
  BackClicked
  FileChosen(input: Dynamic)
  FileRead(Result(#(String, String), String))
  ListSaved(Result(Saved, StorageError))
  DeleteClicked(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  ListDeleted(id: String, result: Result(Nil, StorageError))
}

const first_opened_key = "first_opened"

pub fn init(flags: Flags) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      running: flags.running,
      route: route.parse(flags.hash),
      storage: None,
      persistence: None,
      first_opened: None,
      lists: None,
      problem: None,
      confirming: None,
      scroll: dict.new(),
      update: UpToDate,
    )
  #(
    model,
    effect.batch([
      from_promise(storage.open, StorageOpened),
      from_promise(storage.persist, PersistAnswered),
      check_version(),
      listen(),
    ]),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    StorageOpened(Ok(db)) -> #(
      Model(..model, storage: Some(Ok(db))),
      effect.batch([
        from_promise(fn() { load_first_opened(db) }, FirstOpenedLoaded),
        from_promise(fn() { load_lists(db) }, ListsLoaded),
      ]),
    )
    StorageOpened(Error(error)) -> #(
      Model(
        ..model,
        storage: Some(Error(error)),
        first_opened: Some(Error(error)),
        lists: Some(Error(error)),
      ),
      effect.none(),
    )
    FirstOpenedLoaded(result) -> #(
      Model(..model, first_opened: Some(result)),
      effect.none(),
    )
    ListsLoaded(lists) -> #(Model(..model, lists: Some(lists)), effect.none())
    PersistAnswered(answer) -> #(
      Model(..model, persistence: Some(answer)),
      effect.none(),
    )
    VersionFetched(fetched) -> #(
      Model(..model, update: update_after_fetch(model, fetched)),
      effect.none(),
    )
    VisibilityChanged("visible") -> #(model, check_version())
    VisibilityChanged(_) -> #(model, effect.none())
    ReloadClicked -> #(
      Model(..model, update: Applying),
      from_promise(browser.activate_new_worker, WorkerActivated),
    )
    // The new worker takes over and fires ControllerChanged, which reloads.
    // ponytail: if its install fails nothing reloads; Reload stays on screen
    // and a second press tries again. Add a timeout if that ever bites.
    WorkerActivated(True) -> #(model, effect.none())
    WorkerActivated(False) -> #(model, reload())
    // A worker also takes over on the very first visit; reload only on request.
    ControllerChanged ->
      case model.update {
        Applying -> #(model, reload())
        UpToDate | Available -> #(model, effect.none())
      }
    // Remember where the screen being left was scrolled to, and go back to
    // where the next one was, or to its top.
    HashChanged(hash:, left_at:) -> {
      let scroll =
        dict.insert(model.scroll, route.to_hash(model.route), left_at)
      let next = route.parse(hash)
      let top = dict.get(scroll, route.to_hash(next)) |> result.unwrap(0.0)
      #(
        Model(..model, route: next, scroll:, confirming: None, problem: None),
        scroll_to(top),
      )
    }
    BackClicked -> #(model, {
      use _ <- effect.from
      browser.history_back()
    })
    FileChosen(input:) -> #(
      Model(..model, problem: None),
      from_promise(fn() { browser.read_chosen_file(input) }, FileRead),
    )
    FileRead(Error(reason)) -> #(
      Model(..model, problem: Some(FileNotRead(reason))),
      effect.none(),
    )
    FileRead(Ok(#(file_name, text))) ->
      case roster.decode(text), model.storage {
        Error(error), _ -> #(
          Model(..model, problem: Some(NotAList(error))),
          effect.none(),
        )
        Ok(decoded), Some(Ok(db)) -> #(
          model,
          from_promise(
            fn() { save_list(db, file_name, text, decoded) },
            ListSaved,
          ),
        )
        Ok(_), _ -> #(Model(..model, problem: Some(NoStorage)), effect.none())
      }
    ListSaved(Ok(saved)) -> #(
      Model(..model, lists: Some(Ok([saved, ..saved_lists(model)]))),
      effect.none(),
    )
    ListSaved(Error(error)) -> #(
      Model(..model, problem: Some(NotSaved(error))),
      effect.none(),
    )
    DeleteClicked(id:) -> #(
      Model(..model, confirming: Some(id), problem: None),
      effect.none(),
    )
    DeleteCancelled -> #(Model(..model, confirming: None), effect.none())
    DeleteConfirmed(id:) ->
      case model.storage {
        Some(Ok(db)) -> #(
          model,
          from_promise(fn() { storage.delete(db, storage.Lists, id) }, fn(done) {
            ListDeleted(id:, result: done)
          }),
        )
        _ -> #(
          Model(..model, confirming: None, problem: Some(NoStorage)),
          effect.none(),
        )
      }
    ListDeleted(id:, result: Ok(Nil)) -> {
      let lists = list.filter(saved_lists(model), fn(saved) { saved.id != id })
      #(Model(..model, confirming: None, lists: Some(Ok(lists))), effect.none())
    }
    ListDeleted(result: Error(error), ..) -> #(
      Model(..model, confirming: None, problem: Some(NotDeleted(error))),
      effect.none(),
    )
  }
}

fn saved_lists(model: Model) -> List(Saved) {
  case model.lists {
    Some(Ok(lists)) -> lists
    Some(Error(_)) | None -> []
  }
}

fn update_after_fetch(model: Model, fetched: Result(String, String)) -> Update {
  let running = version.parse(model.running)
  let latest =
    result.try(fetched, fn(text) {
      version.from_json(text) |> result.replace_error("")
    })
  case model.update, running, latest {
    UpToDate, Ok(running), Ok(latest) ->
      case version.is_newer(latest, than: running) {
        True -> Available
        False -> UpToDate
      }
    current, _, _ -> current
  }
}

/// When this device first opened the app, recorded now if this is the first time.
fn load_first_opened(db: Database) -> Promise(Result(Int, StorageError)) {
  use stored <- promise.try_await(storage.get(
    db,
    storage.Meta,
    first_opened_key,
    decode.int,
  ))
  case stored {
    Some(ms) -> promise.resolve(Ok(ms))
    None -> {
      let now = browser.now_ms()
      storage.put(db, storage.Meta, first_opened_key, json.int(now))
      |> promise.map(result.replace(_, now))
    }
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

fn from_promise(run: fn() -> Promise(a), to_msg: fn(a) -> Msg) -> Effect(Msg) {
  use dispatch <- effect.from
  let _ = promise.tap(run(), fn(value) { dispatch(to_msg(value)) })
  Nil
}

fn check_version() -> Effect(Msg) {
  from_promise(fn() { browser.fetch_no_store("version.json") }, VersionFetched)
}

fn listen() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.register_worker("sw.js")
  browser.on_visibility_change(fn(state) { dispatch(VisibilityChanged(state)) })
  browser.on_controller_change(fn() { dispatch(ControllerChanged) })
  browser.manual_scroll_restoration()
  route.on_hash_change(fn(hash) {
    dispatch(HashChanged(hash:, left_at: browser.scroll_y()))
  })
}

fn scroll_to(y: Float) -> Effect(Msg) {
  use _, _ <- effect.before_paint
  browser.scroll_to(y)
}

fn reload() -> Effect(Msg) {
  use _ <- effect.from
  browser.reload()
}

// --- Views ------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  let page = case model.route {
    route.Home -> home(model)
    route.ListPage(list_id:) -> with_list(model, list_id, list_page)
    route.UnitPage(list_id:, unit_id:) ->
      with_list(model, list_id, fn(saved, decoded) {
        unit_page(saved, decoded, unit_id)
      })
    route.RulePage(list_id:, rule_name:) ->
      with_list(model, list_id, fn(saved, decoded) {
        rule_page(saved, decoded, rule_name)
      })
  }
  html.main(
    [attribute.class("page")],
    list.append(page, [update_bar(model.update)]),
  )
}

fn home(model: Model) -> List(Element(Msg)) {
  [
    html.h1([], [html.text("Tabletop")]),
    html.div([attribute.class("import")], [
      html.input([
        attribute.type_("file"),
        attribute.id("import-file"),
        attribute.class("visually-hidden"),
        attribute.accept([".json", "application/json"]),
        event.on(
          "change",
          decode.at(["target"], decode.dynamic) |> decode.map(FileChosen),
        ),
      ]),
      html.label([attribute.for("import-file"), attribute.class("button big")], [
        html.text("Import a list"),
      ]),
    ]),
    case model.problem {
      None -> element.none()
      Some(problem) ->
        html.p([attribute.class("problem"), attribute.role("alert")], [
          html.text(describe_problem(problem)),
        ])
    },
    saved_lists_view(model),
    html.section([attribute.class("about")], [
      html.h2([], [html.text("About this device")]),
      html.dl([], [
        fact("Version", model.running),
        fact("Storage", storage_label(model.storage)),
        fact("Persistent storage", persistence_label(model.persistence)),
        fact(
          "First opened on this device",
          first_opened_label(model.first_opened),
        ),
      ]),
    ]),
  ]
}

fn saved_lists_view(model: Model) -> Element(Msg) {
  case model.lists {
    None -> html.p([attribute.class("note")], [html.text("Opening the lists…")])
    Some(Error(error)) ->
      html.p([attribute.class("note")], [
        html.text("The saved lists could not be read. " <> describe(error)),
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
            saved_row(saved, model.confirming == Some(saved.id))
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
          meta(sheet.format_costs(roster.totals(decoded))),
          meta("Imported " <> browser.local_time(saved.imported)),
        ],
      )
    Error(Nil) ->
      html.div([attribute.class("row-link")], [
        name,
        meta("This list could not be read"),
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
  model: Model,
  list_id: String,
  render: fn(Saved, Roster) -> List(Element(Msg)),
) -> List(Element(Msg)) {
  case model.lists {
    None -> [html.p([attribute.class("note")], [html.text("Opening…")])]
    Some(Error(error)) ->
      not_found("The saved lists could not be read. " <> describe(error))
    Some(Ok(lists)) ->
      case list.find(lists, fn(saved) { saved.id == list_id }) {
        Error(Nil) -> not_found("This list is not on this device.")
        Ok(Saved(roster: Error(Nil), ..)) ->
          not_found("This list could not be read.")
        Ok(Saved(roster: Ok(decoded), ..) as saved) -> render(saved, decoded)
      }
  }
}

fn not_found(message: String) -> List(Element(Msg)) {
  [
    back_link(route.Home, "All lists"),
    html.p([attribute.class("note")], [html.text(message)]),
  ]
}

fn list_page(saved: Saved, decoded: Roster) -> List(Element(Msg)) {
  let titled = list.length(decoded.forces) > 1
  [
    back_link(route.Home, "All lists"),
    html.h1([], [html.text(title(saved))]),
    costs(roster.totals(decoded)),
    ..list.map(decoded.forces, force_section(saved.id, _, titled))
  ]
}

fn force_section(
  list_id: String,
  force: roster.Force,
  titled: Bool,
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
          let values = list.map(setting.selections, fn(value) { value.name })
          html.li([], [
            html.span([attribute.class("setting-name")], [
              html.text(setting.name),
            ]),
            html.text(case values {
              [] -> ""
              _ -> ": " <> string.join(values, ", ")
            }),
          ])
        }),
      )
  }
  let rules =
    rule_chips(
      list_id,
      list.filter(force.rules, fn(rule) { !rule.hidden }),
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
  html.section([attribute.class("force")], [title, settings, rules, ..units])
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
        meta(sheet.format_costs(roster.unit_costs(unit))),
      ],
    ),
  ])
}

fn unit_page(
  saved: Saved,
  decoded: Roster,
  unit_id: String,
) -> List(Element(Msg)) {
  case roster.find_unit(decoded, unit_id) {
    Error(Nil) -> not_found("This unit is not in this list.")
    Ok(unit) -> {
      let text = rich_text(saved.id, rule_links(decoded), _)
      let keywords = list.map(unit.categories, fn(category) { category.name })
      list.flatten([
        [
          back_link(route.ListPage(saved.id), title(saved)),
          html.h1([], [html.text(unit.name)]),
          costs(roster.unit_costs(unit)),
        ],
        list.map(
          sheet.profile_groups(roster.unit_profiles(unit)),
          profile_group(_, text),
        ),
        [
          rule_chips(saved.id, roster.unit_rules(unit), html.h2),
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

fn profile_group(
  group: sheet.ProfileGroup,
  text: fn(String) -> List(Element(Msg)),
) -> Element(Msg) {
  case group {
    sheet.TextList(type_name:, items:) ->
      html.section([], [
        html.h2([], [html.text(type_name)]),
        html.ul(
          [attribute.class("text-list")],
          list.map(items, fn(item) {
            html.li([], [
              html.strong([], [html.text(item.0)]),
              html.div([attribute.class("prose")], text(item.1)),
            ])
          }),
        ),
      ])
    sheet.Table(type_name:, columns:, rows:) ->
      html.section([], [
        html.h2([], [html.text(type_name)]),
        html.div(
          [
            attribute.class("table-scroll"),
            attribute.role("region"),
            attribute.aria_label(type_name),
            attribute.tabindex(0),
          ],
          [
            html.table([], [
              html.thead([], [
                html.tr([], [
                  html.th([attribute.scope("col")], [html.text("Name")]),
                  ..list.map(columns, fn(column) {
                    html.th([attribute.scope("col")], [html.text(column)])
                  })
                ]),
              ]),
              html.tbody(
                [],
                list.map(rows, fn(row) {
                  html.tr([], [
                    html.th([attribute.scope("row")], [
                      html.text(row.name),
                      ..list.map(row.notes, fn(note) {
                        html.div([attribute.class("note")], [
                          html.span([attribute.class("note-label")], [
                            html.text(note.0),
                          ]),
                          html.text(" "),
                          ..text(note.1)
                        ])
                      })
                    ]),
                    ..list.map(row.cells, fn(cell) { html.td([], text(cell)) })
                  ])
                }),
              ),
            ]),
          ],
        ),
      ])
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

fn rule_page(
  saved: Saved,
  decoded: Roster,
  rule_name: String,
) -> List(Element(Msg)) {
  case roster.find_rule(decoded, rule_name) {
    Error(Nil) -> not_found("This rule is not in this list.")
    Ok(rule) -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("back"),
          event.on_click(BackClicked),
        ],
        [arrow(), html.text("Back")],
      ),
      html.h1([], [html.text(rule.name)]),
      html.div(
        [attribute.class("prose")],
        rich_text(saved.id, rule_links(decoded), rule.description),
      ),
    ]
  }
}

/// Every rule in the list a name can link to, the rule name as the target.
fn rule_links(decoded: Roster) -> text.Links(String) {
  roster.all_rules(decoded)
  |> list.map(fn(rule) { #(rule.name, rule.name) })
  |> text.links
}

/// Text with `**bold**` shown bold and rule names as links to the rule.
fn rich_text(
  list_id: String,
  links: text.Links(String),
  content: String,
) -> List(Element(Msg)) {
  use segment <- list.map(text.segments(content, links))
  case segment {
    text.Text(text: run, weight: text.Regular) -> html.text(run)
    text.Text(text: run, weight: text.Bold) -> html.strong([], [html.text(run)])
    text.Link(name:, target:, weight:) -> {
      let link =
        html.a(
          [attribute.href(route.to_hash(route.RulePage(list_id, target)))],
          [html.text(name)],
        )
      case weight {
        text.Regular -> link
        text.Bold -> html.strong([], [link])
      }
    }
  }
}

fn rule_chips(
  list_id: String,
  rules: List(sheet.Rule),
  heading: fn(List(attribute.Attribute(Msg)), List(Element(Msg))) ->
    Element(Msg),
) -> Element(Msg) {
  case rules {
    [] -> element.none()
    _ ->
      html.section([], [
        heading([], [html.text("Rules")]),
        html.ul(
          [attribute.class("chips")],
          list.map(rules, fn(rule) {
            html.li([], [
              html.a(
                [
                  attribute.href(
                    route.to_hash(route.RulePage(list_id, rule.name)),
                  ),
                ],
                [html.text(rule.name)],
              ),
            ])
          }),
        ),
      ])
  }
}

fn back_link(to: Route, label: String) -> Element(Msg) {
  html.a([attribute.class("back"), attribute.href(route.to_hash(to))], [
    arrow(),
    html.text(label),
  ])
}

fn arrow() -> Element(Msg) {
  html.span([attribute.aria_hidden(True)], [html.text("← ")])
}

fn costs(costs: List(sheet.Cost)) -> Element(Msg) {
  case costs {
    [] -> element.none()
    _ ->
      html.p([attribute.class("costs")], [
        html.text(sheet.format_costs(costs)),
      ])
  }
}

fn meta(text: String) -> Element(Msg) {
  html.span([attribute.class("meta")], [html.text(text)])
}

fn title(saved: Saved) -> String {
  case string.trim(saved.name) {
    "" -> "Untitled list"
    _ -> saved.name
  }
}

fn fact(term: String, detail: String) -> Element(Msg) {
  html.div([], [
    html.dt([], [html.text(term)]),
    html.dd([], [html.text(detail)]),
  ])
}

fn update_bar(update: Update) -> Element(Msg) {
  case update {
    UpToDate -> element.none()
    Available | Applying ->
      html.div([attribute.class("update-bar"), attribute.role("status")], [
        html.span([], [html.text("New version")]),
        html.button([attribute.type_("button"), event.on_click(ReloadClicked)], [
          html.text("Reload"),
        ]),
      ])
  }
}

fn storage_label(storage: Option(Result(Database, StorageError))) -> String {
  case storage {
    None -> "Opening…"
    Some(Ok(_)) -> "Open"
    Some(Error(error)) -> describe(error)
  }
}

fn persistence_label(persistence: Option(Persistence)) -> String {
  case persistence {
    None -> "Asking the browser…"
    Some(storage.Persistent) -> "Granted"
    Some(storage.NotPersistent) ->
      "Not granted. The browser may clear saved data when space runs low."
    Some(storage.PersistUnavailable) -> "Not available in this browser"
  }
}

fn first_opened_label(
  first_opened: Option(Result(Int, StorageError)),
) -> String {
  case first_opened {
    None -> "Reading…"
    Some(Ok(ms)) -> browser.local_time(ms)
    Some(Error(error)) -> "Unknown. " <> describe(error)
  }
}

fn describe(error: StorageError) -> String {
  case error {
    storage.OpenFailed(reason) -> "Could not open. " <> reason
    storage.ReadFailed(reason) -> "Could not read. " <> reason
    storage.WriteFailed(reason) -> "Could not save. " <> reason
    storage.DeleteFailed(reason) -> "Could not delete. " <> reason
    storage.Undecodable(key) -> "The saved " <> key <> " could not be read."
  }
}

fn describe_problem(problem: Problem) -> String {
  case problem {
    FileNotRead(reason) -> "That file could not be read. " <> reason
    NotAList(roster.NotJson) ->
      "That file is not a list export. It is not JSON."
    NotAList(roster.NoRoster) ->
      "That file is JSON, but not a list export. It has no roster in it."
    NotAList(roster.UnexpectedShape(at:)) ->
      "That list file has something this app cannot read, at " <> at <> "."
    NotSaved(error) -> "The list could not be saved. " <> describe(error)
    NotDeleted(error) -> "The list could not be deleted. " <> describe(error)
    NoStorage -> "Storage is not open on this device, so lists cannot change."
  }
}
