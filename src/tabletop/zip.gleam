//// Read a zip archive from its bytes: list its entries and hand out one
//// entry's bytes as the zip stores them. `tabletop/bytes` unpacks them.

// ponytail: no CRC-32 check, so a damaged entry is caught only when it fails
// to inflate or comes out at the wrong size. Add the check when a zip that
// unpacks to wrong bytes of the right size shows up.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result

pub type Method {
  Stored
  Deflated
  OtherMethod(Int)
}

pub type Entry {
  Entry(
    name: String,
    method: Method,
    /// Where the entry's local header starts in the zip.
    offset: Int,
    compressed_size: Int,
    size: Int,
  )
}

pub type ZipError {
  NotAZip
  CutShort
  Unsupported(reason: Reason)
}

pub type Reason {
  Zip64
  Encrypted
  NameNotUtf8
}

/// The length of the end-of-central-directory record without its comment.
const end_length = 22

/// The length of a local file header without its name and extra field.
const local_length = 30

/// The bytes start with a local file header signature.
pub fn is_zip(bytes: BitArray) -> Bool {
  case bytes {
    <<0x04034b50:32-little, _:bytes>> -> True
    _ -> False
  }
}

/// Every entry in the central directory, folders included, in its order.
pub fn entries(bytes: BitArray) -> Result(List(Entry), ZipError) {
  let size = bit_array.byte_size(bytes)
  use #(count, offset) <- result.try(find_end(bytes, size, size - end_length))
  use directory <- result.try(
    bit_array.slice(bytes, offset, size - offset)
    |> result.replace_error(CutShort),
  )
  read_directory(directory, count, [])
}

/// The entry count and the central directory's offset, from the end record.
/// A comment can follow the record, so search back from the end for the
/// record whose comment runs exactly to the end of the bytes.
fn find_end(
  bytes: BitArray,
  size: Int,
  at: Int,
) -> Result(#(Int, Int), ZipError) {
  // A comment is 65,535 bytes at most.
  let none_left = at < 0 || at < size - end_length - 0xffff
  let found = case bit_array.slice(bytes, at, end_length) {
    Ok(<<
      0x06054b50:32-little,
      _:bytes-size(6),
      count:16-little,
      _:bytes-size(4),
      offset:32-little,
      comment:16-little,
    >>)
      if at + end_length + comment == size
    -> Ok(#(count, offset))
    _ -> Error(Nil)
  }
  // The recursion stays in tail position, so a long comment cannot fill the
  // stack.
  case found, none_left, is_zip(bytes) {
    _, True, True -> Error(CutShort)
    _, True, False -> Error(NotAZip)
    Ok(#(count, offset)), False, _ ->
      case count == 0xffff || offset == 0xffffffff {
        True -> Error(Unsupported(Zip64))
        False -> Ok(#(count, offset))
      }
    Error(Nil), False, _ -> find_end(bytes, size, at - 1)
  }
}

fn read_directory(
  directory: BitArray,
  count: Int,
  entries: List(Entry),
) -> Result(List(Entry), ZipError) {
  case count {
    0 -> Ok(list.reverse(entries))
    _ ->
      case read_header(directory) {
        Ok(#(entry, rest)) ->
          read_directory(rest, count - 1, [entry, ..entries])
        Error(error) -> Error(error)
      }
  }
}

/// One central directory header, and the bytes after it.
fn read_header(directory: BitArray) -> Result(#(Entry, BitArray), ZipError) {
  case directory {
    <<
      0x02014b50:32-little,
      _:bytes-size(4),
      flags:16-little,
      method:16-little,
      _:bytes-size(8),
      compressed_size:32-little,
      size:32-little,
      name_length:16-little,
      extra_length:16-little,
      comment_length:16-little,
      _:bytes-size(8),
      offset:32-little,
      name:bytes-size(name_length),
      _:bytes-size(extra_length),
      _:bytes-size(comment_length),
      rest:bytes,
    >> -> {
      // The lowest flag bit.
      let encrypted = flags % 2 == 1
      use <- bool.guard(encrypted, Error(Unsupported(Encrypted)))
      let zip64 = list.contains([compressed_size, size, offset], 0xffffffff)
      use <- bool.guard(zip64, Error(Unsupported(Zip64)))
      use name <- result.map(
        bit_array.to_string(name)
        |> result.replace_error(Unsupported(NameNotUtf8)),
      )
      let method = case method {
        0 -> Stored
        8 -> Deflated
        other -> OtherMethod(other)
      }
      #(Entry(name:, method:, offset:, compressed_size:, size:), rest)
    }
    _ -> Error(CutShort)
  }
}

/// The entry's bytes as the zip stores them. The name and extra lengths come
/// from the local header, because they can differ from the central
/// directory's.
pub fn compressed(bytes: BitArray, entry: Entry) -> Result(BitArray, ZipError) {
  case bit_array.slice(bytes, entry.offset, local_length) {
    Ok(<<
      0x04034b50:32-little,
      _:bytes-size(22),
      name_length:16-little,
      extra_length:16-little,
    >>) ->
      bit_array.slice(
        bytes,
        entry.offset + local_length + name_length + extra_length,
        entry.compressed_size,
      )
      |> result.replace_error(CutShort)
    Ok(_) -> Error(NotAZip)
    Error(Nil) -> Error(CutShort)
  }
}
