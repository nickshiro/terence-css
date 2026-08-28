const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const printer = @import("printer.zig");

const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

const Ast = ast.Ast;
const AutoIndentingWriter = printer.AutoIndentingWriter;
const Separator = printer.Separator;
const TokenSerializer = printer.TokenSerializer;
const TokenIndex = ast.TokenIndex;
const TokenTag = ast.TokenTag;
const TokenView = printer.TokenView;

const Sample = struct {
    tag: TokenTag,
    text: []const u8,
};

test "auto-indenting writer: applies nested indentation lazily" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});

    try indented.writer.writeAll("rule {\n");
    try indented.pushIndent();
    try indented.writer.writeAll("color: red;\n");
    try indented.pushIndent();
    try indented.writer.writeAll("nested\n");
    try indented.popIndent();
    try indented.writer.writeAll("display: block;\n");
    try indented.popIndent();
    try indented.writer.writeByte('}');

    try testing.expectEqualStrings(
        "rule {\n  color: red;\n    nested\n  display: block;\n}",
        output.written(),
    );
}

test "auto-indenting writer: does not indent empty lines" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});

    try indented.pushIndent();
    try indented.writer.writeAll("first\n\n\nsecond\n");

    try testing.expectEqualStrings("  first\n\n\n  second\n", output.written());
}

test "auto-indenting writer: preserves every source line ending" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});

    try indented.pushIndent();
    try indented.writer.writeAll("a\r\nb\rc\x0cd");

    try testing.expectEqualStrings("  a\r\n  b\r  c\x0c  d", output.written());
}

test "auto-indenting writer: supports zero and custom indent widths" {
    const cases = [_]struct {
        width: usize,
        expected: []const u8,
    }{
        .{ .width = 0, .expected = "a\nb" },
        .{ .width = 4, .expected = "        a\n        b" },
    };

    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var indented: AutoIndentingWriter = .init(
            &output.writer,
            .{ .indent_width = case.width },
        );

        try indented.pushIndent();
        try indented.pushIndent();
        try indented.writer.writeAll("a\nb");
        try testing.expectEqualStrings(case.expected, output.written());
    }
}

test "auto-indenting writer: supports vector splat and flush writer operations" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});
    try indented.pushIndent();

    var fragments = [_][]const u8{ "a", "\n", "b\n" };
    try indented.writer.writeVecAll(&fragments);
    try indented.writer.splatBytesAll("c\n", 2);
    try indented.writer.flush();

    try testing.expectEqualStrings("  a\n  b\n  c\n  c\n", output.written());
}

test "auto-indenting writer: depth changes affect only future line content" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});

    try indented.writer.writeAll("a");
    try indented.pushIndent();
    try indented.writer.writeAll("b\n");
    try indented.writer.writeAll("c\n");
    try indented.popIndent();
    try indented.writer.writeAll("d");

    try testing.expectEqualStrings("ab\n  c\nd", output.written());
}

test "auto-indenting writer: rejects indentation underflow" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});

    try testing.expectError(error.IndentUnderflow, indented.popIndent());
    try indented.pushIndent();
    try indented.popIndent();
    try testing.expectError(error.IndentUnderflow, indented.popIndent());
}

test "auto-indenting writer: rejects indentation overflow" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(
        &output.writer,
        .{ .indent_width = std.math.maxInt(usize) },
    );

    try indented.pushIndent();
    try testing.expectError(error.IndentOverflow, indented.pushIndent());
}

test "auto-indenting writer: propagates downstream write failures" {
    var downstream: std.Io.Writer = .failing;
    var indented: AutoIndentingWriter = .init(&downstream, .{});

    try indented.pushIndent();
    try testing.expectError(error.WriteFailed, indented.writer.writeAll("x"));
}

test "auto-indenting writer: composes with token serializer" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a b");
    defer tree.deinit(testing.allocator);
    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var indented: AutoIndentingWriter = .init(&output.writer, .{});
    try indented.pushIndent();
    var serializer: TokenSerializer = .init(tree, &indented.writer);

    try serializer.emitToken(tokens[0], .newline);
    try serializer.emitToken(tokens[1], .none);
    try serializer.finish();

    try testing.expectEqualStrings("  a\n  b", output.written());
}

test "token serializer: CSS Syntax unsafe-pair table (§9)" {
    const left = [_]Sample{
        .{ .tag = .ident, .text = "a" },
        .{ .tag = .at_keyword, .text = "@a" },
        .{ .tag = .hash_id, .text = "#a" },
        .{ .tag = .dimension, .text = "1px" },
        .{ .tag = .delim, .text = "#" },
        .{ .tag = .delim, .text = "-" },
        .{ .tag = .number, .text = "1" },
        .{ .tag = .delim, .text = "@" },
        .{ .tag = .delim, .text = "." },
        .{ .tag = .delim, .text = "+" },
        .{ .tag = .delim, .text = "/" },
    };

    const right = [_]Sample{
        .{ .tag = .ident, .text = "a" },
        .{ .tag = .function, .text = "f(" },
        .{ .tag = .url, .text = "url(x)" },
        .{ .tag = .bad_url, .text = "url(\"x)" },
        .{ .tag = .delim, .text = "-" },
        .{ .tag = .number, .text = "1" },
        .{ .tag = .percentage, .text = "1%" },
        .{ .tag = .dimension, .text = "1px" },
        .{ .tag = .cdc, .text = "-->" },
        .{ .tag = .l_paren, .text = "(" },
        .{ .tag = .delim, .text = "*" },
        .{ .tag = .delim, .text = "%" },
        .{ .tag = .colon, .text = ":" },
    };

    const expected = [_][right.len]bool{
        .{ true, true, true, true, true, true, true, true, true, true, false, false, false },
        .{ true, true, true, true, true, true, true, true, true, false, false, false, false },
        .{ true, true, true, true, true, true, true, true, true, false, false, false, false },
        .{ true, true, true, true, true, true, true, true, true, false, false, false, false },
        .{ true, true, true, true, true, true, true, true, true, false, false, false, false },
        .{ true, true, true, true, true, true, true, true, true, false, false, false, false },
        .{ true, true, true, true, false, true, true, true, true, false, false, true, false },
        .{ true, true, true, true, true, false, false, false, true, false, false, false, false },
        .{ false, false, false, false, false, true, true, true, false, false, false, false, false },
        .{ false, false, false, false, false, true, true, true, false, false, false, false, false },
        .{ false, false, false, false, false, false, false, false, false, false, true, false, false },
    };

    for (left, expected) |left_sample, row| {
        for (right, row) |right_sample, unsafe| {
            try testing.expectEqual(unsafe, printer.needsComment(
                .{ .tag = left_sample.tag, .text = left_sample.text },
                .{ .tag = right_sample.tag, .text = right_sample.text },
            ));
        }
    }
}

test "token serializer: exact delimiter values select special rows and columns" {
    try testing.expect(printer.needsComment(
        .{ .tag = .delim, .text = "#" },
        .{ .tag = .ident, .text = "x" },
    ));

    try testing.expect(!printer.needsComment(
        .{ .tag = .delim, .text = "&" },
        .{ .tag = .ident, .text = "x" },
    ));

    try testing.expect(printer.needsComment(
        .{ .tag = .delim, .text = "/" },
        .{ .tag = .delim, .text = "*" },
    ));

    try testing.expect(!printer.needsComment(
        .{ .tag = .delim, .text = "/" },
        .{ .tag = .delim, .text = "%" },
    ));
    try testing.expect(printer.needsComment(
        .{ .tag = .hash_unrestricted, .text = "#1" },
        .{ .tag = .ident, .text = "x" },
    ));
}

test "token serializer: unicode ranges use conservative boundary protection" {
    try testing.expect(printer.needsComment(
        .{ .tag = .unicode_range, .text = "U+00A0" },
        .{ .tag = .delim, .text = "?" },
    ));

    try testing.expect(printer.needsComment(
        .{ .tag = .ident, .text = "x" },
        .{ .tag = .unicode_range, .text = "U+00A0" },
    ));
}

test "token serializer: synthetic tokens share boundary protection" {
    var tree = try Ast.parseComponentValues(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);

    try serializer.emitSynthetic(.{ .tag = .ident, .text = "alpha" }, .none);
    try serializer.emitSynthetic(.{ .tag = .ident, .text = "beta" }, .none);
    try serializer.emitSynthetic(.{ .tag = .colon, .text = ":" }, .none);
    try serializer.emitSynthetic(.{ .tag = .ident, .text = "gamma" }, .none);
    try serializer.finish();

    try testing.expectEqualStrings("alpha/**/beta:gamma", output.written());
}

test "token serializer: synthetic boundary state does not borrow token text" {
    var tree = try Ast.parseComponentValues(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);

    var delimiter = [_]u8{'/'};
    try serializer.emitSynthetic(.{ .tag = .delim, .text = &delimiter }, .none);
    delimiter[0] = ':';
    try serializer.emitSynthetic(.{ .tag = .delim, .text = "*" }, .none);
    try serializer.finish();

    try testing.expectEqualStrings("//**/*", output.written());
}

test "token serializer: separator modes normalize trivia and retain comments" {
    const source = "a \t/*one*/ \n/*two*/ b";
    const cases = [_]struct {
        separator: Separator,
        expected: []const u8,
    }{
        .{ .separator = .none, .expected = "a/*one*//*two*/b" },
        .{ .separator = .space, .expected = "a /*one*/ /*two*/ b" },
        .{ .separator = .newline, .expected = "a\n/*one*/\n/*two*/\nb" },
        .{ .separator = .blank_line, .expected = "a\n\n/*one*/\n\n/*two*/\n\nb" },
        .{ .separator = .preserve, .expected = source },
    };

    for (cases) |case| {
        var tree = try Ast.parseComponentValues(testing.allocator, source);
        defer tree.deinit(testing.allocator);

        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var serializer: TokenSerializer = .init(tree, &output.writer);
        const tokens = try significantTokens(tree, testing.allocator);
        defer testing.allocator.free(tokens);

        try serializer.emitToken(tokens[0], case.separator);
        try serializer.emitToken(tokens[1], .none);
        try serializer.finish();
        try testing.expectEqualStrings(case.expected, output.written());
    }
}

test "token serializer: leading trailing and comment-only trivia are retained" {
    try expectSerialization(
        " \n/*head*/ a /*tail*/ \t",
        .none,
        "/*head*/a/*tail*/",
    );

    try expectSerialization(
        " \n/*one*/ \t/*two*/ ",
        .none,
        "/*one*//*two*/",
    );
}

test "token serializer: unsafe source pairs reuse comments or insert an empty one" {
    try expectSerialization("alpha beta", .none, "alpha/**/beta");
    try expectSerialization("alpha /* kept */ beta", .none, "alpha/* kept */beta");
    try expectSerialization(": alpha", .none, ":alpha");
}

test "token serializer: normalized significant tokens round trip" {
    const source = "a b @x c #id d 1px e # f - g 1 2 @ h . 3 + 4 / *";
    const serialized = try serialize(testing.allocator, source, .none);
    defer testing.allocator.free(serialized);

    try expectSameSignificantTags(source, serialized);
}

test "token serializer: raw ranges preserve recovered text exactly" {
    const source = "a /*lead*/ ??? ; b";
    var tree = try Ast.parseComponentValues(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);

    try serializer.emitToken(tokens[0], .space);
    try serializer.emitRaw(.{
        .start = tokens[1],
        .end = tokens[tokens.len - 2] + 1,
    }, .newline);
    try serializer.emitToken(tokens[tokens.len - 1], .none);
    try serializer.finish();

    try testing.expectEqualStrings("a /*lead*/ ??? ;\nb", output.written());
}

test "token serializer: raw ranges receive boundary protection" {
    const source = "a b";
    var tree = try Ast.parseComponentValues(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);

    try serializer.emitToken(tokens[0], .none);
    try serializer.emitRaw(.{ .start = tokens[1], .end = tokens[1] + 1 }, .none);
    try serializer.finish();

    try testing.expectEqualStrings("a/**/b", output.written());
}

test "token serializer: backslash delimiters retain the required newline" {
    try expectSerialization("\\\nalpha", .none, "\\\nalpha");
    try expectSerialization("\\\n", .none, "\\\n");

    var tree = try Ast.parseComponentValues(testing.allocator, "");
    defer tree.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);
    try serializer.emitSynthetic(.{ .tag = .delim, .text = "\\" }, .none);
    try serializer.emitSynthetic(.{ .tag = .ident, .text = "alpha" }, .none);
    try serializer.finish();
    try testing.expectEqualStrings("\\\nalpha", output.written());
}

test "token serializer: bad strings retain their terminating newline" {
    try expectSerialization("\"broken\nalpha", .none, "\"broken\nalpha");
}

test "token serializer: rejects invalid ordering and unhandled source tokens" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a b");
    defer tree.deinit(testing.allocator);
    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var skipped: TokenSerializer = .init(tree, &output.writer);
    try testing.expectError(error.UnhandledToken, skipped.emitToken(tokens[1], .none));
    try testing.expectError(error.UnhandledToken, skipped.finish());

    var ordered: TokenSerializer = .init(tree, &output.writer);
    try ordered.emitToken(tokens[0], .none);
    try testing.expectError(error.OutOfOrderToken, ordered.emitToken(tokens[0], .none));
}

test "token serializer: rejects trivia EOF bad ranges and emission after finish" {
    var tree = try Ast.parseComponentValues(testing.allocator, " a");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var serializer: TokenSerializer = .init(tree, &output.writer);
    try testing.expectError(error.TriviaToken, serializer.emitToken(0, .none));
    try testing.expectError(
        error.CannotEmitEof,
        serializer.emitToken(@intCast(tree.tokens.len - 1), .none),
    );

    try testing.expectError(
        error.InvalidTokenRange,
        serializer.emitRaw(.{ .start = 2, .end = 1 }, .none),
    );

    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);
    try serializer.emitToken(tokens[0], .none);
    try serializer.finish();
    try serializer.finish();

    try testing.expectError(
        error.AlreadyFinished,
        serializer.emitSynthetic(.{ .tag = .semicolon, .text = ";" }, .none),
    );
}

fn expectSerialization(
    source: []const u8,
    separator: Separator,
    expected: []const u8,
) !void {
    const actual = try serialize(testing.allocator, source, separator);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

fn serialize(
    allocator: std.mem.Allocator,
    source: []const u8,
    separator: Separator,
) ![]u8 {
    var tree = try Ast.parseComponentValues(allocator, source);
    defer tree.deinit(allocator);
    const tokens = try significantTokens(tree, allocator);
    defer allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);
    for (tokens, 0..) |token, index| {
        const after = if (index + 1 < tokens.len) separator else .none;
        try serializer.emitToken(token, after);
    }
    try serializer.finish();

    return output.toOwnedSlice();
}

fn significantTokens(tree: Ast, allocator: Allocator) ![]TokenIndex {
    var tokens: std.ArrayList(TokenIndex) = .empty;
    defer tokens.deinit(allocator);

    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, raw_index| {
        if (tag != .eof and tag != .whitespace and tag != .comment) {
            try tokens.append(allocator, @intCast(raw_index));
        }
    }

    return tokens.toOwnedSlice(allocator);
}

fn expectSameSignificantTags(left: []const u8, right: []const u8) !void {
    var left_tokenizer: Tokenizer = .init(left);
    var right_tokenizer: Tokenizer = .init(right);

    while (true) {
        const left_token = nextSignificant(&left_tokenizer);
        const right_token = nextSignificant(&right_tokenizer);
        try testing.expectEqual(left_token.tag, right_token.tag);
        if (left_token.tag == .eof) break;
    }
}

fn nextSignificant(css_tokenizer: *Tokenizer) tokenizer.Token {
    while (true) {
        const token = css_tokenizer.next();
        if (token.tag != .whitespace and token.tag != .comment) {
            return token;
        }
    }
}
