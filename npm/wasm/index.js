import { createFormatterFrom } from "./shared.js";

export { TerenceCssError } from "./shared.js";

export function createFormatter(source) {
  return createFormatterFrom(
    source ?? fetch(new URL("./terence_css.wasm", import.meta.url)),
  );
}
