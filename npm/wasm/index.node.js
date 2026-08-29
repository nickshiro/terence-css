import { readFile } from "node:fs/promises";

import { createFormatterFrom } from "./shared.js";

export { TerenceCssError } from "./shared.js";

export async function createFormatter(source) {
  return createFormatterFrom(
    source ?? readFile(new URL("./terence_css.wasm", import.meta.url)),
  );
}
