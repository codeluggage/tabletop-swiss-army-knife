import gleam/bit_array
import gleam/list
import gleam/string
import tabletop/zip.{
  CutShort, Deflated, Encrypted, Entry, NotAZip, Stored, Unsupported, Zip64,
}
import tabletop/zip_writer.{Deflate, File, Store}

const recipe = <<"{\"tea\": \"mint\"}":utf8>>

/// Long and repetitive, so it deflates to fewer bytes.
fn menu() -> BitArray {
  <<string.repeat("scones and jam, ", 40):utf8>>
}

fn sample(comment: String) -> BitArray {
  zip_writer.write(
    "picnic",
    [
      File("recipe.json", recipe, Store),
      File("menu.txt", menu(), Deflate),
    ],
    comment,
  )
}

pub fn entries_have_names_methods_and_sizes_test() {
  let assert Ok([folder, stored, deflated]) = zip.entries(sample("for sunday"))
  assert folder == Entry("picnic/", Stored, 0, 0, 0)
  assert #(stored.name, stored.method, stored.size, stored.compressed_size)
    == #("picnic/recipe.json", Stored, 15, 15)
  assert #(deflated.name, deflated.method, deflated.size)
    == #("picnic/menu.txt", Deflated, 640)
  assert deflated.compressed_size < 100
}

pub fn a_stored_entry_gives_its_bytes_test() {
  let bytes = sample("for sunday")
  let assert Ok([_, stored, deflated]) = zip.entries(bytes)
  assert zip.compressed(bytes, stored) == Ok(recipe)
  let assert Ok(packed) = zip.compressed(bytes, deflated)
  assert bit_array.byte_size(packed) == deflated.compressed_size
}

pub fn a_comment_at_the_end_changes_nothing_test() {
  let assert Ok(without) = zip.entries(sample(""))
  assert zip.entries(sample("for sunday")) == Ok(without)
  // A comment that holds the end record's own signature.
  assert zip.entries(sample("PK\u{5}\u{6} is not the end")) == Ok(without)
  assert zip.entries(sample(string.repeat("crumbs ", 5000))) == Ok(without)
}

pub fn bytes_that_are_not_a_zip_are_not_a_zip_test() {
  assert !zip.is_zip(<<"{\"roster\": {}}":utf8>>)
  assert !zip.is_zip(<<>>)
  assert zip.is_zip(sample(""))
  assert zip.entries(<<"{\"roster\": {}}":utf8>>) == Error(NotAZip)
  assert zip.entries(<<>>) == Error(NotAZip)
  assert zip.entries(<<string.repeat("tea", 40_000):utf8>>) == Error(NotAZip)
}

pub fn a_zip_cut_short_says_so_test() {
  let bytes = sample("for sunday")
  let cut = fn(length) {
    let assert Ok(start) = bit_array.slice(bytes, 0, length)
    start
  }
  let size = bit_array.byte_size(bytes)
  assert zip.entries(cut(size - 1)) == Error(CutShort)
  assert zip.entries(cut(size / 2)) == Error(CutShort)
  assert zip.entries(cut(40)) == Error(CutShort)
  // The entry is known from the whole zip, and its bytes are gone.
  let assert Ok(entries) = zip.entries(bytes)
  let assert Ok(last) = list.last(entries)
  assert zip.compressed(cut(last.offset + 10), last) == Error(CutShort)
  assert zip.compressed(cut(last.offset + 60), last) == Error(CutShort)
  assert zip.compressed(bytes, Entry(..last, offset: 3)) == Error(NotAZip)
}

pub fn a_zip_this_reader_cannot_read_says_why_test() {
  let locked =
    zip_writer.write_flagged("picnic", [File("a.json", recipe, Store)], "", 1)
  assert zip.entries(locked) == Error(Unsupported(Encrypted))
  // An end record with every count at its largest value points at zip64.
  let large = <<
    0x06054b50:32-little, 0:32, 0xffff:16, 0xffff:16, 0:32, 0:32, 0:16,
  >>
  assert zip.entries(large) == Error(Unsupported(Zip64))
}
