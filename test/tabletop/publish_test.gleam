import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tabletop/publish.{
  Behind, Build, Cancelled, CheckFailed, CouldNotRun, Failed, FailedAt,
  FailedSomewhere, Format, Live, NoAddress, NoRun, NotCombined, NotOnMain,
  NotSent, NotShownYet, Passed, Refused, RunFailed, RunNotStarted, RunTooSlow,
  Running, SameLines, Sent, StatusUnreadable, Tests, Types, Unreachable, Unsaved,
  WentLive,
}

const git_words = [
  "branch", "checkout", "clone", "commit", "commits", "fetch", "git", "head",
  "merge", "origin", "pull", "push", "rebase", "remote", "repository", "stash",
  "tag",
]

fn sentences(text: String) -> Int {
  string.split(text <> " ", ". ") |> list.length |> fn(n) { n - 1 }
}

pub fn every_failure_is_one_or_two_plain_sentences_test() {
  let outcomes = [
    NotOnMain(""),
    NotOnMain("other"),
    Unsaved,
    NoAddress,
    CouldNotRun("gleam"),
    Unreachable,
    SameLines,
    NotCombined,
    CheckFailed(Format),
    CheckFailed(Types),
    CheckFailed(Tests),
    CheckFailed(Build),
    NotSent,
    RunFailed(Some("Run the tests")),
    RunFailed(None),
    RunNotStarted,
    RunTooSlow,
    StatusUnreadable,
    NotShownYet,
  ]
  list.each(outcomes, fn(outcome) {
    let said = publish.say(outcome)
    let words =
      string.lowercase(said)
      |> string.replace(".", " ")
      |> string.replace(",", " ")
      |> string.replace("\"", " ")
      |> string.split(" ")
    assert !string.contains(said, "\n") as said
    assert sentences(said) >= 1 && sentences(said) <= 2 as said
    assert !list.any(words, list.contains(git_words, _)) as said
  })
}

pub fn the_sentences_say_what_happened_test() {
  assert publish.say(SameLines)
    == "This change and a change from another person touch the same lines, so nothing was published. Ask the person who helps with the project."
  assert publish.say(RunFailed(Some("Run the tests")))
    == "The step \"Run the tests\" failed on GitHub, so the live site is unchanged."
  assert publish.say(NotOnMain("other"))
    == "Publishing works only from main, and this copy is on \"other\", so nothing was published."
}

pub fn the_last_lines_name_the_live_version_test() {
  assert publish.say(Live("2026.11.13.1542"))
    == "Version 2026.11.13.1542 is live.\nOpen the app. If a bar says \"New version\", tap Reload."
}

pub fn read_push_test() {
  let to = "To github.com:owner/repo.git\n"
  assert publish.read_push(
      0,
      to <> "=\trefs/heads/main:refs/heads/main\t[up to date]\nDone\n",
    )
    == Sent
  assert publish.read_push(
      0,
      to <> " \trefs/heads/main:refs/heads/main\t776d09c..a3ca338\nDone\n",
    )
    == Sent
  assert publish.read_push(
      1,
      to
        <> "!\trefs/heads/main:refs/heads/main\t[rejected] (fetch first)\nDone\n",
    )
    == Behind
  assert publish.read_push(
      1,
      to
        <> "!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n",
    )
    == Behind
  // Refused for another reason, or a status that says so without a line.
  assert publish.read_push(
      1,
      to
        <> "!\trefs/heads/main:refs/heads/main\t[remote rejected] (protected branch hook declined)\nDone\n",
    )
    == Refused
  assert publish.read_push(
      0,
      to <> "!\trefs/heads/main:refs/heads/main\t[rejected] (stale info)\n",
    )
    == Refused
  assert publish.read_push(128, "") == Refused
}

fn runs(list: List(String)) -> String {
  "{\"total_count\":"
  <> "1,\"workflow_runs\":["
  <> string.join(list, ",")
  <> "]}"
}

fn run(id: String, status: String, conclusion: String) -> String {
  "{\"id\":"
  <> id
  <> ",\"head_branch\":\"main\",\"status\":\""
  <> status
  <> "\",\"conclusion\":"
  <> conclusion
  <> "}"
}

pub fn read_runs_reads_the_newest_run_test() {
  assert publish.read_runs(runs([])) == Ok(NoRun)
  assert publish.read_runs(runs([run("7", "queued", "null")])) == Ok(Running)
  assert publish.read_runs(runs([run("7", "in_progress", "null")]))
    == Ok(Running)
  assert publish.read_runs(runs([run("7", "completed", "\"success\"")]))
    == Ok(Passed)
  assert publish.read_runs(runs([run("7", "completed", "\"cancelled\"")]))
    == Ok(Cancelled)
  assert publish.read_runs(
      runs([run("43452454461", "completed", "\"failure\"")]),
    )
    == Ok(Failed(43_452_454_461))
  assert publish.read_runs(runs([run("7", "completed", "\"timed_out\"")]))
    == Ok(Failed(7))
  assert publish.read_runs(
      runs([
        run("8", "in_progress", "null"),
        run("7", "completed", "\"success\""),
      ]),
    )
    == Ok(Running)
}

pub fn read_runs_refuses_other_answers_test() {
  assert publish.read_runs("{\"message\":\"API rate limit exceeded\"}")
    == Error(Nil)
  assert publish.read_runs("<!doctype html>") == Error(Nil)
}

fn jobs(list: List(String)) -> String {
  "{\"total_count\":2,\"jobs\":[" <> string.join(list, ",") <> "]}"
}

fn job(name: String, conclusion: String, steps: List(#(String, String))) {
  let steps =
    list.map(steps, fn(step) {
      "{\"name\":\"" <> step.0 <> "\",\"conclusion\":" <> step.1 <> "}"
    })
  "{\"name\":\""
  <> name
  <> "\",\"conclusion\":"
  <> conclusion
  <> ",\"steps\":["
  <> string.join(steps, ",")
  <> "]}"
}

pub fn read_jobs_names_the_first_failed_step_test() {
  let check =
    job("check", "\"failure\"", [
      #("Set up job", "\"success\""),
      #("Run the tests", "\"failure\""),
      #("Build the site", "\"skipped\""),
    ])
  let deploy = job("deploy", "null", [])
  assert publish.read_jobs(jobs([check, deploy]))
    == Ok(FailedAt("Run the tests"))
}

pub fn read_jobs_knows_when_only_the_tag_failed_test() {
  let check = job("check", "\"success\"", [#("Run the tests", "\"success\"")])
  let deploy =
    job("deploy", "\"success\"", [#("Publish the site", "\"success\"")])
  let tag =
    job("tag", "\"failure\"", [
      #("Tag the commit with its version", "\"failure\""),
    ])
  assert publish.read_jobs(jobs([check, deploy, tag])) == Ok(WentLive)
}

pub fn read_jobs_without_a_failed_step_test() {
  let check = job("check", "\"failure\"", [])
  assert publish.read_jobs(jobs([check])) == Ok(FailedSomewhere)
  assert publish.read_jobs("{}") == Error(Nil)
}
