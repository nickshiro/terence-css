const std = @import("std");
const testing = std.testing;

const tokenizer = @import("tokenizer.zig");
const Tag = tokenizer.Token.Tag;
const ParseError = tokenizer.Token.ParseError;

/// Runs the source through the tokenizer and verifies the complete tag sequence.
fn expectTagsWithOptions(
    source: []const u8,
    options: tokenizer.Tokenizer.Options,
    expected: []const Tag,
) !void {
    var tok = tokenizer.Tokenizer.initWithOptions(source, options);

    for (expected, 0..) |expected_tag, i| {
        const token = tok.next();

        testing.expectEqual(expected_tag, token.tag) catch |err| {
            std.debug.print(
                "token #{d}: expected .{s}, got .{s} (loc {d}..{d} = \"{s}\")\n",
                .{ i, @tagName(expected_tag), @tagName(token.tag), token.loc.start, token.loc.end, source[token.loc.start..token.loc.end] },
            );

            return err;
        };
    }
}

fn expectTags(source: []const u8, expected: []const Tag) !void {
    return expectTagsWithOptions(source, .{}, expected);
}

/// Checks the tag and source span of the first token.
fn expectFirstTokenWithOptions(
    source: []const u8,
    options: tokenizer.Tokenizer.Options,
    expected_tag: Tag,
    expected_text: []const u8,
) !void {
    var tok = tokenizer.Tokenizer.initWithOptions(source, options);
    const token = tok.next();

    try testing.expectEqual(expected_tag, token.tag);
    try testing.expectEqualStrings(expected_text, source[token.loc.start..token.loc.end]);
}

fn expectFirstToken(source: []const u8, expected_tag: Tag, expected_text: []const u8) !void {
    return expectFirstTokenWithOptions(source, .{}, expected_tag, expected_text);
}

fn expectFirstUnicodeRange(source: []const u8, expected_text: []const u8) !void {
    return expectFirstTokenWithOptions(
        source,
        .{ .unicode_ranges_allowed = true },
        .unicode_range,
        expected_text,
    );
}

fn expectFirstParseError(
    source: []const u8,
    expected_tag: Tag,
    expected_error: ParseError,
) !void {
    var tok = tokenizer.Tokenizer.init(source);
    const token = tok.next();

    try testing.expectEqual(expected_tag, token.tag);
    try testing.expectEqual(expected_error, token.parse_error.?);
}

// -- punctuation and based single tokens --

test "punctuation tokens" {
    try expectTags(":;,[](){}", &.{
        .colon,     .semicolon, .comma,
        .l_bracket, .r_bracket, .l_paren,
        .r_paren,   .l_brace,   .r_brace,
        .eof,
    });
}

test "whitespace merged into a single token" {
    try expectTags("  \t\n  ", &.{ .whitespace, .eof });
}

test "input preprocessing normalizes CR, CRLF, and form feed as whitespace" {
    try expectFirstToken("\r\r\n\x0c\n", .whitespace, "\r\r\n\x0c\n");
}

test "input preprocessing replaces NULL with an ident code point" {
    try expectFirstToken("\x00name", .ident, "\x00name");
}

test "invalid UTF-8 is processed as replacement characters" {
    const source = [_]u8{ 0xff, 0xfe, 'a' };
    try expectFirstToken(&source, .ident, &source);
}

test "eof on empty source" {
    try expectTags("", &.{.eof});
}

// -- identifier tokens --

test "identifier starting with single hyphen" {
    try expectFirstToken("-foo", .ident, "-foo");
}

test "custom property identifier (double hyphen)" {
    try expectFirstToken("--custom-prop", .ident, "--custom-prop");
}

test "escaped hex code point inside identifier" {
    try expectFirstToken("\\41 ", .ident, "\\41 ");
}

test "hex escape consumes one preprocessed whitespace code point" {
    try expectFirstToken("\\41\r\nb", .ident, "\\41\r\nb");
}

test "lone backslash before EOF starts an ident and reports an escape error" {
    try expectTags("\\", &.{ .ident, .eof });
    try expectFirstParseError("\\", .ident, .eof_in_escape);
}

test "backslash before newline is not a valid escape" {
    try expectTags("\\\n", &.{ .delim, .whitespace, .eof });
    try expectFirstParseError("\\\n", .delim, .invalid_escape);
}

test "parse error state is reset for every token" {
    var tok = tokenizer.Tokenizer.init("\\\n");
    try testing.expectEqual(ParseError.invalid_escape, tok.next().parse_error.?);
    try testing.expectEqual(null, tok.next().parse_error);
}

test "backslash before a preprocessed newline is not a valid escape" {
    try expectTags("\\\r\n", &.{ .delim, .whitespace, .eof });
    try expectTags("\\\x0c", &.{ .delim, .whitespace, .eof });
}

test "current non-ASCII ident ranges accept and reject boundary code points" {
    try expectFirstToken("·name", .ident, "·name");
    try expectFirstToken("‿name", .ident, "‿name");
    try expectFirstToken("😀name", .ident, "😀name");
    try expectFirstToken("\u{00a0}name", .delim, "\u{00a0}");
    try expectFirstToken("\u{200b}name", .delim, "\u{200b}");
    try expectFirstToken("\u{202e}name", .delim, "\u{202e}");
}

// -- functions and at-keyword --

test "function token" {
    try expectFirstToken("calc(", .function, "calc(");
}

test "at-keyword" {
    try expectFirstToken("@media", .at_keyword, "@media");
}

test "at-keyword with leading hyphen" {
    try expectFirstToken("@-webkit-keyframes", .at_keyword, "@-webkit-keyframes");
}

test "lone @ not followed by ident sequence is a delim" {
    try expectTags("@1", &.{ .delim, .number, .eof });
}

// -- hash --

test "hash with ident-start after # is hash_id" {
    try expectFirstToken("#foo", .hash_id, "#foo");
}

test "hash starting with hyphen+letter is still hash_id" {
    try expectFirstToken("#-foo", .hash_id, "#-foo");
}

test "hash starting with digit is hash_unrestricted" {
    try expectFirstToken("#123", .hash_unrestricted, "#123");
}

test "lone # is a delim" {
    try expectTags("#", &.{ .delim, .eof });
}

// -- strings --

test "simple double-quoted string" {
    try expectFirstToken("\"hello\"", .string, "\"hello\"");
}

test "simple single-quoted string" {
    try expectFirstToken("'hello'", .string, "'hello'");
}

test "unescaped newline breaks the string into bad_string" {
    // source: "abc\ndef  (quote, abc, LF, d)
    var tok = tokenizer.Tokenizer.init("\"abc\ndef");

    const bad = tok.next();
    try testing.expectEqual(Tag.bad_string, bad.tag);

    const ws = tok.next();
    try testing.expectEqual(Tag.whitespace, ws.tag);

    const ident = tok.next();
    try testing.expectEqual(Tag.ident, ident.tag);
}

test "escaped newline inside string is a line continuation" {
    try expectFirstToken("\"a\\\nb\"", .string, "\"a\\\nb\"");
}

test "preprocessed newline inside string produces a bad string" {
    try expectFirstToken("\"a\rb", .bad_string, "\"a");
    try expectFirstToken("\"a\x0cb", .bad_string, "\"a");
}

test "escaped CRLF inside string is a line continuation" {
    try expectFirstToken("\"a\\\r\nb\"", .string, "\"a\\\r\nb\"");
}

test "unterminated string at EOF" {
    try expectFirstToken("\"unterminated", .string, "\"unterminated");
    try expectFirstParseError("\"unterminated", .string, .eof_in_string);
}

test "newline in string reports a parse error" {
    try expectFirstParseError("\"a\nb", .bad_string, .newline_in_string);
}

// -- numbers --

test "integer" {
    try expectFirstToken("42", .number, "42");
}

test "float" {
    try expectFirstToken("42.5", .number, "42.5");
}

test "float with exponent" {
    try expectFirstToken("42.5e10", .number, "42.5e10");
}

test "float with signed exponent" {
    try expectFirstToken("42.5e+10", .number, "42.5e+10");
}

test "percentage" {
    try expectFirstToken("42%", .percentage, "42%");
}

test "dimension" {
    try expectFirstToken("42px", .dimension, "42px");
}

test "leading plus starts a number" {
    try expectFirstToken("+42", .number, "+42");
}

test "lone plus is a delim" {
    try expectTags("+", &.{ .delim, .eof });
}

test "leading dot with digit starts a number" {
    try expectFirstToken(".5", .number, ".5");
}

test "lone dot is a delim" {
    try expectTags(".", &.{ .delim, .eof });
}

test "plus-dot-digit starts a number" {
    try expectFirstToken("+.5", .number, "+.5");
}

test "trailing 'e' without exponent digits becomes unit, not exponent" {
    // "1.5e" - there are no digits after 'e' => 'e' is interpreted as a unit dimension
    try expectFirstToken("1.5e", .dimension, "1.5e");
}

test "valid exponent followed by unit is still one dimension token" {
    try expectFirstToken("1.5e2px", .dimension, "1.5e2px");
}

// -- unicode ranges --

test "unicode range is disabled during normal tokenization" {
    try expectTags("u+1234", &.{ .ident, .number, .eof });
}

test "unicode range accepts lowercase and uppercase prefixes" {
    try expectFirstUnicodeRange("u+1234", "u+1234");
    try expectFirstUnicodeRange("U+ABCD", "U+ABCD");
}

test "unicode range consumes at most six initial hex digits" {
    try expectTagsWithOptions(
        "U+1234567",
        .{ .unicode_ranges_allowed = true },
        &.{ .unicode_range, .number, .eof },
    );
    try expectFirstUnicodeRange("U+1234567", "U+123456");
}

test "unicode range accepts question-mark wildcards" {
    try expectFirstUnicodeRange("u+???", "u+???");
    try expectFirstUnicodeRange("u+12?????", "u+12????");
}

test "unicode range accepts an explicit end" {
    try expectFirstUnicodeRange("u+0025-00FF", "u+0025-00FF");
    try expectFirstUnicodeRange("U+FFFF-0", "U+FFFF-0");
}

test "unicode range consumes at most six end hex digits" {
    try expectTagsWithOptions(
        "u+1-abcdef0",
        .{ .unicode_ranges_allowed = true },
        &.{ .unicode_range, .number, .eof },
    );
    try expectFirstUnicodeRange("u+1-abcdef0", "u+1-abcdef");
}

test "unicode range does not consume an invalid explicit end" {
    try expectTagsWithOptions(
        "u+123-xyz",
        .{ .unicode_ranges_allowed = true },
        &.{ .unicode_range, .ident, .eof },
    );
    try expectFirstUnicodeRange("u+123-xyz", "u+123");
}

test "unicode range wildcard form does not accept an explicit end" {
    try expectTagsWithOptions(
        "u+?-f",
        .{ .unicode_ranges_allowed = true },
        &.{ .unicode_range, .ident, .eof },
    );
    try expectFirstUnicodeRange("u+?-f", "u+?");
}

test "unicode range mode preserves non-range ident tokenization" {
    try expectTagsWithOptions(
        "u+g url(foo)",
        .{ .unicode_ranges_allowed = true },
        &.{ .ident, .delim, .ident, .whitespace, .url, .eof },
    );
}

// -- minus: number / CDC / ident / delim --

test "minus followed by digit starts a number" {
    try expectFirstToken("-5px", .dimension, "-5px");
}

test "CDC token" {
    try expectTags("-->", &.{ .cdc, .eof });
}

test "minus-greater without second hyphen is not CDC" {
    try expectTags("->", &.{ .delim, .delim, .eof });
}

test "minus followed by ident-start is an ident" {
    try expectFirstToken("-webkit-transform", .ident, "-webkit-transform");
}

test "lone minus is a delim" {
    try expectTags("-", &.{ .delim, .eof });
}

// -- CDO --

test "CDO token" {
    try expectTags("<!--", &.{ .cdo, .eof });
}

test "less-than not forming CDO is a delim followed by ident" {
    try expectTags("<div", &.{ .delim, .ident, .eof });
}

// -- comments --

test "comment token" {
    try expectFirstToken("/* hello */", .comment, "/* hello */");
}

test "unterminated comment consumes to EOF" {
    try expectFirstToken("/* hello", .comment, "/* hello");
    try expectFirstParseError("/* hello", .comment, .eof_in_comment);
}

test "lone slash is a delim" {
    try expectTags("/", &.{ .delim, .eof });
}

// -- url() --

test "unquoted url token" {
    try expectFirstToken("url(foo.png)", .url, "url(foo.png)");
}

test "unquoted url token with surrounding whitespace" {
    try expectFirstToken("url( foo.png )", .url, "url( foo.png )");
}

test "quoted url is tokenized as function + string, not url-token" {
    try expectTags("url('foo.png')", &.{
        .function, .string, .r_paren, .eof,
    });
}

test "quoted url with whitespace around the string" {
    try expectTags("url( 'foo.png' )", &.{
        .function, .whitespace, .string, .whitespace, .r_paren, .eof,
    });
}

test "escaped url name produces a url token" {
    try expectFirstToken("u\\72l(foo)", .url, "u\\72l(foo)");
    try expectFirstToken("\\75 rl(foo)", .url, "\\75 rl(foo)");
}

test "escaped url name with a quoted value produces a function token" {
    try expectTags("u\\72l(\"foo\")", &.{ .function, .string, .r_paren, .eof });
}

test "url accepts preprocessed whitespace" {
    try expectFirstToken("url(\r\nfoo\x0c)", .url, "url(\r\nfoo\x0c)");
}

test "unterminated url reports a parse error" {
    try expectFirstParseError("url(foo", .url, .eof_in_url);
}

test "unquoted url with embedded whitespace before non-paren is bad_url" {
    try expectFirstToken("url(foo bar)", .bad_url, "url(foo bar)");
}

test "unquoted url with embedded quote is bad_url" {
    try expectFirstToken("url(foo\"bar)", .bad_url, "url(foo\"bar)");
    try expectFirstParseError("url(foo\"bar)", .bad_url, .invalid_url);
}

// -- integration tests --

test "realistic css snippet tag sequence" {
    const source = ".foo:hover{color:#ff0000;/* red */width:calc(100% - 10px);}";
    try expectTags(source, &.{
        .delim,   .ident,      .colon,     .ident,      .l_brace,
        .ident,   .colon,      .hash_id,   .semicolon,  .comment,
        .ident,   .colon,      .function,  .percentage, .whitespace,
        .delim,   .whitespace, .dimension, .r_paren,    .semicolon,
        .r_brace, .eof,
    });
}
