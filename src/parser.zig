const std = @import("std");
const Allocator = std.mem.Allocator;

const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const TokenTag = tokenizer.Token.Tag;

const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;
const Index = ast.Index;
const TokenIndex = ast.TokenIndex;

const SourceRange = struct {
    start: u32,
    end: u32,
};

/// §5.4.1: Parses component values and matches them against a caller-supplied
/// CSS grammar production. A mismatch produces an empty root and an error.
pub fn parseAccordingToGrammar(
    gpa: Allocator,
    source: []const u8,
    grammar: Ast.Grammar,
) !Ast {
    var tree = try parseComponentValues(gpa, source);
    errdefer tree.deinit(gpa);

    if (!grammar.matches(tree, tree.extraChildren(tree.root))) {
        try setGrammarFailure(gpa, &tree);
    }

    return tree;
}

/// §5.4.2: Parses top-level comma-separated component-value groups and matches
/// each group independently. Failed items use .component_value_list_invalid.
pub fn parseCommaSeparatedAccordingToGrammar(
    gpa: Allocator,
    source: []const u8,
    grammar: Ast.Grammar,
) !Ast {
    var tree = try parseCommaSeparatedComponentValues(gpa, source);

    const root_children = tree.extraChildren(tree.root);
    if (root_children.len == 1 and
        valuesContainOnlyTrivia(tree, tree.extraChildren(root_children[0])))
    {
        tree.nodes.items(.data)[tree.root] = .{};
        return tree;
    }

    const tags = tree.nodes.items(.tag);
    for (root_children) |group| {
        if (!grammar.matches(tree, tree.extraChildren(group))) {
            tags[group] = .component_value_list_invalid;
        }
    }

    return tree;
}

fn setGrammarFailure(gpa: Allocator, tree: *Ast) !void {
    const old_errors = tree.errors;
    const errors = try gpa.alloc(Ast.Error, old_errors.len + 1);
    @memcpy(errors[0..old_errors.len], old_errors);
    errors[old_errors.len] = .{
        .tag = .grammar_mismatch,
        .token = firstSignificantToken(tree.*),
    };

    gpa.free(old_errors);
    tree.errors = errors;
    tree.nodes.items(.data)[tree.root] = .{};
}

fn firstSignificantToken(tree: Ast) TokenIndex {
    const tags = tree.tokens.items(.tag);
    var token: TokenIndex = 0;
    while (tags[token] == .whitespace or tags[token] == .comment) {
        token += 1;
    }

    return token;
}

fn valuesContainOnlyTrivia(tree: Ast, values: []const Index) bool {
    for (values) |value| {
        if (tree.nodes.items(.tag)[value] != .token) {
            return false;
        }

        const token = tree.nodes.items(.main_token)[value];
        const tag = tree.tokenTag(token);
        if (tag != .whitespace and tag != .comment) {
            return false;
        }
    }

    return true;
}

/// Parses exactly one component value (§5.4.8). Empty input or significant
/// input after the value produces an empty root and a parser error.
pub fn parseComponentValue(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .component_value);
}

/// Tokenizes the entire source and builds a component-value tree (§5.4.9 and
/// §5.5.7, "Parse a list of component values"). This generic layer knows nothing
/// about rules, declarations, or selectors; it only groups brackets and
/// functions. Grammars for specific constructs are built on top of this tree
/// in a separate pass.
pub fn parseComponentValues(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .component_values);
}

/// Parses top-level comma-separated groups of component values (§5.4.10).
/// Separating commas are not included in the returned groups.
pub fn parseCommaSeparatedComponentValues(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .comma_separated_component_values);
}

/// Parses a stylesheet into top-level at-rules and qualified rules (§5.4.3 and
/// §5.5.1). Each rule block contains nested rules and declaration lists.
pub fn parseStylesheet(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .stylesheet);
}

/// Parses the contents of an existing stylesheet (§5.4.4). This project does
/// not model CSSOM location metadata, so it shares the stylesheet AST builder.
pub fn parseStylesheetContents(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .stylesheet);
}

/// Parses block contents into nested rules and declaration lists (§5.4.5).
/// The source excludes the surrounding braces.
pub fn parseBlockContents(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .block_contents);
}

/// Parses exactly one rule (§5.4.6). Empty input, an invalid rule, or
/// significant input after the rule produces an empty root and a parser error.
pub fn parseRule(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .rule);
}

/// Parses one declaration (§5.4.7) and returns it as the root's only child.
/// Invalid input produces an empty root and a parser error.
pub fn parseDeclaration(gpa: Allocator, source: []const u8) !Ast {
    return parse(gpa, source, .declaration);
}

const ParseMode = enum {
    component_value,
    component_values,
    comma_separated_component_values,
    stylesheet,
    block_contents,
    rule,
    declaration,
};

fn parse(gpa: Allocator, source: []const u8, mode: ParseMode) !Ast {
    var unicode_range_intervals: std.ArrayListUnmanaged(SourceRange) = .empty;
    defer unicode_range_intervals.deinit(gpa);

    var result = try parsePass(
        gpa,
        source,
        mode,
        &unicode_range_intervals,
        &.{},
    );
    if (unicode_range_intervals.items.len == 0) {
        return result;
    }

    result.deinit(gpa);
    return parsePass(
        gpa,
        source,
        mode,
        null,
        unicode_range_intervals.items,
    );
}

fn parsePass(
    gpa: Allocator,
    source: []const u8,
    mode: ParseMode,
    discovered_unicode_ranges: ?*std.ArrayListUnmanaged(SourceRange),
    unicode_range_intervals: []const SourceRange,
) !Ast {
    var tokens: Ast.TokenList = .empty;
    errdefer tokens.deinit(gpa);

    var tzer = Tokenizer.init(source);
    var interval_index: usize = 0;
    while (true) {
        while (interval_index < unicode_range_intervals.len and
            tzer.index >= unicode_range_intervals[interval_index].end)
        {
            interval_index += 1;
        }

        var unicode_ranges_allowed = false;
        if (interval_index < unicode_range_intervals.len) {
            const interval = unicode_range_intervals[interval_index];
            unicode_ranges_allowed = tzer.index >= interval.start and
                tzer.index < interval.end;
        }
        tzer.setUnicodeRangesAllowed(unicode_ranges_allowed);

        const token = tzer.next();

        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(token.loc.start),
            .end = @intCast(token.loc.end),
        });

        if (token.tag == .eof) {
            break;
        }
    }

    var parser = Parser{
        .gpa = gpa,
        .source = source,
        .tok_tags = tokens.items(.tag),
        .tok_starts = tokens.items(.start),
        .tok_ends = tokens.items(.end),
        .tok_i = 0,
        .nodes = .empty,
        .extra_data = .empty,
        .errors = .empty,
        .scratch = .empty,
        .decl_scratch = .empty,
        .discovered_unicode_ranges = discovered_unicode_ranges,
    };
    errdefer parser.nodes.deinit(gpa);
    errdefer parser.extra_data.deinit(gpa);
    errdefer parser.errors.deinit(gpa);
    defer parser.scratch.deinit(gpa);
    defer parser.decl_scratch.deinit(gpa);

    const root_index = switch (mode) {
        .component_value => try parser.parseComponentValueEntry(),
        .component_values => try parser.consumeComponentValueList(),
        .comma_separated_component_values => try parser.parseCommaSeparatedComponentValuesEntry(),
        .stylesheet => try parser.consumeStylesheetContents(),
        .block_contents => try parser.parseBlockContentsEntry(),
        .rule => try parser.parseRuleEntry(),
        .declaration => try parser.parseDeclarationEntry(),
    };
    const extra_data = try parser.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);
    const errors = try parser.errors.toOwnedSlice(gpa);
    errdefer gpa.free(errors);

    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = errors,
        .root = root_index,
    };
}

const Parser = struct {
    gpa: Allocator,
    source: []const u8,
    tok_tags: []const TokenTag,
    tok_starts: []const u32,
    tok_ends: []const u32,
    tok_i: TokenIndex,

    nodes: Ast.NodeList,
    extra_data: std.ArrayListUnmanaged(Index),
    errors: std.ArrayListUnmanaged(Ast.Error),

    /// shared buffer for collecting child lists during recursion. This is the
    /// same technique std.zig.Parser uses for statement and parameter lists:
    /// nested calls append to the shared buffer and trim their portion on exit
    /// instead of allocating a separate ArrayList for each node.
    scratch: std.ArrayListUnmanaged(Index),

    /// Declarations are collected separately until a rule boundary turns them
    /// into one declaration_list node.
    decl_scratch: std.ArrayListUnmanaged(Index),

    /// Value source ranges that must be retokenized with unicode ranges enabled.
    /// This is non-null only during the discovery pass.
    discovered_unicode_ranges: ?*std.ArrayListUnmanaged(SourceRange),

    const Mark = struct {
        tok_i: TokenIndex,
        nodes_len: usize,
        extra_data_len: usize,
        errors_len: usize,
    };

    fn mark(self: *Parser) Mark {
        return .{
            .tok_i = self.tok_i,
            .nodes_len = self.nodes.len,
            .extra_data_len = self.extra_data.items.len,
            .errors_len = self.errors.items.len,
        };
    }

    fn restore(self: *Parser, checkpoint: Mark) void {
        self.tok_i = checkpoint.tok_i;
        self.nodes.shrinkRetainingCapacity(checkpoint.nodes_len);
        self.extra_data.shrinkRetainingCapacity(checkpoint.extra_data_len);
        self.errors.shrinkRetainingCapacity(checkpoint.errors_len);
    }

    fn addError(self: *Parser, tag: Ast.Error.Tag) error{OutOfMemory}!void {
        try self.addErrorAt(tag, self.tok_i);
    }

    fn addErrorAt(
        self: *Parser,
        tag: Ast.Error.Tag,
        token: TokenIndex,
    ) error{OutOfMemory}!void {
        try self.errors.append(self.gpa, .{
            .tag = tag,
            .token = token,
        });
    }

    fn addNode(self: *Parser, node: Node) error{OutOfMemory}!Index {
        const result: Index = @intCast(self.nodes.len);
        try self.nodes.append(self.gpa, node);

        return result;
    }

    fn addTokenNode(self: *Parser, token: TokenIndex) error{OutOfMemory}!Index {
        return self.addNode(.{ .tag = .token, .main_token = token, .data = .{} });
    }

    fn addExtraChildren(self: *Parser, children: []const Index) error{OutOfMemory}!Node.Data {
        const start: Index = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.gpa, children);
        const end: Index = @intCast(self.extra_data.items.len);

        return .{ .lhs = start, .rhs = end };
    }

    fn tokenSlice(self: *Parser, token: TokenIndex) []const u8 {
        return self.source[self.tok_starts[token]..self.tok_ends[token]];
    }

    fn discardNodesSince(self: *Parser, nodes_top: usize, extra_data_top: usize) void {
        self.nodes.shrinkRetainingCapacity(nodes_top);
        self.extra_data.shrinkRetainingCapacity(extra_data_top);
    }

    /// Returns the current token index and advances the cursor. At EOF, the
    /// cursor remains in place so outer loops can repeatedly check their stop
    /// condition.
    fn advance(self: *Parser) TokenIndex {
        const i = self.tok_i;

        if (self.tok_tags[i] != .eof) {
            self.tok_i += 1;
        }

        return i;
    }

    /// §5.5.7: Consume a list of component values.
    fn consumeComponentValueList(self: *Parser) error{OutOfMemory}!Index {
        const data = try self.consumeComponentValues(null);
        return self.addNode(.{ .tag = .root, .main_token = 0, .data = data });
    }

    fn consumeComponentValues(self: *Parser, stop_tag: ?TokenTag) error{OutOfMemory}!Node.Data {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const tag = self.tok_tags[self.tok_i];
            if (tag == .eof) {
                break;
            }

            if (stop_tag) |stop| {
                if (tag == stop) {
                    break;
                }
            }

            if (tag == .r_brace) {
                try self.addError(.unexpected_closing_brace);
            }

            const value = try self.consumeComponentValue();
            try self.scratch.append(self.gpa, value);
        }

        return self.addExtraChildren(self.scratch.items[scratch_top..]);
    }

    /// §5.4.10: Parse a comma-separated list of component values.
    fn parseCommaSeparatedComponentValuesEntry(
        self: *Parser,
    ) error{OutOfMemory}!Index {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (self.tok_tags[self.tok_i] != .eof) {
            const data = try self.consumeComponentValues(.comma);
            const group = try self.addNode(.{
                .tag = .component_value_list,
                .main_token = 0,
                .data = data,
            });
            try self.scratch.append(self.gpa, group);

            if (self.tok_tags[self.tok_i] == .comma) {
                _ = self.advance();
            }
        }

        return self.addRoot(self.scratch.items[scratch_top..]);
    }

    /// §5.4.8: Parse a component value.
    fn parseComponentValueEntry(self: *Parser) error{OutOfMemory}!Index {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        self.discardWhitespace();
        if (self.tok_tags[self.tok_i] == .eof) {
            try self.addError(.expected_component_value);
            return self.addRoot(self.scratch.items[scratch_top..]);
        }

        const nodes_top = self.nodes.len;
        const extra_data_top = self.extra_data.items.len;
        const value = try self.consumeComponentValue();

        self.discardWhitespace();
        if (self.tok_tags[self.tok_i] != .eof) {
            try self.addError(.unexpected_input_after_component_value);
            self.discardNodesSince(nodes_top, extra_data_top);
            return self.addRoot(self.scratch.items[scratch_top..]);
        }

        try self.scratch.append(self.gpa, value);
        return self.addRoot(self.scratch.items[scratch_top..]);
    }

    /// §5.5.1: Consume a stylesheet's contents.
    fn consumeStylesheetContents(self: *Parser) error{OutOfMemory}!Index {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            switch (self.tok_tags[self.tok_i]) {
                .whitespace, .comment, .cdo, .cdc => {
                    _ = self.advance();
                },
                .eof => break,
                .at_keyword => {
                    const rule = try self.consumeAtRule(false);
                    try self.scratch.append(self.gpa, rule);
                },
                else => {
                    switch (try self.consumeQualifiedRule(null, false)) {
                        .rule => |rule| {
                            try self.scratch.append(self.gpa, rule);
                        },
                        .nothing, .invalid => {},
                    }
                },
            }
        }

        const data = try self.addExtraChildren(self.scratch.items[scratch_top..]);
        return self.addNode(.{ .tag = .root, .main_token = 0, .data = data });
    }

    fn parseBlockContentsEntry(self: *Parser) error{OutOfMemory}!Index {
        const data = try self.consumeBlockContents();
        return self.addNode(.{ .tag = .root, .main_token = 0, .data = data });
    }

    /// §5.4.6: Parse a rule.
    fn parseRuleEntry(self: *Parser) error{OutOfMemory}!Index {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        self.discardWhitespace();
        const first_token = self.tok_i;
        if (self.tok_tags[self.tok_i] == .eof) {
            try self.addError(.expected_rule);
            return self.addRoot(self.scratch.items[scratch_top..]);
        }

        const nodes_top = self.nodes.len;
        const extra_data_top = self.extra_data.items.len;
        var rule: ?Index = null;
        if (self.tok_tags[self.tok_i] == .at_keyword) {
            rule = try self.consumeAtRule(false);
        } else {
            switch (try self.consumeQualifiedRule(null, false)) {
                .rule => |parsed_rule| {
                    rule = parsed_rule;
                },
                .nothing => {
                    try self.addErrorAt(.expected_rule, first_token);
                },
                .invalid => {},
            }
        }

        if (rule == null) {
            self.discardNodesSince(nodes_top, extra_data_top);
            return self.addRoot(self.scratch.items[scratch_top..]);
        }

        self.discardWhitespace();
        if (self.tok_tags[self.tok_i] != .eof) {
            try self.addError(.unexpected_input_after_rule);
            self.discardNodesSince(nodes_top, extra_data_top);
            return self.addRoot(self.scratch.items[scratch_top..]);
        }

        try self.scratch.append(self.gpa, rule.?);
        return self.addRoot(self.scratch.items[scratch_top..]);
    }

    fn addRoot(self: *Parser, children: []const Index) error{OutOfMemory}!Index {
        const data = try self.addExtraChildren(children);
        return self.addNode(.{ .tag = .root, .main_token = 0, .data = data });
    }

    /// §5.4.7: Parse a declaration.
    fn parseDeclarationEntry(self: *Parser) error{OutOfMemory}!Index {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        self.discardWhitespace();
        if (try self.consumeDeclaration(false)) |declaration| {
            try self.scratch.append(self.gpa, declaration);
        }

        const data = try self.addExtraChildren(self.scratch.items[scratch_top..]);
        return self.addNode(.{ .tag = .root, .main_token = 0, .data = data });
    }

    /// §5.5.2: Consume an at-rule.
    fn consumeAtRule(self: *Parser, nested: bool) error{OutOfMemory}!Index {
        const at_token = self.advance();
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            switch (self.tok_tags[self.tok_i]) {
                .semicolon => {
                    _ = self.advance();
                    break;
                },
                .eof => break,
                .r_brace => {
                    if (nested) {
                        break;
                    }

                    const token = self.advance();
                    const node = try self.addTokenNode(token);
                    try self.scratch.append(self.gpa, node);
                },
                .l_brace => {
                    const block = try self.consumeBlock();
                    try self.scratch.append(self.gpa, block);
                    break;
                },
                else => {
                    const value = try self.consumeComponentValue();
                    try self.scratch.append(self.gpa, value);
                },
            }
        }

        const data = try self.addExtraChildren(self.scratch.items[scratch_top..]);
        return self.addNode(.{ .tag = .at_rule, .main_token = at_token, .data = data });
    }

    const QualifiedRuleResult = union(enum) {
        rule: Index,
        nothing,
        invalid,
    };

    /// §5.5.3: Consume a qualified rule.
    fn consumeQualifiedRule(
        self: *Parser,
        stop_tag: ?TokenTag,
        nested: bool,
    ) error{OutOfMemory}!QualifiedRuleResult {
        const main_token = self.tok_i;
        const nodes_top = self.nodes.len;
        const extra_data_top = self.extra_data.items.len;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const current_tag = self.tok_tags[self.tok_i];
            if (current_tag == .eof or current_tag == stop_tag) {
                try self.addError(.qualified_rule_without_block);
                self.discardNodesSince(nodes_top, extra_data_top);
                return .invalid;
            }

            switch (current_tag) {
                .r_brace => {
                    try self.addError(.unexpected_closing_brace);
                    if (nested) {
                        self.discardNodesSince(nodes_top, extra_data_top);
                        return .nothing;
                    }

                    const token = self.advance();
                    const node = try self.addTokenNode(token);
                    try self.scratch.append(self.gpa, node);
                },
                .l_brace => {
                    if (self.startsLikeCustomProperty(self.scratch.items[scratch_top..])) {
                        if (nested) {
                            try self.consumeBadDeclaration(true);
                        } else {
                            _ = try self.consumeBlock();
                        }

                        self.discardNodesSince(nodes_top, extra_data_top);
                        return .nothing;
                    }

                    const block = try self.consumeBlock();
                    try self.scratch.append(self.gpa, block);
                    const data = try self.addExtraChildren(self.scratch.items[scratch_top..]);
                    const rule = try self.addNode(.{
                        .tag = .qualified_rule,
                        .main_token = main_token,
                        .data = data,
                    });
                    return .{ .rule = rule };
                },
                else => {
                    const value = try self.consumeComponentValue();
                    try self.scratch.append(self.gpa, value);
                },
            }
        }
    }

    /// §5.5.4: Consume a block.
    fn consumeBlock(self: *Parser) error{OutOfMemory}!Index {
        const open_token = self.advance();
        const data = try self.consumeBlockContents();

        if (self.tok_tags[self.tok_i] == .r_brace) {
            _ = self.advance();
        }

        return self.addNode(.{
            .tag = .block,
            .main_token = open_token,
            .data = data,
        });
    }

    /// §5.5.5: Consume a block's contents.
    fn consumeBlockContents(self: *Parser) error{OutOfMemory}!Node.Data {
        const scratch_top = self.scratch.items.len;
        const declarations_top = self.decl_scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        defer self.decl_scratch.shrinkRetainingCapacity(declarations_top);

        while (true) {
            switch (self.tok_tags[self.tok_i]) {
                .whitespace, .comment, .semicolon => {
                    _ = self.advance();
                },
                .eof, .r_brace => {
                    try self.flushDeclarations(declarations_top);
                    return self.addExtraChildren(self.scratch.items[scratch_top..]);
                },
                .at_keyword => {
                    try self.flushDeclarations(declarations_top);
                    const rule = try self.consumeAtRule(true);
                    try self.scratch.append(self.gpa, rule);
                },
                else => {
                    const checkpoint = self.mark();
                    if (try self.consumeDeclaration(true)) |declaration| {
                        try self.decl_scratch.append(self.gpa, declaration);
                        continue;
                    }

                    self.restore(checkpoint);
                    switch (try self.consumeQualifiedRule(.semicolon, true)) {
                        .rule => |rule| {
                            try self.flushDeclarations(declarations_top);
                            try self.scratch.append(self.gpa, rule);
                        },
                        .invalid => {
                            try self.flushDeclarations(declarations_top);
                        },
                        .nothing => {},
                    }
                },
            }
        }
    }

    fn flushDeclarations(
        self: *Parser,
        declarations_top: usize,
    ) error{OutOfMemory}!void {
        if (self.decl_scratch.items.len == declarations_top) {
            return;
        }

        const declarations = self.decl_scratch.items[declarations_top..];
        const main_token = self.nodes.items(.main_token)[declarations[0]];
        const data = try self.addExtraChildren(declarations);
        const list = try self.addNode(.{
            .tag = .declaration_list,
            .main_token = main_token,
            .data = data,
        });
        self.decl_scratch.shrinkRetainingCapacity(declarations_top);
        try self.scratch.append(self.gpa, list);
    }

    fn startsLikeCustomProperty(self: *Parser, values: []const Index) bool {
        var significant: [2]Index = undefined;
        var count: usize = 0;

        for (values) |value| {
            const tag = self.nodes.items(.tag)[value];
            if (tag == .token) {
                const token = self.nodes.items(.main_token)[value];
                const token_tag = self.tok_tags[token];

                if (token_tag == .whitespace or token_tag == .comment) {
                    continue;
                }
            }

            significant[count] = value;
            count += 1;
            if (count == significant.len) {
                break;
            }
        }

        if (count != significant.len) {
            return false;
        }

        const first = significant[0];
        const second = significant[1];
        if (self.nodes.items(.tag)[first] != .token or self.nodes.items(.tag)[second] != .token) {
            return false;
        }

        const first_token = self.nodes.items(.main_token)[first];
        const second_token = self.nodes.items(.main_token)[second];
        return self.tok_tags[first_token] == .ident and
            self.identValueStartsWith(first_token, "--") and
            self.tok_tags[second_token] == .colon;
    }

    /// §5.5.6: Consume a declaration.
    fn consumeDeclaration(self: *Parser, nested: bool) error{OutOfMemory}!?Index {
        const nodes_top = self.nodes.len;
        const extra_data_top = self.extra_data.items.len;

        if (self.tok_tags[self.tok_i] != .ident) {
            try self.addError(.expected_declaration_name);
            try self.consumeBadDeclaration(nested);
            self.discardNodesSince(nodes_top, extra_data_top);
            return null;
        }

        const name_token = self.advance();
        self.discardWhitespace();

        if (self.tok_tags[self.tok_i] != .colon) {
            try self.addError(.expected_colon);
            try self.consumeBadDeclaration(nested);
            self.discardNodesSince(nodes_top, extra_data_top);
            return null;
        }

        _ = self.advance();
        self.discardWhitespace();
        const raw_value_start = self.tok_i;

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        try self.consumeComponentValuesUntil(.semicolon, nested);
        const raw_value_end = self.tok_i;

        const important = self.removeImportant(scratch_top);
        self.trimTrailingWhitespace(scratch_top);

        const values = self.scratch.items[scratch_top..];
        if (!self.isCustomPropertyName(name_token) and self.hasInvalidBraceValue(values)) {
            try self.addErrorAt(.invalid_declaration_value, name_token);
            self.discardNodesSince(nodes_top, extra_data_top);
            return null;
        }

        if (self.discovered_unicode_ranges) |intervals| {
            if (self.identValueEqlIgnoreCase(name_token, "unicode-range")) {
                try intervals.append(self.gpa, .{
                    .start = self.tok_starts[raw_value_start],
                    .end = self.tok_starts[raw_value_end],
                });
            }
        }

        const data = try self.addExtraChildren(values);
        var declaration_tag: Node.Tag = .declaration;
        if (important) {
            declaration_tag = .declaration_important;
        }

        const declaration = try self.addNode(.{
            .tag = declaration_tag,
            .main_token = name_token,
            .data = data,
        });
        return declaration;
    }

    fn discardWhitespace(self: *Parser) void {
        while (self.tok_tags[self.tok_i] == .whitespace or
            self.tok_tags[self.tok_i] == .comment)
        {
            _ = self.advance();
        }
    }

    fn consumeComponentValuesUntil(
        self: *Parser,
        stop_tag: TokenTag,
        nested: bool,
    ) error{OutOfMemory}!void {
        while (true) {
            const tag = self.tok_tags[self.tok_i];
            if (tag == .eof or tag == stop_tag) {
                return;
            }

            if (tag == .r_brace) {
                if (nested) {
                    return;
                }

                try self.addError(.unexpected_closing_brace);
                const token = self.advance();
                const node = try self.addTokenNode(token);
                try self.scratch.append(self.gpa, node);
                continue;
            }

            const value = try self.consumeComponentValue();
            try self.scratch.append(self.gpa, value);
        }
    }

    fn consumeBadDeclaration(self: *Parser, nested: bool) error{OutOfMemory}!void {
        while (true) {
            switch (self.tok_tags[self.tok_i]) {
                .eof, .semicolon => {
                    _ = self.advance();
                    return;
                },
                .r_brace => {
                    if (nested) {
                        return;
                    }

                    _ = self.advance();
                },
                else => {
                    _ = try self.consumeComponentValue();
                },
            }
        }
    }

    fn removeImportant(self: *Parser, scratch_top: usize) bool {
        var last: ?usize = null;
        var previous: ?usize = null;
        var i = self.scratch.items.len;

        while (i > scratch_top) {
            i -= 1;
            if (self.isWhitespaceValue(self.scratch.items[i])) {
                continue;
            }

            if (last == null) {
                last = i;
            } else {
                previous = i;
                break;
            }
        }

        const important_index = last orelse return false;
        const bang_index = previous orelse return false;
        if (!self.isTokenValue(self.scratch.items[bang_index], .delim, "!")) {
            return false;
        }

        if (!self.isIdentValueIgnoreCase(self.scratch.items[important_index], "important")) {
            return false;
        }

        _ = self.scratch.orderedRemove(important_index);
        _ = self.scratch.orderedRemove(bang_index);
        return true;
    }

    fn trimTrailingWhitespace(self: *Parser, scratch_top: usize) void {
        while (self.scratch.items.len > scratch_top and
            self.isWhitespaceValue(self.scratch.items[self.scratch.items.len - 1]))
        {
            _ = self.scratch.pop();
        }
    }

    fn isWhitespaceValue(self: *Parser, value: Index) bool {
        if (self.nodes.items(.tag)[value] != .token) {
            return false;
        }

        const token = self.nodes.items(.main_token)[value];
        return self.tok_tags[token] == .whitespace or self.tok_tags[token] == .comment;
    }

    fn isTokenValue(
        self: *Parser,
        value: Index,
        tag: TokenTag,
        text: []const u8,
    ) bool {
        if (self.nodes.items(.tag)[value] != .token) {
            return false;
        }

        const token = self.nodes.items(.main_token)[value];
        return self.tok_tags[token] == tag and std.mem.eql(u8, self.tokenSlice(token), text);
    }

    fn isIdentValueIgnoreCase(self: *Parser, value: Index, text: []const u8) bool {
        if (self.nodes.items(.tag)[value] != .token) {
            return false;
        }

        const token = self.nodes.items(.main_token)[value];
        return self.tok_tags[token] == .ident and
            self.identValueEqlIgnoreCase(token, text);
    }

    fn isCustomPropertyName(self: *Parser, name_token: TokenIndex) bool {
        return self.identValueStartsWith(name_token, "--");
    }

    fn identValueEqlIgnoreCase(
        self: *Parser,
        token: TokenIndex,
        expected: []const u8,
    ) bool {
        const raw = self.tokenSlice(token);
        var raw_i: usize = 0;
        var expected_i: usize = 0;

        while (raw_i < raw.len) {
            if (expected_i == expected.len) {
                return false;
            }

            const c = nextIdentAscii(raw, &raw_i) orelse return false;
            if (std.ascii.toLower(c) != std.ascii.toLower(expected[expected_i])) {
                return false;
            }

            expected_i += 1;
        }

        return expected_i == expected.len;
    }

    fn identValueStartsWith(
        self: *Parser,
        token: TokenIndex,
        expected: []const u8,
    ) bool {
        const raw = self.tokenSlice(token);
        var raw_i: usize = 0;

        for (expected) |expected_c| {
            if (raw_i == raw.len) {
                return false;
            }

            const c = nextIdentAscii(raw, &raw_i) orelse return false;
            if (std.ascii.toLower(c) != std.ascii.toLower(expected_c)) {
                return false;
            }
        }

        return true;
    }

    fn hasInvalidBraceValue(self: *Parser, values: []const Index) bool {
        var significant_count: usize = 0;
        var has_brace = false;

        for (values) |value| {
            if (self.isWhitespaceValue(value)) {
                continue;
            }

            significant_count += 1;
            if (self.nodes.items(.tag)[value] == .simple_block_brace) {
                has_brace = true;
            }
        }

        return has_brace and significant_count > 1;
    }

    /// §5.5.8: Consume a component value.
    fn consumeComponentValue(self: *Parser) error{OutOfMemory}!Index {
        return switch (self.tok_tags[self.tok_i]) {
            .l_brace => self.consumeSimpleBlock(.r_brace, .simple_block_brace),
            .l_bracket => self.consumeSimpleBlock(.r_bracket, .simple_block_bracket),
            .l_paren => self.consumeSimpleBlock(.r_paren, .simple_block_paren),
            .function => self.consumeFunction(),

            else => blk: {
                const t = self.advance();
                break :blk self.addTokenNode(t);
            },
        };
    }

    /// §5.5.9: Consume a simple block.
    /// The current input token is an opening bracket (l_brace/l_bracket/l_paren).
    fn consumeSimpleBlock(
        self: *Parser,
        close_tag: TokenTag,
        node_tag: Node.Tag,
    ) error{OutOfMemory}!Index {
        const open_token = self.advance();

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const tag = self.tok_tags[self.tok_i];

            // Return the unclosed block at EOF.
            if (tag == .eof) {
                break;
            }

            if (tag == close_tag) {
                _ = self.advance();
                break;
            }

            const cv = try self.consumeComponentValue();
            try self.scratch.append(self.gpa, cv);
        }

        const data = try self.addExtraChildren(self.scratch.items[scratch_top..]);
        return self.addNode(.{ .tag = node_tag, .main_token = open_token, .data = data });
    }

    /// §5.5.10: Consume a function.
    /// The current input token is the <function-token> itself ("ident(").
    fn consumeFunction(self: *Parser) error{OutOfMemory}!Index {
        const func_token = self.advance();

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const tag = self.tok_tags[self.tok_i];

            // Return the unclosed function at EOF.
            if (tag == .eof) {
                break;
            }

            if (tag == .r_paren) {
                _ = self.advance();
                break;
            }

            const cv = try self.consumeComponentValue();
            try self.scratch.append(self.gpa, cv);
        }

        const data = try self.addExtraChildren(self.scratch.items[scratch_top..]);
        return self.addNode(.{ .tag = .function, .main_token = func_token, .data = data });
    }
};

fn nextIdentAscii(raw: []const u8, index: *usize) ?u8 {
    const c = raw[index.*];
    if (c != '\\') {
        if (!std.ascii.isAscii(c)) {
            return null;
        }

        index.* += 1;
        return c;
    }

    index.* += 1;
    if (index.* == raw.len or raw[index.*] == '\n') {
        return null;
    }

    if (!std.ascii.isHex(raw[index.*])) {
        const escaped = raw[index.*];
        if (!std.ascii.isAscii(escaped)) {
            return null;
        }

        index.* += 1;
        return escaped;
    }

    var value: u32 = 0;
    var count: u8 = 0;
    while (index.* < raw.len and count < 6 and std.ascii.isHex(raw[index.*])) {
        const digit: u32 = std.fmt.charToDigit(raw[index.*], 16) catch unreachable;
        value = value * 16 + digit;
        index.* += 1;
        count += 1;
    }

    if (index.* < raw.len and isCssWhitespace(raw[index.*])) {
        index.* += 1;
    }

    if (value == 0 or value > std.math.maxInt(u7)) {
        return null;
    }

    return @intCast(value);
}

fn isCssWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}
