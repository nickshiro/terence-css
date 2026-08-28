const std = @import("std");
const Writer = std.Io.Writer;

const ast = @import("ast.zig");
pub const Ast = ast.Ast;
pub const TokenIndex = ast.TokenIndex;
pub const TokenRange = ast.TokenRange;
pub const TokenTag = ast.TokenTag;

/// Whitespace requested by the AST renderer before the next emitted token.
/// Comments found in the corresponding source gap are always retained.
pub const Separator = enum {
    none,
    space,
    newline,
    blank_line,
    preserve,
};

/// A token that need not belong to the source AST. This lets inserted closing
/// delimiters and other synthetic syntax use the same boundary checks as
/// source tokens.
pub const TokenView = struct {
    tag: TokenTag,
    text: []const u8,
};

/// Serializes source and synthetic tokens without accidentally changing their
/// tokenization. Formatting policy belongs to the AST renderer; this type owns
/// source trivia, token ordering, and CSS Syntax §9 boundary protection.
pub const TokenSerializer = struct {
    tree: Ast,
    writer: *Writer,
    cursor: TokenIndex = 0,
    previous: ?PreviousToken = null,
    previous_is_separated: bool = false,
    pending_separator: Separator = .none,
    finished: bool = false,

    pub const Error = Writer.Error || error{
        AlreadyFinished,
        CannotEmitEof,
        InvalidTokenRange,
        OutOfOrderToken,
        TriviaToken,
        UnhandledToken,
    };

    pub fn init(tree: Ast, writer: *Writer) TokenSerializer {
        return .{ .tree = tree, .writer = writer };
    }

    /// Emits one non-trivia source token. `after` becomes the formatting
    /// request for the source gap before the next emitted item.
    pub fn emitToken(
        self: *TokenSerializer,
        token: TokenIndex,
        after: Separator,
    ) Error!void {
        try self.ensureActive();

        if (token >= self.tree.tokens.len) {
            return error.InvalidTokenRange;
        }

        if (token < self.cursor) {
            return error.OutOfOrderToken;
        }

        const view = self.sourceTokenView(token);
        switch (view.tag) {
            .eof => return error.CannotEmitEof,
            .whitespace, .comment => return error.TriviaToken,
            else => {},
        }

        const separated = try self.emitGap(token);
        try self.emitBoundary(view, separated);
        try self.writer.writeAll(view.text);

        self.cursor = token + 1;
        self.previous = .init(view);
        self.previous_is_separated = false;
        self.pending_separator = after;
    }

    /// Emits syntax that is not backed by a source token. Source trivia is not
    /// consumed; it remains attached to the next source token or `finish`.
    pub fn emitSynthetic(
        self: *TokenSerializer,
        token: TokenView,
        after: Separator,
    ) Error!void {
        try self.ensureActive();
        switch (token.tag) {
            .eof => return error.CannotEmitEof,
            .whitespace, .comment => return error.TriviaToken,
            else => {},
        }

        const separated = try self.emitSyntheticSeparator();
        try self.emitBoundary(token, separated);
        try self.writer.writeAll(token.text);

        self.previous = .init(token);
        self.previous_is_separated = false;
        self.pending_separator = after;
    }

    /// Copies a recovered or otherwise opaque source range exactly. The range
    /// must begin at or after the serializer cursor; only trivia may be skipped
    /// between the cursor and its start.
    pub fn emitRaw(
        self: *TokenSerializer,
        range: TokenRange,
        after: Separator,
    ) Error!void {
        try self.ensureActive();

        const eof = self.eofToken();
        if (range.start > range.end or range.end > eof) {
            return error.InvalidTokenRange;
        }

        if (range.start < self.cursor) {
            return error.OutOfOrderToken;
        }

        var separated = try self.emitGap(range.start);
        if (range.isEmpty()) {
            self.pending_separator = after;
            return;
        }

        const tags = self.tree.tokens.items(.tag);
        var first_significant: ?TokenIndex = null;
        var last_significant: ?TokenIndex = null;
        var leading_trivia = true;
        var trailing_trivia = false;
        for (range.start..range.end) |raw_index| {
            const token: TokenIndex = @intCast(raw_index);
            if (isTrivia(tags[token])) {
                if (leading_trivia) {
                    separated = true;
                }

                trailing_trivia = true;
            } else {
                if (first_significant == null) {
                    first_significant = token;
                }

                last_significant = token;
                leading_trivia = false;
                trailing_trivia = false;
            }
        }

        if (first_significant) |token| {
            try self.emitBoundary(self.sourceTokenView(token), separated);
        }
        try self.writer.writeAll(self.tree.tokenRangeSlice(range));

        if (last_significant) |token| {
            self.previous = .init(self.sourceTokenView(token));
            self.previous_is_separated = trailing_trivia;
        } else if (range.start != range.end) {
            self.previous_is_separated = true;
        }

        self.cursor = range.end;
        self.pending_separator = after;
    }

    /// Emits trailing comments/trivia and verifies that every remaining source
    /// token was handled. Calling `finish` more than once is harmless.
    pub fn finish(self: *TokenSerializer) Error!void {
        if (self.finished) return;
        _ = try self.emitGap(self.eofToken());
        self.cursor = self.eofToken();
        self.pending_separator = .none;
        self.finished = true;
    }

    fn ensureActive(self: TokenSerializer) Error!void {
        if (self.finished) {
            return error.AlreadyFinished;
        }
    }

    fn eofToken(self: TokenSerializer) TokenIndex {
        std.debug.assert(self.tree.tokens.len > 0);
        return @intCast(self.tree.tokens.len - 1);
    }

    fn sourceTokenView(self: TokenSerializer, token: TokenIndex) TokenView {
        return .{
            .tag = self.tree.tokenTag(token),
            .text = self.tree.tokenSlice(token),
        };
    }

    fn emitGap(self: *TokenSerializer, until: TokenIndex) Error!bool {
        if (until < self.cursor) return error.OutOfOrderToken;
        if (until > self.eofToken()) return error.InvalidTokenRange;

        const tags = self.tree.tokens.items(.tag);
        for (self.cursor..until) |raw_index| {
            const token: TokenIndex = @intCast(raw_index);
            if (!isTrivia(tags[token])) return error.UnhandledToken;
        }

        const force_newline = if (self.previous) |previous|
            previous.requires_newline and !self.previous_is_separated
        else
            false;
        var separated = self.previous_is_separated;

        if (self.pending_separator == .preserve) {
            const gap = self.sourceGap(until);
            if (force_newline and !startsWithNewline(gap)) {
                try self.writer.writeByte('\n');
                separated = true;
            }

            if (gap.len != 0) {
                try self.writer.writeAll(gap);
                separated = true;
            }
        } else {
            if (force_newline and self.pending_separator != .newline and
                self.pending_separator != .blank_line)
            {
                try self.writer.writeByte('\n');
                separated = true;
            }

            separated = (try self.emitNormalizedGap(until)) or separated;
        }

        self.cursor = until;
        self.previous_is_separated = separated;
        return separated;
    }

    fn emitSyntheticSeparator(self: *TokenSerializer) Error!bool {
        var separated = self.previous_is_separated;
        const force_newline = if (self.previous) |previous|
            previous.requires_newline and !separated
        else
            false;

        if (force_newline and self.pending_separator != .newline and
            self.pending_separator != .blank_line)
        {
            try self.writer.writeByte('\n');
            separated = true;
        }

        switch (self.pending_separator) {
            .none, .preserve => {},
            .space => {
                try self.writer.writeByte(' ');
                separated = true;
            },
            .newline => {
                try self.writer.writeByte('\n');
                separated = true;
            },
            .blank_line => {
                try self.writer.writeAll("\n\n");
                separated = true;
            },
        }

        self.previous_is_separated = separated;
        return separated;
    }

    fn emitNormalizedGap(self: *TokenSerializer, until: TokenIndex) Error!bool {
        const tags = self.tree.tokens.items(.tag);
        const has_comments = blk: {
            for (self.cursor..until) |raw_index| {
                const token: TokenIndex = @intCast(raw_index);
                if (tags[token] == .comment) break :blk true;
            }
            break :blk false;
        };

        switch (self.pending_separator) {
            .none => {
                for (self.cursor..until) |raw_index| {
                    const token: TokenIndex = @intCast(raw_index);
                    if (tags[token] == .comment) {
                        try self.writer.writeAll(self.tree.tokenSlice(token));
                    }
                }

                return has_comments;
            },
            .space, .newline, .blank_line => |separator| {
                try self.writeSeparator(separator);
                for (self.cursor..until) |raw_index| {
                    const token: TokenIndex = @intCast(raw_index);
                    if (tags[token] == .comment) {
                        try self.writer.writeAll(self.tree.tokenSlice(token));
                        try self.writeSeparator(separator);
                    }
                }

                return true;
            },
            .preserve => unreachable,
        }
    }

    fn writeSeparator(self: *TokenSerializer, separator: Separator) Error!void {
        switch (separator) {
            .space => try self.writer.writeByte(' '),
            .newline => try self.writer.writeByte('\n'),
            .blank_line => try self.writer.writeAll("\n\n"),
            .none, .preserve => unreachable,
        }
    }

    fn sourceGap(self: TokenSerializer, until: TokenIndex) []const u8 {
        const start = if (self.cursor == until)
            self.tree.tokenStart(until)
        else
            self.tree.tokenStart(self.cursor);
        return self.tree.source[start..self.tree.tokenStart(until)];
    }

    fn emitBoundary(
        self: *TokenSerializer,
        current: TokenView,
        separated: bool,
    ) Error!void {
        if (separated) {
            return;
        }

        const previous = self.previous orelse return;
        const current_bit = bit(rightClass(current));
        if (previous.unsafe_rights & current_bit != 0) {
            try self.writer.writeAll("/**/");
            self.previous_is_separated = true;
        }
    }
};

const PreviousToken = struct {
    unsafe_rights: u16,
    requires_newline: bool,

    fn init(token: TokenView) PreviousToken {
        return .{
            .unsafe_rights = leftMask(token),
            .requires_newline = requiresNewlineAfter(token),
        };
    }
};

const RightClass = enum(u4) {
    ident,
    function,
    url,
    bad_url,
    minus,
    number,
    percentage,
    dimension,
    cdc,
    l_paren,
    star,
    percent,
    other,
};

/// Implements the unsafe-pair table in CSS Syntax §9. Exact delimiter text is
/// significant because several rows and columns represent delim-token values.
pub fn needsComment(left: TokenView, right: TokenView) bool {
    const right_bit = @as(u16, 1) << @intFromEnum(rightClass(right));
    return leftMask(left) & right_bit != 0;
}

fn leftMask(token: TokenView) u16 {
    const ident_through_paren = bits(.ident, .l_paren);
    const ident_through_cdc = bits(.ident, .cdc);

    return switch (token.tag) {
        .ident => ident_through_paren,
        .at_keyword,
        .hash_unrestricted,
        .hash_id,
        .dimension,
        => ident_through_cdc,
        .number => bit(.ident) |
            bit(.function) |
            bit(.url) |
            bit(.bad_url) |
            bit(.number) |
            bit(.percentage) |
            bit(.dimension) |
            bit(.cdc) |
            bit(.percent),
        .unicode_range => std.math.maxInt(u16),
        .delim => if (token.text.len == 1) switch (token.text[0]) {
            '#' => ident_through_cdc,
            '-' => ident_through_cdc,
            '@' => bit(.ident) |
                bit(.function) |
                bit(.url) |
                bit(.bad_url) |
                bit(.minus) |
                bit(.cdc),
            '.', '+' => bit(.number) | bit(.percentage) | bit(.dimension),
            '/' => bit(.star),
            else => 0,
        } else 0,
        else => 0,
    };
}

fn rightClass(token: TokenView) RightClass {
    return switch (token.tag) {
        .ident, .unicode_range => .ident,
        .function => .function,
        .url => .url,
        .bad_url => .bad_url,
        .number => .number,
        .percentage => .percentage,
        .dimension => .dimension,
        .cdc => .cdc,
        .l_paren => .l_paren,
        .delim => if (token.text.len == 1) switch (token.text[0]) {
            '-' => .minus,
            '*' => .star,
            '%' => .percent,
            else => .other,
        } else .other,
        else => .other,
    };
}

fn bit(class: RightClass) u16 {
    return @as(u16, 1) << @intFromEnum(class);
}

fn bits(first: RightClass, last: RightClass) u16 {
    const first_bit = @intFromEnum(first);
    const width = @intFromEnum(last) - first_bit + 1;
    return ((@as(u16, 1) << @intCast(width)) - 1) << @intCast(first_bit);
}

fn isTrivia(tag: TokenTag) bool {
    return tag == .whitespace or tag == .comment;
}

fn requiresNewlineAfter(token: TokenView) bool {
    return token.tag == .bad_string or
        (token.tag == .delim and std.mem.eql(u8, token.text, "\\"));
}

fn startsWithNewline(text: []const u8) bool {
    if (text.len == 0) {
        return false;
    }

    return text[0] == '\n' or text[0] == '\r' or text[0] == 0x0c;
}
