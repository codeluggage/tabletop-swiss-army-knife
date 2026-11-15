// Page-level browser calls for browser.gleam: the version stamped into the
// page, the service worker, the clock. No decisions here; Gleam makes them.
import { Result$Ok, Result$Error, BitArray$BitArray, BitArray$BitArray$data } from "../gleam.mjs";

export function running_version() {
  return document.querySelector('meta[name="tabletop-version"]').content;
}

export function running_commit() {
  return document.querySelector('meta[name="tabletop-commit"]').content;
}

export function fetch_no_store(url) {
  return fetch(url, { cache: "no-store" }).then(
    async (response) => Result$Ok(await response.text()),
    (error) => Result$Error(String(error)),
  );
}

export function is_local_development() {
  return location.hostname === "localhost" || location.hostname === "127.0.0.1";
}

export async function fetch_local_page(url) {
  try {
    const response = await fetch(
      "/__local_test_page?url=" + encodeURIComponent(url),
      { cache: "no-store" },
    );
    if (!response.ok) return Result$Error(await response.text());
    const sourceUrl = response.headers.get("x-source-url") || url;
    const page = new DOMParser().parseFromString(await response.text(), "text/html");
    const name = page.querySelector("h1")?.textContent?.trim()
      || page.title.split(/\s+[—–-]\s+/)[0].trim();
    const rows = [...page.querySelectorAll("tr")];
    const cost = rows
      .map((row) => [...row.querySelectorAll("td")].map((cell) => cell.textContent.replace(/\s+/g, " ").trim()))
      .find((cells) => /\d+\s+models?/i.test(cells[0] ?? "") && /\d/.test(cells[1] ?? ""));
    const points = cost?.[1]?.match(/\d[\d,]*/)?.[0].replaceAll(",", "");
    if (!name || !points) return Result$Error("Could not find a page title and a model cost row.");
    const sheet = page.querySelector(".datasheet");
    const preview = sheet?.cloneNode(true);
    if (preview) {
      for (const section of [...preview.children]) {
        if (section.classList.contains("ShowDatasheetFeatures")) section.remove();
      }
      for (const element of [preview, ...preview.querySelectorAll("*")]) {
        for (const attribute of [...element.attributes]) {
          if (attribute.name.toLowerCase().startsWith("on")) {
            element.removeAttribute(attribute.name);
          }
        }
      }
      for (const element of preview.querySelectorAll("script, iframe, object, embed, form")) {
        element.remove();
      }
    }
    const sections = [...(sheet?.children ?? [])]
      .filter((section) => !section.classList.contains("ShowDatasheetFeatures"));
    for (const row of sections.flatMap((section) => [...section.querySelectorAll("tr")])) {
      const cells = [...row.querySelectorAll("th, td")]
        .map((cell) => cell.textContent.replace(/\s+/g, " ").trim())
        .filter(Boolean);
      if (cells.length > 0) row.replaceWith(page.createTextNode(cells.join(" | ") + "\n"));
    }
    for (const node of sections.flatMap((section) =>
      [...section.querySelectorAll("div, p, ul, ol, li, h1, h2, h3, h4, h5, h6")])) {
      node.insertAdjacentText("beforebegin", "\n");
      node.insertAdjacentText("afterend", "\n");
    }
    const lines = sections
      .map((section) => section.textContent || "")
      .join("\n\n")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const details = lines
      .filter((line, index) => line !== lines[index - 1]
        && !(line.includes("|") === false && lines[index + 1]?.startsWith(line + " | ")))
      .join("\n");
    const base = '<base href="' + sourceUrl.replace(/"/g, "%22") + '">';
    const styles = [...page.querySelectorAll('link[rel~="stylesheet"]')]
      .map((link) => {
        try {
          const href = new URL(link.getAttribute("href"), sourceUrl);
          return href.protocol === "https:"
            ? '<link rel="stylesheet" href="' + href.href + '">'
            : "";
        } catch {
          return "";
        }
      })
      .join("");
    const previewHtml = preview
      ? "<!doctype html><html><head>" + base
        + '<meta name="viewport" content="width=device-width, initial-scale=1">'
        + styles + "</head><body>" + preview.outerHTML + "</body></html>"
      : "";
    return Result$Ok([name, Number(points), details, previewHtml]);
  } catch (error) {
    return Result$Error(String(error));
  }
}

export function register_worker(url) {
  navigator.serviceWorker?.register(url);
}

export function on_visibility_change(callback) {
  document.addEventListener("visibilitychange", () => callback(document.visibilityState));
}

export function on_controller_change(callback) {
  navigator.serviceWorker?.addEventListener("controllerchange", () => callback());
}

// Fetch the newest worker and tell it to take over. False when there is no
// new worker to tell (or no service worker at all).
export async function activate_new_worker() {
  try {
    const registration = await navigator.serviceWorker.getRegistration();
    await registration.update();
    (registration.waiting ?? registration.installing).postMessage("skip-waiting");
    return true;
  } catch {
    return false;
  }
}

export function reload() {
  location.reload();
}

export function now_ms() {
  return Date.now();
}

export function local_time(ms) {
  return new Date(ms).toLocaleString();
}

export function iso_time(ms) {
  return new Date(ms).toISOString();
}

export function local_time_of_iso(text) {
  return new Date(text).toLocaleString();
}

// getMonth counts from 0.
export function local_date(ms) {
  const date = new Date(ms);
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()];
}

// The address is let go after a minute, when the browser has the file.
export function download(name, text) {
  const url = URL.createObjectURL(new Blob([text], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

export function current_hash() {
  return location.hash;
}

export function set_hash(hash) {
  location.hash = hash;
}

export function on_hash_change(callback) {
  window.addEventListener("hashchange", () => callback(location.hash));
}

export function history_back() {
  history.back();
}

export function scroll_y() {
  return window.scrollY;
}

export function scroll_to(y) {
  window.scrollTo(0, y);
}

export function manual_scroll_restoration() {
  history.scrollRestoration = "manual";
}

export function random_id() {
  return crypto.randomUUID();
}

// stream: true is only for Node 22, whose one-shot decode of windows-1252 is
// Latin-1. A single-byte encoding leaves nothing for a later call.
export function windows_1252_to_string(bytes) {
  return new TextDecoder("windows-1252").decode(BitArray$BitArray$data(bytes), { stream: true });
}

// The file chosen in a file input: its name and bytes. Clears the input, so
// choosing the same file again still fires a change.
export async function read_chosen_file(input) {
  try {
    const file = input.files[0];
    input.value = "";
    return Result$Ok([file.name, BitArray$BitArray(new Uint8Array(await file.arrayBuffer()))]);
  } catch (error) {
    return Result$Error(String(error));
  }
}
