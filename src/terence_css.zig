//! Public API for parsing and formatting CSS.
//!
//! An `Ast` owns its tokens, nodes, extra data, and diagnostics, but borrows
//! the source passed to `parseStylesheet`. The source must therefore remain
//! alive until the AST is deinitialized.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const ast = @import("ast.zig");
const printer = @import("printer.zig");

pub const Ast = ast.Ast;
pub const Index = ast.Index;
pub const Node = ast.Node;
pub const TokenIndex = ast.TokenIndex;
pub const TokenRange = ast.TokenRange;
pub const TokenTag = ast.TokenTag;

pub const ErrorMode = enum {
    /// Preserve malformed input through the parser's recovery nodes.
    recover,
    /// Reject a stylesheet when parsing produced one or more diagnostics.
    strict,
};

pub const FormatOptions = struct {
    indent_width: usize = 2,
    final_newline: bool = true,
    error_mode: ErrorMode = .recover,
};

pub const RenderOptions = struct {
    indent_width: usize = 2,
};

/// Parses a complete stylesheet. The returned AST borrows `source` and must be
/// released with `Ast.deinit` using the same allocator.
pub fn parseStylesheet(allocator: Allocator, source: []const u8) !Ast {
    return Ast.parseStylesheet(allocator, source);
}

/// Renders an already parsed AST. Unlike `formatStylesheet`, this low-level
/// operation does not add a terminal newline or inspect parser diagnostics.
pub fn render(
    tree: Ast,
    writer: *Writer,
    options: RenderOptions,
) printer.RenderError!void {
    return printer.render(tree, writer, .{
        .indent_width = options.indent_width,
    });
}

/// Parses and formats a stylesheet into `writer`.
pub fn formatStylesheet(
    allocator: Allocator,
    source: []const u8,
    writer: *Writer,
    options: FormatOptions,
) !void {
    const formatted = try formatStylesheetAlloc(allocator, source, options);
    defer allocator.free(formatted);
    try writer.writeAll(formatted);
}

/// Parses and formats a stylesheet into a caller-owned allocation.
pub fn formatStylesheetAlloc(
    allocator: Allocator,
    source: []const u8,
    options: FormatOptions,
) ![]u8 {
    var tree = try parseStylesheet(allocator, source);
    defer tree.deinit(allocator);

    if (options.error_mode == .strict and tree.errors.len != 0) {
        return error.InvalidCss;
    }

    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try render(tree, &output.writer, .{
        .indent_width = options.indent_width,
    });

    if (options.final_newline and
        (output.written().len == 0 or output.written()[output.written().len - 1] != '\n'))
    {
        try output.writer.writeByte('\n');
    }

    return output.toOwnedSlice();
}
