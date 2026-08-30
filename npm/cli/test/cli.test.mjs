import assert from "node:assert/strict";
import {
  chmod,
  mkdir,
  mkdtemp,
  open,
  readFile,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import test, { after } from "node:test";

import { platformPackage } from "../lib/platform.js";

const packageDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const host = `${process.platform}-${process.arch}`;
const hostPackage = platformPackage();
if (!hostPackage) throw new Error(`unsupported test host: ${host}`);

const binary = resolve(
  packageDirectory,
  "../native",
  host,
  "bin",
  hostPackage[1],
);
const launcher = resolve(packageDirectory, "bin/terence-css.js");
const formattedCss = "a {\n  color: red;\n}\n";
const temporaryDirectories = [];

after(async () => {
  await Promise.all(
    temporaryDirectories.map((directory) =>
      rm(directory, { recursive: true, force: true }),
    ),
  );
});

test("maps every supported Node platform to its native package", () => {
  assert.deepEqual(platformPackage("linux", "x64"), [
    "@terence-css/cli-linux-x64",
    "terence-css",
  ]);
  assert.deepEqual(platformPackage("linux", "arm64"), [
    "@terence-css/cli-linux-arm64",
    "terence-css",
  ]);
  assert.deepEqual(platformPackage("darwin", "x64"), [
    "@terence-css/cli-darwin-x64",
    "terence-css",
  ]);
  assert.deepEqual(platformPackage("darwin", "arm64"), [
    "@terence-css/cli-darwin-arm64",
    "terence-css",
  ]);
  assert.deepEqual(platformPackage("win32", "x64"), [
    "@terence-css/cli-win32-x64",
    "terence-css.exe",
  ]);
  assert.equal(platformPackage("freebsd", "x64"), undefined);
});

test("launcher forwards arguments and exit status", async () => {
  const directory = await temporaryDirectory();
  await writeFile(join(directory, "input.css"), "a{color:red}");

  const result = await execute(
    process.execPath,
    [launcher, "--check", "input.css"],
    {
      cwd: directory,
      env: { TERENCE_CSS_BINARY: binary },
    },
  );
  assert.equal(result.code, 1);
  assert.equal(result.stdout, "input.css\n");
  assert.equal(result.stderr, "");
});

test("formats standard input", async () => {
  const result = await run([], { input: "a{color:red}" });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, formattedCss);
  assert.equal(result.stderr, "");
});

test("accepts - as standard input", async () => {
  const result = await run(["-"], { input: "a{color:red}" });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, formattedCss);
  assert.equal(result.stderr, "");
});

test("formats a file to stdout without changing it", async () => {
  const directory = await temporaryDirectory();
  await writeFile(join(directory, "input.css"), "a{color:red}");

  const result = await run(["input.css"], { cwd: directory });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, formattedCss);
  assert.equal(
    await readFile(join(directory, "input.css"), "utf8"),
    "a{color:red}",
  );
});

test("writes multiple files and preserves permissions", async () => {
  const directory = await temporaryDirectory();
  await writeFile(join(directory, "a.css"), "a{color:red}");
  await writeFile(join(directory, "b.css"), "b{color:blue}");
  await chmod(join(directory, "a.css"), 0o640);

  const result = await run(["--write", "a.css", "b.css"], { cwd: directory });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "");
  assert.equal(await readFile(join(directory, "a.css"), "utf8"), formattedCss);
  assert.equal(
    await readFile(join(directory, "b.css"), "utf8"),
    "b {\n  color: blue;\n}\n",
  );
  assert.equal((await stat(join(directory, "a.css"))).mode & 0o777, 0o640);
});

test("recursively writes CSS files in a directory", async () => {
  const directory = await temporaryDirectory();
  await mkdir(join(directory, "nested"));
  await writeFile(join(directory, "root.css"), "a{color:red}");
  await writeFile(join(directory, "nested", "child.css"), "b{color:blue}");
  await writeFile(join(directory, "nested", "ignored.txt"), "not css");

  const result = await run(["--write", directory]);
  assert.equal(result.code, 0);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "");
  assert.equal(
    await readFile(join(directory, "root.css"), "utf8"),
    formattedCss,
  );
  assert.equal(
    await readFile(join(directory, "nested", "child.css"), "utf8"),
    "b {\n  color: blue;\n}\n",
  );
  assert.equal(
    await readFile(join(directory, "nested", "ignored.txt"), "utf8"),
    "not css",
  );
});

test("recursively checks CSS files in a directory", async () => {
  const directory = await temporaryDirectory();
  await mkdir(join(directory, "nested"));
  await writeFile(join(directory, "clean.css"), formattedCss);
  await writeFile(join(directory, "nested", "dirty.css"), "b{color:blue}");

  const result = await run(["--check", directory]);
  assert.equal(result.code, 1);
  assert.equal(result.stdout, `${directory}/nested/dirty.css\n`);
  assert.equal(result.stderr, "");
});

test("checks files and reports only unformatted paths", async () => {
  const directory = await temporaryDirectory();
  await writeFile(join(directory, "clean.css"), formattedCss);
  await writeFile(join(directory, "dirty.css"), "a{color:red}");

  const dirty = await run(["--check", "clean.css", "dirty.css"], {
    cwd: directory,
  });
  assert.equal(dirty.code, 1);
  assert.equal(dirty.stdout, "dirty.css\n");
  assert.equal(dirty.stderr, "");

  const clean = await run(["--check", "clean.css"], { cwd: directory });
  assert.equal(clean.code, 0);
  assert.equal(clean.stdout, "");
});

test("does not rewrite malformed CSS", async () => {
  const directory = await temporaryDirectory();
  const path = join(directory, "invalid.css");
  await writeFile(path, "a");

  const result = await run(["--write", "invalid.css"], { cwd: directory });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /^terence-css: invalid\.css: /);
  assert.equal(await readFile(path, "utf8"), "a");
});

test("rejects symbolic links in write mode", async (context) => {
  if (process.platform === "win32") {
    return context.skip("symlink setup varies on Windows");
  }

  const directory = await temporaryDirectory();
  await writeFile(join(directory, "target.css"), "a{color:red}");
  await symlink("target.css", join(directory, "link.css"));

  const result = await run(["--write", "link.css"], { cwd: directory });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /SymbolicLink/);
  assert.equal(
    await readFile(join(directory, "target.css"), "utf8"),
    "a{color:red}",
  );
});

test("accepts paths beginning with a dash after --", async () => {
  const directory = await temporaryDirectory();
  await writeFile(join(directory, "-input.css"), "a{color:red}");

  const result = await run(["--", "-input.css"], { cwd: directory });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, formattedCss);
});

for (const args of [
  ["--write"],
  ["--check"],
  ["--write", "--check", "a.css"],
  ["--unknown"],
  ["a.css", "b.css"],
  ["--write", "-"],
]) {
  test(`reports invalid arguments: ${args.join(" ")}`, async () => {
    const result = await run(args);
    assert.equal(result.code, 2);
    assert.equal(
      result.stderr,
      "usage: terence-css [-w|--write | -c|--check] [FILE...]\n",
    );
  });
}

async function run(args, options = {}) {
  return execute(binary, args, options);
}

async function execute(command, args, options = {}) {
  const ioDirectory = await temporaryDirectory();
  const stdinPath = join(ioDirectory, "stdin");
  const stdoutPath = join(ioDirectory, "stdout");
  const stderrPath = join(ioDirectory, "stderr");
  await writeFile(stdinPath, options.input ?? "");

  const stdin = await open(stdinPath, "r");
  const stdout = await open(stdoutPath, "w+");
  const stderr = await open(stderrPath, "w+");

  let code;
  try {
    code = await new Promise((resolvePromise, reject) => {
      const child = spawn(command, args, {
        cwd: options.cwd,
        env: { ...process.env, ...options.env },
        stdio: [stdin.fd, stdout.fd, stderr.fd],
      });
      child.on("error", reject);
      child.on("exit", (exitCode, signal) => {
        if (signal) return reject(new Error(`process terminated by ${signal}`));
        resolvePromise(exitCode);
      });
    });
  } finally {
    await Promise.all([stdin.close(), stdout.close(), stderr.close()]);
  }

  return {
    code,
    stdout: await readFile(stdoutPath, "utf8"),
    stderr: await readFile(stderrPath, "utf8"),
  };
}

async function temporaryDirectory() {
  const directory = await mkdtemp(join(tmpdir(), "terence-css-cli-"));
  temporaryDirectories.push(directory);
  return directory;
}
