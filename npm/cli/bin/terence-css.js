#!/usr/bin/env node

import { spawn } from "node:child_process";

import { resolveBinary } from "../lib/platform.js";

try {
  const binary = process.env.TERENCE_CSS_BINARY ?? resolveBinary();
  const child = spawn(binary, process.argv.slice(2), {
    stdio: "inherit",
    windowsHide: true,
  });
  process.exitCode = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (signal) {
        process.kill(process.pid, signal);
      } else {
        resolve(code ?? 1);
      }
    });
  });
} catch (error) {
  process.stderr.write(`terence-css: ${errorMessage(error)}\n`);
  process.exitCode = 1;
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
