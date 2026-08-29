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

test "renderer: trims outer trivia and preserves semantic whitespace" {
    const source = " \n/*head*/ a  >\tb /*tail*/ \n";
    const actual = try renderComponentValues(testing.allocator, source);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "/*head*/a  >\tb/*tail*/",
        actual,
    );
}

test "renderer: formats nested functions simple blocks and commas" {
    const source = "fn(  a,b ,c,[x,y],{ z } )";
    const actual = try renderComponentValues(testing.allocator, source);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "fn(  a, b, c, [x, y], { z } )",
        actual,
    );
    try expectSameSignificantTags(source, actual);
}

test "renderer: retains comments while normalizing comma spacing" {
    const actual = try renderComponentValues(
        testing.allocator,
        "fn(a/*before*/,/*after*/b)",
    );
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "fn(a/*before*/, /*after*/ b)",
        actual,
    );
}

test "renderer: does not synthesize implicit function and block closers" {
    const cases = [_][]const u8{
        "fn(a",
        "(a",
        "[a",
        "{a",
    };

    for (cases) |source| {
        const actual = try renderComponentValues(testing.allocator, source);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(source, actual);
    }
}

test "renderer: emits every explicit simple block closer" {
    const source = "([a]{b}fn(c))";
    const actual = try renderComponentValues(testing.allocator, source);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(source, actual);
}

test "renderer: formats comma-separated roots including empty groups" {
    var tree = try Ast.parseCommaSeparatedComponentValues(
        testing.allocator,
        ",a,, b,",
    );
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(", a,, b,", actual);
}

test "renderer: renders invalid grammar groups structurally" {
    const grammar = Ast.Grammar{
        .matchFn = struct {
            fn rejectAll(_: ?*const anyopaque, _: Ast, _: []const ast.Index) bool {
                return false;
            }
        }.rejectAll,
    };
    var tree = try Ast.parseCommaSeparatedAccordingToGrammar(
        testing.allocator,
        "a,b",
        grammar,
    );
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings("a, b", actual);
}

test "renderer: preserves invalid recovery ranges exactly" {
    const source = "broken ???;";
    var tree = try Ast.parseBlockContents(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(source, actual);
}

test "renderer: handles empty whitespace-only and comment-only roots" {
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = "", .expected = "" },
        .{ .source = " \n\t ", .expected = "" },
        .{ .source = " /*one*/ \n/*two*/ ", .expected = "/*one*//*two*/" },
    };

    for (cases) |case| {
        const actual = try renderComponentValues(testing.allocator, case.source);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
    }
}

test "renderer: formats declarations with canonical semicolons" {
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = "  color : red  ; ", .expected = "color: red;" },
        .{ .source = "opacity:.5", .expected = "opacity: .5;" },
        .{ .source = "empty:;", .expected = "empty:;" },
        .{ .source = "empty:   ", .expected = "empty:;" },
        .{ .source = "empty:   ;", .expected = "empty:;" },
    };

    for (cases) |case| {
        var tree = try Ast.parseDeclaration(testing.allocator, case.source);
        defer tree.deinit(testing.allocator);
        const actual = try renderTree(testing.allocator, tree);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
    }
}

test "renderer: reconstructs important from source tokens" {
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .source = "color: red ! ImPoRtAnT  ;",
            .expected = "color: red !ImPoRtAnT;",
        },
        .{
            .source = "color:red !\\69mportant",
            .expected = "color: red !\\69mportant;",
        },
        .{
            .source = "color:!important;",
            .expected = "color: !important;",
        },
        .{
            .source = "color:red/**/!/**/important;",
            .expected = "color: red /**/ !/**/important;",
        },
    };

    for (cases) |case| {
        var tree = try Ast.parseDeclaration(testing.allocator, case.source);
        defer tree.deinit(testing.allocator);
        const actual = try renderTree(testing.allocator, tree);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
    }
}

test "renderer: formats declaration component values structurally" {
    const source = "--theme : fn(a,b),[c,d],{e,f} !important;";
    var tree = try Ast.parseDeclaration(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "--theme: fn(a, b), [c, d], {e, f} !important;",
        actual,
    );
}

test "renderer: emits declaration lists one declaration per line" {
    const source = " color:red; width : 1px ; --x:fn(a,b);";
    var tree = try Ast.parseBlockContents(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "color: red;\nwidth: 1px;\n--x: fn(a, b);",
        actual,
    );
}

test "renderer: places inter-declaration comments on their own lines" {
    const source = "color:red; /* between */ width:1px;";
    var tree = try Ast.parseBlockContents(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "color: red;\n/* between */\nwidth: 1px;",
        actual,
    );
}

test "renderer: retains invalid block contents between declaration lists" {
    const source = "color:red; broken ???; width:1px;";
    var tree = try Ast.parseBlockContents(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "color: red;\nbroken ???;\nwidth: 1px;",
        actual,
    );
}

test "renderer: preserves unicode-range tokens in declarations" {
    var tree = try Ast.parseDeclaration(
        testing.allocator,
        "unicode-range:U+0025-00FF,U+4??;",
    );
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "unicode-range: U+0025-00FF/**/, U+4??/**/;",
        actual,
    );

    var reparsed = try Ast.parseDeclaration(testing.allocator, actual);
    defer reparsed.deinit(testing.allocator);
    const declaration = reparsed.extraChildren(reparsed.root)[0];
    const values = reparsed.extraChildren(declaration);
    try testing.expectEqual(TokenTag.unicode_range, reparsed.tokenTag(
        reparsed.nodes.items(.main_token)[values[0]],
    ));
    try testing.expectEqual(TokenTag.unicode_range, reparsed.tokenTag(
        reparsed.nodes.items(.main_token)[values[3]],
    ));
}

test "renderer: declaration formatting is idempotent" {
    const source = " color:red;/* note */--x:fn(a,b)! important; width: 1px";
    var first_tree = try Ast.parseBlockContents(testing.allocator, source);
    defer first_tree.deinit(testing.allocator);
    const once = try renderTree(testing.allocator, first_tree);
    defer testing.allocator.free(once);

    var second_tree = try Ast.parseBlockContents(testing.allocator, once);
    defer second_tree.deinit(testing.allocator);
    const twice = try renderTree(testing.allocator, second_tree);
    defer testing.allocator.free(twice);

    try testing.expectEqualStrings(once, twice);
}

test "renderer: reports malformed declaration structure" {
    var tree = try Ast.parseDeclaration(testing.allocator, "color: red;");
    defer tree.deinit(testing.allocator);
    tree.tokens.items(.tag)[1] = .semicolon;
    var output: std.Io.Writer.Discarding = .init(&.{});
    try testing.expectError(
        error.MalformedDeclaration,
        printer.render(tree, &output.writer, .{}),
    );
}

test "renderer: formats qualified rules and declaration blocks" {
    const source = "a:hover,  .b >\tc{color:red;width:1px;}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "a:hover, .b > c {\n  color: red;\n  width: 1px;\n}",
        actual,
    );
    try expectSameSignificantTagsAllowingSyntheticSemicolons(source, actual);
}

test "renderer: supports terminated and EOF-terminated at-rules" {
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .source = "@import   url(theme.css) ;",
            .expected = "@import url(theme.css);",
        },
        .{ .source = "@charset \"UTF-8\"", .expected = "@charset \"UTF-8\";" },
        .{ .source = "@layer;", .expected = "@layer;" },
        .{
            .source = "@import/**/\"x.css\"/**/;",
            .expected = "@import /**/ \"x.css\"/**/;",
        },
    };

    for (cases) |case| {
        var tree = try Ast.parseStylesheet(testing.allocator, case.source);
        defer tree.deinit(testing.allocator);
        const actual = try renderTree(testing.allocator, tree);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
        try expectSameSignificantTagsAllowingSyntheticSemicolons(case.source, actual);
    }
}

test "renderer: formats block at-rules recursively" {
    const source = "@media  screen and (width >= 1px){a{color:red}}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "@media screen and (width >= 1px) {\n" ++
            "  a {\n" ++
            "    color: red;\n" ++
            "  }\n" ++
            "}",
        actual,
    );
    try expectSameSignificantTagsAllowingSyntheticSemicolons(source, actual);
}

test "renderer: separates top-level rules with blank lines" {
    const source = "@import \"theme.css\";a{}@media print{b{display:none;}}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "@import \"theme.css\";\n\n" ++
            "a {}\n\n" ++
            "@media print {\n" ++
            "  b {\n" ++
            "    display: none;\n" ++
            "  }\n" ++
            "}",
        actual,
    );
}

test "renderer: separates declarations and nested rules" {
    const source = ".card{color:red;&:hover{color:blue;}width:1px;}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        ".card {\n" ++
            "  color: red;\n\n" ++
            "  &:hover {\n" ++
            "    color: blue;\n" ++
            "  }\n\n" ++
            "  width: 1px;\n" ++
            "}",
        actual,
    );
}

test "renderer: compacts whitespace-only blocks and expands comment-only blocks" {
    const source = "a { \n } b{/* only */}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "a {}\n\nb {\n  /* only */\n}",
        actual,
    );
}

test "renderer: indents leading and trailing block comments" {
    const source = "a{/* lead */color:red;/* tail */}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "a {\n" ++
            "  /* lead */\n" ++
            "  color: red;\n" ++
            "  /* tail */\n" ++
            "}",
        actual,
    );
}

test "renderer: synthesizes optional semicolons but not closing delimiters" {
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = "a{color:red", .expected = "a {\n  color: red;" },
        .{
            .source = "@media screen{a{color:red",
            .expected = "@media screen {\n  a {\n    color: red;",
        },
        .{ .source = "@import \"x.css\"", .expected = "@import \"x.css\";" },
    };

    for (cases) |case| {
        var tree = try Ast.parseStylesheet(testing.allocator, case.source);
        defer tree.deinit(testing.allocator);
        const actual = try renderTree(testing.allocator, tree);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
    }
}

test "renderer: places synthetic semicolons after trailing inline comments" {
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .source = "a{color:red/* value */}",
            .expected = "a {\n  color: red/* value */;\n}",
        },
        .{
            .source = "@charset \"UTF-8\"/* encoding */",
            .expected = "@charset \"UTF-8\"/* encoding */;",
        },
    };

    for (cases) |case| {
        var tree = try Ast.parseStylesheet(testing.allocator, case.source);
        defer tree.deinit(testing.allocator);
        const actual = try renderTree(testing.allocator, tree);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case.expected, actual);
    }
}

test "renderer: retains invalid nodes around valid stylesheet rules" {
    const source = "--theme:red{} /**/ @import \"a.css\"; a{} trailing";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "--theme:red{}\n\n/**/\n\n" ++
            "@import \"a.css\";\n\n" ++
            "a {}\n\n" ++
            "trailing",
        actual,
    );
}

test "renderer: formats keyframe rule blocks without at-rule special cases" {
    const source = "@keyframes fade{from{opacity:0}50%,to{opacity:1}}";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "@keyframes fade {\n" ++
            "  from {\n" ++
            "    opacity: 0;\n" ++
            "  }\n\n" ++
            "  50%, to {\n" ++
            "    opacity: 1;\n" ++
            "  }\n" ++
            "}",
        actual,
    );
}

test "renderer: keeps comments on their syntactic side of synthetic semicolons" {
    const source =
        "/* head */a{color:/* before */red/* value */;" ++
        "/* between */width:1px}/* tail */";
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const actual = try renderTree(testing.allocator, tree);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(
        "/* head */\n" ++
            "a {\n" ++
            "  color: /* before */ red/* value */;\n" ++
            "  /* between */\n" ++
            "  width: 1px;\n" ++
            "}\n" ++
            "/* tail */",
        actual,
    );
}

test "renderer: applies configured indentation throughout rule blocks" {
    var tree = try Ast.parseStylesheet(
        testing.allocator,
        "@media screen{a{color:red;}}",
    );
    defer tree.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try printer.render(tree, &output.writer, .{ .indent_width = 4 });

    try testing.expectEqualStrings(
        "@media screen {\n" ++
            "    a {\n" ++
            "        color: red;\n" ++
            "    }\n" ++
            "}",
        output.written(),
    );
}

test "renderer: stylesheet formatting is idempotent" {
    const source = "@import \"x.css\";.card{color:red;&:hover{color:blue}}";
    var first_tree = try Ast.parseStylesheet(testing.allocator, source);
    defer first_tree.deinit(testing.allocator);
    const once = try renderTree(testing.allocator, first_tree);
    defer testing.allocator.free(once);

    var second_tree = try Ast.parseStylesheet(testing.allocator, once);
    defer second_tree.deinit(testing.allocator);
    const twice = try renderTree(testing.allocator, second_tree);
    defer testing.allocator.free(twice);

    try testing.expectEqualStrings(once, twice);
}

test "renderer: reports a qualified rule without a structural block" {
    var tree = try Ast.parseStylesheet(testing.allocator, "a{}");
    defer tree.deinit(testing.allocator);
    const rule = tree.extraChildren(tree.root)[0];
    const block = tree.extraChildren(rule)[1];
    tree.nodes.items(.tag)[block] = .simple_block_brace;
    var output: std.Io.Writer.Discarding = .init(&.{});

    try testing.expectError(
        error.MalformedRule,
        printer.render(tree, &output.writer, .{}),
    );
}

test "renderer: propagates downstream failures" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a");
    defer tree.deinit(testing.allocator);
    var downstream: std.Io.Writer = .failing;

    try testing.expectError(
        error.WriteFailed,
        printer.render(tree, &downstream, .{}),
    );
}

test "renderer: component-value formatting is idempotent" {
    const source = " fn(a,b , [c,d],{ e,f }) ";
    const once = try renderComponentValues(testing.allocator, source);
    defer testing.allocator.free(once);
    const twice = try renderComponentValues(testing.allocator, once);
    defer testing.allocator.free(twice);

    try testing.expectEqualStrings("fn(a, b, [c, d], { e, f })", once);
    try testing.expectEqualStrings(once, twice);
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

test "token serializer: emits trivia separately from its following token" {
    const source = "a /*one*/ b";
    var tree = try Ast.parseComponentValues(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);

    try serializer.emitToken(tokens[0], .newline);
    try serializer.emitTriviaUntil(tokens[1]);
    try serializer.emitToken(tokens[1], .none);
    try serializer.finish();

    try testing.expectEqualStrings("a\n/*one*/\nb", output.written());
}

test "token serializer: trivia emission validates ordering and source gaps" {
    var tree = try Ast.parseComponentValues(testing.allocator, "a x b");
    defer tree.deinit(testing.allocator);
    const tokens = try significantTokens(tree, testing.allocator);
    defer testing.allocator.free(tokens);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var serializer: TokenSerializer = .init(tree, &output.writer);

    try serializer.emitToken(tokens[0], .none);
    try testing.expectError(
        error.UnhandledToken,
        serializer.emitTriviaUntil(tokens[2]),
    );
    try testing.expectError(
        error.OutOfOrderToken,
        serializer.emitTriviaUntil(tokens[0]),
    );
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

fn renderComponentValues(
    allocator: Allocator,
    source: []const u8,
) ![]u8 {
    var tree = try Ast.parseComponentValues(allocator, source);
    defer tree.deinit(allocator);
    return renderTree(allocator, tree);
}

fn renderTree(allocator: Allocator, tree: Ast) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try printer.render(tree, &output.writer, .{});
    return output.toOwnedSlice();
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

fn expectSameSignificantTagsAllowingSyntheticSemicolons(
    source: []const u8,
    formatted: []const u8,
) !void {
    var source_tokenizer: Tokenizer = .init(source);
    var formatted_tokenizer: Tokenizer = .init(formatted);
    var source_token = nextSignificant(&source_tokenizer);
    var formatted_token = nextSignificant(&formatted_tokenizer);

    while (true) {
        if (formatted_token.tag == .semicolon and source_token.tag != .semicolon) {
            formatted_token = nextSignificant(&formatted_tokenizer);
            continue;
        }

        try testing.expectEqual(source_token.tag, formatted_token.tag);
        if (source_token.tag == .eof) return;
        source_token = nextSignificant(&source_tokenizer);
        formatted_token = nextSignificant(&formatted_tokenizer);
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
