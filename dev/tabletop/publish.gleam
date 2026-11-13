//// `gleam run -m tabletop/publish` takes the work saved on `main` to the live
//// site and says in its last line which version is live. Its reader is a
//// small language model that repeats that line to a person who is not a
//// developer, so every message is one or two plain sentences.
////
//// In order: on main with nothing unsaved; take in the changes on GitHub;
//// the checks and the build; send the change to GitHub; wait for GitHub to
//// publish it; wait for the live site to show it. Each failure stops there,
//// changes nothing further and says so. With nothing to send it only waits,
//// so it also answers which version is live.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tabletop/site.{type Repository}
import tabletop/version

pub type Check {
  Format
  Types
  Tests
  Build
}

/// How a publish ended.
pub type Outcome {
  NotOnMain(branch: String)
  Unsaved
  NoAddress
  CouldNotRun(program: String)
  Unreachable
  SameLines
  NotCombined
  CheckFailed(Check)
  NotSent
  RunFailed(step: Option(String))
  RunNotStarted
  RunTooSlow
  StatusUnreadable
  NotShownYet
  Live(release: String)
}

/// An outcome that stops the publish, and what the failing program printed,
/// shown above the sentence.
type Stop =
  #(Outcome, String)

const checks = [
  #(Format, ["format", "--check", "src", "test", "dev"]),
  #(Types, ["check"]),
  #(Tests, ["test"]),
  #(Build, ["run", "-m", "tabletop/build"]),
]

/// The wait between two questions about the run. GitHub answers 60 questions
/// an hour without a sign-in, and one publish asks at most 46.
const run_poll_ms = 20_000

/// Five minutes for the run to appear, fifteen for it to finish.
const start_polls = 15

const run_polls = 45

/// Five minutes for the live site to show the change.
const live_poll_ms = 10_000

const live_polls = 30

pub fn main() -> Nil {
  let _ = {
    use published <- promise.map(publish())
    case published {
      Ok(release) -> io.println(say(Live(release)))
      Error(#(outcome, detail)) -> {
        case string.trim(detail) {
          "" -> Nil
          detail -> io.println(detail)
        }
        io.println(say(outcome))
        set_exit_code(1)
      }
    }
  }
  Nil
}

/// The last words of a publish.
pub fn say(outcome: Outcome) -> String {
  let unpublished = ", so nothing was published."
  let ask = " Ask the person who helps with the project."
  let later = " Run this command again later to see which version is live."
  case outcome {
    NotOnMain("") ->
      "Publishing works only from main, and this copy is not on main"
      <> unpublished
    NotOnMain(branch) ->
      "Publishing works only from main, and this copy is on \""
      <> branch
      <> "\""
      <> unpublished
    Unsaved ->
      "Some changes are not saved to the project history yet" <> unpublished
    NoAddress ->
      "This copy of the project has no address on GitHub" <> unpublished <> ask
    CouldNotRun(program) ->
      "The program " <> program <> " did not work" <> unpublished <> ask
    Unreachable ->
      "GitHub could not be reached"
      <> unpublished
      <> " Check the internet connection and try again."
    SameLines ->
      "This change and a change from another person touch the same lines"
      <> unpublished
      <> ask
    NotCombined ->
      "The changes on GitHub could not be combined with this one"
      <> unpublished
      <> ask
    CheckFailed(Format) ->
      "The code is not formatted"
      <> unpublished
      <> " Run gleam format src test dev and publish again."
    CheckFailed(Types) ->
      "The code has errors"
      <> unpublished
      <> " Fix what gleam check says above and publish again."
    CheckFailed(Tests) ->
      "A test failed"
      <> unpublished
      <> " Fix what gleam test says above and publish again."
    CheckFailed(Build) ->
      "The site could not be built"
      <> unpublished
      <> " Fix what the build says above and publish again."
    NotSent -> "GitHub did not take the change" <> unpublished <> ask
    RunFailed(Some(step)) ->
      "The step \""
      <> step
      <> "\" failed on GitHub, so the live site is unchanged."
    RunFailed(None) ->
      "Publishing failed on GitHub, so the live site is unchanged."
    RunNotStarted ->
      "GitHub has not started publishing after five minutes." <> later
    RunTooSlow -> "GitHub is still publishing after fifteen minutes." <> later
    StatusUnreadable -> "GitHub did not say how publishing went." <> later
    NotShownYet ->
      "GitHub has published, but the live site does not show it after five minutes."
      <> later
    Live(release) ->
      "Version "
      <> release
      <> " is live.\nOpen the app. If a bar says \"New version\", tap Reload."
  }
}

pub type Push {
  Sent
  /// GitHub has changes this copy has not taken in yet.
  Behind
  Refused
}

/// What `git push --porcelain` did, from its exit status and its standard
/// output, where a refused ref is a line that starts with `!`.
pub fn read_push(status: Int, porcelain: String) -> Push {
  let refused =
    string.split(porcelain, "\n")
    |> list.filter(string.starts_with(_, "!"))
  let behind =
    list.any(refused, fn(line) {
      string.contains(line, "fetch first")
      || string.contains(line, "non-fast-forward")
    })
  case refused, behind, status {
    _, True, _ -> Behind
    [], _, 0 -> Sent
    _, _, _ -> Refused
  }
}

pub type Run {
  NoRun
  Running
  Passed
  Cancelled
  Failed(id: Int)
}

/// The newest run in a list of workflow runs as the GitHub API sends it,
/// newest first.
pub fn read_runs(text: String) -> Result(Run, Nil) {
  let run = {
    use id <- decode.field("id", decode.int)
    use status <- decode.field("status", decode.string)
    use conclusion <- decode.field("conclusion", decode.optional(decode.string))
    decode.success(#(id, status, conclusion))
  }
  let decoder = decode.at(["workflow_runs"], decode.list(run))
  use runs <- result.map(json.parse(text, decoder) |> result.replace_error(Nil))
  case runs {
    [] -> NoRun
    [#(_, "completed", Some("success")), ..] -> Passed
    [#(_, "completed", Some("cancelled")), ..] -> Cancelled
    [#(id, "completed", _), ..] -> Failed(id)
    [_, ..] -> Running
  }
}

pub type Failure {
  /// The site went live and only a later job failed.
  WentLive
  FailedAt(step: String)
  FailedSomewhere
}

/// Why a run failed, from its jobs as the GitHub API sends them.
pub fn read_jobs(text: String) -> Result(Failure, Nil) {
  let step = {
    use name <- decode.field("name", decode.string)
    use conclusion <- decode.field("conclusion", decode.optional(decode.string))
    decode.success(#(name, conclusion))
  }
  let job = {
    use name <- decode.field("name", decode.string)
    use conclusion <- decode.field("conclusion", decode.optional(decode.string))
    use steps <- decode.optional_field("steps", [], decode.list(step))
    decode.success(#(name, conclusion, steps))
  }
  let decoder = decode.at(["jobs"], decode.list(job))
  use jobs <- result.map(json.parse(text, decoder) |> result.replace_error(Nil))
  let deployed =
    list.any(jobs, fn(job) { job.0 == "deploy" && job.1 == Some("success") })
  let failed_step =
    list.find_map(jobs, fn(job) {
      list.find_map(job.2, fn(step) {
        case step {
          #(name, Some("failure")) -> Ok(name)
          _ -> Error(Nil)
        }
      })
    })
  case deployed, failed_step {
    True, _ -> WentLive
    False, Ok(step) -> FailedAt(step)
    False, Error(Nil) -> FailedSomewhere
  }
}

// --- The thin layer: processes and requests ---------------------------------

fn publish() -> Promise(Result(String, Stop)) {
  case prepare() {
    Error(stop) -> promise.resolve(Error(stop))
    Ok(#(repository, commit)) -> {
      io.println("Waiting for GitHub to publish. This takes a few minutes.")
      use _ <- promise.try_await(wait_for_run(
        repository,
        "head_sha=" <> commit,
        0,
      ))
      io.println("Waiting for the live site to show it.")
      wait_for_live(repository, commit, 0)
    }
  }
}

/// Steps 1 to 4: the commit that GitHub has, sent now or before.
fn prepare() -> Result(#(Repository, String), Stop) {
  use branch <- result.try(git(["branch", "--show-current"]))
  let branch = string.trim(branch)
  use <- bool.guard(branch != "main", Error(#(NotOnMain(branch), "")))
  use status <- result.try(git(["status", "--porcelain"]))
  use <- bool.guard(string.trim(status) != "", Error(#(Unsaved, status)))
  use repository <- result.try(
    site.origin() |> result.map_error(fn(reason) { #(NoAddress, reason) }),
  )
  use commit <- result.map(send(tries: 2))
  #(repository, commit)
}

fn send(tries tries: Int) -> Result(String, Stop) {
  use _ <- result.try(take_in())
  use commit <- result.try(git(["rev-parse", "HEAD"]))
  use on_github <- result.try(git(["rev-parse", "origin/main"]))
  let commit = string.trim(commit)
  use <- bool.guard(commit == string.trim(on_github), Ok(commit))
  use _ <- result.try(run_checks())
  io.println("Sending the change to GitHub.")
  // Never forced: a plain push of main, which GitHub refuses when it has
  // changes this copy has not taken in.
  use #(status, out, error) <- result.try(
    run("git", ["push", "--porcelain", "origin", "main"])
    |> result.map_error(fn(reason) { #(CouldNotRun("git"), reason) }),
  )
  case read_push(status, out), tries {
    Sent, _ -> Ok(commit)
    Behind, 2 -> send(tries: 1)
    _, _ -> Error(#(NotSent, out <> error))
  }
}

/// Fetch and merge GitHub's main, never a rebase. A conflict is undone.
fn take_in() -> Result(Nil, Stop) {
  io.println("Taking in the changes on GitHub.")
  use fetched <- result.try(
    run("git", ["fetch", "origin", "main"])
    |> result.map_error(fn(reason) { #(CouldNotRun("git"), reason) }),
  )
  use <- bool.guard(
    fetched.0 != 0,
    Error(#(Unreachable, fetched.1 <> fetched.2)),
  )
  case run("git", ["merge", "--no-edit", "origin/main"]) {
    Ok(#(0, _, _)) -> Ok(Nil)
    Ok(#(_, out, error)) ->
      // Only a merge left half done can be aborted, and that is a conflict.
      case run("git", ["merge", "--abort"]) {
        Ok(#(0, _, _)) -> Error(#(SameLines, out <> error))
        _ -> Error(#(NotCombined, out <> error))
      }
    Error(reason) -> Error(#(CouldNotRun("git"), reason))
  }
}

fn run_checks() -> Result(Nil, Stop) {
  io.println("Checking the code and building the site.")
  list.try_each(checks, fn(check) {
    case run("gleam", check.1) {
      Ok(#(0, _, _)) -> Ok(Nil)
      Ok(#(_, out, error)) -> Error(#(CheckFailed(check.0), out <> error))
      Error(reason) -> Error(#(CouldNotRun("gleam"), reason))
    }
  })
}

/// Step 5: the deploy run of `query`, or the newest on main once a newer push
/// has taken over.
fn wait_for_run(
  repository: Repository,
  query: String,
  polls: Int,
) -> Promise(Result(Nil, Stop)) {
  use answer <- promise.await(
    fetch_text(api(
      repository,
      "actions/workflows/deploy.yml/runs?event=push&per_page=1&" <> query,
    )),
  )
  let again = fn(query) {
    use _ <- promise.await(promise.wait(run_poll_ms))
    wait_for_run(repository, query, polls + 1)
  }
  case read_answer(answer, read_runs) {
    Error(detail) -> promise.resolve(Error(#(StatusUnreadable, detail)))
    Ok(Passed) -> promise.resolve(Ok(Nil))
    Ok(Failed(id)) -> why_failed(repository, id)
    Ok(NoRun) if polls >= start_polls ->
      promise.resolve(Error(#(RunNotStarted, "")))
    Ok(_) if polls >= run_polls -> promise.resolve(Error(#(RunTooSlow, "")))
    Ok(Cancelled) -> again("branch=main")
    Ok(NoRun) | Ok(Running) -> again(query)
  }
}

fn why_failed(repository: Repository, id: Int) -> Promise(Result(Nil, Stop)) {
  use answer <- promise.map(
    fetch_text(api(repository, "actions/runs/" <> int.to_string(id) <> "/jobs")),
  )
  case read_answer(answer, read_jobs) {
    Ok(WentLive) -> Ok(Nil)
    Ok(FailedAt(step)) -> Error(#(RunFailed(Some(step)), ""))
    Ok(FailedSomewhere) -> Error(#(RunFailed(None), ""))
    Error(detail) -> Error(#(RunFailed(None), detail))
  }
}

/// Step 6: the live release once the live site runs `commit` or a later
/// commit that contains it.
fn wait_for_live(
  repository: Repository,
  commit: String,
  polls: Int,
) -> Promise(Result(String, Stop)) {
  use answer <- promise.await(site.live_version(repository))
  let live = case answer {
    Ok(#(200, body)) ->
      case version.stamp_from_json(body) {
        Ok(Some(live)) ->
          case contains(live.commit, commit) {
            True -> Some(version.to_string(live.release))
            False -> None
          }
        _ -> None
      }
    _ -> None
  }
  case live {
    Some(release) -> promise.resolve(Ok(release))
    None if polls >= live_polls -> promise.resolve(Error(#(NotShownYet, "")))
    None -> {
      use _ <- promise.await(promise.wait(live_poll_ms))
      wait_for_live(repository, commit, polls + 1)
    }
  }
}

/// Whether the short commit `live` is `commit` or a later one that holds it.
/// A commit this copy has not seen yet is fetched first.
fn contains(live: String, commit: String) -> Bool {
  let is_ancestor = fn() {
    run("git", ["merge-base", "--is-ancestor", commit, live])
  }
  use <- bool.guard(live == "", False)
  use <- bool.guard(string.starts_with(commit, live), True)
  case is_ancestor() {
    Ok(#(0, _, _)) -> True
    Ok(#(1, _, _)) -> False
    _ -> {
      let _ = run("git", ["fetch", "--quiet", "origin", "main"])
      is_ancestor()
      |> result.map(fn(out) { out.0 == 0 })
      |> result.unwrap(False)
    }
  }
}

fn api(repository: Repository, path: String) -> String {
  "https://api.github.com/repos/"
  <> repository.owner
  <> "/"
  <> repository.name
  <> "/"
  <> path
}

fn read_answer(
  answer: Result(#(Int, String), String),
  read: fn(String) -> Result(a, Nil),
) -> Result(a, String) {
  let start = fn(body) { string.slice(body, 0, 300) }
  case answer {
    Ok(#(200, body)) ->
      read(body) |> result.replace_error("GitHub answered: " <> start(body))
    Ok(#(status, body)) ->
      Error("GitHub answered " <> int.to_string(status) <> ": " <> start(body))
    Error(reason) -> Error(reason)
  }
}

/// The standard output of git with `args`. Any failure is unexpected here.
fn git(args: List(String)) -> Result(String, Stop) {
  case run("git", args) {
    Ok(#(0, out, _)) -> Ok(out)
    Ok(#(_, out, error)) -> Error(#(CouldNotRun("git"), out <> error))
    Error(reason) -> Error(#(CouldNotRun("git"), reason))
  }
}

@external(javascript, "./node_ffi.mjs", "run")
fn run(
  program: String,
  args: List(String),
) -> Result(#(Int, String, String), String)

@external(javascript, "./node_ffi.mjs", "fetch_text")
fn fetch_text(url: String) -> Promise(Result(#(Int, String), String))

@external(javascript, "./node_ffi.mjs", "set_exit_code")
fn set_exit_code(code: Int) -> Nil
