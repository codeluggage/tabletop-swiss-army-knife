//// The page-level browser calls the app makes: the version stamped into the
//// page, `version.json`, the service worker, tab visibility and the clock.

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
