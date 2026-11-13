import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import tabletop/live_check
import tabletop/publish.{
  Behind, Build, Cancelled, CheckFailed, CheckHere, CouldNotRun, Failed,
  FailedAgain, FailedAt, FailedOnlyOnGitHub, FailedSomewhere, Format, GiveUp,
  Live, NoAddress, NoRun, NotCombined, NotOnMain, NotSent, NotShownYet, Passed,
  Refused, RunNotStarted, RunTooSlow, Running, SameLines, SameMinute, SendAgain,
  Sent, StatusUnreadable, StepRemoved, Tests, Types, Unreachable, Unsaved,
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
    SameMinute,
    StepRemoved,
    NotSent,
    FailedOnlyOnGitHub(Types),
    FailedOnlyOnGitHub(Tests),
    FailedOnlyOnGitHub(Build),
    FailedAgain(Some("Publish the site")),
    FailedAgain(None),
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
  assert publish.say(SameMinute)
    == "A version went live in this same minute, so nothing was published. Run this command again in one minute."
  assert publish.say(StepRemoved)
    == "This change removes a storage step that phones already have, so nothing was published. Put the step back in upgrades in src/tabletop/storage.gleam."
  assert publish.say(FailedOnlyOnGitHub(Tests))
    == "The tests failed on GitHub, but the same checks passed on this computer, so the live site is unchanged. Ask the person who helps with the project."
  assert publish.say(FailedAgain(Some("Publish the site")))
    == "The step \"Publish the site\" failed on GitHub again, so the live site is unchanged. Ask the person who helps with the project."
  assert publish.say(NotOnMain("other"))
    == "Publishing works only from main, and this copy is on \"other\", so nothing was published."
}

pub fn the_last_lines_name_the_live_version_test() {
  let closing =
    "Version 2026.11.13.1542 is live.\nOpen the app. If a bar says \"New version\", tap Reload."
  assert publish.say(Live("2026.11.13.1542", tagged: True)) == closing
  // Without its tag, one sentence comes before the same two closing lines.
  assert publish.say(Live("2026.11.13.1542", tagged: False))
    == "Version 2026.11.13.1542 is live, but the list of versions will not show it. Tell the person who helps with the project.\n"
    <> closing
}

pub fn a_build_the_live_site_refuses_is_not_sent_test() {
  assert publish.may_send(live_check.NotLater("")) == Error(SameMinute)
  assert publish.may_send(live_check.OlderLayout("")) == Error(StepRemoved)
  assert publish.may_send(live_check.MayGoLive("")) == Ok(Nil)
  // GitHub runs the same check before it publishes.
  assert publish.may_send(live_check.CannotTell("")) == Ok(Nil)
}

pub fn a_failed_check_on_github_is_checked_here_test() {
  assert publish.retry(Some("Check the types"), "a change") == CheckHere(Types)
  assert publish.retry(Some("Run the tests"), "a change") == CheckHere(Tests)
  assert publish.retry(Some("Build the site"), "publish again")
    == CheckHere(Build)
}

pub fn every_name_publish_acts_on_is_in_the_workflow_test() {
  let assert Ok(workflow) = simplifile.read(".github/workflows/deploy.yml")
  let lines = string.split(workflow, "\n")
  let names =
    list.filter_map(lines, fn(line) {
      case string.trim(line) {
        "- name: " <> name | "name: " <> name -> Ok(name)
        _ -> Error(Nil)
      }
    })
  list.each(publish.check_steps, fn(step) {
    assert list.contains(names, step.0) as step.0
  })
  assert list.contains(lines, "  " <> publish.deploy_job <> ":")
}

pub fn any_other_failure_is_sent_once_more_test() {
  let live_check = "Check that this version may replace the live one"
  assert publish.retry(Some(live_check), "a change") == SendAgain
  assert publish.retry(Some("Publish the site"), "a change") == SendAgain
  assert publish.retry(None, "a change") == SendAgain
  assert publish.retry(Some("Publish the site"), publish.again) == GiveUp
  assert publish.retry(None, publish.again) == GiveUp
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
