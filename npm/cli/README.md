# terence-css

Portable native CSS formatter written in Zig. npm automatically installs the
binary matching the current operating system and CPU architecture.

```sh
npm install --save-dev terence-css
```

```sh
npx terence-css input.css
npx terence-css --write src/main.css src/theme.css
npx terence-css --check src/main.css src/theme.css
```

Without a file, `terence-css` reads CSS from standard input and writes the
formatted result to standard output.
