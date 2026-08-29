# npm packages

`terence-css` is a small launcher that installs one matching native package
through `optionalDependencies`. `@terence-css/wasm` remains the embeddable
browser and Node.js library.

Build all native packages from the repository root:

```sh
node npm/scripts/build-native.mjs
```

The command produces stripped binaries for Linux x64/arm64, macOS x64/arm64,
and Windows x64 inside `npm/native/*/bin`. Keep all six package versions equal,
publish the five `@terence-css/cli-*` packages first, and publish `terence-css`
last.
