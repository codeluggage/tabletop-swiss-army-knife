//// The views every feature uses to show a datasheet: profile tables, text
//// with links, rule chips, costs and the small pieces around them. Each works
//// for any message type, and a feature says where a link goes with an `href`
//// function, so no feature imports another feature's messages.

import gleam/list
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import tabletop/route.{type Route}
import tabletop/sheet.{type Cost, type ProfileGroup, type Rule}
import tabletop/storage.{type StorageError}
import tabletop/text.{type Links}

/// One profile group as a section. `show_text` turns a value into elements,
/// such as `rich_text` with the feature's links.
pub fn profile_group(
  group: ProfileGroup,
  show_text: fn(String) -> List(Element(msg)),
) -> Element(msg) {
  case group {
    sheet.TextList(type_name:, items:) ->
      html.section([], [
        html.h2([], [html.text(type_name)]),
        html.ul(
          [attribute.class("text-list")],
          list.map(items, fn(item) {
            html.li([], [
              html.strong([], [html.text(item.0)]),
              html.div([attribute.class("prose")], show_text(item.1)),
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
                          ..show_text(note.1)
                        ])
                      })
                    ]),
                    ..list.map(row.cells, fn(cell) {
                      html.td([], show_text(cell))
                    })
                  ])
                }),
              ),
            ]),
          ],
        ),
      ])
  }
}

/// Text with `**bold**` and `^^keyword^^` shown bold and each linked name as
/// a link to `href(target)`.
pub fn rich_text(
  content: String,
  links: Links(target),
  href: fn(target) -> String,
) -> List(Element(msg)) {
  use segment <- list.map(text.segments(content, links))
  case segment {
    text.Text(text: run, weight: text.Regular) -> html.text(run)
    text.Text(text: run, weight: text.Bold) -> html.strong([], [html.text(run)])
    text.Link(name:, target:, weight:) -> {
      let link = html.a([attribute.href(href(target))], [html.text(name)])
      case weight {
        text.Regular -> link
        text.Bold -> html.strong([], [link])
      }
    }
  }
}

/// The rules as links under a "Rules" heading, nothing when there are none.
pub fn rule_chips(
  rules: List(Rule),
  href: fn(Rule) -> String,
  heading: fn(List(Attribute(msg)), List(Element(msg))) -> Element(msg),
) -> Element(msg) {
  case rules {
    [] -> element.none()
    _ ->
      html.section([], [
        heading([], [html.text("Rules")]),
        html.ul(
          [attribute.class("chips")],
          list.map(rules, fn(rule) {
            html.li([], [
              html.a([attribute.href(href(rule))], [html.text(rule.name)]),
            ])
          }),
        ),
      ])
  }
}

pub fn costs(costs: List(Cost)) -> Element(msg) {
  case costs {
    [] -> element.none()
    _ ->
      html.p([attribute.class("costs")], [
        html.text(sheet.format_costs(costs)),
      ])
  }
}

pub fn meta(text: String) -> Element(msg) {
  html.span([attribute.class("meta")], [html.text(text)])
}

pub fn back_link(to: Route, label: String) -> Element(msg) {
  html.a([attribute.class("back"), attribute.href(route.to_hash(to))], [
    arrow(),
    html.text(label),
  ])
}

pub fn arrow() -> Element(msg) {
  html.span([attribute.aria_hidden(True)], [html.text("← ")])
}

/// A plain message under a link back to every list, for a screen whose
/// subject is not there.
pub fn not_found(message: String) -> List(Element(msg)) {
  [
    back_link(route.Home, "All lists"),
    html.p([attribute.class("note")], [html.text(message)]),
  ]
}

/// A storage error in words, for any screen that shows one.
pub fn describe_storage_error(error: StorageError) -> String {
  case error {
    storage.OpenFailed(reason) -> "Could not open. " <> reason
    storage.ReadFailed(reason) -> "Could not read. " <> reason
    storage.WriteFailed(reason) -> "Could not save. " <> reason
    storage.DeleteFailed(reason) -> "Could not delete. " <> reason
    storage.Undecodable(key) -> "The saved " <> key <> " could not be read."
  }
}
