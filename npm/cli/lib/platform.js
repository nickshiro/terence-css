import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const PACKAGES = new Map([
  ["darwin-arm64", ["@terence-css/cli-darwin-arm64", "terence-css"]],
  ["darwin-x64", ["@terence-css/cli-darwin-x64", "terence-css"]],
  ["linux-arm64", ["@terence-css/cli-linux-arm64", "terence-css"]],
  ["linux-x64", ["@terence-css/cli-linux-x64", "terence-css"]],
  ["win32-x64", ["@terence-css/cli-win32-x64", "terence-css.exe"]],
]);

export function platformPackage(
  platform = process.platform,
  arch = process.arch,
) {
  return PACKAGES.get(`${platform}-${arch}`);
}

export function resolveBinary(
  platform = process.platform,
  arch = process.arch,
) {
  const target = platformPackage(platform, arch);
  if (!target) {
    throw new Error(`unsupported platform: ${platform}-${arch}`);
  }

  const [packageName, executable] = target;
  try {
    return require.resolve(`${packageName}/bin/${executable}`);
  } catch (error) {
    if (error?.code !== "MODULE_NOT_FOUND") throw error;
    throw new Error(
      `native package ${packageName} is missing; reinstall terence-css without --omit=optional`,
    );
  }
}
