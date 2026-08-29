# @terence-css/wasm

WebAssembly build of the Terence CSS parser and formatter for browsers, web
workers, online IDEs, and Node.js.

```js
import { createFormatter } from "@terence-css/wasm";

const formatter = await createFormatter();
const css = formatter.format("a{color:red}");
formatter.dispose();
```

`format` accepts `indentWidth`, `finalNewline`, and `errorMode` (`recover` or
`strict`). Pass a `Response`, `WebAssembly.Module`, `ArrayBuffer`, or typed array
to `createFormatter` to control how the WASM binary is loaded.
