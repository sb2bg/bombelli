//! Central resource limits for compile-time construction and evaluation.

pub const construction_nodes = 1024;
pub const polynomial_variables = 128;
pub const symbolic_conditions = 128;

pub const eval_branch = struct {
    pub const evaluation = 100_000;
    pub const render = 1_000_000;
    pub const vector_render = 2_000_000;
    pub const matrix_render = 4_000_000;
    pub const local_transform = 5_000_000;
    pub const transform = 10_000_000;
    pub const polynomial = 20_000_000;
    pub const rational = 30_000_000;
    pub const solve = 50_000_000;
};
