import { spawn } from "node:child_process";
import { chmod, copyFile, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryDirectory = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../..",
);

const TARGETS = [
  {
    node: "linux-x64",
    package: "@terence-css/cli-linux-x64",
    zig: "x86_64-linux",
  },
  {
    node: "linux-arm64",
    package: "@terence-css/cli-linux-arm64",
    zig: "aarch64-linux",
  },
  {
    node: "darwin-x64",
    package: "@terence-css/cli-darwin-x64",
    zig: "x86_64-macos",
  },
  {
    node: "darwin-arm64",
    package: "@terence-css/cli-darwin-arm64",
    zig: "aarch64-macos",
  },
  {
    node: "win32-x64",
    package: "@terence-css/cli-win32-x64",
    zig: "x86_64-windows",
  },
];

const targetArgumentIndex = process.argv.indexOf("--target");
const requestedTarget =
  targetArgumentIndex === -1
    ? undefined
    : process.argv[targetArgumentIndex + 1];
const selectedTargets = requestedTarget
  ? TARGETS.filter(({ node }) => node === requestedTarget)
  : process.argv.includes("--host")
    ? TARGETS.filter(
        ({ node }) => node === `${process.platform}-${process.arch}`,
      )
    : TARGETS;

if (selectedTargets.length === 0) {
  throw new Error(
    requestedTarget
      ? `unsupported target: ${requestedTarget}`
      : `unsupported build host: ${process.platform}-${process.arch}`,
  );
}

const cliPackage = await readPackage(resolve(repositoryDirectory, "npm/cli"));

for (const target of selectedTargets) {
  const packageDirectory = resolve(
    repositoryDirectory,
    "npm/native",
    target.node,
  );
  const nativePackage = await readPackage(packageDirectory);
  const [os, cpu] = target.node.split("-");
  if (
    nativePackage.name !== target.package ||
    nativePackage.os?.[0] !== os ||
    nativePackage.cpu?.[0] !== cpu
  ) {
    throw new Error(
      `${target.node} package metadata does not match its target`,
    );
  }
  if (nativePackage.version !== cliPackage.version) {
    throw new Error(`${nativePackage.name} version must match terence-css`);
  }
  if (
    cliPackage.optionalDependencies[nativePackage.name] !==
    nativePackage.version
  ) {
    throw new Error(
      `${nativePackage.name} must use version ${cliPackage.version} in optionalDependencies`,
    );
  }

  await rm(resolve(packageDirectory, "bin"), { recursive: true, force: true });
  await run("zig", [
    "build",
    `-Dtarget=${target.zig}`,
    "-Doptimize=ReleaseSmall",
    "-Dstrip=true",
    "-p",
    packageDirectory,
  ]);

  if (!target.node.startsWith("win32-")) {
    await chmod(resolve(packageDirectory, "bin/terence-css"), 0o755);
  }

  await copyFile(
    resolve(repositoryDirectory, "LICENSE"),
    resolve(packageDirectory, "LICENSE"),
  );
  await writeFile(
    resolve(packageDirectory, "README.md"),
    `# @terence-css/cli-${target.node}\n\nNative ${target.node} binary used by the \`terence-css\` npm package.\n`,
  );
}

async function readPackage(directory) {
  return JSON.parse(await readFile(resolve(directory, "package.json"), "utf8"));
}

function run(command, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: repositoryDirectory,
      stdio: "inherit",
    });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (code === 0) {
        resolvePromise();
      } else {
        reject(
          new Error(
            signal
              ? `${command} was terminated by ${signal}`
              : `${command} exited with code ${code}`,
          ),
        );
      }
    });
  });
}
