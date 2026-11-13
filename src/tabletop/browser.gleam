//// The page-level browser calls the app makes: the version stamped into the
//// page, `version.json`, the service worker, tab visibility, the clock,
//// history and scrolling, ids and the chosen file.

import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}

/// The version the build stamped into the running page.
@external(javascript, "./browser_ffi.mjs", "running_version")
pub fn running_version() -> String

/// The body of `url`, fetched past every cache.
@external(javascript, "./browser_ffi.mjs", "fetch_no_store")
pub fn fetch_no_store(url: String) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "register_worker")
pub fn register_worker(url: String) -> Nil

/// Calls back with `document.visibilityState`, `"visible"` or `"hidden"`.
@external(javascript, "./browser_ffi.mjs", "on_visibility_change")
pub fn on_visibility_change(callback: fn(String) -> Nil) -> Nil

/// Calls back when a new service worker takes over the page.
@external(javascript, "./browser_ffi.mjs", "on_controller_change")
pub fn on_controller_change(callback: fn() -> Nil) -> Nil

/// Fetches the newest service worker and tells it to take over. `False` when
/// there was none to tell.
@external(javascript, "./browser_ffi.mjs", "activate_new_worker")
pub fn activate_new_worker() -> Promise(Bool)

@external(javascript, "./browser_ffi.mjs", "reload")
pub fn reload() -> Nil

/// Milliseconds since 1970 UTC.
@external(javascript, "./browser_ffi.mjs", "now_ms")
pub fn now_ms() -> Int

/// `ms` as a date and time in the reader's own locale and time zone.
@external(javascript, "./browser_ffi.mjs", "local_time")
pub fn local_time(ms: Int) -> String

/// `history.back()`.
@external(javascript, "./browser_ffi.mjs", "history_back")
pub fn history_back() -> Nil

/// How far the page is scrolled down, in CSS pixels.
@external(javascript, "./browser_ffi.mjs", "scroll_y")
pub fn scroll_y() -> Float

@external(javascript, "./browser_ffi.mjs", "scroll_to")
pub fn scroll_to(y: Float) -> Nil

/// Stops the browser restoring scroll on back and forward, so the app can.
@external(javascript, "./browser_ffi.mjs", "manual_scroll_restoration")
pub fn manual_scroll_restoration() -> Nil

/// A random UUID from `crypto.randomUUID()`.
@external(javascript, "./browser_ffi.mjs", "random_id")
pub fn random_id() -> String

/// `bytes` read as Windows-1252 text, as a spreadsheet on Windows often
/// saves a table. Every byte is some character in it.
@external(javascript, "./browser_ffi.mjs", "windows_1252_to_string")
pub fn windows_1252_to_string(bytes: BitArray) -> String

/// The name and bytes of the file chosen in the file `input` element. Clears
/// the input, so choosing the same file again fires a change.
@external(javascript, "./browser_ffi.mjs", "read_chosen_file")
pub fn read_chosen_file(
  input: Dynamic,
) -> Promise(Result(#(String, BitArray), String))
