const std = @import("std");
const Allocator = std.mem.Allocator;

const parser_mod = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");

pub const TokenTag = tokenizer.Token.Tag;

pub const Index = u32;
pub const TokenIndex = u32;

pub const Node = struct {
    tag: Tag,
    /// For .token, this is the token itself. For blocks, this is the opening
    /// token. For .function, this is the <function-token>. For rules, this is
    /// the first syntax token. It is unused for .root,
    /// .component_value_list, and .component_value_list_invalid.
    main_token: TokenIndex,
    data: Data,

    pub const Data = struct { lhs: Index = 0, rhs: Index = 0 };

    pub const Tag = enum {
        /// Synthetic tree root. data is a range in extra_data containing the
        /// results produced by the selected parser entry point.
        root,

        /// One group produced by the comma-separated component-value parser.
        /// data contains component values excluding the separating comma.
        component_value_list,

        /// A comma-separated group that did not match the supplied CSS grammar.
        /// data has the same representation as .component_value_list.
        component_value_list_invalid,

        /// An at-rule. main_token is the <at-keyword-token>. data contains its
        /// prelude component values followed by an optional parsed block.
        at_rule,

        /// A qualified rule. main_token starts its prelude. data contains its
        /// prelude component values followed by its parsed block.
        qualified_rule,

        /// Parsed block contents. main_token is '{'. data contains nested rules
        /// and declaration lists in source order.
        block,

        /// Consecutive declarations in block contents. main_token is the first
        /// declaration's property name. data contains declaration nodes.
        declaration_list,

        /// A declaration without !important. main_token is the property name.
        /// data contains the declaration's semantic value.
        declaration,

        /// A declaration whose top-level value ends with !important.
        declaration_important,

        /// One preserved token as a component value. main_token is the token
        /// itself. Covers ident/number/string/delim/whitespace/comment/colon/etc:
        /// everything that is not a {}/[]/() block or a function.
        token,

        /// {} block. main_token is '{'. data is a range in extra_data containing
        /// child component-value indices, excluding '}'.
        simple_block_brace,

        /// [] block. main_token is '['.
        simple_block_bracket,

        /// () block. main_token is '('.
        simple_block_paren,

        /// ident(...) function. main_token is the function token itself. data is
        /// a range in extra_data containing child component values, excluding ')'.
        function,
    };
};

pub const TokenData = struct {
    tag: TokenTag,
    start: u32,
    end: u32,
};

pub const Ast = struct {
    source: []const u8,
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,
    extra_data: []Index,
    errors: []const Error,
    root: Index,

    pub const TokenList = std.MultiArrayList(TokenData);
    pub const NodeList = std.MultiArrayList(Node);

    pub const Error = struct {
        tag: Tag,
        token: TokenIndex,

        pub const Tag = enum {
            unexpected_closing_brace,
            qualified_rule_without_block,
            expected_rule,
            unexpected_input_after_rule,
            expected_component_value,
            unexpected_input_after_component_value,
            grammar_mismatch,
            expected_declaration_name,
            expected_colon,
            invalid_declaration_value,
        };
    };

    /// Adapter for a grammar production defined outside CSS Syntax. The
    /// callback receives one parsed list of component values and returns
    /// whether it matches that production.
    pub const Grammar = struct {
        context: ?*const anyopaque = null,
        matchFn: *const fn (?*const anyopaque, Ast, []const Index) bool,

        pub fn matches(self: Grammar, tree: Ast, values: []const Index) bool {
            return self.matchFn(self.context, tree, values);
        }
    };

    pub fn parseAccordingToGrammar(
        gpa: Allocator,
        source: []const u8,
        grammar: Grammar,
    ) !Ast {
        return parser_mod.parseAccordingToGrammar(gpa, source, grammar);
    }

    pub fn parseCommaSeparatedAccordingToGrammar(
        gpa: Allocator,
        source: []const u8,
        grammar: Grammar,
    ) !Ast {
        return parser_mod.parseCommaSeparatedAccordingToGrammar(gpa, source, grammar);
    }

    pub fn parseComponentValue(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseComponentValue(gpa, source);
    }

    pub fn parseComponentValues(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseComponentValues(gpa, source);
    }

    pub fn parseCommaSeparatedComponentValues(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseCommaSeparatedComponentValues(gpa, source);
    }

    pub fn parseStylesheet(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseStylesheet(gpa, source);
    }

    pub fn parseStylesheetContents(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseStylesheetContents(gpa, source);
    }

    pub fn parseBlockContents(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseBlockContents(gpa, source);
    }

    pub fn parseRule(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseRule(gpa, source);
    }

    pub fn parseDeclaration(gpa: Allocator, source: []const u8) !Ast {
        return parser_mod.parseDeclaration(gpa, source);
    }

    pub fn deinit(self: *Ast, gpa: Allocator) void {
        self.tokens.deinit(gpa);
        self.nodes.deinit(gpa);
        gpa.free(self.extra_data);
        gpa.free(self.errors);
        self.* = undefined;
    }

    pub fn tokenTag(self: Ast, token: TokenIndex) TokenTag {
        return self.tokens.items(.tag)[token];
    }

    pub fn tokenSlice(self: Ast, token: TokenIndex) []const u8 {
        const starts = self.tokens.items(.start);
        const ends = self.tokens.items(.end);
        return self.source[starts[token]..ends[token]];
    }

    /// Returns child nodes for roots, component-value lists, rules, blocks,
    /// declaration lists, simple blocks, and functions.
    /// Panics for .token because leaf nodes have no children.
    pub fn extraChildren(self: Ast, node: Index) []const Index {
        const data = self.nodes.items(.data)[node];
        return self.extra_data[data.lhs..data.rhs];
    }

    /// Dumps the tree for visual inspection until full structural comparison
    /// tests are available.
    pub fn dump(self: Ast, writer: anytype) !void {
        try self.dumpNode(writer, self.root, 0);
    }

    fn dumpNode(self: Ast, writer: anytype, node: Index, depth: usize) !void {
        const tag = self.nodes.items(.tag)[node];
        const main_token = self.nodes.items(.main_token)[node];

        try writer.splatByteAll(' ', depth * 2);

        switch (tag) {
            .root => {
                try writer.writeAll("root\n");

                for (self.extraChildren(node)) |child| {
                    try self.dumpNode(writer, child, depth + 1);
                }
            },

            .component_value_list,
            .component_value_list_invalid,
            => {
                try writer.print("{s}\n", .{@tagName(tag)});

                for (self.extraChildren(node)) |child| {
                    try self.dumpNode(writer, child, depth + 1);
                }
            },

            .at_rule,
            .qualified_rule,
            .declaration_list,
            .declaration,
            .declaration_important,
            => {
                try writer.print("{s} \"{f}\"\n", .{
                    @tagName(tag),
                    std.zig.fmtString(self.tokenSlice(main_token)),
                });

                for (self.extraChildren(node)) |child| {
                    try self.dumpNode(writer, child, depth + 1);
                }
            },

            .token => {
                try writer.print("token .{s} \"{f}\"\n", .{
                    @tagName(self.tokenTag(main_token)),
                    std.zig.fmtString(self.tokenSlice(main_token)),
                });
            },

            .block,
            .simple_block_brace,
            .simple_block_bracket,
            .simple_block_paren,
            => {
                try writer.print("{s} \"{f}\"\n", .{
                    @tagName(tag),
                    std.zig.fmtString(self.tokenSlice(main_token)),
                });

                for (self.extraChildren(node)) |child| {
                    try self.dumpNode(writer, child, depth + 1);
                }
            },

            .function => {
                try writer.print("function \"{f}\"\n", .{
                    std.zig.fmtString(self.tokenSlice(main_token)),
                });

                for (self.extraChildren(node)) |child| {
                    try self.dumpNode(writer, child, depth + 1);
                }
            },
        }
    }
};
