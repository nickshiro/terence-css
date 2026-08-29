# Formatting

Terence CSS produces a deterministic representation of a CSS Syntax AST while
preserving the source program. Formatting is intentionally grammar-agnostic:
property values, selectors, and unknown future syntax are treated as component
values rather than interpreted semantically.

## Invariants

- Formatting the output again produces the same bytes.
- Significant source tokens retain their text and relative order.
- The formatter may add only optional declaration and at-rule semicolons plus
  empty comments required to separate unsafe token pairs under CSS Syntax §9.
- Comments retain their order and their position between significant tokens.
- Invalid recovery ranges are copied byte-for-byte.
- Missing `}`, `]`, and `)` delimiters are never synthesized.
- Generated line breaks are LF. Line breaks inside preserved raw ranges remain
  byte-for-byte unchanged.

## Layout

| Construct | Rule |
| --- | --- |
| Top-level rules | Separate with one empty line. |
| Non-empty rule block | Put braces on structural lines and indent contents. |
| Empty or whitespace-only block | Render as `{}`. |
| Declarations | Render one per line and terminate with `;`. |
| Declaration colon | No space before and one space after when a value follows. |
| Nested rules and at-rules | Separate from adjacent block entries with one empty line. |
| Commas | No space before and one space after when another value follows. |
| Generic component values | Preserve source whitespace unless a structural rule applies. |
| Final newline | Added by the high-level formatter according to `FormatOptions`; not by `render`. |

## Comments

- Comments between top-level or block-level constructs are placed on their own
  structural line.
- Comments within a selector, prelude, declaration, function, or simple block
  remain inline and never cross a significant token.
- Leading and trailing structural comments are not joined to a rule or closing
  brace.
- Consecutive comments preserve their source order.
- Comments required to keep adjacent tokens separate are retained. When no
  source trivia separates an unsafe token pair, the serializer inserts `/**/`
  according to CSS Syntax §9.

## Recovery and synthetic syntax

Declarations and at-rules receive their optional canonical `;`, including when
they end at EOF. Synthetic semicolons are emitted after any trailing comment
that belongs to the construct.

The formatter does not repair malformed structure. Invalid nodes are emitted
verbatim, and delimiters implicitly closed by EOF remain absent. Strict callers
can reject any AST containing parser diagnostics; recovery callers receive a
stable, lossless rendering of malformed ranges.
