const std = @import("std");
const testing = std.testing;

const ast = @import("ast.zig");
const Ast = ast.Ast;
const printer = @import("printer.zig");
const corpus = @import("corpus");

const Fixture = struct {
    name: []const u8,
    source: []const u8,
    has_errors: bool = false,
};

const fixtures = [_]Fixture{
    .{ .name = "selectors", .source = corpus.selectors },
    .{ .name = "at-rules", .source = corpus.at_rules },
    .{ .name = "nesting", .source = corpus.nesting },
    .{ .name = "values", .source = corpus.values },
    .{ .name = "comments", .source = corpus.comments },
    .{
        .name = "recovery",
        .source = corpus.recovery,
        .has_errors = true,
    },
};

test "corpus: formatting is idempotent" {
    for (fixtures) |fixture| {
        const once = formatStylesheet(fixture.source) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
        defer testing.allocator.free(once);

        const twice = formatStylesheet(once) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
        defer testing.allocator.free(twice);

        testing.expectEqualStrings(once, twice) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
    }
}

test "corpus: formatting preserves significant AST tokens" {
    for (fixtures) |fixture| {
        const formatted = formatStylesheet(fixture.source) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
        defer testing.allocator.free(formatted);

        expectSameSignificantTokens(fixture.source, formatted) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
    }
}

test "corpus: formatting preserves diagnostics and recovery ranges" {
    for (fixtures) |fixture| {
        const formatted = formatStylesheet(fixture.source) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
        defer testing.allocator.free(formatted);

        expectStableRecovery(fixture, formatted) catch |err| {
            reportFixture(fixture.name);
            return err;
        };
    }
}

fn formatStylesheet(source: []const u8) ![]u8 {
    var tree = try Ast.parseStylesheet(testing.allocator, source);
    defer tree.deinit(testing.allocator);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    try printer.render(tree, &output.writer, .{});

    return output.toOwnedSlice();
}

fn expectSameSignificantTokens(before: []const u8, after: []const u8) !void {
    var before_tree = try Ast.parseStylesheet(testing.allocator, before);
    defer before_tree.deinit(testing.allocator);
    var after_tree = try Ast.parseStylesheet(testing.allocator, after);
    defer after_tree.deinit(testing.allocator);

    var before_cursor: usize = 0;
    var after_cursor: usize = 0;
    while (true) {
        const before_token = nextSignificantToken(before_tree, &before_cursor);
        const after_token = nextSignificantToken(after_tree, &after_cursor);
        try testing.expectEqual(before_token != null, after_token != null);

        if (before_token == null) {
            return;
        }

        try testing.expectEqual(
            before_tree.tokenTag(before_token.?),
            after_tree.tokenTag(after_token.?),
        );
        try testing.expectEqualStrings(
            before_tree.tokenSlice(before_token.?),
            after_tree.tokenSlice(after_token.?),
        );
    }
}

fn expectStableRecovery(fixture: Fixture, formatted: []const u8) !void {
    var before = try Ast.parseStylesheet(testing.allocator, fixture.source);
    defer before.deinit(testing.allocator);
    var after = try Ast.parseStylesheet(testing.allocator, formatted);
    defer after.deinit(testing.allocator);

    if (fixture.has_errors) {
        try testing.expect(before.errors.len != 0);
    } else {
        try testing.expectEqual(@as(usize, 0), before.errors.len);
    }

    try testing.expectEqual(before.errors.len, after.errors.len);
    for (before.errors, after.errors) |before_error, after_error| {
        try testing.expectEqual(before_error.tag, after_error.tag);
    }

    var before_cursor: usize = 0;
    var after_cursor: usize = 0;
    while (true) {
        const before_invalid = nextInvalidNode(before, &before_cursor);
        const after_invalid = nextInvalidNode(after, &after_cursor);
        try testing.expectEqual(before_invalid != null, after_invalid != null);

        if (before_invalid == null) {
            return;
        }

        try testing.expectEqualStrings(
            before.nodeSlice(before_invalid.?),
            after.nodeSlice(after_invalid.?),
        );
    }
}

fn nextSignificantToken(tree: Ast, cursor: *usize) ?ast.TokenIndex {
    while (cursor.* < tree.tokens.len) {
        const token: ast.TokenIndex = @intCast(cursor.*);
        cursor.* += 1;
        switch (tree.tokenTag(token)) {
            .whitespace, .comment, .eof => continue,
            else => return token,
        }
    }

    return null;
}

fn nextInvalidNode(tree: Ast, cursor: *usize) ?ast.Index {
    const tags = tree.nodes.items(.tag);
    while (cursor.* < tree.nodes.len) {
        const node: ast.Index = @intCast(cursor.*);
        cursor.* += 1;

        if (tags[node] == .invalid) {
            return node;
        }
    }

    return null;
}

fn reportFixture(name: []const u8) void {
    std.debug.print("corpus fixture: {s}\n", .{name});
}
