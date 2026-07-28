//! Robust scalar-residual objectives and positive-semidefinite IRLS weights.

const std = @import("std");
const types = @import("types.zig");

pub const Evaluation = struct {
    cost: f64,
    sqrt_weight: f64,
};

pub fn evaluate(loss: types.Loss, residual: f64) Evaluation {
    if (loss.kind == .linear) {
        return .{
            .cost = 0.5 * residual * residual,
            .sqrt_weight = 1.0,
        };
    }

    const magnitude = @abs(residual);
    const t = magnitude / loss.scale;
    return switch (loss.kind) {
        .linear => unreachable,
        .huber => if (t <= 1.0)
            .{
                .cost = 0.5 * residual * residual,
                .sqrt_weight = 1.0,
            }
        else
            .{
                .cost = loss.scale *
                    (magnitude - 0.5 * loss.scale),
                .sqrt_weight = @sqrt(loss.scale / magnitude),
            },
        .soft_l1 => blk: {
            if (t < @sqrt(std.math.floatEps(f64))) {
                break :blk .{
                    .cost = 0.5 * residual * residual,
                    .sqrt_weight = 1.0,
                };
            }
            const hypotenuse = std.math.hypot(loss.scale, residual);
            // hypot(C, r) - C = r² / (hypot(C, r) + C).  Forming
            // r * (r / denominator) avoids overflowing r².
            const difference = if (hypotenuse >
                std.math.floatMax(f64) - loss.scale)
                hypotenuse - loss.scale
            else
                magnitude * (magnitude / (hypotenuse + loss.scale));
            break :blk .{
                .cost = loss.scale * difference,
                .sqrt_weight = @sqrt(loss.scale / hypotenuse),
            };
        },
        .cauchy => blk: {
            if (t < @sqrt(std.math.floatEps(f64))) {
                break :blk .{
                    .cost = 0.5 * residual * residual,
                    .sqrt_weight = 1.0,
                };
            }
            const hypotenuse = std.math.hypot(loss.scale, residual);
            const log_ratio = if (magnitude == 0.0)
                0.0
            else if (!std.math.isFinite(t))
                @log(hypotenuse) - @log(loss.scale)
            else if (t <= @sqrt(std.math.floatMax(f64)))
                0.5 * std.math.log1p(t * t)
            else
                @log(t) + 0.5 * std.math.log1p(1.0 / t / t);
            break :blk .{
                .cost = loss.scale * (loss.scale * log_ratio),
                .sqrt_weight = loss.scale / hypotenuse,
            };
        },
    };
}

test "robust objectives remain finite for huge finite residuals" {
    const testing = std.testing;
    const residual = 1e308;

    const huber = evaluate(types.loss.huber(1.0), residual);
    try testing.expect(std.math.isFinite(huber.cost));
    try testing.expectApproxEqRel(1e308, huber.cost, 1e-15);
    try testing.expect(std.math.isFinite(huber.sqrt_weight));

    const soft_l1 = evaluate(types.loss.softL1(1.0), residual);
    try testing.expect(std.math.isFinite(soft_l1.cost));
    try testing.expectApproxEqRel(1e308, soft_l1.cost, 1e-15);
    try testing.expect(std.math.isFinite(soft_l1.sqrt_weight));

    const cauchy = evaluate(types.loss.cauchy(1.0), residual);
    try testing.expect(std.math.isFinite(cauchy.cost));
    try testing.expect(std.math.isFinite(cauchy.sqrt_weight));
}

test "robust objectives retain small residual precision at huge scales" {
    const soft_l1 = evaluate(types.loss.softL1(1e308), 1.0);
    try std.testing.expectApproxEqRel(0.5, soft_l1.cost, 1e-15);

    const cauchy = evaluate(types.loss.cauchy(1e308), 1.0);
    try std.testing.expectApproxEqRel(0.5, cauchy.cost, 1e-15);
}
