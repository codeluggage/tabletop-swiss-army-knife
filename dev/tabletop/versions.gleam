//// `gleam run -m tabletop/versions [digits]` lists the versions that went
//// live, newest first, each with the first line of what changed. With digits
//// it lists the versions that match what a person said: `1542` is a version
//// made at 15:42, and `342` one made at 03:42 or 15:42.

import gleam/int
import gleam/io
import gleam/javascript/array.{type Array}
import gleam/list
import gleam/result
import gleam/string
import tabletop/version

pub fn main() -> Nil {
  case run("git", ["fetch", "--quiet", "--tags", "origin"]) {
    Ok(#(0, _, _)) -> Nil
    _ ->
      io.println(
        "GitHub could not be reached, so the newest versions may be missing.",
      )
  }
  let listed =
    run("git", [
      "for-each-ref",
      "refs/tags",
      "--format=%(refname:short)%09%(subject)",
    ])
  case listed, string.concat(array.to_list(arguments())) {
    Ok(#(0, out, _)), said -> {
      let versions = read_tags(out)
      let found = list.filter(versions, fn(found) { matches(found.0, said) })
      case versions, said, found {
        [], _, _ -> io.println("No version has gone live yet.")
        _, "", _ -> print(list.take(versions, 10))
        _, _, [] -> {
          io.println("No version matches " <> said <> ". The newest are:")
          print(list.take(versions, 10))
        }
        _, _, found -> print(found)
      }
    }
    _, _ -> {
      io.println("The versions could not be read.")
      set_exit_code(1)
    }
  }
}

/// The versions among the tags, newest first, from lines of
/// `<tag>\t<first line of its commit message>`. Other tags are left out.
pub fn read_tags(text: String) -> List(#(String, String)) {
  string.split(text, "\n")
  |> list.filter_map(fn(line) {
    use #(tag, subject) <- result.try(string.split_once(line, "\t"))
    use _ <- result.map(version.parse(tag))
    #(tag, subject)
  })
  |> list.sort(fn(a, b) { string.compare(b.0, a.0) })
}

/// Whether `version` is one a person meant by `said`. Only the digits count,
/// and the version's digits must end with them. Three or four digits are a
/// time of day that may be before or after noon: `342` and `0342` are 03:42
/// or 15:42, `1542` is only 15:42.
pub fn matches(version: String, said: String) -> Bool {
  let own = digits(version)
  let said = digits(said)
  case string.length(said) {
    0 -> False
    3 | 4 -> list.any(times(said), string.ends_with(own, _))
    _ -> string.ends_with(own, said)
  }
}

fn times(said: String) -> List(String) {
  let minute = string.slice(said, -2, 2)
  case int.parse(string.drop_end(said, 2)) {
    Ok(hour) if hour <= 12 -> [hour % 12, hour % 12 + 12]
    Ok(hour) -> [hour]
    Error(Nil) -> []
  }
  |> list.map(fn(hour) {
    string.pad_start(int.to_string(hour), 2, "0") <> minute
  })
}

fn digits(text: String) -> String {
  string.to_graphemes(text)
  |> list.filter(string.contains("0123456789", _))
  |> string.concat
}

fn print(versions: List(#(String, String))) -> Nil {
  list.each(versions, fn(found) { io.println(found.0 <> "  " <> found.1) })
}

@external(javascript, "./node_ffi.mjs", "run")
fn run(
  program: String,
  args: List(String),
) -> Result(#(Int, String, String), String)

@external(javascript, "./node_ffi.mjs", "arguments_")
fn arguments() -> Array(String)

@external(javascript, "./node_ffi.mjs", "set_exit_code")
fn set_exit_code(code: Int) -> Nil
