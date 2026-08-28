const std = @import("std");
const testing = std.testing;

const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;

fn nodeHasChildren(tag: Node.Tag) bool {
    return switch (tag) {
        .token, .invalid => false,
        else => true,
    };
}

fn expectWellFormedRanges(tree: Ast) !void {
    const eof_token: ast.TokenIndex = @intCast(tree.tokens.len - 1);
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    for (0..tree.nodes.len) |raw_node| {
        const node: ast.Index = @intCast(raw_node);
        const range = tree.nodeRange(node);

        try testing.expect(range.start <= range.end);
        try testing.expect(range.end <= eof_token);

        switch (tags[node]) {
            .root, .component_value_list, .component_value_list_invalid => {},
            else => {
                try testing.expect(range.start < range.end);
                try testing.expect(main_tokens[node] >= range.start);
                try testing.expect(main_tokens[node] < range.end);
            },
        }

        if (!nodeHasChildren(tags[node])) continue;

        var previous_end = range.start;
        for (tree.extraChildren(node)) |child| {
            const child_range = tree.nodeRange(child);
            try testing.expect(child_range.start >= range.start);
            try testing.expect(child_range.end <= range.end);
            try testing.expect(child_range.start >= previous_end);
            previous_end = child_range.end;
        }
    }
}

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

test "ast: ranges are nested, ordered, and bounded by EOF" {
    const source =
        "/**/ @media screen { a/**/ b { color/**/: fn(1,/**/ 2) " ++
        "!/**/important; broken value; } }";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    try expectWellFormedRanges(tree);
    try testing.expectEqualStrings(source, tree.nodeSlice(tree.root));

    var comment_count: usize = 0;
    for (tree.tokens.items(.tag)) |tag| {
        if (tag == .comment) comment_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), comment_count);

    for (0..tree.nodes.len) |raw_node| {
        const node: ast.Index = @intCast(raw_node);
        if (tree.nodes.items(.tag)[node] != .token) continue;
        try testing.expect(tree.tokenTag(tree.nodes.items(.main_token)[node]) != .comment);
    }
}

test "ast: ranges distinguish explicit and implicit closing tokens" {
    var closed = try Ast.parseComponentValues(testing.allocator, "fn([x])");
    defer closed.deinit(testing.allocator);

    const function = closed.extraChildren(closed.root)[0];
    const bracket = closed.extraChildren(function)[0];
    try testing.expect(closed.nodeHasClosingToken(function, .r_paren));
    try testing.expect(closed.nodeHasClosingToken(bracket, .r_bracket));
    try testing.expectEqualStrings("fn([x])", closed.nodeSlice(function));
    try testing.expectEqualStrings("[x]", closed.nodeSlice(bracket));
    try expectWellFormedRanges(closed);

    var unclosed = try Ast.parseComponentValues(testing.allocator, "fn([x");
    defer unclosed.deinit(testing.allocator);

    const unclosed_function = unclosed.extraChildren(unclosed.root)[0];
    const unclosed_bracket = unclosed.extraChildren(unclosed_function)[0];
    try testing.expect(!unclosed.nodeHasClosingToken(unclosed_function, .r_paren));
    try testing.expect(!unclosed.nodeHasClosingToken(unclosed_bracket, .r_bracket));
    try testing.expectEqualStrings("fn([x", unclosed.nodeSlice(unclosed_function));
    try testing.expectEqualStrings("[x", unclosed.nodeSlice(unclosed_bracket));
    try expectWellFormedRanges(unclosed);
}

test "ast: declarations own present semicolons but not following trivia" {
    var tree = try Ast.parseBlockContents(testing.allocator, "a:b; /**/ c:d");
    defer tree.deinit(testing.allocator);

    const list = tree.extraChildren(tree.root)[0];
    const declarations = tree.extraChildren(list);
    try testing.expectEqual(@as(usize, 2), declarations.len);
    try testing.expectEqualStrings("a:b;", tree.nodeSlice(declarations[0]));
    try testing.expectEqualStrings("c:d", tree.nodeSlice(declarations[1]));
    try testing.expectEqualStrings("a:b; /**/ c:d", tree.nodeSlice(list));
    try testing.expect(tree.nodeHasClosingToken(declarations[0], .semicolon));
    try testing.expect(!tree.nodeHasClosingToken(declarations[1], .semicolon));
    try expectWellFormedRanges(tree);
}

test "ast: synthetic nodes have exact empty and grouped ranges" {
    var empty = try Ast.parseComponentValues(testing.allocator, "");
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.nodeRange(empty.root).isEmpty());
    try testing.expectEqualStrings("", empty.nodeSlice(empty.root));

    var groups = try Ast.parseCommaSeparatedComponentValues(
        testing.allocator,
        ",a,,/**/,b,",
    );
    defer groups.deinit(testing.allocator);

    const children = groups.extraChildren(groups.root);
    try testing.expectEqual(@as(usize, 5), children.len);
    try testing.expectEqualStrings("", groups.nodeSlice(children[0]));
    try testing.expectEqualStrings("a", groups.nodeSlice(children[1]));
    try testing.expectEqualStrings("", groups.nodeSlice(children[2]));
    try testing.expectEqualStrings("/**/", groups.nodeSlice(children[3]));
    try testing.expectEqualStrings("b", groups.nodeSlice(children[4]));
    try testing.expectEqual(@as(usize, 0), groups.extraChildren(children[3]).len);
    try expectWellFormedRanges(groups);
}

test "ast: invalid nodes retain exact recovery source ranges" {
    const source = "color:red; broken fn(a;b); width:1px;";
    var tree = try Ast.parseBlockContents(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), children.len);
    try testing.expectEqual(Node.Tag.declaration_list, tree.nodes.items(.tag)[children[0]]);
    try testing.expectEqual(Node.Tag.invalid, tree.nodes.items(.tag)[children[1]]);
    try testing.expectEqual(Node.Tag.declaration_list, tree.nodes.items(.tag)[children[2]]);
    try testing.expectEqualStrings("broken fn(a;b);", tree.nodeSlice(children[1]));
    try testing.expectEqual(@as(usize, 0), tree.extraChildren(children[1]).len);
    try expectWellFormedRanges(tree);
}
