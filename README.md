# Terence CSS

Lightweight, dependency-free CSS formatter written in Zig.

## Roadmap

1. Complete the AST renderer and define stable formatting rules.
2. Create command-line interface for files and standard input.
3. Add formatting options.
4. Ensure idempotent output and reliable recovery for malformed CSS.
5. Publish native binaries and an npm package for easy installation.
6. Provide WASM build and lib for browser-based editors and playgrounds.
7. Add other CSS-family languages?

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
| Printer/Formatter | — | in progress |
| Token serialization | §9 | implemented |
| Printer entry point | — | not started |
| AST renderer | — | not started |
| Separator selection | — | not started |
| Synthetic token rendering | — | not started |
| Comment placement | — | not started |
| Malformed CSS recovery rendering | — | not started |
| Auto-indenting writer | — | implemented |
| Printer idempotence verification | — | not started |
