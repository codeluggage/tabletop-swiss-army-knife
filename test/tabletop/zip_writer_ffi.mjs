// Compression for the test zip writer, on Node only.
import { deflateRawSync } from "node:zlib";
import { BitArray$BitArray, BitArray$BitArray$data } from "../gleam.mjs";

export function deflate_raw(bytes) {
  return BitArray$BitArray(new Uint8Array(deflateRawSync(BitArray$BitArray$data(bytes))));
}
