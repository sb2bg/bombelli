//! Public value types shared by Bombelli optimizers.

/// Robust scalar-residual loss family.
pub const LossKind = enum {
    linear,
    huber,
    soft_l1,
    cauchy,
};

/// A robust scalar-residual loss and its scale in residual units.
pub const Loss = struct {
    kind: LossKind,
    scale: f64,
};

/// Type-safe robust-loss constructors.
pub const loss = struct {
    pub fn linear() Loss {
        return .{ .kind = .linear, .scale = 1.0 };
    }

    pub fn huber(scale: f64) Loss {
        return .{ .kind = .huber, .scale = scale };
    }

    pub fn softL1(scale: f64) Loss {
        return .{ .kind = .soft_l1, .scale = scale };
    }

    pub fn cauchy(scale: f64) Loss {
        return .{ .kind = .cauchy, .scale = scale };
    }
};

/// Parameter scaling used by nonlinear least-squares solvers.
pub const LeastSquaresScaling = enum {
    none,
    jacobian,
    user,
};

/// Handling of an initial point outside configured box bounds.
pub const InitialBoundsPolicy = enum {
    reject,
    project,
};

/// Completion reason from a nonlinear least-squares solve.
pub const LeastSquaresStatus = enum {
    converged_gradient,
    converged_cost,
    converged_step,
    max_iterations,
    max_function_evaluations,
    infeasible_initial,
    non_finite_initial,
    non_finite_jacobian,
    line_search_failed,
    numerical_failure,
};
