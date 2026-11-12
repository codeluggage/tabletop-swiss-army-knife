// Node calls for the build and serve commands. No decisions here.
import { execSync } from "node:child_process";
import { createServer } from "node:http";
import { Result$Ok, Result$Error, BitArray$BitArray$data } from "../gleam.mjs";

export function now_iso() {
  return new Date().toISOString();
}

export function git_commit() {
  try {
    const out = execSync("git rev-parse --short HEAD", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    return Result$Ok(out.trim());
  } catch (error) {
    return Result$Error(String(error));
  }
}

export function arguments_() {
  return process.argv.slice(2);
}

export function set_exit_code(code) {
  process.exitCode = code;
}

// `respond` is a Gleam fn(url) -> #(status, content_type, body).
export function start_server(port, respond) {
  createServer((request, response) => {
    const [status, type, body] = respond(request.url);
    const view = BitArray$BitArray$data(body);
    response.writeHead(status, { "content-type": type, "cache-control": "no-cache" });
    response.end(new Uint8Array(view.buffer, view.byteOffset, view.byteLength));
  }).listen(port);
}
