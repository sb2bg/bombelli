const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");

pub fn parse(comptime source: []const u8) ast.Expr {
    @setEvalBranchQuota(1_000_000);
    var parser = Parser.init(source);
    return parser.parse();
}

const Parser = struct {
    source: []const u8,
    lexer: lexer.Lexer,
    current: lexer.Token,
    expression: ast.Expr,

    fn init(source: []const u8) Parser {
        var tokenizer = lexer.Lexer.init(source);
        const first = tokenizer.next();
        return .{
            .source = source,
            .lexer = tokenizer,
            .current = first,
            .expression = ast.Expr.init(source),
        };
    }

    fn parse(self: *Parser) ast.Expr {
        if (self.current.kind == .eof) {
            diagnostic.fail(self.source, 0, "expected an expression");
        }

        self.expression.root = self.parseAddition();
        if (self.current.kind != .eof) {
            diagnostic.fail(self.source, self.current.start, "unexpected trailing token");
        }
        return self.expression;
    }

    fn parseAddition(self: *Parser) ast.NodeId {
        var left = self.parseMultiplication();
        while (self.current.kind == .plus or self.current.kind == .minus) {
            const operator = self.current.kind;
            self.advance();
            const right = self.parseMultiplication();
            left = if (operator == .plus)
                self.expression.addNode(.{ .add = .{ .left = left, .right = right } })
            else
                self.expression.addNode(.{ .sub = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseMultiplication(self: *Parser) ast.NodeId {
        var left = self.parseUnary();
        while (self.current.kind == .star or self.current.kind == .slash) {
            const operator = self.current.kind;
            self.advance();
            const right = self.parseUnary();
            left = if (operator == .star)
                self.expression.addNode(.{ .mul = .{ .left = left, .right = right } })
            else
                self.expression.addNode(.{ .div = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ast.NodeId {
        if (self.current.kind == .minus) {
            self.advance();
            return self.expression.addNode(.{ .negate = self.parseUnary() });
        }
        return self.parsePower();
    }

    fn parsePower(self: *Parser) ast.NodeId {
        const base = self.parsePrimary();
        if (self.current.kind != .caret) return base;

        const caret_position = self.current.start;
        self.advance();
        if (self.current.kind != .integer) {
            diagnostic.fail(self.source, caret_position, "power exponent must be a non-negative integer literal");
        }

        const token = self.current;
        const exponent = std.fmt.parseInt(u32, self.tokenText(token), 10) catch
            diagnostic.fail(self.source, token.start, "power exponent is too large");
        self.advance();
        return self.expression.addNode(.{ .pow = .{
            .base = base,
            .exponent = exponent,
        } });
    }

    fn parsePrimary(self: *Parser) ast.NodeId {
        const token = self.current;
        return switch (token.kind) {
            .integer => blk: {
                self.advance();
                const value = std.fmt.parseInt(i64, self.tokenText(token), 10) catch
                    diagnostic.fail(self.source, token.start, "integer literal is out of range");
                break :blk self.expression.addNode(.{ .integer = value });
            },
            .float => blk: {
                self.advance();
                const value = std.fmt.parseFloat(f64, self.tokenText(token)) catch
                    diagnostic.fail(self.source, token.start, "invalid floating-point literal");
                break :blk self.expression.addNode(.{ .float = value });
            },
            .identifier => self.parseIdentifier(),
            .left_paren => blk: {
                self.advance();
                const inner = self.parseAddition();
                if (self.current.kind != .right_paren) {
                    diagnostic.fail(self.source, self.current.start, "missing closing parenthesis");
                }
                self.advance();
                break :blk inner;
            },
            else => diagnostic.fail(self.source, token.start, "expected a number, symbol, function, or parenthesized expression"),
        };
    }

    fn parseIdentifier(self: *Parser) ast.NodeId {
        const token = self.current;
        const name = self.tokenText(token);
        self.advance();

        if (self.current.kind != .left_paren) {
            return self.expression.addNode(.{ .symbol = name });
        }

        const function_kind: Function = if (std.mem.eql(u8, name, "sin"))
            .sin
        else if (std.mem.eql(u8, name, "cos"))
            .cos
        else if (std.mem.eql(u8, name, "exp"))
            .exp
        else if (std.mem.eql(u8, name, "ln"))
            .ln
        else
            diagnostic.fail(self.source, token.start, "unknown function");

        self.advance();
        const argument = self.parseAddition();
        if (self.current.kind != .right_paren) {
            diagnostic.fail(self.source, self.current.start, "missing closing parenthesis");
        }
        self.advance();

        return switch (function_kind) {
            .sin => self.expression.addNode(.{ .sin = argument }),
            .cos => self.expression.addNode(.{ .cos = argument }),
            .exp => self.expression.addNode(.{ .exp = argument }),
            .ln => self.expression.addNode(.{ .ln = argument }),
        };
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.next();
    }

    fn tokenText(self: *Parser, token: lexer.Token) []const u8 {
        return self.source[token.start..token.end];
    }
};

const Function = enum {
    sin,
    cos,
    exp,
    ln,
};
