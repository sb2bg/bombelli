const diagnostic = @import("diagnostic.zig");

pub const Kind = enum {
    eof,
    integer,
    float,
    identifier,
    plus,
    minus,
    star,
    slash,
    caret,
    left_paren,
    right_paren,
    comma,
};

pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
};

pub const Lexer = struct {
    source: []const u8,
    position: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Token {
        while (self.position < self.source.len and isWhitespace(self.source[self.position])) {
            self.position += 1;
        }

        if (self.position == self.source.len) {
            return .{
                .kind = .eof,
                .start = self.position,
                .end = self.position,
            };
        }

        const start = self.position;
        const byte = self.source[self.position];
        self.position += 1;

        return switch (byte) {
            '+' => self.single(.plus, start),
            '-' => self.single(.minus, start),
            '*' => self.single(.star, start),
            '/' => self.single(.slash, start),
            '^' => self.single(.caret, start),
            '(' => self.single(.left_paren, start),
            ')' => self.single(.right_paren, start),
            ',' => self.single(.comma, start),
            '0'...'9' => self.number(start),
            'a'...'z', 'A'...'Z', '_' => self.identifier(start),
            else => diagnostic.fail(self.source, start, "unexpected character"),
        };
    }

    fn single(self: *Lexer, kind: Kind, start: usize) Token {
        return .{ .kind = kind, .start = start, .end = self.position };
    }

    fn identifier(self: *Lexer, start: usize) Token {
        while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
            self.position += 1;
        }
        return .{ .kind = .identifier, .start = start, .end = self.position };
    }

    fn number(self: *Lexer, start: usize) Token {
        var kind: Kind = .integer;

        while (self.position < self.source.len and isDigit(self.source[self.position])) {
            self.position += 1;
        }

        if (self.position < self.source.len and self.source[self.position] == '.') {
            kind = .float;
            self.position += 1;
            while (self.position < self.source.len and isDigit(self.source[self.position])) {
                self.position += 1;
            }
        }

        if (self.position < self.source.len and
            (self.source[self.position] == 'e' or self.source[self.position] == 'E'))
        {
            kind = .float;
            self.position += 1;
            if (self.position < self.source.len and
                (self.source[self.position] == '+' or self.source[self.position] == '-'))
            {
                self.position += 1;
            }
            if (self.position == self.source.len or !isDigit(self.source[self.position])) {
                diagnostic.fail(self.source, self.position, "invalid floating-point literal");
            }
            while (self.position < self.source.len and isDigit(self.source[self.position])) {
                self.position += 1;
            }
        }

        return .{ .kind = kind, .start = start, .end = self.position };
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isIdentifierContinue(byte: u8) bool {
    return isDigit(byte) or
        (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        byte == '_';
}
