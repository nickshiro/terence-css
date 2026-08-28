const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    parse_error: ?ParseError = null,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        eof,

        whitespace,
        comment,

        ident,
        function,
        at_keyword,
        hash_unrestricted,
        hash_id,
        string,
        bad_string,
        url,
        bad_url,

        delim,

        number,
        percentage,
        dimension,
        unicode_range,

        cdo,
        cdc,

        colon,
        semicolon,
        comma,

        l_bracket,
        r_bracket,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
    };

    pub const ParseError = enum {
        eof_in_comment,
        eof_in_string,
        newline_in_string,
        eof_in_url,
        invalid_url,
        invalid_escape,
        eof_in_escape,
    };
};

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    unicode_ranges_allowed: bool,
    parse_error: ?Token.ParseError,

    pub const Options = struct {
        unicode_ranges_allowed: bool = false,
    };

    pub fn init(buffer: []const u8) Tokenizer {
        return initWithOptions(buffer, .{});
    }

    pub fn initWithOptions(buffer: []const u8, options: Options) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .unicode_ranges_allowed = options.unicode_ranges_allowed,
            .parse_error = null,
        };
    }

    pub fn setUnicodeRangesAllowed(self: *Tokenizer, allowed: bool) void {
        self.unicode_ranges_allowed = allowed;
    }

    /// §4.3.1: Consumes and returns the next token.
    pub fn next(self: *Tokenizer) Token {
        self.parse_error = null;
        var token = self.nextImpl();
        token.parse_error = self.parse_error;
        return token;
    }

    fn nextImpl(self: *Tokenizer) Token {
        const start = self.index;

        if (self.index >= self.buffer.len) {
            return .{ .tag = .eof, .loc = .{ .start = start, .end = start } };
        }

        const c = self.buffer[self.index];

        switch (c) {
            ' ', '\t', '\n', '\r', 0x0c => return self.consumeWhitespace(start),

            '"' => return self.consumeString(start, '"'),
            '\'' => return self.consumeString(start, '\''),

            '#' => return self.consumeHash(start),

            '(' => return self.single(.l_paren),
            ')' => return self.single(.r_paren),
            '[' => return self.single(.l_bracket),
            ']' => return self.single(.r_bracket),
            '{' => return self.single(.l_brace),
            '}' => return self.single(.r_brace),
            ':' => return self.single(.colon),
            ';' => return self.single(.semicolon),
            ',' => return self.single(.comma),

            '+' => return self.consumePlusOrDelim(start),
            '-' => return self.consumeMinusOrDelimOrCDC(start),
            '.' => return self.consumeDotOrDelim(start),

            '/' => return self.consumeSlashOrComment(start),

            '<' => return self.consumeLessThanOrCDO(start),

            '@' => return self.consumeAtKeywordOrDelim(start),

            '\\' => return self.consumeIdentLikeOrDelim(start),

            '0'...'9' => return self.consumeNumeric(start),

            'U', 'u' => {
                if (self.unicode_ranges_allowed and self.wouldStartUnicodeRangeAt(start)) {
                    return self.consumeUnicodeRange(start);
                }

                return self.consumeIdentLike(start);
            },

            else => {
                const code_point = codePointAt(self.buffer, start).?;
                if (isIdentStartCodePoint(code_point.value)) {
                    return self.consumeIdentLike(start);
                }

                return self.singleDelim(start);
            },
        }
    }

    fn single(self: *Tokenizer, tag: Token.Tag) Token {
        const start = self.index;
        self.index += 1;

        return .{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
    }

    fn singleDelim(self: *Tokenizer, start: usize) Token {
        self.index = start + codePointAt(self.buffer, start).?.len;

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.8: Checks whether the code points at index form a valid escape.
    fn isValidEscape(self: *Tokenizer, index: usize) bool {
        if (index >= self.buffer.len or self.buffer[index] != '\\') {
            return false;
        }

        if (index + 1 >= self.buffer.len) {
            return true;
        }

        return !isNewlineAt(self.buffer, index + 1);
    }

    /// §4.3.7: Consumes an escaped code point after the reverse solidus.
    fn consumeEscapedCodePoint(self: *Tokenizer) void {
        if (self.index >= self.buffer.len) {
            self.recordError(.eof_in_escape);
            return;
        }

        const c = self.buffer[self.index];
        if (isHexDigit(c)) {
            var count: u8 = 0;
            while (self.index < self.buffer.len and count < 6 and isHexDigit(self.buffer[self.index])) {
                self.index += 1;
                count += 1;
            }

            if (isWhitespaceAt(self.buffer, self.index)) {
                self.index += codePointAt(self.buffer, self.index).?.len;
            }

            return;
        }

        self.index += codePointAt(self.buffer, self.index).?.len;
    }

    fn recordError(self: *Tokenizer, parse_error: Token.ParseError) void {
        if (self.parse_error == null) {
            self.parse_error = parse_error;
        }
    }

    /// §4.3.9: Checks whether the code points at index start an ident sequence.
    fn wouldStartIdentSequenceAt(self: *Tokenizer, index: usize) bool {
        const first = codePointAt(self.buffer, index) orelse {
            return false;
        };

        if (first.value == '-') {
            const second_index = index + first.len;
            const second = codePointAt(self.buffer, second_index) orelse {
                return false;
            };

            if (isIdentStartCodePoint(second.value) or second.value == '-') {
                return true;
            }

            if (second.value == '\\') {
                return self.isValidEscape(second_index);
            }

            return false;
        }

        if (isIdentStartCodePoint(first.value)) {
            return true;
        }

        if (first.value == '\\') {
            return self.isValidEscape(index);
        }

        return false;
    }

    /// §4.3.10: Checks whether the code points at index start a number.
    fn wouldStartNumberAt(self: *Tokenizer, index: usize) bool {
        if (index >= self.buffer.len) {
            return false;
        }

        const c = self.buffer[index];

        if (c == '+' or c == '-') {
            if (index + 1 >= self.buffer.len) {
                return false;
            }

            const c2 = self.buffer[index + 1];

            if (isDigit(c2)) {
                return true;
            }

            if (c2 == '.' and index + 2 < self.buffer.len and isDigit(self.buffer[index + 2])) {
                return true;
            }

            return false;
        }

        if (c == '.') {
            return index + 1 < self.buffer.len and isDigit(self.buffer[index + 1]);
        }

        return isDigit(c);
    }

    /// §4.3.11: Check whether the code points at index start a unicode-range.
    fn wouldStartUnicodeRangeAt(self: *Tokenizer, index: usize) bool {
        if (index + 2 >= self.buffer.len) {
            return false;
        }

        const first = self.buffer[index];
        return (first == 'U' or first == 'u') and
            self.buffer[index + 1] == '+' and
            (isHexDigit(self.buffer[index + 2]) or self.buffer[index + 2] == '?');
    }

    /// §4.3.12: Consumes an ident sequence.
    fn consumeIdentSequence(self: *Tokenizer) void {
        while (self.index < self.buffer.len) {
            const code_point = codePointAt(self.buffer, self.index).?;
            if (isIdentCodePoint(code_point.value)) {
                self.index += code_point.len;
            } else if (code_point.value == '\\' and self.isValidEscape(self.index)) {
                self.index += 1;
                self.consumeEscapedCodePoint();
            } else {
                break;
            }
        }
    }

    fn consumeWhitespace(self: *Tokenizer, start: usize) Token {
        while (isWhitespaceAt(self.buffer, self.index)) {
            self.index += codePointAt(self.buffer, self.index).?.len;
        }

        return .{ .tag = .whitespace, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.5: Consumes a string token.
    fn consumeString(self: *Tokenizer, start: usize, quote: u8) Token {
        self.index += 1;

        while (true) {
            if (self.index >= self.buffer.len) {
                self.recordError(.eof_in_string);
                return .{ .tag = .string, .loc = .{ .start = start, .end = self.index } };
            }

            const code_point = codePointAt(self.buffer, self.index).?;
            const c = code_point.value;

            if (c == quote) {
                self.index += code_point.len;
                return .{ .tag = .string, .loc = .{ .start = start, .end = self.index } };
            }

            if (c == '\n') {
                self.recordError(.newline_in_string);
                return .{ .tag = .bad_string, .loc = .{ .start = start, .end = self.index } };
            }

            if (c == '\\') {
                if (self.index + 1 >= self.buffer.len) {
                    self.index += 1;
                    continue;
                }

                if (isNewlineAt(self.buffer, self.index + 1)) {
                    self.index += 1;
                    self.index += codePointAt(self.buffer, self.index).?.len;
                    continue;
                }

                self.index += 1;
                self.consumeEscapedCodePoint();
                continue;
            }

            self.index += code_point.len;
        }
    }

    fn consumeHash(self: *Tokenizer, start: usize) Token {
        self.index += 1;

        const next_code_point = codePointAt(self.buffer, self.index);
        const next_is_ident_or_escape = if (next_code_point) |code_point|
            isIdentCodePoint(code_point.value) or self.isValidEscape(self.index)
        else
            false;

        if (next_is_ident_or_escape) {
            const is_id_type = self.wouldStartIdentSequenceAt(self.index);
            self.consumeIdentSequence();

            return .{
                .tag = if (is_id_type) .hash_id else .hash_unrestricted,
                .loc = .{ .start = start, .end = self.index },
            };
        }

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.2: Consumes comments as lossless extension tokens.
    fn consumeSlashOrComment(self: *Tokenizer, start: usize) Token {
        self.index += 1;

        if (self.index < self.buffer.len and self.buffer[self.index] == '*') {
            self.index += 1;
            while (self.index < self.buffer.len) {
                if (self.buffer[self.index] == '*' and
                    self.index + 1 < self.buffer.len and
                    self.buffer[self.index + 1] == '/')
                {
                    self.index += 2;
                    return .{ .tag = .comment, .loc = .{ .start = start, .end = self.index } };
                }

                self.index += 1;
            }

            self.recordError(.eof_in_comment);
            return .{ .tag = .comment, .loc = .{ .start = start, .end = self.index } };
        }

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.1, branch U+002B PLUS SIGN
    fn consumePlusOrDelim(self: *Tokenizer, start: usize) Token {
        if (self.wouldStartNumberAt(start)) {
            return self.consumeNumeric(start);
        }

        self.index = start + 1;

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.1, branch U+002D HYPHEN-MINUS
    fn consumeMinusOrDelimOrCDC(self: *Tokenizer, start: usize) Token {
        if (self.wouldStartNumberAt(start)) {
            return self.consumeNumeric(start);
        }

        if (start + 2 < self.buffer.len and
            self.buffer[start + 1] == '-' and
            self.buffer[start + 2] == '>')
        {
            self.index = start + 3;
            return .{ .tag = .cdc, .loc = .{ .start = start, .end = self.index } };
        }

        if (self.wouldStartIdentSequenceAt(start)) {
            return self.consumeIdentLike(start);
        }

        self.index = start + 1;

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.1, branch U+002E FULL STOP
    fn consumeDotOrDelim(self: *Tokenizer, start: usize) Token {
        if (self.wouldStartNumberAt(start)) {
            return self.consumeNumeric(start);
        }

        self.index = start + 1;

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.1, branch U+003C LESS-THAN SIGN ("<!--")
    fn consumeLessThanOrCDO(self: *Tokenizer, start: usize) Token {
        if (start + 3 < self.buffer.len and
            self.buffer[start + 1] == '!' and
            self.buffer[start + 2] == '-' and
            self.buffer[start + 3] == '-')
        {
            self.index = start + 4;

            return .{ .tag = .cdo, .loc = .{ .start = start, .end = self.index } };
        }

        self.index = start + 1;

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.1, branch U+0040 COMMERCIAL AT
    fn consumeAtKeywordOrDelim(self: *Tokenizer, start: usize) Token {
        self.index = start + 1;

        if (self.wouldStartIdentSequenceAt(self.index)) {
            self.consumeIdentSequence();

            return .{ .tag = .at_keyword, .loc = .{ .start = start, .end = self.index } };
        }

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.1, branch U+005C REVERSE SOLIDUS
    fn consumeIdentLikeOrDelim(self: *Tokenizer, start: usize) Token {
        if (self.isValidEscape(start)) {
            return self.consumeIdentLike(start);
        }

        self.recordError(.invalid_escape);
        self.index = start + 1;

        return .{ .tag = .delim, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.3: Consumes a numeric token.
    fn consumeNumeric(self: *Tokenizer, start: usize) Token {
        self.index = start;
        self.consumeNumber();

        if (self.wouldStartIdentSequenceAt(self.index)) {
            self.consumeIdentSequence();

            return .{ .tag = .dimension, .loc = .{ .start = start, .end = self.index } };
        }

        if (self.index < self.buffer.len and self.buffer[self.index] == '%') {
            self.index += 1;

            return .{ .tag = .percentage, .loc = .{ .start = start, .end = self.index } };
        }

        return .{ .tag = .number, .loc = .{ .start = start, .end = self.index } };
    }

    /// §4.3.13: Consumes a number with the grammar:
    /// [+-]? digit* ('.' digit+)? ([eE] [+-]? digit+)?
    fn consumeNumber(self: *Tokenizer) void {
        if (self.index < self.buffer.len and
            (self.buffer[self.index] == '+' or self.buffer[self.index] == '-'))
        {
            self.index += 1;
        }

        while (self.index < self.buffer.len and isDigit(self.buffer[self.index])) {
            self.index += 1;
        }

        if (self.index + 1 < self.buffer.len and
            self.buffer[self.index] == '.' and
            isDigit(self.buffer[self.index + 1]))
        {
            self.index += 2;
            while (self.index < self.buffer.len and isDigit(self.buffer[self.index])) {
                self.index += 1;
            }
        }

        if (self.index < self.buffer.len and
            (self.buffer[self.index] == 'e' or self.buffer[self.index] == 'E'))
        {
            var lookahead = self.index + 1;
            if (lookahead < self.buffer.len and
                (self.buffer[lookahead] == '+' or self.buffer[lookahead] == '-'))
            {
                lookahead += 1;
            }

            if (lookahead < self.buffer.len and isDigit(self.buffer[lookahead])) {
                self.index = lookahead;
                while (self.index < self.buffer.len and isDigit(self.buffer[self.index])) {
                    self.index += 1;
                }
            }
        }
    }

    /// §4.3.14: Consume a unicode-range token.
    fn consumeUnicodeRange(self: *Tokenizer, start: usize) Token {
        self.index = start + 2;

        var hex_count: u8 = 0;
        while (self.index < self.buffer.len and
            hex_count < 6 and
            isHexDigit(self.buffer[self.index]))
        {
            self.index += 1;
            hex_count += 1;
        }

        var question_count: u8 = 0;
        while (self.index < self.buffer.len and
            hex_count + question_count < 6 and
            self.buffer[self.index] == '?')
        {
            self.index += 1;
            question_count += 1;
        }

        if (question_count == 0 and
            self.index + 1 < self.buffer.len and
            self.buffer[self.index] == '-' and
            isHexDigit(self.buffer[self.index + 1]))
        {
            self.index += 1;

            var end_count: u8 = 0;
            while (self.index < self.buffer.len and
                end_count < 6 and
                isHexDigit(self.buffer[self.index]))
            {
                self.index += 1;
                end_count += 1;
            }
        }

        return .{
            .tag = .unicode_range,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    /// §4.3.4: Consumes an ident-like token.
    fn consumeIdentLike(self: *Tokenizer, start: usize) Token {
        self.index = start;
        self.consumeIdentSequence();
        const ident_end = self.index;

        if (self.index < self.buffer.len and self.buffer[self.index] == '(') {
            self.index += 1;
            const paren_end = self.index;

            if (identSequenceEqlAsciiIgnoreCase(self.buffer, start, ident_end, "url")) {
                return self.consumeUrlOrFunction(start, paren_end);
            }

            return .{ .tag = .function, .loc = .{ .start = start, .end = paren_end } };
        }

        return .{ .tag = .ident, .loc = .{ .start = start, .end = self.index } };
    }

    fn consumeUrlOrFunction(self: *Tokenizer, start: usize, paren_end: usize) Token {
        var peek = paren_end;
        while (isWhitespaceAt(self.buffer, peek)) {
            peek += codePointAt(self.buffer, peek).?.len;
        }

        if (peek < self.buffer.len and (self.buffer[peek] == '"' or self.buffer[peek] == '\'')) {
            return .{ .tag = .function, .loc = .{ .start = start, .end = paren_end } };
        }

        self.index = paren_end;
        return self.consumeUrlToken(start);
    }

    /// §4.3.6: Consumes a URL token.
    fn consumeUrlToken(self: *Tokenizer, start: usize) Token {
        while (isWhitespaceAt(self.buffer, self.index)) {
            self.index += codePointAt(self.buffer, self.index).?.len;
        }

        while (true) {
            if (self.index >= self.buffer.len) {
                self.recordError(.eof_in_url);
                return .{ .tag = .url, .loc = .{ .start = start, .end = self.index } };
            }

            const code_point = codePointAt(self.buffer, self.index).?;
            const c = code_point.value;
            switch (c) {
                ')' => {
                    self.index += code_point.len;
                    return .{ .tag = .url, .loc = .{ .start = start, .end = self.index } };
                },

                ' ', '\t', '\n' => {
                    while (isWhitespaceAt(self.buffer, self.index)) {
                        self.index += codePointAt(self.buffer, self.index).?.len;
                    }

                    if (self.index >= self.buffer.len) {
                        self.recordError(.eof_in_url);
                        return .{ .tag = .url, .loc = .{ .start = start, .end = self.index } };
                    }

                    if (self.buffer[self.index] == ')') {
                        self.index += 1;
                        return .{ .tag = .url, .loc = .{ .start = start, .end = self.index } };
                    }

                    self.recordError(.invalid_url);
                    return self.consumeBadUrlRemnants(start);
                },

                '"', '\'', '(' => {
                    self.recordError(.invalid_url);
                    return self.consumeBadUrlRemnants(start);
                },

                0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
                    self.recordError(.invalid_url);
                    return self.consumeBadUrlRemnants(start);
                },

                '\\' => {
                    if (self.isValidEscape(self.index)) {
                        self.index += 1;
                        self.consumeEscapedCodePoint();
                    } else {
                        self.recordError(.invalid_url);
                        return self.consumeBadUrlRemnants(start);
                    }
                },

                else => {
                    self.index += code_point.len;
                },
            }
        }
    }

    /// §4.3.15: Consumes the remnants of a bad URL.
    fn consumeBadUrlRemnants(self: *Tokenizer, start: usize) Token {
        while (self.index < self.buffer.len) {
            const code_point = codePointAt(self.buffer, self.index).?;
            const c = code_point.value;
            if (c == ')') {
                self.index += code_point.len;
                break;
            }

            if (c == '\\' and self.isValidEscape(self.index)) {
                self.index += 1;
                self.consumeEscapedCodePoint();
                continue;
            }

            self.index += code_point.len;
        }

        return .{ .tag = .bad_url, .loc = .{ .start = start, .end = self.index } };
    }
};

const CodePoint = struct {
    value: u21,
    len: usize,
};

/// §3.3: Reads one filtered code point while retaining its original byte span.
fn codePointAt(buffer: []const u8, index: usize) ?CodePoint {
    if (index >= buffer.len) {
        return null;
    }

    const first = buffer[index];
    if (first == '\r') {
        if (index + 1 < buffer.len and buffer[index + 1] == '\n') {
            return .{ .value = '\n', .len = 2 };
        }

        return .{ .value = '\n', .len = 1 };
    }

    if (first == 0x0c) {
        return .{ .value = '\n', .len = 1 };
    }

    if (first == 0) {
        return .{ .value = 0xfffd, .len = 1 };
    }

    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch {
        return .{ .value = 0xfffd, .len = 1 };
    };
    if (index + sequence_len > buffer.len) {
        return .{ .value = 0xfffd, .len = 1 };
    }

    const value = std.unicode.utf8Decode(buffer[index .. index + sequence_len]) catch {
        return .{ .value = 0xfffd, .len = 1 };
    };
    return .{ .value = value, .len = sequence_len };
}

fn isNewlineAt(buffer: []const u8, index: usize) bool {
    const code_point = codePointAt(buffer, index) orelse {
        return false;
    };
    return code_point.value == '\n';
}

fn isWhitespaceAt(buffer: []const u8, index: usize) bool {
    const code_point = codePointAt(buffer, index) orelse {
        return false;
    };
    return code_point.value == ' ' or code_point.value == '\t' or code_point.value == '\n';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// §4.2: Tests whether a code point is an ident-start code point.
fn isIdentStartCodePoint(c: u21) bool {
    return switch (c) {
        'a'...'z',
        'A'...'Z',
        '_',
        0x00b7,
        0x00c0...0x00d6,
        0x00d8...0x00f6,
        0x00f8...0x037d,
        0x037f...0x1fff,
        0x200c,
        0x200d,
        0x203f,
        0x2040,
        0x2070...0x218f,
        0x2c00...0x2fef,
        0x3001...0xd7ff,
        0xf900...0xfdcf,
        0xfdf0...0xfffd,
        0x10000...0x10ffff,
        => true,
        else => false,
    };
}

fn isIdentCodePoint(c: u21) bool {
    return isIdentStartCodePoint(c) or (c >= '0' and c <= '9') or c == '-';
}

fn identSequenceEqlAsciiIgnoreCase(
    buffer: []const u8,
    start: usize,
    end: usize,
    expected: []const u8,
) bool {
    var index = start;
    var expected_index: usize = 0;
    while (index < end) {
        const value = if (buffer[index] == '\\') blk: {
            index += 1;
            break :blk escapedCodePointValueAt(buffer, &index);
        } else blk: {
            const code_point = codePointAt(buffer, index).?;
            index += code_point.len;
            break :blk code_point.value;
        };

        if (expected_index >= expected.len or value > 0x7f) {
            return false;
        }

        if (std.ascii.toLower(@intCast(value)) != std.ascii.toLower(expected[expected_index])) {
            return false;
        }
        expected_index += 1;
    }

    return expected_index == expected.len;
}

fn escapedCodePointValueAt(buffer: []const u8, index: *usize) u21 {
    if (index.* >= buffer.len) {
        return 0xfffd;
    }

    if (isHexDigit(buffer[index.*])) {
        var value: u32 = 0;
        var count: u8 = 0;
        while (index.* < buffer.len and count < 6 and isHexDigit(buffer[index.*])) {
            value = value * 16 + hexDigitValue(buffer[index.*]);
            index.* += 1;
            count += 1;
        }

        if (isWhitespaceAt(buffer, index.*)) {
            index.* += codePointAt(buffer, index.*).?.len;
        }

        if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) {
            return 0xfffd;
        }
        return @intCast(value);
    }

    const code_point = codePointAt(buffer, index.*).?;
    index.* += code_point.len;
    return code_point.value;
}

fn hexDigitValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => unreachable,
    };
}
