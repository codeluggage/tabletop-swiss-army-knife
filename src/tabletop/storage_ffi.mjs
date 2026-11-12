// IndexedDB calls for storage.gleam. Every function resolves to a Gleam
// Result and never rejects. Values are the JSON strings Gleam made.
import { Result$Ok, Result$Error } from "../gleam.mjs";

async function attempt(run) {
  try {
    return await run();
  } catch (error) {
    return Result$Error(String(error));
  }
}

export function open(name, version, storesToCreate) {
  return attempt(() => new Promise((resolve) => {
    const request = indexedDB.open(name, version);
    request.onupgradeneeded = (event) => {
      for (const store of storesToCreate(event.oldVersion)) request.result.createObjectStore(store);
    };
    request.onsuccess = () => {
      // Close when a newer tab asks to upgrade the schema, so it is not blocked.
      request.result.onversionchange = () => request.result.close();
      resolve(Result$Ok(request.result));
    };
    request.onerror = () => resolve(Result$Error(String(request.error)));
  }));
}

export function get(db, store, key) {
  return attempt(() => new Promise((resolve) => {
    const request = db.transaction(store, "readonly").objectStore(store).get(key);
    request.onsuccess = () => resolve(Result$Ok(request.result));
    request.onerror = () => resolve(Result$Error(String(request.error)));
  }));
}

export function put(db, store, key, value) {
  return attempt(() => new Promise((resolve) => {
    const transaction = db.transaction(store, "readwrite");
    transaction.objectStore(store).put(value, key);
    transaction.oncomplete = () => resolve(Result$Ok(undefined));
    transaction.onerror = transaction.onabort = () => resolve(Result$Error(String(transaction.error)));
  }));
}

// Resolves to [keys, values]: two arrays in the same key order.
export function get_all(db, store) {
  return attempt(() => new Promise((resolve) => {
    const objects = db.transaction(store, "readonly").objectStore(store);
    const keys = objects.getAllKeys();
    const values = objects.getAll();
    values.onsuccess = () => resolve(Result$Ok([keys.result, values.result]));
    keys.onerror = () => resolve(Result$Error(String(keys.error)));
    values.onerror = () => resolve(Result$Error(String(values.error)));
  }));
}

export function delete_(db, store, key) {
  return attempt(() => new Promise((resolve) => {
    const transaction = db.transaction(store, "readwrite");
    transaction.objectStore(store).delete(key);
    transaction.oncomplete = () => resolve(Result$Ok(undefined));
    transaction.onerror = transaction.onabort = () => resolve(Result$Error(String(transaction.error)));
  }));
}

export function persist() {
  return attempt(async () => Result$Ok(await navigator.storage.persist()));
}
