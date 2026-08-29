import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { createFormatter, TerenceCssError } from "./index.node.js";
import { createFormatter as createBrowserFormatter } from "./index.js";

const wasmPath =
  process.argv[2] ?? new URL("./terence_css.wasm", import.meta.url);
const wasmBytes = await readFile(wasmPath);
const wasmModule = await WebAssembly.compile(wasmBytes);

assert.deepEqual(WebAssembly.Module.imports(wasmModule), []);
assert.deepEqual(
  WebAssembly.Module.exports(wasmModule)
    .map(({ name }) => name)
    .sort(),
  [
    "memory",
    "terence_abi_version",
    "terence_alloc",
    "terence_format",
    "terence_free",
    "terence_result_error",
    "terence_result_free",
    "terence_result_len",
    "terence_result_ptr",
  ].sort(),
);

const formatter = await createFormatter(wasmModule);

assert.equal(formatter.format("a{color:red}"), "a {\n  color: red;\n}\n");
assert.equal(
  formatter.format('@media screen{a{content:"Привет"}}', {
    indentWidth: 4,
    finalNewline: false,
  }),
  '@media screen {\n    a {\n        content: "Привет";\n    }\n}',
);
assert.equal(formatter.format("a"), "a\n");
assert.equal(formatter.format(""), "\n");

assert.throws(
  () => formatter.format("a", { errorMode: "strict" }),
  (error) => error instanceof TerenceCssError && error.code === "INVALID_CSS",
);
assert.throws(() => formatter.format("a{}", { indentWidth: -1 }), RangeError);

for (let index = 0; index < 100; index += 1) {
  assert.equal(formatter.format("a{}"), "a {}\n");
}

const largeCss = "a{color:red}".repeat(2048);
const largeFormatted = formatter.format(largeCss);
assert.ok(largeFormatted.length > largeCss.length);
assert.ok(largeFormatted.startsWith("a {\n  color: red;\n}"));
assert.ok(largeFormatted.endsWith("a {\n  color: red;\n}\n"));

formatter.dispose();
assert.throws(() => formatter.format("a{}"), /disposed/);

const response = new Response(wasmBytes, {
  headers: { "content-type": "application/wasm" },
});
const browserFormatter = await createBrowserFormatter(response);
assert.equal(
  browserFormatter.format("a{width:1px}"),
  "a {\n  width: 1px;\n}\n",
);
browserFormatter.dispose();
