import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import tabletop/storage.{Undecodable}

pub fn schema_is_at_version_three_test() {
  assert storage.schema_version() == 3
}

pub fn a_new_database_gets_every_store_test() {
  assert storage.stores_to_create(from: 0)
    == ["meta", "lists", "data_indexes", "data_zips"]
}

pub fn a_version_one_database_gets_the_later_stores_test() {
  assert storage.stores_to_create(from: 1)
    == ["lists", "data_indexes", "data_zips"]
}

pub fn a_version_two_database_gets_the_data_stores_test() {
  assert storage.stores_to_create(from: 2) == ["data_indexes", "data_zips"]
}

pub fn a_current_database_gets_no_store_test() {
  assert storage.stores_to_create(from: storage.schema_version()) == []
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
