const std = @import("std");
const testing = std.testing;

const ast = @import("ast.zig");
const Ast = ast.Ast;
const Index = ast.Index;
const Node = ast.Node;
const TokenTag = ast.TokenTag;

fn nodeTag(tree: Ast, node: Index) Node.Tag {
    return tree.nodes.items(.tag)[node];
}

fn expectTokenNode(tree: Ast, node: Index, tag: TokenTag, text: []const u8) !void {
    try testing.expectEqual(Node.Tag.token, nodeTag(tree, node));

    const token = tree.nodes.items(.main_token)[node];
    try testing.expectEqual(tag, tree.tokenTag(token));
    try testing.expectEqualStrings(text, tree.tokenSlice(token));
}

fn expectInvalidNode(tree: Ast, node: Index, text: []const u8) !void {
    try testing.expectEqual(Node.Tag.invalid, nodeTag(tree, node));
    try testing.expectEqualStrings(text, tree.nodeSlice(node));
    try testing.expectEqual(@as(usize, 0), tree.extraChildren(node).len);
}

fn expectContainer(
    tree: Ast,
    node: Index,
    tag: Node.Tag,
    opening_text: []const u8,
    child_count: usize,
) ![]const Index {
    try testing.expectEqual(tag, nodeTag(tree, node));

    const token = tree.nodes.items(.main_token)[node];
    try testing.expectEqualStrings(opening_text, tree.tokenSlice(token));

    const children = tree.extraChildren(node);
    try testing.expectEqual(child_count, children.len);
    return children;
}

fn expectComponentValueList(tree: Ast, node: Index, child_count: usize) ![]const Index {
    try testing.expectEqual(Node.Tag.component_value_list, nodeTag(tree, node));

    const children = tree.extraChildren(node);
    try testing.expectEqual(child_count, children.len);
    return children;
}

const TokenGrammarContext = struct {
    tag: TokenTag,
};

fn matchSingleToken(
    context: ?*const anyopaque,
    tree: Ast,
    values: []const Index,
) bool {
    const grammar_context: *const TokenGrammarContext = @ptrCast(@alignCast(context.?));
    var matched_value: ?Index = null;

    for (values) |value| {
        if (nodeTag(tree, value) == .token) {
            const token = tree.nodes.items(.main_token)[value];
            const tag = tree.tokenTag(token);
            if (tag == .whitespace or tag == .comment) {
                continue;
            }
        }

        if (matched_value != null) {
            return false;
        }
        matched_value = value;
    }

    const value = matched_value orelse return false;
    if (nodeTag(tree, value) != .token) {
        return false;
    }

    const token = tree.nodes.items(.main_token)[value];
    return tree.tokenTag(token) == grammar_context.tag;
}

fn tokenGrammar(context: *const TokenGrammarContext) Ast.Grammar {
    return .{
        .context = context,
        .matchFn = matchSingleToken,
    };
}

test "component value parser: parses one token" {
    var tree = try Ast.parseComponentValue(testing.allocator, "/**/ red \n");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);
    try expectTokenNode(tree, root_children[0], .ident, "red");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "component value parser: parses one simple block" {
    var tree = try Ast.parseComponentValue(testing.allocator, "[foo bar]");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const block_children = try expectContainer(
        tree,
        root_children[0],
        .simple_block_bracket,
        "[",
        3,
    );
    try expectTokenNode(tree, block_children[0], .ident, "foo");
    try expectTokenNode(tree, block_children[2], .ident, "bar");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "component value parser: parses one function" {
    var tree = try Ast.parseComponentValue(testing.allocator, "calc(1px + var(--gap))");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const function_children = try expectContainer(
        tree,
        root_children[0],
        .function,
        "calc(",
        5,
    );
    _ = try expectContainer(tree, function_children[4], .function, "var(", 1);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "component value parser: rejects empty input after discarding whitespace" {
    const sources = [_][]const u8{
        "",
        " \t\n",
        "/**/ \n",
    };

    for (sources) |source| {
        var tree = try Ast.parseComponentValue(testing.allocator, source);
        defer tree.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
        try testing.expectEqual(@as(usize, 1), tree.errors.len);
        try testing.expectEqual(Ast.Error.Tag.expected_component_value, tree.errors[0].tag);
        try testing.expectEqual(TokenTag.eof, tree.tokenTag(tree.errors[0].token));
    }
}

test "component value parser: rejects a second value" {
    var tree = try Ast.parseComponentValue(testing.allocator, "red blue");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(
        Ast.Error.Tag.unexpected_input_after_component_value,
        tree.errors[0].tag,
    );
    try testing.expectEqualStrings("blue", tree.tokenSlice(tree.errors[0].token));
}

test "component value parser: rejects trailing punctuation" {
    var tree = try Ast.parseComponentValue(testing.allocator, "red,");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(
        Ast.Error.Tag.unexpected_input_after_component_value,
        tree.errors[0].tag,
    );
    try testing.expectEqualStrings(",", tree.tokenSlice(tree.errors[0].token));
}

test "component value parser: closes a function at EOF" {
    var tree = try Ast.parseComponentValue(testing.allocator, "var(--color");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    _ = try expectContainer(tree, root_children[0], .function, "var(", 1);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "comma-separated component values parser: empty input produces no groups" {
    var tree = try Ast.parseCommaSeparatedComponentValues(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "comma-separated component values parser: keeps one unsplit group" {
    var tree = try Ast.parseCommaSeparatedComponentValues(testing.allocator, "a b");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const group = try expectComponentValueList(tree, root_children[0], 3);
    try expectTokenNode(tree, group[0], .ident, "a");
    try expectTokenNode(tree, group[1], .whitespace, " ");
    try expectTokenNode(tree, group[2], .ident, "b");
}

test "comma-separated component values parser: splits at top-level commas" {
    var tree = try Ast.parseCommaSeparatedComponentValues(testing.allocator, "a,b,c");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);

    const first = try expectComponentValueList(tree, root_children[0], 1);
    const second = try expectComponentValueList(tree, root_children[1], 1);
    const third = try expectComponentValueList(tree, root_children[2], 1);
    try expectTokenNode(tree, first[0], .ident, "a");
    try expectTokenNode(tree, second[0], .ident, "b");
    try expectTokenNode(tree, third[0], .ident, "c");
}

test "comma-separated component values parser: preserves nested commas" {
    var tree = try Ast.parseCommaSeparatedComponentValues(
        testing.allocator,
        "rgb(1, 2), [a,b]",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), root_children.len);

    const first = try expectComponentValueList(tree, root_children[0], 1);
    const function_children = try expectContainer(tree, first[0], .function, "rgb(", 4);
    try expectTokenNode(tree, function_children[1], .comma, ",");

    const second = try expectComponentValueList(tree, root_children[1], 2);
    try expectTokenNode(tree, second[0], .whitespace, " ");
    const block_children = try expectContainer(
        tree,
        second[1],
        .simple_block_bracket,
        "[",
        3,
    );
    try expectTokenNode(tree, block_children[1], .comma, ",");
}

test "comma-separated component values parser: represents leading and middle empty groups" {
    var tree = try Ast.parseCommaSeparatedComponentValues(testing.allocator, ",a,,b");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 4), root_children.len);

    _ = try expectComponentValueList(tree, root_children[0], 0);
    const second = try expectComponentValueList(tree, root_children[1], 1);
    _ = try expectComponentValueList(tree, root_children[2], 0);
    const fourth = try expectComponentValueList(tree, root_children[3], 1);
    try expectTokenNode(tree, second[0], .ident, "a");
    try expectTokenNode(tree, fourth[0], .ident, "b");
}

test "comma-separated component values parser: does not add a group after a trailing comma" {
    var tree = try Ast.parseCommaSeparatedComponentValues(testing.allocator, "a,");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);
    _ = try expectComponentValueList(tree, root_children[0], 1);
}

test "comma-separated component values parser: preserves trivia inside groups" {
    var tree = try Ast.parseCommaSeparatedComponentValues(
        testing.allocator,
        " a /**/, b ",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const first = try expectComponentValueList(tree, root_children[0], 3);
    const second = try expectComponentValueList(tree, root_children[1], 3);
    try expectTokenNode(tree, first[0], .whitespace, " ");
    try expectTokenNode(tree, first[2], .whitespace, " ");
    try expectTokenNode(tree, second[0], .whitespace, " ");
    try expectTokenNode(tree, second[2], .whitespace, " ");
    try testing.expectEqualStrings(" a /**/", tree.nodeSlice(root_children[0]));
}

test "comma-separated component values parser: reports an unexpected closing brace" {
    var tree = try Ast.parseCommaSeparatedComponentValues(testing.allocator, "},a");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const first = try expectComponentValueList(tree, root_children[0], 1);
    _ = try expectComponentValueList(tree, root_children[1], 1);
    try expectTokenNode(tree, first[0], .r_brace, "}");

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.unexpected_closing_brace, tree.errors[0].tag);
}

test "grammar parser: returns component values that match the grammar" {
    const context = TokenGrammarContext{ .tag = .ident };
    var tree = try Ast.parseAccordingToGrammar(
        testing.allocator,
        " /**/ red ",
        tokenGrammar(&context),
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 4), root_children.len);
    try expectTokenNode(tree, root_children[2], .ident, "red");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "grammar parser: returns failure when component values do not match" {
    const context = TokenGrammarContext{ .tag = .ident };
    var tree = try Ast.parseAccordingToGrammar(
        testing.allocator,
        " 42 ",
        tokenGrammar(&context),
    );
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.grammar_mismatch, tree.errors[0].tag);
    try testing.expectEqualStrings("42", tree.tokenSlice(tree.errors[0].token));
}

test "comma-separated grammar parser: matches every item independently" {
    const context = TokenGrammarContext{ .tag = .ident };
    var tree = try Ast.parseCommaSeparatedAccordingToGrammar(
        testing.allocator,
        ", red, 42, blue",
        tokenGrammar(&context),
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 4), root_children.len);
    try testing.expectEqual(
        Node.Tag.component_value_list_invalid,
        nodeTag(tree, root_children[0]),
    );
    try testing.expectEqual(
        Node.Tag.component_value_list,
        nodeTag(tree, root_children[1]),
    );
    try testing.expectEqual(
        Node.Tag.component_value_list_invalid,
        nodeTag(tree, root_children[2]),
    );
    try testing.expectEqual(
        Node.Tag.component_value_list,
        nodeTag(tree, root_children[3]),
    );
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "comma-separated grammar parser: whitespace-only input returns an empty list" {
    const context = TokenGrammarContext{ .tag = .ident };
    var tree = try Ast.parseCommaSeparatedAccordingToGrammar(
        testing.allocator,
        " /**/ \n",
        tokenGrammar(&context),
    );
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "comma-separated grammar parser: a trailing comma adds no item" {
    const context = TokenGrammarContext{ .tag = .ident };
    var tree = try Ast.parseCommaSeparatedAccordingToGrammar(
        testing.allocator,
        "red,",
        tokenGrammar(&context),
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);
    try testing.expectEqual(
        Node.Tag.component_value_list,
        nodeTag(tree, root_children[0]),
    );
}

test "parser: empty source produces an empty root" {
    var tree = try Ast.parseComponentValues(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), tree.tokens.len);
    try testing.expectEqual(TokenTag.eof, tree.tokenTag(0));
    try testing.expectEqual(Node.Tag.root, nodeTag(tree, tree.root));
    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "parser: comments remain token trivia rather than component values" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a /**/ 42)");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 5), children.len);
    try expectTokenNode(tree, children[0], .ident, "a");
    try expectTokenNode(tree, children[1], .whitespace, " ");
    try expectTokenNode(tree, children[2], .whitespace, " ");
    try expectTokenNode(tree, children[3], .number, "42");
    try expectTokenNode(tree, children[4], .r_paren, ")");
    try testing.expectEqual(TokenTag.comment, tree.tokenTag(2));
    try testing.expectEqualStrings("a /**/ 42)", tree.nodeSlice(tree.root));
}

test "parser: groups each simple block kind" {
    var tree = try Ast.parseComponentValues(testing.allocator, "{a}[b](c)");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);

    const brace_children = try expectContainer(tree, root_children[0], .simple_block_brace, "{", 1);
    try expectTokenNode(tree, brace_children[0], .ident, "a");

    const bracket_children = try expectContainer(tree, root_children[1], .simple_block_bracket, "[", 1);
    try expectTokenNode(tree, bracket_children[0], .ident, "b");

    const paren_children = try expectContainer(tree, root_children[2], .simple_block_paren, "(", 1);
    try expectTokenNode(tree, paren_children[0], .ident, "c");
}

test "parser: recursively groups nested blocks" {
    var tree = try Ast.parseComponentValues(testing.allocator, "{a[b (c)]d}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const brace_children = try expectContainer(tree, root_children[0], .simple_block_brace, "{", 3);
    try expectTokenNode(tree, brace_children[0], .ident, "a");
    try expectTokenNode(tree, brace_children[2], .ident, "d");

    const bracket_children = try expectContainer(tree, brace_children[1], .simple_block_bracket, "[", 3);
    try expectTokenNode(tree, bracket_children[0], .ident, "b");
    try expectTokenNode(tree, bracket_children[1], .whitespace, " ");

    const paren_children = try expectContainer(tree, bracket_children[2], .simple_block_paren, "(", 1);
    try expectTokenNode(tree, paren_children[0], .ident, "c");
}

test "parser: groups functions and nested component values" {
    var tree = try Ast.parseComponentValues(testing.allocator, "calc(100% - var(--gap))");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const calc_children = try expectContainer(tree, root_children[0], .function, "calc(", 5);
    try expectTokenNode(tree, calc_children[0], .percentage, "100%");
    try expectTokenNode(tree, calc_children[1], .whitespace, " ");
    try expectTokenNode(tree, calc_children[2], .delim, "-");
    try expectTokenNode(tree, calc_children[3], .whitespace, " ");

    const var_children = try expectContainer(tree, calc_children[4], .function, "var(", 1);
    try expectTokenNode(tree, var_children[0], .ident, "--gap");
}

test "parser: url token is preserved rather than parsed as a function" {
    var tree = try Ast.parseComponentValues(testing.allocator, "url(image.png)");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectTokenNode(tree, children[0], .url, "url(image.png)");
}

test "parser: quoted url syntax is parsed as a function" {
    var tree = try Ast.parseComponentValues(testing.allocator, "url('image.png')");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const function_children = try expectContainer(tree, root_children[0], .function, "url(", 1);
    try expectTokenNode(tree, function_children[0], .string, "'image.png'");
}

test "parser: mismatched closing tokens are preserved" {
    var tree = try Ast.parseComponentValues(testing.allocator, "{)]}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const block_children = try expectContainer(tree, root_children[0], .simple_block_brace, "{", 2);
    try expectTokenNode(tree, block_children[0], .r_paren, ")");
    try expectTokenNode(tree, block_children[1], .r_bracket, "]");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "parser: unexpected top-level closing brace reports an error" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a}");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), children.len);
    try expectTokenNode(tree, children[0], .ident, "a");
    try expectTokenNode(tree, children[1], .r_brace, "}");

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.unexpected_closing_brace, tree.errors[0].tag);
    try testing.expectEqualStrings("}", tree.tokenSlice(tree.errors[0].token));
}

test "parser: unclosed block ends at EOF" {
    var tree = try Ast.parseComponentValues(testing.allocator, "{foo");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const block_children = try expectContainer(tree, root_children[0], .simple_block_brace, "{", 1);
    try expectTokenNode(tree, block_children[0], .ident, "foo");
}

test "parser: unclosed function ends at EOF" {
    var tree = try Ast.parseComponentValues(testing.allocator, "calc(1px");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const function_children = try expectContainer(tree, root_children[0], .function, "calc(", 1);
    try expectTokenNode(tree, function_children[0], .dimension, "1px");
}

test "stylesheet parser: empty source produces an empty root" {
    var tree = try Ast.parseStylesheet(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet parser: consumes a qualified rule" {
    var tree = try Ast.parseStylesheet(testing.allocator, "a:hover { color: red; }");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const rule_children = try expectContainer(tree, root_children[0], .qualified_rule, "a", 5);
    try expectTokenNode(tree, rule_children[0], .ident, "a");
    try expectTokenNode(tree, rule_children[1], .colon, ":");
    try expectTokenNode(tree, rule_children[2], .ident, "hover");

    const block_children = try expectContainer(tree, rule_children[4], .block, "{", 1);
    const declarations = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "color",
        1,
    );
    const value = try expectContainer(tree, declarations[0], .declaration, "color", 1);
    try expectTokenNode(tree, value[0], .ident, "red");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet parser: consumes a semicolon at-rule" {
    var tree = try Ast.parseStylesheet(testing.allocator, "@import url(theme.css);");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(tree, root_children[0], .at_rule, "@import", 2);
    try expectTokenNode(tree, rule_children[0], .whitespace, " ");
    try expectTokenNode(tree, rule_children[1], .url, "url(theme.css)");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet parser: parses a block at-rule body" {
    var tree = try Ast.parseStylesheet(testing.allocator, "@media screen { a { color: red } }");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(tree, root_children[0], .at_rule, "@media", 4);
    try expectTokenNode(tree, rule_children[1], .ident, "screen");

    const body_children = try expectContainer(tree, rule_children[3], .block, "{", 1);
    const nested_rule_children = try expectContainer(
        tree,
        body_children[0],
        .qualified_rule,
        "a",
        3,
    );
    const nested_block_children = try expectContainer(
        tree,
        nested_rule_children[2],
        .block,
        "{",
        1,
    );
    _ = try expectContainer(
        tree,
        nested_block_children[0],
        .declaration_list,
        "color",
        1,
    );
}

test "stylesheet parser: discards top-level trivia from the rule list" {
    var tree = try Ast.parseStylesheet(testing.allocator, "<!-- /**/ @import \"a\"; --> .a{}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), root_children.len);
    try testing.expectEqual(Node.Tag.at_rule, nodeTag(tree, root_children[0]));
    try testing.expectEqual(Node.Tag.qualified_rule, nodeTag(tree, root_children[1]));

    var saw_cdo = false;
    var saw_comment = false;
    var saw_cdc = false;
    for (tree.tokens.items(.tag)) |tag| {
        switch (tag) {
            .cdo => saw_cdo = true,
            .comment => saw_comment = true,
            .cdc => saw_cdc = true,
            else => {},
        }
    }

    try testing.expect(saw_cdo);
    try testing.expect(saw_comment);
    try testing.expect(saw_cdc);
}

test "stylesheet parser: rejects a qualified rule without a block" {
    var tree = try Ast.parseStylesheet(testing.allocator, "a");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], "a");
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.qualified_rule_without_block, tree.errors[0].tag);
    try testing.expectEqual(TokenTag.eof, tree.tokenTag(tree.errors[0].token));
}

test "stylesheet parser: recovers from a top-level closing brace" {
    var tree = try Ast.parseStylesheet(testing.allocator, ".a} {}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(tree, root_children[0], .qualified_rule, ".", 5);
    try expectTokenNode(tree, rule_children[2], .r_brace, "}");

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.unexpected_closing_brace, tree.errors[0].tag);
}

test "stylesheet parser: rejects a qualified rule shaped like a custom property" {
    var tree = try Ast.parseStylesheet(testing.allocator, "--foo: bar {} .a {}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), root_children.len);
    try expectInvalidNode(tree, root_children[0], "--foo: bar {}");
    _ = try expectContainer(tree, root_children[1], .qualified_rule, ".", 4);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet contents parser: empty input produces no rules" {
    var tree = try Ast.parseStylesheetContents(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet contents parser: parses rules in source order" {
    var tree = try Ast.parseStylesheetContents(
        testing.allocator,
        "@import \"theme.css\"; a { color:red; }",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), root_children.len);
    _ = try expectContainer(tree, root_children[0], .at_rule, "@import", 2);

    const rule_children = try expectContainer(
        tree,
        root_children[1],
        .qualified_rule,
        "a",
        3,
    );
    const block_children = try expectContainer(tree, rule_children[2], .block, "{", 1);
    _ = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "color",
        1,
    );
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet contents parser: discards top-level CDO and CDC tokens" {
    var tree = try Ast.parseStylesheetContents(
        testing.allocator,
        "<!-- @import \"a\"; --> b {}",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), root_children.len);
    try testing.expectEqual(Node.Tag.at_rule, nodeTag(tree, root_children[0]));
    try testing.expectEqual(Node.Tag.qualified_rule, nodeTag(tree, root_children[1]));
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet contents parser: keeps semicolons in a qualified-rule prelude" {
    var tree = try Ast.parseStylesheetContents(testing.allocator, "invalid; a {}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);
    _ = try expectContainer(tree, root_children[0], .qualified_rule, "invalid", 6);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "rule parser: parses one qualified rule" {
    var tree = try Ast.parseRule(testing.allocator, "/**/ a { color:red; } /**/");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const rule_children = try expectContainer(
        tree,
        root_children[0],
        .qualified_rule,
        "a",
        3,
    );
    const block_children = try expectContainer(tree, rule_children[2], .block, "{", 1);
    _ = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "color",
        1,
    );
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "rule parser: parses one at-rule" {
    var tree = try Ast.parseRule(testing.allocator, " \t@import \"theme.css\";\n");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(
        tree,
        root_children[0],
        .at_rule,
        "@import",
        2,
    );
    try expectTokenNode(tree, rule_children[1], .string, "\"theme.css\"");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "rule parser: rejects empty input after discarding whitespace" {
    const sources = [_][]const u8{
        "",
        " \t\n",
        "/**/ \n",
    };

    for (sources) |source| {
        var tree = try Ast.parseRule(testing.allocator, source);
        defer tree.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
        try testing.expectEqual(@as(usize, 1), tree.errors.len);
        try testing.expectEqual(Ast.Error.Tag.expected_rule, tree.errors[0].tag);
        try testing.expectEqual(TokenTag.eof, tree.tokenTag(tree.errors[0].token));
    }
}

test "rule parser: rejects a qualified rule without a block" {
    var tree = try Ast.parseRule(testing.allocator, "a:hover");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], "a:hover");
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.qualified_rule_without_block, tree.errors[0].tag);
}

test "rule parser: rejects a custom-property-shaped rule" {
    var tree = try Ast.parseRule(testing.allocator, "--theme: red {}");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], "--theme: red {}");
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.expected_rule, tree.errors[0].tag);
    try testing.expectEqualStrings("--theme", tree.tokenSlice(tree.errors[0].token));
}

test "rule parser: rejects a second rule" {
    var tree = try Ast.parseRule(testing.allocator, "a {} b {}");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.unexpected_input_after_rule, tree.errors[0].tag);
    try testing.expectEqualStrings("b", tree.tokenSlice(tree.errors[0].token));
}

test "rule parser: treats a trailing semicolon as extra input" {
    var tree = try Ast.parseRule(testing.allocator, "a {} ;");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.unexpected_input_after_rule, tree.errors[0].tag);
    try testing.expectEqualStrings(";", tree.tokenSlice(tree.errors[0].token));
}

test "rule parser: treats CDO as qualified-rule input" {
    var tree = try Ast.parseRule(testing.allocator, "<!-- a {}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(
        tree,
        root_children[0],
        .qualified_rule,
        "<!--",
        5,
    );
    try expectTokenNode(tree, rule_children[0], .cdo, "<!--");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "rule parser: keeps a recovered qualified rule" {
    var tree = try Ast.parseRule(testing.allocator, "a} {}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    _ = try expectContainer(tree, root_children[0], .qualified_rule, "a", 4);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.unexpected_closing_brace, tree.errors[0].tag);
}

test "rule parser: closes a rule block at EOF" {
    var tree = try Ast.parseRule(testing.allocator, "a { color:red");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(tree, root_children[0], .qualified_rule, "a", 3);
    const block_children = try expectContainer(tree, rule_children[2], .block, "{", 1);
    _ = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "color",
        1,
    );
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "block contents parser: empty source produces an empty root" {
    var tree = try Ast.parseBlockContents(testing.allocator, "");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "block contents parser: groups consecutive declarations" {
    var tree = try Ast.parseBlockContents(testing.allocator, "color: red; width: 1px");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const declarations = try expectContainer(
        tree,
        root_children[0],
        .declaration_list,
        "color",
        2,
    );
    _ = try expectContainer(tree, declarations[0], .declaration, "color", 1);
    _ = try expectContainer(tree, declarations[1], .declaration, "width", 1);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "block contents parser: preserves declaration and nested rule order" {
    var tree = try Ast.parseBlockContents(
        testing.allocator,
        "color: red; & .child { width: 1px; } background: blue;",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);

    _ = try expectContainer(tree, root_children[0], .declaration_list, "color", 1);
    const rule_children = try expectContainer(
        tree,
        root_children[1],
        .qualified_rule,
        "&",
        6,
    );
    const block_children = try expectContainer(tree, rule_children[5], .block, "{", 1);
    _ = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "width",
        1,
    );
    _ = try expectContainer(
        tree,
        root_children[2],
        .declaration_list,
        "background",
        1,
    );
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "block contents parser: an at-rule separates declaration lists" {
    var tree = try Ast.parseBlockContents(
        testing.allocator,
        "color:red; @media (width > 1px) { width:1px; } background:blue;",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);
    _ = try expectContainer(tree, root_children[0], .declaration_list, "color", 1);

    const at_rule_children = try expectContainer(
        tree,
        root_children[1],
        .at_rule,
        "@media",
        4,
    );
    const block_children = try expectContainer(tree, at_rule_children[3], .block, "{", 1);
    _ = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "width",
        1,
    );
    _ = try expectContainer(
        tree,
        root_children[2],
        .declaration_list,
        "background",
        1,
    );
}

test "block contents parser: restores after a failed declaration" {
    var tree = try Ast.parseBlockContents(testing.allocator, "color red; width: 1px;");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), root_children.len);
    try expectInvalidNode(tree, root_children[0], "color red;");
    const declarations = try expectContainer(
        tree,
        root_children[1],
        .declaration_list,
        "width",
        1,
    );
    _ = try expectContainer(tree, declarations[0], .declaration, "width", 1);

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.qualified_rule_without_block, tree.errors[0].tag);
    try testing.expectEqualStrings(";", tree.tokenSlice(tree.errors[0].token));
}

test "block contents parser: an invalid rule separates declaration lists" {
    var tree = try Ast.parseBlockContents(
        testing.allocator,
        "color:red; broken value; width:1px;",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);
    _ = try expectContainer(tree, root_children[0], .declaration_list, "color", 1);
    try expectInvalidNode(tree, root_children[1], "broken value;");
    _ = try expectContainer(tree, root_children[2], .declaration_list, "width", 1);

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.qualified_rule_without_block, tree.errors[0].tag);
}

test "block contents parser: stops before a closing brace" {
    var tree = try Ast.parseBlockContents(testing.allocator, "color:red;} width:1px;");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declarations = try expectContainer(
        tree,
        root_children[0],
        .declaration_list,
        "color",
        1,
    );
    _ = try expectContainer(tree, declarations[0], .declaration, "color", 1);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "stylesheet parser: closes a rule block at EOF" {
    var tree = try Ast.parseStylesheet(testing.allocator, ".a { color:red");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const rule_children = try expectContainer(tree, root_children[0], .qualified_rule, ".", 4);
    const block_children = try expectContainer(tree, rule_children[3], .block, "{", 1);
    _ = try expectContainer(
        tree,
        block_children[0],
        .declaration_list,
        "color",
        1,
    );
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "declaration parser: consumes a declaration value" {
    var tree = try Ast.parseDeclaration(testing.allocator, "  color : rgb(1, 2, 3)  ;");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(tree, root_children[0], .declaration, "color", 1);
    _ = try expectContainer(tree, declaration_children[0], .function, "rgb(", 7);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "declaration parser: retokenizes a unicode-range descriptor value" {
    var tree = try Ast.parseDeclaration(
        testing.allocator,
        "unicode-range: U+0025-00FF, U+4??;",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const values = try expectContainer(
        tree,
        root_children[0],
        .declaration,
        "unicode-range",
        4,
    );
    try expectTokenNode(tree, values[0], .unicode_range, "U+0025-00FF");
    try expectTokenNode(tree, values[1], .comma, ",");
    try expectTokenNode(tree, values[2], .whitespace, " ");
    try expectTokenNode(tree, values[3], .unicode_range, "U+4??");
}

test "declaration parser: recognizes escaped unicode-range descriptor names" {
    var tree = try Ast.parseDeclaration(
        testing.allocator,
        "\\75 nicode-range: u+0-7f;",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const values = try expectContainer(
        tree,
        root_children[0],
        .declaration,
        "\\75 nicode-range",
        1,
    );
    try expectTokenNode(tree, values[0], .unicode_range, "u+0-7f");
}

test "declaration parser: removes important after unicode-range retokenization" {
    var tree = try Ast.parseDeclaration(
        testing.allocator,
        "UNICODE-RANGE: U+0-7F !important;",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const values = try expectContainer(
        tree,
        root_children[0],
        .declaration_important,
        "UNICODE-RANGE",
        1,
    );
    try expectTokenNode(tree, values[0], .unicode_range, "U+0-7F");
}

test "declaration parser: does not enable unicode ranges for other properties" {
    var tree = try Ast.parseDeclaration(testing.allocator, "value: U+0-7F;");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const values = try expectContainer(
        tree,
        root_children[0],
        .declaration,
        "value",
        3,
    );
    try expectTokenNode(tree, values[0], .ident, "U");
    try expectTokenNode(tree, values[1], .number, "+0");
    try expectTokenNode(tree, values[2], .dimension, "-7F");
}

test "stylesheet parser: enables unicode ranges only inside descriptor values" {
    var tree = try Ast.parseStylesheet(
        testing.allocator,
        "u+123 {} @font-face { unicode-range: U+0-7F; src: url(font.woff2); }",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const selector = tree.extraChildren(root_children[0]);
    try expectTokenNode(tree, selector[0], .ident, "u");
    try expectTokenNode(tree, selector[1], .number, "+123");

    const at_rule = tree.extraChildren(root_children[1]);
    const block = tree.extraChildren(at_rule[1]);
    const declarations = tree.extraChildren(block[0]);
    const unicode_values = tree.extraChildren(declarations[0]);
    try expectTokenNode(tree, unicode_values[0], .unicode_range, "U+0-7F");

    const src_values = tree.extraChildren(declarations[1]);
    try expectTokenNode(tree, src_values[0], .url, "url(font.woff2)");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "declaration parser: retokenizes unicode ranges inside functions" {
    var tree = try Ast.parseDeclaration(
        testing.allocator,
        "unicode-range: fn(U+26);",
    );
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const values = tree.extraChildren(root_children[0]);
    const function_values = try expectContainer(tree, values[0], .function, "fn(", 1);
    try expectTokenNode(tree, function_values[0], .unicode_range, "U+26");
}

test "declaration parser: removes a case-insensitive important annotation" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: red ! ImPoRtAnT  ;");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(
        tree,
        root_children[0],
        .declaration_important,
        "color",
        1,
    );
    try expectTokenNode(tree, declaration_children[0], .ident, "red");
}

test "declaration parser: recognizes an escaped important annotation" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: red !\\69mportant;");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(
        tree,
        root_children[0],
        .declaration_important,
        "color",
        1,
    );
    try expectTokenNode(tree, declaration_children[0], .ident, "red");
}

test "declaration parser: ignores important inside a function" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: fn(!important);");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(tree, root_children[0], .declaration, "color", 1);
    const function_children = try expectContainer(tree, declaration_children[0], .function, "fn(", 2);
    try expectTokenNode(tree, function_children[0], .delim, "!");
    try expectTokenNode(tree, function_children[1], .ident, "important");
}

test "declaration parser: reports a missing name" {
    var tree = try Ast.parseDeclaration(testing.allocator, ": red;");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], ": red;");
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.expected_declaration_name, tree.errors[0].tag);
    try testing.expectEqualStrings(":", tree.tokenSlice(tree.errors[0].token));
}

test "declaration parser: reports a missing colon" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color red;");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], "color red;");
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.expected_colon, tree.errors[0].tag);
    try testing.expectEqualStrings("red", tree.tokenSlice(tree.errors[0].token));
}

test "declaration parser: permits mixed brace values for custom properties" {
    var tree = try Ast.parseDeclaration(testing.allocator, "--theme: red { fallback: blue }");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(tree, root_children[0], .declaration, "--theme", 3);
    try expectTokenNode(tree, declaration_children[0], .ident, "red");
    _ = try expectContainer(tree, declaration_children[2], .simple_block_brace, "{", 6);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "declaration parser: recognizes an escaped custom property prefix" {
    var tree = try Ast.parseDeclaration(testing.allocator, "\\2d -theme: red {}");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(
        tree,
        root_children[0],
        .declaration,
        "\\2d -theme",
        3,
    );
    try expectTokenNode(tree, declaration_children[0], .ident, "red");
    _ = try expectContainer(tree, declaration_children[2], .simple_block_brace, "{", 0);
}

test "declaration parser: rejects mixed brace values for regular properties" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: red { fallback: blue }");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], "color: red { fallback: blue }");
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.invalid_declaration_value, tree.errors[0].tag);
    try testing.expectEqualStrings("color", tree.tokenSlice(tree.errors[0].token));
}

test "declaration parser: permits a brace block as the whole value" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: { fallback: blue }");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(tree, root_children[0], .declaration, "color", 1);
    _ = try expectContainer(tree, declaration_children[0], .simple_block_brace, "{", 6);
}

test "declaration parser: stops the value at a semicolon" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: red; width: 1px");
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const declaration_children = try expectContainer(tree, root_children[0], .declaration, "color", 1);
    try expectTokenNode(tree, declaration_children[0], .ident, "red");
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "component values parser: removes comments but preserves whitespace tokens" {
    var tree = try Ast.parseComponentValues(
        testing.allocator,
        "a/**/b a/**/ b fn(/**/ x /**/) [/**/]",
    );
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 10), children.len);
    try expectTokenNode(tree, children[0], .ident, "a");
    try expectTokenNode(tree, children[1], .ident, "b");
    try expectTokenNode(tree, children[2], .whitespace, " ");
    try expectTokenNode(tree, children[3], .ident, "a");
    try expectTokenNode(tree, children[4], .whitespace, " ");
    try expectTokenNode(tree, children[5], .ident, "b");
    try expectTokenNode(tree, children[6], .whitespace, " ");

    const function_children = try expectContainer(tree, children[7], .function, "fn(", 3);
    try expectTokenNode(tree, function_children[0], .whitespace, " ");
    try expectTokenNode(tree, function_children[1], .ident, "x");
    try expectTokenNode(tree, function_children[2], .whitespace, " ");
    try expectTokenNode(tree, children[8], .whitespace, " ");
    _ = try expectContainer(tree, children[9], .simple_block_bracket, "[", 0);

    var comments: usize = 0;
    for (tree.tokens.items(.tag)) |tag| {
        if (tag == .comment) comments += 1;
    }
    try testing.expectEqual(@as(usize, 5), comments);
}

test "component values parser: a comment-only input has no semantic values" {
    var tree = try Ast.parseComponentValues(testing.allocator, "/**//**/");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), tree.extraChildren(tree.root).len);
    try testing.expectEqualStrings("/**//**/", tree.nodeSlice(tree.root));
    try testing.expectEqual(TokenTag.comment, tree.tokenTag(0));
    try testing.expectEqual(TokenTag.comment, tree.tokenTag(1));
}

test "stylesheet parser: comments are trivia in every structural context" {
    const source = "/**/@media/**/ screen/**/{/**/a/**/{/**/color/**/:/**/red/**/;/**/}/**/}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    const root_children = tree.extraChildren(tree.root);
    const at_children = try expectContainer(tree, root_children[0], .at_rule, "@media", 3);
    try expectTokenNode(tree, at_children[0], .whitespace, " ");
    try expectTokenNode(tree, at_children[1], .ident, "screen");

    // The block follows the prelude but comments never appear as children.
    const at_rule_children = tree.extraChildren(root_children[0]);
    const at_block = at_rule_children[at_rule_children.len - 1];
    try testing.expectEqual(Node.Tag.block, nodeTag(tree, at_block));
    const nested_rule = tree.extraChildren(at_block)[0];
    const nested_children = tree.extraChildren(nested_rule);
    try testing.expectEqual(@as(usize, 2), nested_children.len);
    try expectTokenNode(tree, nested_children[0], .ident, "a");

    const declaration_list = tree.extraChildren(nested_children[1])[0];
    const declaration = tree.extraChildren(declaration_list)[0];
    const value = tree.extraChildren(declaration);
    try testing.expectEqual(@as(usize, 1), value.len);
    try expectTokenNode(tree, value[0], .ident, "red");
    try testing.expectEqualStrings(source, tree.nodeSlice(tree.root));
}

test "declaration parser: comments do not prevent important recognition" {
    const source = "color/**/: red !/**/IMPORTANT/**/;";
    var tree = try Ast.parseDeclaration(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    const declaration = tree.extraChildren(tree.root)[0];
    try testing.expectEqual(Node.Tag.declaration_important, nodeTag(tree, declaration));
    const value = tree.extraChildren(declaration);
    try testing.expectEqual(@as(usize, 1), value.len);
    try expectTokenNode(tree, value[0], .ident, "red");
    try testing.expectEqualStrings(source, tree.nodeSlice(declaration));
    try testing.expect(tree.nodeHasClosingToken(declaration, .semicolon));
}

test "block contents parser: invalid declarations retain nested recovery tokens" {
    const source = "broken value(fn(a;b), [c;d]); /**/ width:1px;";
    var tree = try Ast.parseBlockContents(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 2), children.len);
    try expectInvalidNode(tree, children[0], "broken value(fn(a;b), [c;d]);");

    const declarations = try expectContainer(
        tree,
        children[1],
        .declaration_list,
        "width",
        1,
    );
    _ = try expectContainer(tree, declarations[0], .declaration, "width", 1);
    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(Ast.Error.Tag.qualified_rule_without_block, tree.errors[0].tag);
}

test "block contents parser: invalid recovery stops before the containing brace" {
    var tree = try Ast.parseBlockContents(testing.allocator, "broken value/**/} width:1px;");
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 1), children.len);
    try expectInvalidNode(tree, children[0], "broken value/**/");
    try testing.expectEqualStrings("}", tree.tokenSlice(tree.errors[0].token));
    try testing.expectEqualStrings("broken value/**/} width:1px;", tree.nodeSlice(tree.root));
}

test "stylesheet parser: invalid and valid constructs keep source order" {
    const source = "--theme: red {} /**/ @import \"a.css\"; a {} trailing";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    const children = tree.extraChildren(tree.root);
    try testing.expectEqual(@as(usize, 4), children.len);
    try expectInvalidNode(tree, children[0], "--theme: red {}");
    _ = try expectContainer(tree, children[1], .at_rule, "@import", 2);
    _ = try expectContainer(tree, children[2], .qualified_rule, "a", 3);
    try expectInvalidNode(tree, children[3], "trailing");
    try testing.expectEqualStrings(source, tree.nodeSlice(tree.root));
}

test "stylesheet parser: ranges record explicit and implicit rule closure" {
    var explicit = try Ast.parseStylesheet(testing.allocator, "a{color:red;}");
    defer explicit.deinit(testing.allocator);
    const explicit_rule = explicit.extraChildren(explicit.root)[0];
    const explicit_block = explicit.extraChildren(explicit_rule)[1];
    try testing.expect(explicit.nodeHasClosingToken(explicit_block, .r_brace));
    try testing.expectEqualStrings("a{color:red;}", explicit.nodeSlice(explicit_rule));

    var implicit = try Ast.parseStylesheet(testing.allocator, "a{color:red");
    defer implicit.deinit(testing.allocator);
    const implicit_rule = implicit.extraChildren(implicit.root)[0];
    const implicit_block = implicit.extraChildren(implicit_rule)[1];
    const declaration_list = implicit.extraChildren(implicit_block)[0];
    const declaration = implicit.extraChildren(declaration_list)[0];
    try testing.expect(!implicit.nodeHasClosingToken(implicit_block, .r_brace));
    try testing.expect(!implicit.nodeHasClosingToken(declaration, .semicolon));
    try testing.expectEqualStrings("a{color:red", implicit.nodeSlice(implicit_rule));
}
