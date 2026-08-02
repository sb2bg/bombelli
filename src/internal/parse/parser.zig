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
            if (ast.Constant.fromName(name)) |constant| {
                return self.builder.constant(constant);
            }
            return self.builder.symbol(name);
        }

        const function_kind: Function = if (std.mem.eql(u8, name, "sin"))
            .sin
        else if (std.mem.eql(u8, name, "cos"))
            .cos
        else if (std.mem.eql(u8, name, "tan"))
            .tan
        else if (std.mem.eql(u8, name, "asin"))
            .asin
        else if (std.mem.eql(u8, name, "acos"))
            .acos
        else if (std.mem.eql(u8, name, "atan"))
            .atan
        else if (std.mem.eql(u8, name, "sinh"))
            .sinh
        else if (std.mem.eql(u8, name, "cosh"))
            .cosh
        else if (std.mem.eql(u8, name, "tanh"))
            .tanh
        else if (std.mem.eql(u8, name, "abs"))
            .abs
        else if (std.mem.eql(u8, name, "sqrt"))
            .sqrt
        else if (std.mem.eql(u8, name, "exp"))
            .exp
        else if (std.mem.eql(u8, name, "ln"))
            .ln
        else if (std.mem.eql(u8, name, "log2"))
            .log2
        else if (std.mem.eql(u8, name, "log10"))
            .log10
        else if (std.mem.eql(u8, name, "atan2"))
            .atan2
        else if (std.mem.eql(u8, name, "hypot"))
            .hypot
        else
            diagnostic.fail(self.source, token.start, "unknown function");

        self.advance();
        const arguments = self.parseFunctionArguments(
            token,
            name,
            function_kind.arity(),
        );

        return switch (function_kind) {
            .sin => self.builder.sine(arguments.values[0]),
            .cos => self.builder.cosine(arguments.values[0]),
            .tan => self.builder.tangent(arguments.values[0]),
            .asin => self.builder.arcsine(arguments.values[0]),
            .acos => self.builder.arccosine(arguments.values[0]),
            .atan => self.builder.arctangent(arguments.values[0]),
            .sinh => self.builder.hyperbolicSine(arguments.values[0]),
            .cosh => self.builder.hyperbolicCosine(arguments.values[0]),
            .tanh => self.builder.hyperbolicTangent(arguments.values[0]),
            .abs => self.builder.absolute(arguments.values[0]),
            .sqrt => self.builder.power(arguments.values[0], exact.Rational{
                .numerator = 1,
                .denominator = 2,
            }),
            .exp => self.builder.exponential(arguments.values[0]),
            .ln => self.builder.logarithm(arguments.values[0]),
            .log2 => self.builder.logarithm2(arguments.values[0]),
            .log10 => self.builder.logarithm10(arguments.values[0]),
            .atan2 => self.builder.arctangent2(
                arguments.values[0],
                arguments.values[1],
            ),
            .hypot => self.builder.hypotenuse(
                arguments.values[0],
                arguments.values[1],
            ),
        };
    }

    fn parseFunctionArguments(
        self: *Parser,
        function_token: lexer.Token,
        function_name: []const u8,
        expected: usize,
    ) ParsedArguments {
        var arguments = ParsedArguments{
            .values = undefined,
            .len = 0,
        };

        if (self.current.kind != .right_paren) {
            while (true) {
                if (self.current.kind == .comma) {
                    diagnostic.fail(
                        self.source,
                        self.current.start,
                        "expected a function argument before ','",
                    );
                }
                if (arguments.len == arguments.values.len) {
                    diagnostic.fail(
                        self.source,
                        function_token.start,
                        std.fmt.comptimePrint(
                            "function '{s}' expects {d} argument{s}",
                            .{
                                function_name,
                                expected,
                                if (expected == 1) "" else "s",
                            },
                        ),
                    );
                }
                arguments.values[arguments.len] = self.parseAddition();
                arguments.len += 1;
                if (self.current.kind != .comma) break;
                self.advance();
                if (self.current.kind == .right_paren) {
                    diagnostic.fail(
                        self.source,
                        self.current.start,
                        "expected a function argument after ','",
                    );
                }
            }
        }

        if (self.current.kind != .right_paren) {
            diagnostic.fail(self.source, self.current.start, "missing closing parenthesis");
        }
        self.advance();
        if (arguments.len != expected) {
            diagnostic.fail(
                self.source,
                function_token.start,
                std.fmt.comptimePrint(
                    "function '{s}' expects {d} argument{s}, received {d}",
                    .{
                        function_name,
                        expected,
                        if (expected == 1) "" else "s",
                        arguments.len,
                    },
                ),
            );
        }
        return arguments;
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
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    abs,
    sqrt,
    exp,
    ln,
    log2,
    log10,
    atan2,
    hypot,

    fn arity(self: Function) usize {
        return switch (self) {
            .atan2, .hypot => 2,
            else => 1,
        };
    }
};

const ParsedArguments = struct {
    values: [3]ast.NodeId,
    len: usize,
};
