import gleam/bit_array
import gleam/dynamic
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import simplifile
import tabletop/backup.{
  Backup, Broken, Made, NotABackup, SomeKeys, Source, TooNew,
}
import tabletop/browser
import tabletop/data
import tabletop/score
import tabletop/storage.{
  BytesValue, Cards, DataIndexes, DataZips, Games, JsonValue, Lists, Meta, Put,
  Sheets,
}

fn fixture() -> String {
  let assert Ok(text) = simplifile.read("test/fixtures/invented-backup.json")
  text
}

fn with_schema(text: String, schema: Int) -> String {
  string.replace(text, "\"schema\": 5", "\"schema\": " <> int.to_string(schema))
}

// --- Which stores a backup holds ---------------------------------------------

pub fn every_store_says_how_it_goes_into_a_backup_test() {
  assert list.map(storage.stores(), backup.kind)
    == [SomeKeys([]), Source, Source, Source, Source, Source, Source]
  // Nothing is made today, so every store is in the file, Meta with no key.
  assert backup.stores() == storage.stores()
  assert !list.contains(list.map(storage.stores(), backup.kind), Made)
}

pub fn the_device_keys_stay_on_the_device_test() {
  let meta = [
    #("first_opened", JsonValue(json.int(1))),
    #("last_backup", JsonValue(json.int(2))),
  ]
  assert backup.keep(meta, Meta) == []
  let lists = [#("l1", JsonValue(json.object([])))]
  assert backup.keep(lists, Lists) == lists
}

// --- The file -----------------------------------------------------------------

fn a_backup() -> backup.Backup {
  let list_record =
    json.object([
      #("name", json.string("Sunday Picnic")),
      #("imported", json.int(1_762_980_000_000)),
      #("file", json.string("{\"roster\":{}}")),
      #("tags", json.preprocessed_array([json.bool(True), json.null()])),
      #("weight", json.float(1.5)),
    ])
  Backup(
    made: "2026-11-13T15:42:00.000Z",
    release: "2026.11.13.1542",
    schema: 5,
    stores: [
      #(Meta, []),
      #(Lists, [#("list-sunday", JsonValue(list_record))]),
      #(DataIndexes, []),
      // Not UTF-8, and a length that base64 pads.
      #(DataZips, [#("sys-picnic", BytesValue(<<0, 255, 128, 1, 2>>))]),
      #(Cards, []),
      #(Sheets, []),
      #(Games, []),
    ],
  )
}

pub fn a_backup_round_trips_with_json_and_bytes_test() {
  let text = backup.encode(a_backup())
  assert string.starts_with(text, "{\"format\":\"tabletop-backup\",")
  assert string.contains(
    text,
    "{\"key\":\"sys-picnic\",\"base64\":\"AP+AAQI=\"}",
  )
  assert backup.read(text, schema: 5) == Ok(a_backup())
}

pub fn a_file_of_another_format_is_not_a_backup_test() {
  assert backup.read("{\"format\":\"something-else\"}", schema: 5)
    == Error(NotABackup)
  assert backup.read("{\"roster\":{}}", schema: 5) == Error(NotABackup)
  assert backup.read("[1, 2]", schema: 5) == Error(NotABackup)
  assert backup.read("not json", schema: 5) == Error(NotABackup)
  let assert Ok(list) = simplifile.read("test/fixtures/invented-list.json")
  assert backup.read(list, schema: 5) == Error(NotABackup)
}

pub fn a_backup_from_a_later_schema_is_refused_test() {
  assert backup.read(with_schema(fixture(), 6), schema: 5) == Error(TooNew(6))
  // Refused before its stores are read, which this app may not know.
  let unknown =
    "{\"format\":\"tabletop-backup\",\"made\":\"\",\"release\":\"\",\"schema\":9,\"stores\":{\"maps\":[{\"shape\":1}]}}"
  assert backup.read(unknown, schema: 5) == Error(TooNew(9))
}

pub fn a_backup_from_an_earlier_schema_is_restored_test() {
  let assert Ok(now) = backup.read(fixture(), schema: 5)
  let assert Ok(earlier) = backup.read(with_schema(fixture(), 3), schema: 5)
  assert earlier.schema == 3
  assert earlier.stores == now.stores
  // A schema 3 app had no cards store, so its backup has none.
  let no_cards =
    "{\"format\":\"tabletop-backup\",\"made\":\"\",\"release\":\"\",\"schema\":3,\"stores\":{\"lists\":[]}}"
  let assert Ok(old) = backup.read(no_cards, schema: 5)
  assert list.key_find(old.stores, Cards) == Ok([])
}

pub fn a_broken_record_breaks_the_backup_test() {
  let broken = fn(from, to) {
    backup.read(string.replace(fixture(), from, to), schema: 5)
  }
  assert broken("UEsFBgAAAAAAAAAAAAAAAAAAAAA=", "not base64!") == Error(Broken)
  assert broken("\"key\": \"card-pour\"", "\"id\": \"card-pour\"")
    == Error(Broken)
  assert broken("\"base64\":", "\"bytes\":") == Error(Broken)
  assert broken("\"made\":", "\"when\":") == Error(Broken)
  assert broken("\"stores\": {", "\"stores\": 5, \"old\": {") == Error(Broken)
}

pub fn the_file_name_is_the_date_test() {
  assert backup.file_name(#(2026, 1, 5)) == "tabletop-backup-2026-01-05.json"
  assert backup.file_name(#(2026, 11, 13)) == "tabletop-backup-2026-11-13.json"
}

pub fn a_saved_file_says_where_to_look_until_the_screen_changes_test() {
  let file = "tabletop-backup-2026-11-13.json"
  let #(state, _) =
    backup.update(backup.init(), backup.Saved(Ok(#(0, file))), None)
  let shown = fn(state) {
    element.fragment(backup.section(state)) |> element.to_string
  }
  assert string.contains(shown(state), "Last backup file made: ")
  assert string.contains(
    shown(state),
    "Look for the file " <> file <> " in your downloads",
  )
  assert !string.contains(shown(backup.screen_changed(state)), "Look for")
}

// --- Restoring ----------------------------------------------------------------

pub fn the_question_counts_what_the_backup_holds_test() {
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  assert backup.holds(read)
    == "1 list, 1 game data set, 2 cards, 1 score sheet and 1 game"
  assert backup.holds(a_backup()) == "1 list"
  assert backup.holds(Backup(..a_backup(), stores: [])) == "nothing"
  let two_lists =
    Backup(..a_backup(), stores: [
      #(Lists, [#("a", JsonValue(json.null())), #("b", JsonValue(json.null()))]),
      #(Cards, [#("c", JsonValue(json.null()))]),
    ])
  assert backup.holds(two_lists) == "2 lists and 1 card"
}

pub fn a_restore_puts_every_record_and_no_device_key_test() {
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  let writes = backup.writes(read)
  assert list.map(writes, fn(write) { #(write.store, write.key) })
    == [
      #(Lists, "list-sunday"),
      #(DataIndexes, "sys-picnic"),
      #(DataZips, "sys-picnic"),
      #(Cards, "card-pour"),
      #(Cards, "card-crumb"),
      #(Sheets, "sheet-picnic"),
      #(Games, "game-picnic"),
    ]
  assert list.all(writes, fn(write) {
    case write {
      Put(..) -> True
      storage.Remove(..) -> False
    }
  })
}

/// The fixture against a device that has its game, its sheet and one of its
/// two cards, plus records of its own.
fn a_split() -> backup.Split {
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  backup.split(read, [
    #(Cards, ["card-pour", "card-own"]),
    #(Sheets, ["sheet-picnic"]),
    #(Games, ["game-own", "game-picnic"]),
  ])
}

fn keys(writes: List(storage.Write)) -> List(#(storage.Store, String)) {
  list.map(writes, fn(write) { #(write.store, write.key) })
}

pub fn a_backup_splits_into_missing_and_present_by_key_test() {
  let split = a_split()
  let stores = fn(part: backup.Backup) {
    list.map(part.stores, fn(store) {
      #(store.0, list.map(store.1, fn(record) { record.0 }))
    })
  }
  assert stores(split.missing)
    == [
      #(Meta, []),
      #(Lists, ["list-sunday"]),
      #(DataIndexes, ["sys-picnic"]),
      #(DataZips, ["sys-picnic"]),
      #(Cards, ["card-crumb"]),
      #(Sheets, []),
      #(Games, []),
    ]
  assert stores(split.present)
    == [
      #(Meta, []),
      #(Lists, []),
      #(DataIndexes, []),
      #(DataZips, []),
      #(Cards, ["card-pour"]),
      #(Sheets, ["sheet-picnic"]),
      #(Games, ["game-picnic"]),
    ]
  assert split.missing.release == split.backup.release
  // A device with none of it: everything is missing.
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  assert backup.split(read, []).missing == read
}

pub fn the_question_says_how_much_is_already_here_test() {
  assert backup.already_here(a_split())
    == Some(
      "1 card, 1 score sheet and 1 game in this file are already on this device.",
    )
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  assert backup.already_here(backup.split(read, [#(Games, ["game-picnic"])]))
    == Some("1 game in this file is already on this device.")
  assert backup.already_here(backup.split(read, [#(Games, ["game-own"])]))
    == None
}

pub fn add_only_what_is_missing_leaves_the_device_copies_test() {
  assert keys(backup.restore_writes(a_split(), backup.AddMissing))
    == [
      #(Lists, "list-sunday"),
      #(DataIndexes, "sys-picnic"),
      #(DataZips, "sys-picnic"),
      #(Cards, "card-crumb"),
    ]
  assert backup.restored(a_split(), backup.AddMissing)
    == "Added 1 list, 1 game data set and 1 card from the backup file. Kept this device's copies of 1 card, 1 score sheet and 1 game."
}

pub fn replace_writes_every_record_over_the_device_copies_test() {
  assert keys(backup.restore_writes(a_split(), backup.ReplaceAll))
    == [
      #(Lists, "list-sunday"),
      #(DataIndexes, "sys-picnic"),
      #(DataZips, "sys-picnic"),
      #(Cards, "card-pour"),
      #(Cards, "card-crumb"),
      #(Sheets, "sheet-picnic"),
      #(Games, "game-picnic"),
    ]
  assert backup.restored(a_split(), backup.ReplaceAll)
    == "Added 1 list, 1 game data set and 1 card from the backup file. Replaced this device's copies of 1 card, 1 score sheet and 1 game with the copies in the file."
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  assert backup.restored(backup.split(read, []), backup.ReplaceAll)
    == "Added 1 list, 1 game data set, 2 cards, 1 score sheet and 1 game from the backup file."
}

pub fn the_question_offers_a_choice_only_when_some_is_here_test() {
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  let checking = backup.State(..backup.init(), restore: backup.Checking(read))
  let page = fn(state) {
    element.fragment(backup.question_page(state)) |> element.to_string
  }
  assert string.contains(page(checking), "Looking at what is already")
  let answered = fn(keys) {
    backup.update(checking, backup.KeysRead(Ok(keys)), None).0
  }
  let none_here = page(answered([]))
  assert string.contains(none_here, ">Restore</button>")
  assert !string.contains(none_here, "Add only what is missing")
  let some_here = answered([#(Games, ["game-picnic"])])
  assert string.contains(page(some_here), ">Add only what is missing</button>")
  assert string.contains(
    page(some_here),
    ">Replace with the copies in the file</button>",
  )
  assert string.contains(page(some_here), ">Cancel</button>")
  // A pressed answer with no storage writes nothing.
  let #(pressed, _) =
    backup.update(some_here, backup.RestoreClicked(backup.AddMissing), None)
  assert pressed.restore == backup.Failed(backup.NoStorage)
}

pub fn a_restored_index_is_built_again_from_its_zip_test() {
  // The index inside a data set's record is made from its zip. A restored
  // record whose index is older than the app's goes to the rebuild path, as
  // any older record does when the app opens.
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  let assert Ok(Put(value: JsonValue(record), ..)) =
    list.find(backup.writes(read), fn(write) { write.store == DataIndexes })
  assert json.parse(json.to_string(record), data.record_decoder())
    == Ok(#("picnic.zip", 1_762_980_000_000, None))
}

pub fn a_restored_sheet_and_game_read_as_the_tracker_reads_them_test() {
  let assert Ok(read) = backup.read(fixture(), schema: 5)
  let record = fn(store) {
    let assert Ok(Put(value: JsonValue(record), ..)) =
      list.find(backup.writes(read), fn(write) { write.store == store })
    json.to_string(record)
  }
  let assert Ok(sheet) = json.parse(record(Sheets), score.sheet_decoder())
  let assert Ok(game) = json.parse(record(Games), score.game_decoder())
  assert game.sheet == sheet
  assert score.result(game) == "Bram: Crumb Win"
}

// --- Size ---------------------------------------------------------------------

/// A data set's zip is several megabytes, and its index holds thousands of
/// roots. Making and reading the file runs on the page, so this prints how
/// long each step takes for a 4 MB zip and an index of 10,000 roots.
pub fn a_large_backup_is_made_and_read_quickly_test() {
  let assert Ok(files) = simplifile.read_directory("test/fixtures/data")
  let one =
    list.map(files, fn(name) {
      let assert Ok(bytes) = simplifile.read_bits("test/fixtures/data/" <> name)
      bytes
    })
    |> bit_array.concat
  let times = 4_000_000 / bit_array.byte_size(one) + 1
  let zip = bit_array.concat(list.repeat(one, times))
  let root = fn(number) {
    let id = "root-" <> int.to_string(number)
    json.object([
      #("id", json.string(id)),
      #("name", json.string("Teapot Golem " <> id)),
      #("target_id", json.string("")),
      #("kind", json.string("unit")),
      #("primary", json.string("Line")),
      #("shown", json.bool(True)),
    ])
  }
  let stored_index =
    json.object([
      #("file_name", json.string("picnic.zip")),
      #("imported", json.int(1)),
      #(
        "index",
        json.object([
          #("version", json.int(2)),
          #("roots", json.array(int.range(0, 10_000, [], list.prepend), root)),
        ]),
      ),
    ])
    |> json.to_string
  let start = browser.now_ms()
  // As storage hands a record to the backup: its stored JSON text.
  let assert Ok(index) = storage.stored_value(dynamic.string(stored_index))
  let index_read = browser.now_ms()
  let big =
    Backup(..a_backup(), stores: [
      #(Meta, []),
      #(Lists, []),
      #(DataIndexes, [#("sys-picnic", index)]),
      #(DataZips, [#("sys-picnic", BytesValue(zip))]),
      #(Cards, []),
      #(Sheets, []),
      #(Games, []),
    ])
  let text = backup.encode(big)
  let made = browser.now_ms()
  let assert Ok(read) = backup.read(text, schema: 5)
  let done = browser.now_ms()
  assert read == big
  io.println(
    "\nbackup: a "
    <> int.to_string(bit_array.byte_size(zip) / 1000)
    <> " KB zip and a "
    <> int.to_string(string.byte_size(stored_index) / 1000)
    <> " KB index: the index read from storage in "
    <> int.to_string(index_read - start)
    <> " ms, a "
    <> int.to_string(string.byte_size(text) / 1000)
    <> " KB file made in "
    <> int.to_string(made - index_read)
    <> " ms, read back in "
    <> int.to_string(done - made)
    <> " ms",
  )
}
