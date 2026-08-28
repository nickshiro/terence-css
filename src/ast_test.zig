const std = @import("std");
const testing = std.testing;

const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;

test "ast: stores token tags and source spans" {
    const source = "a { 42px }";
    var tree = try Ast.parseComponentValues(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    const expected_tags = [_]ast.TokenTag{
        .ident,
        .whitespace,
        .l_brace,
        .whitespace,
        .dimension,
        .whitespace,
        .r_brace,
        .eof,
    };
    const expected_text = [_][]const u8{
        "a",
        " ",
        "{",
        " ",
        "42px",
        " ",
        "}",
        "",
    };

    try testing.expectEqual(expected_tags.len, tree.tokens.len);
    for (expected_tags, expected_text, 0..) |tag, text, token| {
        try testing.expectEqual(tag, tree.tokenTag(@intCast(token)));
        try testing.expectEqualStrings(text, tree.tokenSlice(@intCast(token)));
    }

    const starts = tree.tokens.items(.start);
    const ends = tree.tokens.items(.end);
    for (starts, ends) |start, end| {
        try testing.expect(start <= end);
        try testing.expect(end <= source.len);
    }
}

test "ast: exposes root and container children through extra data" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a{b}c");
    defer tree.deinit(testing.allocator);

    const tags = tree.nodes.items(.tag);
    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);
    try testing.expectEqual(Node.Tag.token, tags[root_children[0]]);
    try testing.expectEqual(Node.Tag.simple_block_brace, tags[root_children[1]]);
    try testing.expectEqual(Node.Tag.token, tags[root_children[2]]);

    const block_children = tree.extraChildren(root_children[1]);
    try testing.expectEqual(@as(usize, 1), block_children.len);
    try testing.expectEqual(Node.Tag.token, tags[block_children[0]]);
}

test "ast: dump renders a stable structural snapshot" {
    var tree = try Ast.parseComponentValues(testing.allocator, ".foo { color: rgb(1, 2, 3); }");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings(
        \\root
        \\  token .delim "."
        \\  token .ident "foo"
        \\  token .whitespace " "
        \\  simple_block_brace "{"
        \\    token .whitespace " "
        \\    token .ident "color"
        \\    token .colon ":"
        \\    token .whitespace " "
        \\    function "rgb("
        \\      token .number "1"
        \\      token .comma ","
        \\      token .whitespace " "
        \\      token .number "2"
        \\      token .comma ","
        \\      token .whitespace " "
        \\      token .number "3"
        \\    token .semicolon ";"
        \\    token .whitespace " "
        \\
    , output.written());
}

test "ast: dump renders an empty root" {
    var tree = try Ast.parseComponentValues(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings("root\n", output.written());
}

test "ast: dump renders comma-separated component-value groups" {
    var tree = try Ast.parseCommaSeparatedComponentValues(
        testing.allocator,
        "a, fn(b,c)",
    );
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings(
        \\root
        \\  component_value_list
        \\    token .ident "a"
        \\  component_value_list
        \\    token .whitespace " "
        \\    function "fn("
        \\      token .ident "b"
        \\      token .comma ","
        \\      token .ident "c"
        \\
    , output.written());
}

test "ast: dump distinguishes failed grammar items" {
    const GrammarContext = struct {
        fn matchIdent(
            _: ?*const anyopaque,
            tree: Ast,
            values: []const ast.Index,
        ) bool {
            for (values) |value| {
                if (tree.nodes.items(.tag)[value] != .token) {
                    return false;
                }

                const token = tree.nodes.items(.main_token)[value];
                const tag = tree.tokenTag(token);
                if (tag == .whitespace or tag == .comment) {
                    continue;
                }

                return tag == .ident;
            }

            return false;
        }
    };

    var tree = try Ast.parseCommaSeparatedAccordingToGrammar(
        testing.allocator,
        "red, 42",
        .{ .matchFn = GrammarContext.matchIdent },
    );
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings(
        \\root
        \\  component_value_list
        \\    token .ident "red"
        \\  component_value_list_invalid
        \\    token .whitespace " "
        \\    token .number "42"
        \\
    , output.written());
}

test "ast: dump renders stylesheet rules" {
    var tree = try Ast.parseStylesheet(testing.allocator, "@import \"a\";\na {}");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings(
        \\root
        \\  at_rule "@import"
        \\    token .whitespace " "
        \\    token .string "\"a\""
        \\  qualified_rule "a"
        \\    token .ident "a"
        \\    token .whitespace " "
        \\    block "{"
        \\
    , output.written());
}

test "ast: dump renders parsed block contents" {
    var tree = try Ast.parseStylesheet(testing.allocator, "a { color: red; & b {} }");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings(
        \\root
        \\  qualified_rule "a"
        \\    token .ident "a"
        \\    token .whitespace " "
        \\    block "{"
        \\      declaration_list "color"
        \\        declaration "color"
        \\          token .ident "red"
        \\      qualified_rule "&"
        \\        token .delim "&"
        \\        token .whitespace " "
        \\        token .ident "b"
        \\        token .whitespace " "
        \\        block "{"
        \\
    , output.written());
}

test "ast: dump renders an important declaration" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: red !important;");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try tree.dump(&output.writer);

    try testing.expectEqualStrings(
        \\root
        \\  declaration_important "color"
        \\    token .ident "red"
        \\
    , output.written());
}
