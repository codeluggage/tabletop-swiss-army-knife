//// Unpack one entry of a zip to its bytes. `tabletop/zip` finds the entry;
//// the platform inflates it.

import gleam/bit_array
import gleam/javascript/promise.{type Promise}
import gleam/result
import tabletop/zip

pub type UnpackError {
  /// The entry's bytes could not be read from the zip.
  BadZip(zip.ZipError)
  /// The entry is neither stored nor deflated. Holds the zip's method number.
  UnsupportedMethod(Int)
  InflateFailed(reason: String)
  /// The bytes came out at another size than the zip says.
  WrongSize(expected: Int, actual: Int)
}

/// The entry's bytes, unpacked.
pub fn unpack(
  zip_bytes: BitArray,
  entry: zip.Entry,
) -> Promise(Result(BitArray, UnpackError)) {
  let unpacked = case zip.compressed(zip_bytes, entry), entry.method {
    Error(error), _ -> promise.resolve(Error(BadZip(error)))
    Ok(bytes), zip.Stored -> promise.resolve(Ok(bytes))
    Ok(bytes), zip.Deflated ->
      inflate_raw(bytes) |> promise.map(result.map_error(_, InflateFailed))
    Ok(_), zip.OtherMethod(method) ->
      promise.resolve(Error(UnsupportedMethod(method)))
  }
  use bytes <- promise.map_try(unpacked)
  case bit_array.byte_size(bytes) {
    actual if actual == entry.size -> Ok(bytes)
    actual -> Error(WrongSize(expected: entry.size, actual:))
  }
}

@external(javascript, "./bytes_ffi.mjs", "inflate_raw")
fn inflate_raw(bytes: BitArray) -> Promise(Result(BitArray, String))
