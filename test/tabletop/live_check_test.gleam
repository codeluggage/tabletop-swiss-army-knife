import tabletop/live_check.{CannotTell, MayGoLive, NotLater, OlderLayout}
import tabletop/version.{type Stamp, Stamp}

fn stamp(release: String, schema: Int) -> Stamp {
  let assert Ok(release) = version.parse(release)
  Stamp(release:, commit: "aaaaaaa", schema:)
}

fn live(release: String, schema: Int) -> Result(#(Int, String), String) {
  Ok(#(200, version.to_json(stamp(release, schema), legacy: "")))
}

const new = "2026.11.13.1542"

pub fn a_later_version_may_go_live_test() {
  let assert MayGoLive(_) =
    live_check.decide(stamp(new, 4), live("2026.11.13.1541", 4))
  let assert MayGoLive(_) =
    live_check.decide(stamp(new, 5), live("2026.11.12.2359", 4))
}

pub fn the_same_or_an_older_version_may_not_test() {
  let assert NotLater(_) = live_check.decide(stamp(new, 4), live(new, 4))
  let assert NotLater(_) =
    live_check.decide(stamp(new, 4), live("2026.11.13.1543", 4))
}

pub fn an_older_saved_data_layout_may_not_test() {
  let assert OlderLayout(_) =
    live_check.decide(stamp(new, 3), live("2026.11.13.1541", 4))
}

pub fn a_site_from_before_versions_may_be_replaced_test() {
  let old = Ok(#(200, "{\"version\":\"2026-11-13.152535.776d09c\"}"))
  let assert MayGoLive(_) = live_check.decide(stamp(new, 4), old)
}

pub fn a_new_site_may_go_live_test() {
  let assert MayGoLive(_) =
    live_check.decide(stamp(new, 4), Ok(#(404, "Not found")))
}

pub fn any_other_answer_may_not_test() {
  let assert CannotTell(_) = live_check.decide(stamp(new, 4), Error("offline"))
  let assert CannotTell(_) = live_check.decide(stamp(new, 4), Ok(#(500, "")))
  let assert CannotTell(_) =
    live_check.decide(stamp(new, 4), Ok(#(200, "<!doctype html>")))
  let assert CannotTell(_) =
    live_check.decide(stamp(new, 4), Ok(#(200, "{\"release\":\"soon\"}")))
}
