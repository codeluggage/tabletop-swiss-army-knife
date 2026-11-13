import gleam/javascript/promise.{type Promise}
import gleam/string
import tabletop/bytes.{BadZip, UnsupportedMethod, WrongSize}
import tabletop/zip.{CutShort, Entry, OtherMethod}
import tabletop/zip_writer.{Deflate, File, Store}

const recipe = <<"{\"tea\": \"mint\"}":utf8>>

fn menu() -> BitArray {
  <<string.repeat("scones and jam, ", 40):utf8>>
}

/// A zip with one stored and one deflated entry, and those two entries.
fn sample() -> #(BitArray, zip.Entry, zip.Entry) {
  let archive =
    zip_writer.write(
      "picnic",
      [File("recipe.json", recipe, Store), File("menu.txt", menu(), Deflate)],
      "for sunday",
    )
  let assert Ok([_, stored, deflated]) = zip.entries(archive)
  #(archive, stored, deflated)
}

// gleeunit waits for the promise a test returns, and a failed assert in it
// fails the test.

pub fn a_stored_and_a_deflated_entry_unpack_test() -> Promise(Nil) {
  let #(archive, stored, deflated) = sample()
  use from_stored <- promise.await(bytes.unpack(archive, stored))
  use from_deflated <- promise.map(bytes.unpack(archive, deflated))
  assert from_stored == Ok(recipe)
  assert from_deflated == Ok(menu())
}

pub fn a_size_that_does_not_match_is_an_error_test() -> Promise(Nil) {
  let #(archive, stored, deflated) = sample()
  let longer = Entry(..stored, size: stored.size + 1)
  let shorter = Entry(..deflated, size: deflated.size - 1)
  use from_stored <- promise.await(bytes.unpack(archive, longer))
  use from_deflated <- promise.map(bytes.unpack(archive, shorter))
  assert from_stored == Error(WrongSize(expected: 16, actual: 15))
  assert from_deflated == Error(WrongSize(expected: 639, actual: 640))
}

pub fn an_entry_that_cannot_be_unpacked_says_why_test() -> Promise(Nil) {
  let #(archive, stored, deflated) = sample()
  let other = Entry(..stored, method: OtherMethod(12))
  let beyond = Entry(..stored, compressed_size: 100_000)
  // Stored bytes are not a deflate stream.
  let not_deflated = Entry(..deflated, offset: stored.offset)
  use from_other <- promise.await(bytes.unpack(archive, other))
  use from_beyond <- promise.await(bytes.unpack(archive, beyond))
  use from_not_deflated <- promise.map(bytes.unpack(archive, not_deflated))
  assert from_other == Error(UnsupportedMethod(12))
  assert from_beyond == Error(BadZip(CutShort))
  let assert Error(bytes.InflateFailed(_)) = from_not_deflated
  Nil
}
