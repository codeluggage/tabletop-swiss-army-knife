//// The file half of the content rule in AGENTS.md: a data file lives only in
//// test/fixtures/, and no file is over 300 KB.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tabletop/build

const skipped = [".git", "build", "dist", "local-data", "node_modules"]

const data_extensions = [
  "json", "xml", "csv", "yaml", "yml", "zip", "cat", "gst", "ros", "catz",
  "gstz", "rosz",
]

/// Data files allowed outside test/fixtures/. The web manifest and Gleam's own
/// project files need no entry: none has a data extension.
fn allowed(path: String) -> Bool {
  string.starts_with(path, "test/fixtures/")
  || string.starts_with(path, ".github/workflows/")
  // The Codex hooks that run the checks.
  || path == ".codex/hooks.json"
  // Local Claude Code settings, gitignored, never committed.
  || path == ".claude/settings.local.json"
}

const max_bytes = 300_000

/// What is wrong with the file at `path` of size `bytes`, one line per rule.
pub fn breaches(path: String, bytes: Int) -> List(String) {
  let extension = extension(path)
  let data = case list.contains(data_extensions, extension) && !allowed(path) {
    True -> [
      path
      <> ": a ."
      <> extension
      <> " data file outside test/fixtures/. The content rule in AGENTS.md keeps data files in test/fixtures/ only.",
    ]
    False -> []
  }
  let size = case bytes > max_bytes {
    True -> [
      path
      <> ": "
      <> int.to_string(bytes)
      <> " bytes. The content rule in AGENTS.md allows no file over 300 KB.",
    ]
    False -> []
  }
  list.append(data, size)
}

fn extension(path: String) -> String {
  let name = string.split(path, "/") |> list.last |> result.unwrap(path)
  case string.split(name, ".") {
    [_] -> ""
    parts -> list.last(parts) |> result.unwrap("") |> string.lowercase
  }
}

pub fn repository_follows_the_content_rule_test() {
  let assert Ok(files) = build.files_under(".", skip: list.contains(skipped, _))
  let problems =
    list.flat_map(files, fn(path) {
      let assert Ok(info) = simplifile.file_info(path)
      breaches(path, info.size)
    })
  assert problems == [] as string.join(problems, "\n")
}

pub fn breaches_test() {
  assert breaches("src/tabletop.gleam", 100) == []
  assert breaches("test/fixtures/invented-game.json", 100) == []
  assert breaches(".github/workflows/deploy.yml", 100) == []
  assert breaches(".codex/hooks.json", 100) == []
  assert list.length(breaches(".codex/units.json", 100)) == 1
  assert breaches("web/manifest.webmanifest", 100) == []
  assert breaches("json", 100) == []
  assert list.length(breaches("units.JSON", 100)) == 1
  assert list.length(breaches("web/lists/army.rosz", 100)) == 1
  assert list.length(breaches("web/icons/huge.png", 300_001)) == 1
  assert list.length(breaches("test/fixtures/huge.json", 300_001)) == 1
  assert list.length(breaches("data.csv", 300_001)) == 2
}
