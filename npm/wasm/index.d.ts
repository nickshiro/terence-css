export type ErrorMode = "recover" | "strict";

export interface FormatOptions {
  indentWidth?: number;
  finalNewline?: boolean;
  errorMode?: ErrorMode;
}

export type WasmSource =
  | Response
  | WebAssembly.Module
  | ArrayBuffer
  | ArrayBufferView
  | Promise<Response | WebAssembly.Module | ArrayBuffer | ArrayBufferView>;

export interface Formatter {
  format(css: string, options?: FormatOptions): string;
  dispose(): void;
}

export type TerenceCssErrorCode =
  | "OUT_OF_MEMORY"
  | "INVALID_CSS"
  | "FORMAT_FAILED"
  | "INVALID_ARGUMENT"
  | "UNKNOWN";

export class TerenceCssError extends Error {
  readonly code: TerenceCssErrorCode;
  constructor(code: TerenceCssErrorCode, message: string);
}

export function createFormatter(source?: WasmSource): Promise<Formatter>;
