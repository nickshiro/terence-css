# Terence CSS

Terence CSS is a portable, dependency-free CSS parsing and formatting engine
that includes an embeddable Zig library, a native CLI formatter, and a WASM library.

## Usage

```sh
terence-css [FILE|-]         # format to stdout
terence-css --write FILE...  # format in place
terence-css --check FILE...  # check formatting
```

The default mode accepts CSS from a file or standard input and writes formatted
CSS to standard output. `--write` and `--check` reject files with parser
diagnostics instead of rewriting malformed input.

## Zig library

The package exports the `terence_css` module. Once the dependency is declared
in `build.zig.zon`, add it to your executable or library:

```zig
const dependency = b.dependency("terence_css", .{
    .target = target,
    .optimize = optimize,
});
root_module.addImport("terence_css", dependency.module("terence_css"));
```

Parse CSS when you need its syntax tree and diagnostics:

```zig
const terence_css = @import("terence_css");

var tree = try terence_css.parseStylesheet(allocator, source);
defer tree.deinit(allocator);

for (tree.errors) |diagnostic| {
    // Inspect diagnostic.tag and diagnostic.token.
}
```

The AST owns its allocated data but borrows `source`; keep the source alive
until `tree.deinit` returns. For direct formatting, use the convenience API:

```zig
const formatted = try terence_css.formatStylesheetAlloc(
    allocator,
    source,
    .{
        .indent_width = 2,
        .final_newline = true,
        .error_mode = .recover,
    },
);
defer allocator.free(formatted);
```

Use `.strict` to reject any stylesheet that produced parser diagnostics. The
lower-level `render` function accepts an existing AST and does not force a final
newline.

## Architecture

```text
Tokenizer -> Parser -> AST -> Printer
                 |             |
                 +-- Zig API ---+
                       |
                       +-- native CLI
                       +-- WebAssembly/JavaScript (planned)
```

The canonical layout, comment, recovery, and token-preservation rules are
defined in [FORMATTING.md](FORMATTING.md).

## Roadmap

1. Publish native binaries and an npm CLI package for easy installation.
2. Provide a WASM npm package for browser-based editors and playgrounds.
3. Add other CSS-family languages?

## The project follows three principles:

- Use the [CSS Syntax Module](https://drafts.csswg.org/css-syntax/) as the source of truth.
- Use the [Zig compiler frontend](https://github.com/ziglang/zig/tree/master/lib/std/zig) as an architectural and code-quality reference.
- Follow the Unix philosophy: do one thing and do it well.

## Status

| Component | Specification | Status |
| --- | --- | --- |
| Input preprocessing | §3.3 | implemented |
| Tokenizer | §4 | implemented |
| Tokenizer definitions | §4.2 | implemented |
| Consume a token | §4.3.1 | implemented |
| Consume comments | §4.3.2 | implemented |
| Consume a numeric token | §4.3.3 | implemented |
| Consume an ident-like token | §4.3.4 | implemented |
| Consume a string token | §4.3.5 | implemented |
| Consume a URL token | §4.3.6 | implemented |
| Consume an escaped code point | §4.3.7 | implemented |
| Check if two code points are a valid escape | §4.3.8 | implemented |
| Check if three code points would start an ident sequence | §4.3.9 | implemented |
| Check if three code points would start a number | §4.3.10 | implemented |
| Check if three code points would start a unicode-range | §4.3.11 | implemented |
| Consume an ident sequence | §4.3.12 | implemented |
| Consume a number | §4.3.13 | implemented |
| Consume a unicode-range token | §4.3.14 | implemented |
| Consume the remnants of a bad URL | §4.3.15 | implemented |
| CSS grammar parser | §5 | implemented |
| Parse according to a CSS grammar | §5.4.1 | implemented |
| Parse comma-separated according to a grammar | §5.4.2 | implemented |
| Parse a stylesheet | §5.4.3 | implemented |
| Parse a stylesheet's contents | §5.4.4 | implemented |
| Parse a block's contents | §5.4.5 | implemented |
| Parse a rule | §5.4.6 | implemented |
| Parse a declaration | §5.4.7 | implemented |
| Parse a component value | §5.4.8 | implemented |
| Parse a list of component values | §5.4.9 | implemented |
| Parse comma-separated component values | §5.4.10 | implemented |
| Consume a unicode-range value | §5.5.11 | implemented |
| Printer/Formatter | — | implemented |
| Token serialization | §9 | implemented |
| Printer entry point | — | implemented |
| AST renderer | — | implemented |
| Declaration rendering | §5.4.5, §5.4.7 | implemented |
| Rule and block rendering | §5.5.2–§5.5.5 | implemented |
| Separator selection | — | implemented |
| Synthetic token rendering | — | implemented |
| Comment placement | — | implemented |
| Malformed CSS recovery rendering | — | implemented |
| Auto-indenting writer | — | implemented |
| Printer idempotence verification | — | implemented |
| Golden formatting specification | — | implemented |
| Public Zig library API | — | implemented |
| Native npm CLI package | — | not started |
| WebAssembly npm package | — | not started |
