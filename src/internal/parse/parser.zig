const std = @import("std");
const ast = @import("../../expression.zig");
const build = @import("../core/builder.zig");
const diagnostic = @import("diagnostic.zig");
const exact = @import("../core/exact.zig");
const limits = @import("../core/limits.zig");
const lexer = @import("lexer.zig");

pub fn parse(comptime source: []const u8) ast.Expr {
    @setEvalBranchQuota(limits.eval_branch.local_transform);
    var builder = build.Builder{};
    var parser = Parser.init(source, &builder);
    const root = parser.parse();
    return builder.finish(root, source);
}

const Parser = struct {
    source: []const u8,
    lexer: lexer.Lexer,
    current: lexer.Token,
    builder: *build.Builder,

    fn init(source: []const u8, builder: *build.Builder) Parser {
        var tokenizer = lexer.Lexer.init(source);
        const first = tokenizer.next();
        return .{
            .source = source,
            .lexer = tokenizer,
            .current = first,
            .builder = builder,
        };
    }

    fn parse(self: *Parser) ast.NodeId {
        if (self.current.kind == .eof) {
            diagnostic.fail(self.source, 0, "expected an expression");
        }

        const root = self.parseAddition();
        if (self.current.kind != .eof) {
            diagnostic.fail(self.source, self.current.start, "unexpected trailing token");
        }
        return root;
    }

    fn parseAddition(self: *Parser) ast.NodeId {
        var left = self.parseMultiplication();
        while (self.current.kind == .plus or self.current.kind == .minus) {
            const operator = self.current.kind;
            self.advance();
            const right = self.parseMultiplication();
            left = if (operator == .plus)
                self.builder.add(left, right)
            else
                self.builder.sub(left, right);
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
                self.builder.mul(left, right)
            else
                self.builder.div(left, right);
        }
        return left;
    }

    fn parseUnary(self: *Parser) ast.NodeId {
        if (self.current.kind == .minus) {
            self.advance();
            return self.builder.negate(self.parseUnary());
        }
        return self.parsePower();
    }

    fn parsePower(self: *Parser) ast.NodeId {
        const base = self.parsePrimary();
        if (self.current.kind != .caret) return base;

        const caret_position = self.current.start;
        self.advance();
        const exponent = self.parseExponent(caret_position);
        if (self.current.kind == .caret) {
            diagnostic.fail(
                self.source,
                self.current.start,
                "power chaining is not supported; parenthesize the base",
            );
        }
        return self.builder.power(base, exponent);
    }

    fn parseExponent(self: *Parser, caret_position: usize) exact.Rational {
        const parenthesized = self.current.kind == .left_paren;
        if (parenthesized) self.advance();

        var numerator_sign: i64 = 1;
        if (self.current.kind == .minus) {
            numerator_sign = -1;
            self.advance();
        }
        if (self.current.kind != .integer) {
            diagnostic.fail(
                self.source,
                caret_position,
                "power exponent must be an exact rational literal",
            );
        }
        const numerator_token = self.current;
        var numerator = std.fmt.parseInt(i64, self.tokenText(numerator_token), 10) catch
            diagnostic.fail(self.source, numerator_token.start, "power exponent numerator is too large");
        numerator *= numerator_sign;
        self.advance();

        var denominator: i64 = 1;
        if (parenthesized and self.current.kind == .slash) {
            self.advance();
            var denominator_sign: i64 = 1;
            if (self.current.kind == .minus) {
                denominator_sign = -1;
                self.advance();
            }
            if (self.current.kind != .integer) {
                diagnostic.fail(
                    self.source,
                    self.current.start,
                    "power exponent denominator must be an integer literal",
                );
            }
            const denominator_token = self.current;
            denominator = std.fmt.parseInt(
                i64,
                self.tokenText(denominator_token),
                10,
            ) catch diagnostic.fail(
                self.source,
                denominator_token.start,
                "power exponent denominator is too large",
            );
            denominator *= denominator_sign;
            self.advance();
        }

        if (parenthesized) {
            if (self.current.kind != .right_paren) {
                diagnostic.fail(
                    self.source,
                    self.current.start,
                    "power exponent must contain one exact rational literal",
                );
            }
            self.advance();
        }

        return exact.Rational.init(numerator, denominator) catch |err| switch (err) {
            error.ZeroDenominator => diagnostic.fail(
                self.source,
                caret_position,
                "power exponent denominator cannot be zero",
            ),
            error.Overflow => diagnostic.fail(
                self.source,
                caret_position,
                "power exponent is outside fixed-width range",
            ),
        };
    }

    fn parsePrimary(self: *Parser) ast.NodeId {
        const token = self.current;
        return switch (token.kind) {
            .integer => blk: {
                self.advance();
                const value = std.fmt.parseInt(i64, self.tokenText(token), 10) catch
                    diagnostic.fail(self.source, token.start, "integer literal is out of range");
                break :blk self.builder.integer(value);
            },
            .float => blk: {
                self.advance();
                const value = std.fmt.parseFloat(f64, self.tokenText(token)) catch
                    diagnostic.fail(self.source, token.start, "invalid floating-point literal");
                if (!std.math.isFinite(value)) {
                    diagnostic.fail(self.source, token.start, "floating-point literal is out of range");
                }
                break :blk self.builder.float(value);
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
            if (std.mem.eql(u8, name, "pi")) {
                return self.builder.constant(.pi);
            }
            return self.builder.symbol(name);
        }

        const function_kind: Function = if (std.mem.eql(u8, name, "sin"))
            .sin
        else if (std.mem.eql(u8, name, "cos"))
            .cos
        else if (std.mem.eql(u8, name, "tan"))
            .tan
        else if (std.mem.eql(u8, name, "atan"))
            .atan
        else if (std.mem.eql(u8, name, "abs"))
            .abs
        else if (std.mem.eql(u8, name, "sqrt"))
            .sqrt
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
            .sin => self.builder.sine(argument),
            .cos => self.builder.cosine(argument),
            .tan => self.builder.tangent(argument),
            .atan => self.builder.arctangent(argument),
            .abs => self.builder.absolute(argument),
            .sqrt => self.builder.power(argument, exact.Rational{
                .numerator = 1,
                .denominator = 2,
            }),
            .exp => self.builder.exponential(argument),
            .ln => self.builder.logarithm(argument),
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
    tan,
    atan,
    abs,
    sqrt,
    exp,
    ln,
};
