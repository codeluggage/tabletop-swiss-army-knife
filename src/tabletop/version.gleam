//// The build version: when a build was made (UTC) and from which commit.
////
//// Written as `2026-11-12.204107.abc1234`: the UTC date, the UTC time of the
//// build to the second, and the short git commit. The time keeps two builds of
//// the same commit apart, so a rebuilt site still reaches the browser.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string

pub opaque type Version {
  Version(date: String, time: String, commit: String)
}

pub type VersionError {
  NotThreeParts
  BadDate
  BadTime
  BadCommit
  NotVersionJson
}

pub fn parse(text: String) -> Result(Version, VersionError) {
  case string.split(text, ".") {
    [date, time, commit] -> {
      use date <- result.try(parse_date(date))
      use time <- result.try(parse_time(time))
      use commit <- result.try(parse_commit(commit))
      Ok(Version(date:, time:, commit:))
    }
    _ -> Error(NotThreeParts)
  }
}

/// The version for a build made at `iso` (as `Date.toISOString` writes it,
/// `2026-11-12T20:41:07.123Z`) from the commit `commit`.
pub fn from_build(
  iso: String,
  commit: String,
) -> Result(Version, VersionError) {
  let date = string.slice(iso, 0, 10)
  let time = string.slice(iso, 11, 8) |> string.replace(":", "")
  parse(date <> "." <> time <> "." <> commit)
}

pub fn to_string(version: Version) -> String {
  version.date <> "." <> version.time <> "." <> version.commit
}

/// True when `candidate` was built after `running`. An older or equal build
/// is never offered as an update, which keeps a stale copy of `version.json`
/// from a slow cache from prompting a reload.
pub fn is_newer(candidate: Version, than running: Version) -> Bool {
  string.compare(candidate.date <> candidate.time, running.date <> running.time)
  == order.Gt
}

/// The contents of `version.json`.
pub fn to_json(version: Version) -> String {
  json.object([#("version", json.string(to_string(version)))])
  |> json.to_string
}

pub fn from_json(text: String) -> Result(Version, VersionError) {
  let decoder = {
    use version <- decode.field("version", decode.string)
    decode.success(version)
  }
  case json.parse(text, decoder) {
    Ok(version) -> parse(version)
    Error(_) -> Error(NotVersionJson)
  }
}

fn parse_date(text: String) -> Result(String, VersionError) {
  case string.split(text, "-") {
    [year, month, day] ->
      case digits(year, 4) && digits(month, 2) && digits(day, 2) {
        True -> Ok(text)
        False -> Error(BadDate)
      }
    _ -> Error(BadDate)
  }
}

fn parse_time(text: String) -> Result(String, VersionError) {
  case digits(text, 6) {
    True -> Ok(text)
    False -> Error(BadTime)
  }
}

fn parse_commit(text: String) -> Result(String, VersionError) {
  let allowed = fn(grapheme) {
    string.contains("0123456789abcdefghijklmnopqrstuvwxyz", grapheme)
  }
  case text != "" && list.all(string.to_graphemes(text), allowed) {
    True -> Ok(text)
    False -> Error(BadCommit)
  }
}

fn digits(text: String, count: Int) -> Bool {
  string.length(text) == count
  && list.all(string.to_graphemes(text), string.contains("0123456789", _))
}
