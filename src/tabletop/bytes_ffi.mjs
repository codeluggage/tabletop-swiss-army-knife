// Decompression for bytes.gleam, in a browser and in Node. Resolves to a
// Gleam Result and never rejects. No decisions here; Gleam makes them.
import { Result$Ok, Result$Error, BitArray$BitArray, BitArray$BitArray$data } from "../gleam.mjs";

export async function inflate_raw(bytes) {
  try {
    const stream = new Blob([BitArray$BitArray$data(bytes)]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    return Result$Ok(BitArray$BitArray(new Uint8Array(await new Response(stream).arrayBuffer())));
  } catch (error) {
    return Result$Error(String(error));
  }
}
