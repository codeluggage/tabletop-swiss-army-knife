import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tabletop/build.{FileFailed, ImportOutsideRoot}
import tabletop/version

pub fn import_specifiers_finds_relative_imports_test() {
  let source =
    "import * as $list from \"../gleam_stdlib/gleam/list.mjs\";
import { Ok } from './gleam.mjs';
export * from \"../prelude.mjs\";
import {
  first,
  second,
} from \"./multi.mjs\";
import fs from \"node:fs\";
import \"./side.mjs\";
const later = import(\"./later.mjs\");
import { again } from \"./multi.mjs\";"
  assert build.import_specifiers(source) |> list.sort(string.compare)
    == [
      "../gleam_stdlib/gleam/list.mjs",
      "../prelude.mjs",
      "./gleam.mjs",
      "./later.mjs",
      "./multi.mjs",
      "./side.mjs",
    ]
}

pub fn resolve_test() {
  assert build.resolve("tabletop/tabletop.mjs", "./tabletop/storage.mjs")
    == Ok("tabletop/tabletop/storage.mjs")
  assert build.resolve("tabletop/tabletop/storage.mjs", "../gleam.mjs")
    == Ok("tabletop/gleam.mjs")
  assert build.resolve("tabletop/gleam.mjs", "../prelude.mjs")
    == Ok("prelude.mjs")
  assert build.resolve("tabletop/gleam.mjs", "../../outside.mjs")
    == Error(ImportOutsideRoot("tabletop/gleam.mjs", "../../outside.mjs"))
}

fn reader(files: List(#(String, String))) {
  let files = dict.from_list(files)
  fn(path) {
    dict.get(files, path)
    |> result.replace_error(FileFailed(path, simplifile.Enoent))
  }
}

pub fn module_graph_keeps_only_reachable_modules_test() {
  let read =
    reader([
      #(
        "app/app.mjs",
        "import { a } from \"./app/a.mjs\";\nimport * as $b from \"../lib/b.mjs\";",
      ),
      #("app/app/a.mjs", "import { b } from \"../../lib/b.mjs\";"),
      #("lib/b.mjs", "export * from \"../prelude.mjs\";"),
      #("prelude.mjs", "import { a } from \"./app/app/a.mjs\";"),
      #("unused/c.mjs", ""),
    ])
  assert build.module_graph("app/app.mjs", read)
    == Ok(["app/app.mjs", "app/app/a.mjs", "lib/b.mjs", "prelude.mjs"])
}

pub fn module_graph_fails_on_a_missing_import_test() {
  let read = reader([#("app/app.mjs", "import { a } from \"./gone.mjs\";")])
  assert build.module_graph("app/app.mjs", read)
    == Error(FileFailed("app/gone.mjs", simplifile.Enoent))
}

pub fn precache_lists_the_start_page_shell_and_modules_test() {
  let shell = ["sw.js", "index.html", "icons/icon-192.png"]
  let modules = ["tabletop/tabletop.mjs", "prelude.mjs"]
  assert build.precache(shell, modules)
    == [
      "./",
      "icons/icon-192.png",
      "index.html",
      "js/prelude.mjs",
      "js/tabletop/tabletop.mjs",
    ]
}

pub fn stamp_replaces_every_placeholder_test() {
  assert build.stamp("a __V__ b __V__ __F__", [
      #("__V__", "1"),
      #("__F__", "[]"),
    ])
    == Ok("a 1 b 1 []")
}

pub fn stamp_fails_on_a_missing_placeholder_test() {
  assert build.stamp("no marks", [#("__V__", "1")]) == Error("__V__")
}

// 2026-01-15T15:42:30Z and 2026-07-15T15:42:30Z.
const january = 1_768_491_750_000

const july = 1_784_130_150_000

pub fn release_at_reads_the_london_clock_test() {
  // In January London keeps UTC, in July it is an hour ahead.
  let assert Ok(winter) = build.release_at(january)
  assert version.to_string(winter) == "2026.01.15.1542"
  let assert Ok(summer) = build.release_at(july)
  assert version.to_string(summer) == "2026.07.15.1642"
}

pub fn legacy_version_keeps_the_old_utc_shape_test() {
  assert build.legacy_version(january, "776d09c") == "2026-01-15.154230.776d09c"
  assert build.legacy_version(july, "776d09c") == "2026-07-15.154230.776d09c"
}
