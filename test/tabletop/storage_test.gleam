import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import tabletop/storage.{BytesValue, JsonValue, Undecodable}

pub fn schema_is_at_version_five_test() {
  assert storage.schema_version() == 5
}

pub fn a_new_database_gets_every_store_test() {
  assert storage.stores_to_create(from: 0)
    == [
      "meta",
      "lists",
      "data_indexes",
      "data_zips",
      "cards",
      "sheets",
      "games",
    ]
}

pub fn a_version_one_database_gets_the_later_stores_test() {
  assert storage.stores_to_create(from: 1)
    == ["lists", "data_indexes", "data_zips", "cards", "sheets", "games"]
}

pub fn a_version_two_database_gets_the_data_stores_test() {
  assert storage.stores_to_create(from: 2)
    == ["data_indexes", "data_zips", "cards", "sheets", "games"]
}

pub fn a_version_three_database_gets_the_cards_store_test() {
  assert storage.stores_to_create(from: 3) == ["cards", "sheets", "games"]
}

pub fn a_version_four_database_gets_the_sheets_and_games_test() {
  assert storage.stores_to_create(from: 4) == ["sheets", "games"]
}

pub fn a_current_database_gets_no_store_test() {
  assert storage.stores_to_create(from: storage.schema_version()) == []
}

pub fn an_app_older_than_the_data_is_its_own_error_test() {
  let words =
    "VersionError: The requested version (4) is less than the existing version (5)."
  assert storage.open_error(#("VersionError", words))
    == storage.AppOlderThanData
  assert storage.open_error(#("UnknownError", "UnknownError: gone"))
    == storage.OpenFailed("UnknownError: gone")
  assert storage.open_error(#("", "TypeError: no indexedDB"))
    == storage.OpenFailed("TypeError: no indexedDB")
}

pub fn a_missing_value_is_none_test() {
  assert storage.decode_value(dynamic.nil(), "first_opened", decode.int)
    == Ok(None)
}

pub fn a_stored_value_round_trips_test() {
  let stored = json.int(1_762_980_067_123) |> json.to_string |> dynamic.string
  assert storage.decode_value(stored, "first_opened", decode.int)
    == Ok(Some(1_762_980_067_123))
}

pub fn an_unreadable_value_names_its_key_test() {
  let not_json = dynamic.string("not json")
  let wrong_shape = dynamic.string("\"a string\"")
  let not_a_string = dynamic.int(5)
  assert storage.decode_value(not_json, "first_opened", decode.int)
    == Error(Undecodable("first_opened"))
  assert storage.decode_value(wrong_shape, "first_opened", decode.int)
    == Error(Undecodable("first_opened"))
  assert storage.decode_value(not_a_string, "first_opened", decode.int)
    == Error(Undecodable("first_opened"))
}

pub fn every_store_in_schema_order_test() {
  assert list.map(storage.stores(), storage.store_name)
    == storage.stores_to_create(from: 0)
}

pub fn a_record_is_read_as_it_is_stored_test() {
  let text = "{\"name\":\"Sunday Picnic\",\"tags\":[1,1.5,true,null]}"
  let assert Ok(JsonValue(value)) = storage.stored_value(dynamic.string(text))
  assert json.parse(json.to_string(value), decode.dynamic)
    == json.parse(text, decode.dynamic)
  assert storage.stored_value(dynamic.bit_array(<<1, 2>>))
    == Ok(BytesValue(<<1, 2>>))
  assert storage.stored_value(dynamic.string("not json")) == Error(Nil)
  assert storage.stored_value(dynamic.int(5)) == Error(Nil)
}
