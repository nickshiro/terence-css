const ABI_VERSION = 1;
const FINAL_NEWLINE_FLAG = 1 << 0;
const STRICT_FLAG = 1 << 1;

const ERROR_CODES = new Map([
  [1, ["OUT_OF_MEMORY", "WebAssembly allocation failed"]],
  [2, ["INVALID_CSS", "CSS contains parser diagnostics"]],
  [3, ["FORMAT_FAILED", "CSS formatting failed"]],
  [4, ["INVALID_ARGUMENT", "Invalid WebAssembly formatter argument"]],
]);

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export class TerenceCssError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "TerenceCssError";
    this.code = code;
  }
}

export async function createFormatterFrom(source) {
  const instance = await instantiate(await source);
  const exports = validateExports(instance.exports);
  return new Formatter(exports);
}

class Formatter {
  #exports;

  constructor(exports) {
    this.#exports = exports;
  }

  format(css, options = {}) {
    if (this.#exports === null) {
      throw new Error("Formatter has been disposed");
    }

    if (typeof css !== "string") {
      throw new TypeError("CSS source must be a string");
    }

    const indentWidth = options.indentWidth ?? 2;
    if (
      !Number.isInteger(indentWidth) ||
      indentWidth < 0 ||
      indentWidth > 0xffffffff
    ) {
      throw new RangeError(
        "indentWidth must be an integer between 0 and 4294967295",
      );
    }

    const finalNewline = options.finalNewline ?? true;
    if (typeof finalNewline !== "boolean") {
      throw new TypeError("finalNewline must be a boolean");
    }

    const errorMode = options.errorMode ?? "recover";
    if (errorMode !== "recover" && errorMode !== "strict") {
      throw new TypeError('errorMode must be "recover" or "strict"');
    }

    const input = encoder.encode(css);
    if (input.length > 0xffffffff) {
      throw new RangeError(
        "Encoded CSS source exceeds the WebAssembly address space",
      );
    }

    const exports = this.#exports;
    let inputPtr = 0;
    let resultHandle = 0;

    try {
      if (input.length !== 0) {
        inputPtr = exports.terence_alloc(input.length);
        if (inputPtr === 0) {
          throw wasmError(1);
        }

        new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(
          input,
        );
      }

      const flags =
        (finalNewline ? FINAL_NEWLINE_FLAG : 0) |
        (errorMode === "strict" ? STRICT_FLAG : 0);
      resultHandle = exports.terence_format(
        inputPtr,
        input.length,
        indentWidth,
        flags,
      );

      if (resultHandle === 0) {
        throw wasmError(1);
      }

      const errorCode = exports.terence_result_error(resultHandle);
      if (errorCode !== 0) {
        throw wasmError(errorCode);
      }

      const resultPtr = exports.terence_result_ptr(resultHandle);
      const resultLen = exports.terence_result_len(resultHandle);
      return decoder.decode(
        new Uint8Array(exports.memory.buffer, resultPtr, resultLen),
      );
    } finally {
      if (resultHandle !== 0) exports.terence_result_free(resultHandle);
      if (inputPtr !== 0) exports.terence_free(inputPtr, input.length);
    }
  }

  dispose() {
    this.#exports = null;
  }
}

async function instantiate(source) {
  if (source instanceof WebAssembly.Module) {
    return WebAssembly.instantiate(source, {});
  }

  if (typeof Response !== "undefined" && source instanceof Response) {
    if (typeof WebAssembly.instantiateStreaming === "function") {
      const fallback = source.clone();
      try {
        const result = await WebAssembly.instantiateStreaming(source, {});
        return result.instance;
      } catch (error) {
        const contentType = fallback.headers.get("content-type") ?? "";
        if (contentType.includes("application/wasm")) {
          throw error;
        }

        source = await fallback.arrayBuffer();
      }
    } else {
      source = await source.arrayBuffer();
    }
  }

  if (ArrayBuffer.isView(source) || source instanceof ArrayBuffer) {
    const result = await WebAssembly.instantiate(source, {});
    return result.instance;
  }

  throw new TypeError(
    "WASM source must be a Response, WebAssembly.Module, ArrayBuffer, or typed array",
  );
}

function validateExports(exports) {
  const functions = [
    "terence_abi_version",
    "terence_alloc",
    "terence_free",
    "terence_format",
    "terence_result_ptr",
    "terence_result_len",
    "terence_result_error",
    "terence_result_free",
  ];

  for (const name of functions) {
    if (typeof exports[name] !== "function") {
      throw new TypeError(`WASM module does not export ${name}`);
    }
  }

  if (!(exports.memory instanceof WebAssembly.Memory)) {
    throw new TypeError("WASM module does not export memory");
  }

  if (exports.terence_abi_version() !== ABI_VERSION) {
    throw new TypeError("Unsupported Terence CSS WASM ABI version");
  }

  return exports;
}

function wasmError(errorCode) {
  const [code, message] = ERROR_CODES.get(errorCode) ?? [
    "UNKNOWN",
    `Unknown WebAssembly error ${errorCode}`,
  ];

  return new TerenceCssError(code, message);
}
