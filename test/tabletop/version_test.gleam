import tabletop/version.{
  BadCommit, BadDate, BadTime, NotThreeParts, NotVersionJson,
}

pub fn parse_round_trips_test() {
  let assert Ok(parsed) = version.parse("2026-11-12.204107.abc1234")
  assert version.to_string(parsed) == "2026-11-12.204107.abc1234"
}

pub fn parse_rejects_malformed_versions_test() {
  assert version.parse("") == Error(NotThreeParts)
  assert version.parse("2026-11-12.204107") == Error(NotThreeParts)
  assert version.parse("2026-11-12.204107.abc.def") == Error(NotThreeParts)
  assert version.parse("26-11-12.204107.abc1234") == Error(BadDate)
  assert version.parse("2026-1-12.204107.abc1234") == Error(BadDate)
  assert version.parse("2026-11-12-01.204107.abc1234") == Error(BadDate)
  assert version.parse("2026-11-12.2041.abc1234") == Error(BadTime)
  assert version.parse("2026-11-12.20410x.abc1234") == Error(BadTime)
  assert version.parse("2026-11-12.204107.") == Error(BadCommit)
  assert version.parse("2026-11-12.204107.ABC1234") == Error(BadCommit)
  assert version.parse("__VERSION__") == Error(NotThreeParts)
}

pub fn from_build_reads_the_iso_time_test() {
  let assert Ok(built) =
    version.from_build("2026-11-12T20:41:07.123Z", "abc1234")
  assert version.to_string(built) == "2026-11-12.204107.abc1234"
  let assert Ok(no_git) =
    version.from_build("2026-11-12T20:41:07.123Z", "nogit")
  assert version.to_string(no_git) == "2026-11-12.204107.nogit"
}

pub fn is_newer_orders_by_build_time_test() {
  let assert Ok(first) = version.parse("2026-11-12.204107.aaaaaaa")
  let assert Ok(same_time) = version.parse("2026-11-12.204107.bbbbbbb")
  let assert Ok(a_second_later) = version.parse("2026-11-12.204108.ccccccc")
  let assert Ok(next_year) = version.parse("2027-01-01.000000.ddddddd")
  assert version.is_newer(a_second_later, than: first)
  assert version.is_newer(next_year, than: a_second_later)
  assert !version.is_newer(first, than: next_year)
  assert !version.is_newer(first, than: first)
  assert !version.is_newer(same_time, than: first)
}

pub fn version_json_round_trips_test() {
  let assert Ok(parsed) = version.parse("2026-11-12.204107.abc1234")
  assert version.to_json(parsed)
    == "{\"version\":\"2026-11-12.204107.abc1234\"}"
  assert version.from_json(version.to_json(parsed)) == Ok(parsed)
}

pub fn from_json_rejects_other_bodies_test() {
  assert version.from_json("<!doctype html><title>Not found</title>")
    == Error(NotVersionJson)
  assert version.from_json("{\"other\":1}") == Error(NotVersionJson)
  assert version.from_json("{\"version\":\"soon\"}") == Error(NotThreeParts)
}
