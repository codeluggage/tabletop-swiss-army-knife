//// `gleam run -m tabletop/live_check` says whether the site in `dist/` may
//// replace the live one. Run it after the build and before a deploy. It exits
//// 0 when the new version may go live, and 1 with the reason when it may not.

import gleam/int
import gleam/io
import gleam/javascript/promise
import gleam/option.{None, Some}
import gleam/result
import simplifile
import tabletop/site
import tabletop/version.{type Stamp}

const built = "dist/version.json"

pub fn main() -> Nil {
  case read_built(), site.origin() {
    Error(reason), _ | _, Error(reason) -> refuse(reason)
    Ok(new), Ok(repository) -> {
      let _ = {
        use live <- promise.map(site.live_version(repository))
        case decide(new, live) {
          Ok(sentence) -> io.println(sentence)
          Error(sentence) -> refuse(sentence)
        }
      }
      Nil
    }
  }
}

/// May the site stamped `new` replace the live one? `live` is the answer to
/// the request for the live `version.json`: #(HTTP status, body). Ok with
/// what was found, or Error with why not, one sentence each.
pub fn decide(
  new: Stamp,
  live: Result(#(Int, String), String),
) -> Result(String, String) {
  let release = version.to_string(new.release)
  case live {
    Error(reason) -> Error("The live version could not be read: " <> reason)
    Ok(#(404, _)) ->
      Ok("There is no live site yet, so version " <> release <> " may go live.")
    Ok(#(200, body)) ->
      case version.stamp_from_json(body) {
        Error(Nil) ->
          Error("The live version.json is not one this check reads.")
        Ok(None) ->
          Ok(
            "The live site is from before versions like "
            <> release
            <> ", so it may be replaced.",
          )
        Ok(Some(live)) -> {
          let live_release = version.to_string(live.release)
          case
            version.is_newer(new.release, than: live.release),
            new.schema < live.schema
          {
            False, _ ->
              Error(
                "Version "
                <> release
                <> " is not later than the live version "
                <> live_release
                <> ", so it may not replace it.",
              )
            True, True ->
              Error(
                "Version "
                <> release
                <> " keeps saved data in an older layout ("
                <> int.to_string(new.schema)
                <> ") than the live version "
                <> live_release
                <> " ("
                <> int.to_string(live.schema)
                <> "), so it may not replace it.",
              )
            True, False ->
              Ok(
                "Version "
                <> release
                <> " may replace the live version "
                <> live_release
                <> ".",
              )
          }
        }
      }
    Ok(#(status, _)) ->
      Error(
        "The live site answered "
        <> int.to_string(status)
        <> " when asked for its version.json.",
      )
  }
}

fn read_built() -> Result(Stamp, String) {
  let stamp =
    simplifile.read(built)
    |> result.replace_error(Nil)
    |> result.try(version.stamp_from_json)
  case stamp {
    Ok(Some(stamp)) -> Ok(stamp)
    _ ->
      Error(built <> " has no version. Run gleam run -m tabletop/build first.")
  }
}

fn refuse(sentence: String) -> Nil {
  io.println_error(sentence)
  set_exit_code(1)
}

@external(javascript, "./node_ffi.mjs", "set_exit_code")
fn set_exit_code(code: Int) -> Nil
