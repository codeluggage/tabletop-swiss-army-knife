//// Writes a zip for the tests: named byte runs under one top folder, each
//// stored or deflated, with a comment at the end. The checksums are left at
//// zero, because the reader does not check them.

import gleam/bit_array
import gleam/list

pub type File {
  File(name: String, bytes: BitArray, packing: Packing)
}

pub type Packing {
  Store
  Deflate
}

/// A packed entry: its full name, zip method number, bytes as stored, and
/// unpacked size.
type Packed {
  Packed(name: BitArray, method: Int, data: BitArray, size: Int)
}

/// Each local header holds this extra field and the central directory holds
/// none, so the two disagree on the extra length, as they do in real zips.
const local_extra = <<0xcafe:16-little, 0:16>>

pub fn write(folder: String, files: List(File), comment: String) -> BitArray {
  write_flagged(folder, files, comment, 0)
}

/// `flags` goes into every header as the general purpose flags.
pub fn write_flagged(
  folder: String,
  files: List(File),
  comment: String,
  flags: Int,
) -> BitArray {
  let folder_entry =
    Packed(name: <<folder:utf8, "/":utf8>>, method: 0, data: <<>>, size: 0)
  let packed = [folder_entry, ..list.map(files, pack(folder, _))]
  let #(locals, directory) =
    list.fold(packed, #(<<>>, <<>>), fn(written, entry) {
      let #(locals, directory) = written
      let offset = bit_array.byte_size(locals)
      #(<<locals:bits, local(entry, flags):bits>>, <<
        directory:bits,
        central(entry, flags, offset):bits,
      >>)
    })
  let count = list.length(packed)
  let comment = <<comment:utf8>>
  <<
    locals:bits,
    directory:bits,
    0x06054b50:32-little,
    0:16,
    0:16,
    count:16-little,
    count:16-little,
    { bit_array.byte_size(directory) }:32-little,
    { bit_array.byte_size(locals) }:32-little,
    { bit_array.byte_size(comment) }:16-little,
    comment:bits,
  >>
}

fn pack(folder: String, file: File) -> Packed {
  let name = <<folder:utf8, "/":utf8, file.name:utf8>>
  let size = bit_array.byte_size(file.bytes)
  case file.packing {
    Store -> Packed(name:, method: 0, data: file.bytes, size:)
    Deflate -> Packed(name:, method: 8, data: deflate_raw(file.bytes), size:)
  }
}

fn local(entry: Packed, flags: Int) -> BitArray {
  <<
    0x04034b50:32-little,
    20:16-little,
    flags:16-little,
    entry.method:16-little,
    0:32,
    0:32,
    { bit_array.byte_size(entry.data) }:32-little,
    entry.size:32-little,
    { bit_array.byte_size(entry.name) }:16-little,
    { bit_array.byte_size(local_extra) }:16-little,
    entry.name:bits,
    local_extra:bits,
    entry.data:bits,
  >>
}

fn central(entry: Packed, flags: Int, offset: Int) -> BitArray {
  <<
    0x02014b50:32-little,
    20:16-little,
    20:16-little,
    flags:16-little,
    entry.method:16-little,
    0:32,
    0:32,
    { bit_array.byte_size(entry.data) }:32-little,
    entry.size:32-little,
    { bit_array.byte_size(entry.name) }:16-little,
    0:16,
    0:16,
    0:16,
    0:16,
    0:32,
    offset:32-little,
    entry.name:bits,
  >>
}

@external(javascript, "./zip_writer_ffi.mjs", "deflate_raw")
fn deflate_raw(bytes: BitArray) -> BitArray
