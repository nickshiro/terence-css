const std = @import("std");
const testing = std.testing;

const terence_css = @import("terence_css");

test "public API: parses a stylesheet and borrows its source" {
    const source = "a { color: red; }";
    var tree = try terence_css.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(source.ptr, tree.source.ptr);
    try testing.expectEqual(source.len, tree.source.len);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    try testing.expectEqual(@as(usize, 1), tree.extraChildren(tree.root).len);
    try testing.expectEqual(
        terence_css.Node.Tag.qualified_rule,
        tree.nodes.items(.tag)[tree.extraChildren(tree.root)[0]],
    );
}

test "public API: exposes parser diagnostics on the AST" {
    var tree = try terence_css.parseStylesheet(testing.allocator, "a");
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqual(
        terence_css.Ast.Error.Tag.qualified_rule_without_block,
        tree.errors[0].tag,
    );
}

test "public API: renders an AST without adding a final newline" {
    var tree = try terence_css.parseStylesheet(testing.allocator, "a{color:red}");
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try terence_css.render(tree, &output.writer, .{});

    try testing.expectEqualStrings("a {\n  color: red\n}", output.written());
}

test "public API: formats recovered CSS and ensures a final newline by default" {
    const formatted = try terence_css.formatStylesheetAlloc(
        testing.allocator,
        "a",
        .{},
    );
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("a\n", formatted);
}

test "public API: supports indentation and final-newline options" {
    const formatted = try terence_css.formatStylesheetAlloc(
        testing.allocator,
        "a{color:red}",
        .{
            .indent_width = 4,
            .final_newline = false,
        },
    );
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("a {\n    color: red\n}", formatted);
}

test "public API: writes formatted CSS to an arbitrary writer" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    try terence_css.formatStylesheet(
        testing.allocator,
        "a{color:red}",
        &output.writer,
        .{},
    );

    try testing.expectEqualStrings("a {\n  color: red\n}\n", output.written());
}

test "public API: strict mode rejects parser diagnostics before writing" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    try testing.expectError(
        error.InvalidCss,
        terence_css.formatStylesheet(
            testing.allocator,
            "a",
            &output.writer,
            .{ .error_mode = .strict },
        ),
    );
    try testing.expectEqual(@as(usize, 0), output.written().len);
}

test "public API: propagates destination writer failures" {
    var writer: std.Io.Writer = .failing;
    try testing.expectError(
        error.WriteFailed,
        terence_css.formatStylesheet(
            testing.allocator,
            "a{}",
            &writer,
            .{},
        ),
    );
}

test "public API: formatting releases every allocation on failure" {
    const source = "@media screen { a { color: red; } }";

    var baseline = testing.FailingAllocator.init(testing.allocator, .{});
    const baseline_allocator = baseline.allocator();
    const formatted = try terence_css.formatStylesheetAlloc(
        baseline_allocator,
        source,
        .{},
    );
    baseline_allocator.free(formatted);

    for (0..baseline.alloc_index) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing.allocator();

        if (terence_css.formatStylesheetAlloc(allocator, source, .{})) |result| {
            allocator.free(result);
            try testing.expect(!failing.has_induced_failure);
        } else |err| {
            try testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try testing.expect(failing.has_induced_failure);
        }

        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
