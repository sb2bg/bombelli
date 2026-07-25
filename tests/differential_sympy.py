#!/usr/bin/env python3
"""Seeded differential validation of Bombelli against SymPy.

The script generates temporary Zig test programs containing only compile-time
Bombelli inputs and numerical constants independently computed by SymPy. Each
program is compiled and run separately to keep compiler memory bounded.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

import sympy as sp


SEED = 0xB0B3111
X, Y = sp.symbols("x y", real=True)
POINTS = ((-1.25, 0.4), (-0.3, 1.1), (0.25, -0.7), (1.4, 0.8))


@dataclass
class Totals:
    programs: int = 0
    assertions: int = 0
    batches: int = 0


def bombelli_parse(source: str) -> sp.Expr:
    return sp.sympify(
        source.replace("^", "**"),
        locals={
            "x": X,
            "y": Y,
            "sin": sp.sin,
            "cos": sp.cos,
            "atan": sp.atan,
            "abs": sp.Abs,
            "sqrt": sp.sqrt,
            "exp": sp.exp,
            "ln": sp.log,
        },
    )


def finite_float(value: sp.Expr) -> float:
    result = float(sp.N(value, 50))
    if not math.isfinite(result):
        raise ValueError(f"non-finite oracle result: {value}")
    return result


def zig_float(value: float) -> str:
    if not math.isfinite(value):
        raise ValueError(f"cannot emit non-finite Zig literal: {value}")
    result = repr(value)
    if "e" not in result and "." not in result:
        result += ".0"
    return result


def zig_string(value: str) -> str:
    return json.dumps(value)


def chunks(values: Sequence[str], size: int) -> Iterable[Sequence[str]]:
    for start in range(0, len(values), size):
        yield values[start : start + size]


def run_zig_batch(
    *,
    zig: str,
    repo: Path,
    temporary: Path,
    category: str,
    batch_index: int,
    bodies: Sequence[str],
    totals: Totals,
) -> None:
    source = "\n".join(
        (
            'const std = @import("std");',
            'const bombelli = @import("bombelli");',
            "",
            "fn expectClose(expected: f64, actual: f64, relative: f64) !void {",
            "    const tolerance = relative * @max(1.0, @abs(expected));",
            "    try std.testing.expectApproxEqAbs(expected, actual, tolerance);",
            "}",
            "",
            f'test "SymPy differential {category} batch {batch_index}" {{',
            "    @setEvalBranchQuota(100_000_000);",
            *bodies,
            "}",
            "",
        )
    )
    source_path = temporary / f"{category}_{batch_index:02d}.zig"
    source_path.write_text(source)
    command = [
        zig,
        "test",
        "--dep",
        "bombelli",
        f"-Mroot={source_path}",
        f"-Mbombelli={repo / 'src' / 'root.zig'}",
    ]
    completed = subprocess.run(
        command,
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if completed.returncode != 0:
        print(completed.stdout, file=sys.stderr)
        raise SystemExit(
            f"SymPy differential batch {category}/{batch_index} failed"
        )
    totals.batches += 1
    print(
        f"[{totals.batches:02d}] {category} batch {batch_index}: "
        f"{len(bodies)} programs passed",
        flush=True,
    )


def rational_literal(rng: random.Random) -> str:
    numerator = rng.choice((-5, -4, -3, -2, -1, 1, 2, 3, 4, 5))
    denominator = rng.choice((1, 1, 1, 2, 3, 4, 5))
    if denominator == 1:
        return str(numerator)
    return f"({numerator}/{denominator})"


def random_expression(rng: random.Random, depth: int) -> str:
    if depth == 0:
        return rng.choice(("x", "y", rational_literal(rng)))

    choice = rng.randrange(11)
    left = random_expression(rng, depth - 1)
    if choice == 0:
        return f"({left}) + ({random_expression(rng, depth - 1)})"
    if choice == 1:
        return f"({left}) - ({random_expression(rng, depth - 1)})"
    if choice == 2:
        return f"({left}) * ({random_expression(rng, depth - 1)})"
    if choice == 3:
        denominator = random_expression(rng, max(0, depth - 2))
        return f"({left}) / (({denominator})^2 + {rng.randint(1, 4)})"
    if choice == 4:
        return f"sin({left})"
    if choice == 5:
        return f"cos({left})"
    if choice == 6:
        return f"atan({left})"
    if choice == 7:
        return f"exp(({left})/{rng.randint(4, 9)})"
    if choice == 8:
        return f"ln(({left})^2 + {rng.randint(1, 4)})"
    if choice == 9:
        return f"sqrt(({left})^2 + {rng.randint(1, 4)})"
    return f"(({left})^2 + {rng.randint(1, 4)})^(-{rng.randint(1, 2)})"


def unique_random_expressions(
    rng: random.Random,
    count: int,
    generator: Callable[[], str],
) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    while len(results) < count:
        source = generator()
        if source in seen:
            continue
        try:
            expression = bombelli_parse(source)
            oracle_values = [
                finite_float(expression.subs({X: x, Y: y})) for x, y in POINTS
            ]
            derivative_values = [
                finite_float(sp.diff(expression, variable).subs({X: x, Y: y}))
                for variable in (X, Y)
                for x, y in POINTS
            ]
            hessian_values = [
                finite_float(
                    sp.diff(expression, left, right).subs({X: x, Y: y})
                )
                for left in (X, Y)
                for right in (X, Y)
                for x, y in POINTS
            ]
            if max(map(abs, oracle_values + derivative_values + hessian_values)) > 1e12:
                continue
        except (TypeError, ValueError, OverflowError, ZeroDivisionError):
            continue
        seen.add(source)
        results.append(source)
    return results


def core_body(source: str, index: int) -> tuple[str, int]:
    expression = bombelli_parse(source)
    lines = [
        f"    const expression_{index} = comptime bombelli.expr({zig_string(source)});",
        f"    const simplified_{index} = comptime expression_{index}.simplify();",
        f"    const gradient_{index} = comptime expression_{index}.gradient(.{{ .x, .y }}).simplify();",
        f"    const hessian_{index} = comptime expression_{index}.hessian(.{{ .x, .y }}).simplify();",
        f"    _ = comptime simplified_{index}.metrics();",
        f"    _ = comptime gradient_{index}.metrics();",
        f"    _ = comptime hessian_{index}.metrics();",
    ]
    assertions = 0
    derivatives = (sp.diff(expression, X), sp.diff(expression, Y))
    hessian = (
        (sp.diff(expression, X, X), sp.diff(expression, X, Y)),
        (sp.diff(expression, Y, X), sp.diff(expression, Y, Y)),
    )
    for point_index, (x_value, y_value) in enumerate(POINTS):
        substitutions = {X: x_value, Y: y_value}
        expected = finite_float(expression.subs(substitutions))
        lines.extend(
            (
                f"    const point_{index}_{point_index} = .{{ .x = {zig_float(x_value)}, .y = {zig_float(y_value)} }};",
                f"    try expectClose({zig_float(expected)}, expression_{index}.eval(point_{index}_{point_index}), 2e-11);",
                f"    try expectClose({zig_float(expected)}, simplified_{index}.eval(point_{index}_{point_index}), 2e-11);",
            )
        )
        assertions += 2
        for variable_index, derivative in enumerate(derivatives):
            expected_derivative = finite_float(derivative.subs(substitutions))
            lines.append(
                f"    try expectClose({zig_float(expected_derivative)}, "
                f"gradient_{index}.eval(point_{index}_{point_index})[{variable_index}], 2e-10);"
            )
            assertions += 1
        for row in range(2):
            for column in range(2):
                expected_second = finite_float(hessian[row][column].subs(substitutions))
                lines.append(
                    f"    try expectClose({zig_float(expected_second)}, "
                    f"hessian_{index}.eval(point_{index}_{point_index})[{row}][{column}], 2e-9);"
                )
                assertions += 1
    return "\n".join(lines), assertions


def polynomial_source(rng: random.Random) -> str:
    factors = []
    for _ in range(rng.randint(2, 4)):
        a = rng.choice((-3, -2, -1, 1, 2, 3))
        b = rng.choice((-3, -2, -1, 1, 2, 3))
        c = rng.randint(-4, 4)
        factors.append(f"({a}*x + {b}*y + {c})^{rng.randint(1, 4)}")
    return " + ".join(factors)


def sympy_to_bombelli(expression: sp.Expr) -> str:
    return sp.sstr(expression).replace("**", "^")


def polynomial_body(source: str, index: int) -> tuple[str, int]:
    expanded = sp.expand(bombelli_parse(source))
    expected_source = sympy_to_bombelli(expanded)
    lines = [
        f"    const polynomial_{index} = comptime bombelli.expr({zig_string(source)});",
        f"    const expanded_{index} = comptime polynomial_{index}.expand();",
        f"    const expected_polynomial_{index} = comptime bombelli.expr({zig_string(expected_source)}).asPolynomial();",
        f"    try std.testing.expect(comptime expanded_{index}.asPolynomial().eql(expected_polynomial_{index}));",
        f"    _ = comptime expanded_{index}.metrics();",
    ]
    assertions = 1
    for point_index, (x_value, y_value) in enumerate(POINTS):
        expected = finite_float(expanded.subs({X: x_value, Y: y_value}))
        lines.append(
            f"    try expectClose({zig_float(expected)}, expanded_{index}.eval("
            f".{{ .x = {zig_float(x_value)}, .y = {zig_float(y_value)} }}), 2e-11);"
        )
        assertions += 1
    return "\n".join(lines), assertions


def random_polynomial(rng: random.Random, terms: int = 4) -> str:
    parts = []
    for _ in range(terms):
        coefficient = rational_literal(rng)
        x_power = rng.randint(0, 3)
        y_power = rng.randint(0, 3)
        factors = [coefficient]
        if x_power:
            factors.append("x" if x_power == 1 else f"x^{x_power}")
        if y_power:
            factors.append("y" if y_power == 1 else f"y^{y_power}")
        parts.append("*".join(factors))
    return " + ".join(parts)


def rational_function_source(rng: random.Random) -> str:
    numerator_left = random_polynomial(rng, rng.randint(2, 4))
    numerator_right = random_polynomial(rng, rng.randint(2, 4))
    denominator_left = f"x^2 + {rng.randint(1, 5)}"
    denominator_right = f"y^2 + {rng.randint(1, 5)}"
    operation = rng.choice(("+", "-", "*"))
    return (
        f"(({numerator_left}) / ({denominator_left})) {operation} "
        f"(({numerator_right}) / ({denominator_right}))"
    )


def rational_function_body(source: str, index: int) -> tuple[str, int]:
    expression = bombelli_parse(source)
    lines = [
        f"    const rational_source_{index} = comptime bombelli.expr({zig_string(source)});",
        f"    const rational_{index} = comptime rational_source_{index}.asRationalFunction();",
        f"    const normalized_{index} = comptime rational_{index}.toExpr();",
        f"    try std.testing.expect(comptime rational_{index}.denominator.terms.len != 0);",
    ]
    assertions = 1
    for point_index, (x_value, y_value) in enumerate(POINTS):
        expected = finite_float(expression.subs({X: x_value, Y: y_value}))
        lines.append(
            f"    try expectClose({zig_float(expected)}, normalized_{index}.eval("
            f".{{ .x = {zig_float(x_value)}, .y = {zig_float(y_value)} }}), 3e-10);"
        )
        assertions += 1
    return "\n".join(lines), assertions


def integration_source(rng: random.Random) -> str:
    slope = rng.choice((-5, -4, -3, -2, -1, 1, 2, 3, 4, 5))
    intercept = rng.randint(-4, 4)
    degree = rng.randint(0, 6)
    family = rng.randrange(5)
    if family == 0:
        return f"{rational_literal(rng)}*x^{max(1, degree)} + {rational_literal(rng)}*x + {rng.randint(-5, 5)}"
    if family == 4:
        return "1/x"
    function = ("sin", "cos", "exp")[family - 1]
    affine = f"{slope}*x + {intercept}"
    if degree == 0:
        return f"{function}({affine})"
    return f"x^{degree}*{function}({affine})"


def integration_body(source: str, index: int) -> tuple[str, int]:
    integrand = bombelli_parse(source)
    oracle = sp.integrate(integrand, X)
    anchor = 0.5
    lines = [
        f"    const integrand_{index} = comptime bombelli.expr({zig_string(source)}).simplify();",
        f"    const antiderivative_{index} = comptime integrand_{index}.integrate(.{{",
        "        .variable = .x,",
        "        .domain = .real,",
        f"    }}).unwrap().simplify();",
    ]
    assertions = 0
    oracle_anchor = finite_float(oracle.subs(X, anchor))
    for point_index, x_value in enumerate((0.2, 0.8, 1.4, 2.0)):
        expected_delta = finite_float(oracle.subs(X, x_value)) - oracle_anchor
        lines.append(
            f"    try expectClose({zig_float(expected_delta)}, "
            f"antiderivative_{index}.eval(.{{ .x = {zig_float(x_value)} }}) - "
            f"antiderivative_{index}.eval(.{{ .x = {zig_float(anchor)} }}), 3e-9);"
        )
        assertions += 1
    return "\n".join(lines), assertions


def nonsingular_matrix(rng: random.Random, size: int) -> sp.Matrix:
    while True:
        matrix = sp.Matrix(
            [[rng.randint(-5, 5) for _ in range(size)] for _ in range(size)]
        )
        if matrix.det() != 0:
            return matrix


def equation_source(coefficients: Sequence[int], rhs: int, names: Sequence[str]) -> str:
    terms = []
    for coefficient, name in zip(coefficients, names):
        if coefficient == 0:
            continue
        terms.append(f"{coefficient}*{name}")
    left = " + ".join(terms) if terms else "0"
    return f"{left} = {rhs}"


def linear_body(
    rng: random.Random,
    size: int,
    index: int,
) -> tuple[str, int]:
    matrix = nonsingular_matrix(rng, size)
    expected = sp.Matrix([rng.randint(-5, 5) for _ in range(size)])
    rhs = matrix * expected
    names = ("x", "y", "z", "w")[:size]
    equations = [
        equation_source(
            [int(matrix[row, column]) for column in range(size)],
            int(rhs[row]),
            names,
        )
        for row in range(size)
    ]
    equation_tuple = ", ".join(zig_string(value) for value in equations)
    unknown_tuple = ", ".join(f".{name}" for name in names)
    lines = [
        f"    const linear_problem_{index} = comptime bombelli.system(.{{ {equation_tuple} }}, .{{",
        f"        .unknowns = .{{ {unknown_tuple} }},",
        "        .domain = .real,",
        "    });",
        f"    const linear_solution_{index} = comptime linear_problem_{index}.solve(.bareiss).requireUnique();",
        f"    const linear_values_{index} = linear_solution_{index}.eval(.{{}});",
    ]
    assertions = 0
    for row in range(size):
        lines.append(
            f"    try expectClose({zig_float(float(expected[row]))}, "
            f"linear_values_{index}[{row}], 2e-12);"
        )
        assertions += 1
    for row in range(size):
        reconstruction = " + ".join(
            f"({int(matrix[row, column])}.0 * linear_values_{index}[{column}])"
            for column in range(size)
        )
        lines.append(
            f"    try expectClose({zig_float(float(rhs[row]))}, {reconstruction}, 2e-12);"
        )
        assertions += 1
    return "\n".join(lines), assertions


def quadrature_sources() -> list[tuple[str, float, float, int]]:
    sources: list[tuple[str, float, float, int]] = []
    integrands = (
        "exp(-x^2)",
        "sin(x)",
        "cos(2*x+1)",
        "1/(x^2+2)",
        "sqrt(x^2+1)",
        "ln(x^2+2)",
    )
    bounds = ((0.0, 1.0), (-0.75, 1.25))
    for source in integrands:
        for lower, upper in bounds:
            for order in (8, 16):
                sources.append((source, lower, upper, order))
    return sources


def quadrature_body(
    case: tuple[str, float, float, int],
    index: int,
) -> tuple[str, int]:
    source, lower, upper, order = case
    expression = bombelli_parse(source)
    expected = finite_float(sp.integrate(expression, (X, lower, upper)))
    tolerance = 3e-7 if order == 8 else 2e-12
    lines = [
        f"    const quadrature_{index} = comptime bombelli.expr({zig_string(source)}).quadrature(.{{",
        "        .variable = .x,",
        "        .rule = .gauss_legendre,",
        f"        .order = {order},",
        "    });",
        f"    try expectClose({zig_float(expected)}, quadrature_{index}.eval(.{{",
        f"        .from = {zig_float(lower)},",
        f"        .to = {zig_float(upper)},",
        f"    }}), {zig_float(tolerance)});",
    ]
    return "\n".join(lines), 1


def newton_body(rng: random.Random) -> tuple[str, int]:
    lines = [
        "    const scalar_solver = comptime bombelli.equationProblem(",
        '        "x^3 = a",',
        "        .{ .unknowns = .{.x}, .domain = .real },",
        "    ).compile(.{",
        "        .algorithm = .newton,",
        "        .jacobian = .symbolic,",
        "        .max_iterations = 32,",
        "        .tolerance = 1e-12,",
        "    });",
        "    const coupled_solver = comptime bombelli.system(.{",
        '        "x^2 + y = p",',
        '        "x + y^2 = q",',
        "    }, .{",
        "        .unknowns = .{ .x, .y },",
        "        .domain = .real,",
        "    }).compile(.{",
        "        .algorithm = .newton,",
        "        .jacobian = .symbolic,",
        "        .max_iterations = 32,",
        "        .tolerance = 1e-12,",
        "    });",
    ]
    assertions = 0
    for index in range(16):
        expected = rng.uniform(0.4, 2.0)
        parameter = expected**3
        initial = expected * rng.uniform(0.8, 1.2)
        oracle = float(
            sp.nsolve(X**3 - parameter, X, initial, tol=1e-30, maxsteps=100)
        )
        lines.extend(
            (
                f"    const scalar_{index} = scalar_solver.eval(.{{ "
                f".initial = .{{ .x = {zig_float(initial)} }}, "
                f".a = {zig_float(parameter)} }});",
                f"    try std.testing.expectEqual(bombelli.NewtonStatus.converged, scalar_{index}.status);",
                f"    try expectClose({zig_float(oracle)}, scalar_{index}.values[0], 2e-10);",
            )
        )
        assertions += 2
    for index in range(12):
        expected_x = rng.uniform(0.5, 1.7)
        expected_y = rng.uniform(0.5, 1.7)
        p_value = expected_x**2 + expected_y
        q_value = expected_x + expected_y**2
        initial_x = expected_x + rng.uniform(-0.08, 0.08)
        initial_y = expected_y + rng.uniform(-0.08, 0.08)
        oracle = sp.nsolve(
            (X**2 + Y - p_value, X + Y**2 - q_value),
            (X, Y),
            (initial_x, initial_y),
            tol=1e-30,
            maxsteps=100,
        )
        lines.extend(
            (
                f"    const coupled_{index} = coupled_solver.eval(.{{",
                f"        .initial = .{{ .x = {zig_float(initial_x)}, .y = {zig_float(initial_y)} }},",
                f"        .p = {zig_float(p_value)},",
                f"        .q = {zig_float(q_value)},",
                "    });",
                f"    try std.testing.expectEqual(bombelli.NewtonStatus.converged, coupled_{index}.status);",
                f"    try expectClose({zig_float(float(oracle[0]))}, coupled_{index}.values[0], 2e-10);",
                f"    try expectClose({zig_float(float(oracle[1]))}, coupled_{index}.values[1], 2e-10);",
            )
        )
        assertions += 3
    return "\n".join(lines), assertions


def execute(args: argparse.Namespace) -> Totals:
    repo = args.repo.resolve()
    zig = args.zig or shutil.which("zig")
    if not zig:
        raise SystemExit("zig was not found on PATH")
    rng = random.Random(SEED)
    totals = Totals()

    with tempfile.TemporaryDirectory(prefix="bombelli-differential-") as temp:
        temporary = Path(temp)

        core_sources = unique_random_expressions(
            rng,
            args.core_cases,
            lambda: random_expression(rng, rng.randint(2, 4)),
        )
        core_bodies = []
        for index, source in enumerate(core_sources):
            body, assertions = core_body(source, index)
            core_bodies.append(body)
            totals.assertions += assertions
        totals.programs += len(core_bodies)
        for batch_index, batch in enumerate(chunks(core_bodies, args.batch_size)):
            run_zig_batch(
                zig=zig,
                repo=repo,
                temporary=temporary,
                category="core",
                batch_index=batch_index,
                bodies=batch,
                totals=totals,
            )

        polynomial_sources = unique_random_expressions(
            rng,
            args.polynomial_cases,
            lambda: polynomial_source(rng),
        )
        polynomial_bodies = []
        for index, source in enumerate(polynomial_sources):
            body, assertions = polynomial_body(source, index)
            polynomial_bodies.append(body)
            totals.assertions += assertions
        totals.programs += len(polynomial_bodies)
        for batch_index, batch in enumerate(chunks(polynomial_bodies, args.batch_size)):
            run_zig_batch(
                zig=zig,
                repo=repo,
                temporary=temporary,
                category="polynomial",
                batch_index=batch_index,
                bodies=batch,
                totals=totals,
            )

        rational_sources = unique_random_expressions(
            rng,
            args.rational_cases,
            lambda: rational_function_source(rng),
        )
        rational_bodies = []
        for index, source in enumerate(rational_sources):
            body, assertions = rational_function_body(source, index)
            rational_bodies.append(body)
            totals.assertions += assertions
        totals.programs += len(rational_bodies)
        for batch_index, batch in enumerate(chunks(rational_bodies, args.batch_size)):
            run_zig_batch(
                zig=zig,
                repo=repo,
                temporary=temporary,
                category="rational",
                batch_index=batch_index,
                bodies=batch,
                totals=totals,
            )

        integration_sources = unique_random_expressions(
            rng,
            args.integration_cases,
            lambda: integration_source(rng),
        )
        integration_bodies = []
        for index, source in enumerate(integration_sources):
            body, assertions = integration_body(source, index)
            integration_bodies.append(body)
            totals.assertions += assertions
        totals.programs += len(integration_bodies)
        for batch_index, batch in enumerate(
            chunks(integration_bodies, max(4, args.batch_size // 2))
        ):
            run_zig_batch(
                zig=zig,
                repo=repo,
                temporary=temporary,
                category="integration",
                batch_index=batch_index,
                bodies=batch,
                totals=totals,
            )

        linear_bodies = []
        for index in range(args.linear_cases):
            size = (2, 3, 4)[index % 3]
            body, assertions = linear_body(rng, size, index)
            linear_bodies.append(body)
            totals.assertions += assertions
        totals.programs += len(linear_bodies)
        for batch_index, batch in enumerate(chunks(linear_bodies, 4)):
            run_zig_batch(
                zig=zig,
                repo=repo,
                temporary=temporary,
                category="linear",
                batch_index=batch_index,
                bodies=batch,
                totals=totals,
            )

        quadrature_bodies = []
        for index, case in enumerate(quadrature_sources()):
            body, assertions = quadrature_body(case, index)
            quadrature_bodies.append(body)
            totals.assertions += assertions
        totals.programs += len(quadrature_bodies)
        for batch_index, batch in enumerate(chunks(quadrature_bodies, args.batch_size)):
            run_zig_batch(
                zig=zig,
                repo=repo,
                temporary=temporary,
                category="quadrature",
                batch_index=batch_index,
                bodies=batch,
                totals=totals,
            )

        newton, assertions = newton_body(rng)
        totals.programs += 28
        totals.assertions += assertions
        run_zig_batch(
            zig=zig,
            repo=repo,
            temporary=temporary,
            category="newton",
            batch_index=0,
            bodies=[newton],
            totals=totals,
        )

    return totals


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--zig", default=None)
    parser.add_argument("--core-cases", type=int, default=128)
    parser.add_argument("--polynomial-cases", type=int, default=64)
    parser.add_argument("--rational-cases", type=int, default=48)
    parser.add_argument("--integration-cases", type=int, default=32)
    parser.add_argument("--linear-cases", type=int, default=18)
    parser.add_argument("--batch-size", type=int, default=16)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    totals = execute(args)
    print(
        "SymPy differential validation passed: "
        f"{totals.programs} programs/problems, "
        f"{totals.assertions} oracle assertions, "
        f"{totals.batches} bounded Zig batches "
        f"(seed {SEED:#x}, SymPy {sp.__version__})."
    )


if __name__ == "__main__":
    main()
