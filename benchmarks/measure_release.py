#!/usr/bin/env python3
"""Reproduce Bombelli's compile scaling, emission size, and runtime baseline."""

from __future__ import annotations

import json
import math
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def run(
    command: list[str],
    *,
    cwd: Path,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if completed.returncode != 0:
        if capture:
            print(completed.stdout)
            print(completed.stderr)
        raise SystemExit(f"command failed: {' '.join(command)}")
    return completed


def compile_case(
    zig: str,
    repo: Path,
    temporary: Path,
    global_cache: Path,
    name: str,
    source: str,
) -> dict[str, float | int | str]:
    source_path = temporary / f"{name}.zig"
    source_path.write_text(source)
    local_cache = temporary / f"cache-{name}"
    command = [
        zig,
        "test",
        "--dep",
        "bombelli",
        f"-Mroot={source_path}",
        f"-Mbombelli={repo / 'src' / 'root.zig'}",
        "--cache-dir",
        str(local_cache),
        "--global-cache-dir",
        str(global_cache),
    ]
    started = time.perf_counter()
    run(command, cwd=repo)
    elapsed = time.perf_counter() - started
    return {
        "name": name,
        "wall_seconds": round(elapsed, 3),
        "source_bytes": len(source.encode()),
    }


def nested_sine(depth: int) -> str:
    result = "x"
    for _ in range(depth):
        result = f"sin({result})"
    return result


def expression_depth_case(depth: int) -> str:
    source = nested_sine(depth)
    return f"""
const std = @import("std");
const bombelli = @import("bombelli");
const derivative = bombelli.expr({json.dumps(source)}).diff(.x).simplify();
comptime {{ _ = derivative.metrics(); }}
test {{ try std.testing.expect(std.math.isFinite(derivative.eval(.{{ .x = 0.4 }}))); }}
"""


def symbol_case(count: int) -> str:
    names = [f"x{index}" for index in range(count)]
    terms = [
        f"sin({names[index]}*{names[(index + 1) % count]})"
        for index in range(count)
    ]
    expression = " + ".join(terms)
    variables = ", ".join(f".{name}" for name in names)
    inputs = ", ".join(f".{name} = 0.2" for name in names)
    return f"""
const std = @import("std");
const bombelli = @import("bombelli");
const gradient = bombelli.expr({json.dumps(expression)})
    .gradient(.{{ {variables} }}).simplify();
comptime {{ _ = gradient.metrics(); }}
test {{
    const values = gradient.eval(.{{ {inputs} }});
    for (values) |value| try std.testing.expect(std.math.isFinite(value));
}}
"""


def symbolic_system_case(size: int) -> str:
    unknowns = ("x", "y", "z", "w")[:size]
    coefficients = ("a", "b", "c", "d")[:size]
    rhs = ("e", "f", "g", "h")[:size]
    equations = []
    for row in range(size):
        terms = []
        for column, unknown in enumerate(unknowns):
            coefficient = coefficients[row] if column == row else "1"
            terms.append(f"{coefficient}*{unknown}")
        equations.append(json.dumps(" + ".join(terms) + f" = {rhs[row]}"))
    equation_tuple = ",\n    ".join(equations)
    unknown_tuple = ", ".join(f".{unknown}" for unknown in unknowns)
    parameter_values = [
        f".{name} = {float(index + size + 1)}"
        for index, name in enumerate(coefficients)
    ]
    parameter_values.extend(
        f".{name} = {float(index + 1)}" for index, name in enumerate(rhs)
    )
    inputs = ", ".join(parameter_values)
    return f"""
const std = @import("std");
const bombelli = @import("bombelli");
const result = bombelli.system(.{{
    {equation_tuple},
}}, .{{
    .unknowns = .{{ {unknown_tuple} }},
    .domain = .real,
}}).solve(.bareiss);
comptime {{
    if (result != .conditional) @compileError("expected a conditional solution");
    _ = result.conditional.values.metrics();
}}
test {{
    const values = result.conditional.values.eval(.{{ {inputs} }});
    for (values) |value| try std.testing.expect(std.math.isFinite(value));
}}
"""


def measure_scaling(
    zig: str,
    repo: Path,
    temporary: Path,
) -> list[dict[str, float | int | str]]:
    global_cache = temporary / "global-cache"
    compile_case(
        zig,
        repo,
        temporary,
        global_cache,
        "warmup",
        """
const std = @import("std");
const bombelli = @import("bombelli");
const value = bombelli.expr("x").diff(.x).simplify();
test { try std.testing.expectEqual(@as(f64, 1.0), value.eval(.{})); }
""",
    )
    cases: list[tuple[str, str]] = []
    for depth in (4, 8, 12, 16):
        cases.append((f"depth-{depth}", expression_depth_case(depth)))
    for count in (2, 4, 8, 16):
        cases.append((f"symbols-{count}", symbol_case(count)))
    for size in (2, 3, 4):
        cases.append((f"symbolic-system-{size}x{size}", symbolic_system_case(size)))

    results = []
    for name, source in cases:
        result = compile_case(
            zig,
            repo,
            temporary,
            global_cache,
            name,
            source,
        )
        results.append(result)
        print(f"{name}: {result['wall_seconds']:.3f}s", flush=True)
    return results


def measure_emission(
    zig: str,
    repo: Path,
    temporary: Path,
) -> list[dict[str, int | str]]:
    generators = (
        "generate_expression_emission.zig",
        "generate_quadrature_emission.zig",
        "generate_newton_emission.zig",
    )
    results = []
    for name in generators:
        generated = run(
            [
                zig,
                "run",
                "--dep",
                "bombelli",
                f"-Mroot={repo / 'tests' / 'codegen' / name}",
                f"-Mbombelli={repo / 'src' / 'root.zig'}",
            ],
            cwd=repo,
        ).stdout
        source_path = temporary / name.replace("generate_", "")
        object_path = temporary / (source_path.stem + ".o")
        source_path.write_text(generated)
        run(
            [
                zig,
                "build-obj",
                str(source_path),
                "-OReleaseFast",
                f"-femit-bin={object_path}",
            ],
            cwd=repo,
        )
        result = {
            "name": name,
            "source_bytes": len(generated.encode()),
            "object_bytes": object_path.stat().st_size,
        }
        results.append(result)
        print(
            f"{name}: {result['source_bytes']} source bytes, "
            f"{result['object_bytes']} object bytes",
            flush=True,
        )
    return results


def compile_runtime_binary(
    zig: str,
    repo: Path,
    temporary: Path,
    source_name: str,
    output_name: str,
    with_bombelli: bool,
) -> Path:
    output = temporary / output_name
    command = [zig, "build-exe", "-OReleaseFast"]
    if with_bombelli:
        command.extend(
            (
                "--dep",
                "bombelli",
                f"-Mroot={repo / 'benchmarks' / source_name}",
                f"-Mbombelli={repo / 'src' / 'root.zig'}",
            )
        )
    else:
        command.extend(
            (
                f"-Mroot={repo / 'benchmarks' / source_name}",
                f"-femit-bin={output}",
            )
        )
    if with_bombelli:
        command.append(f"-femit-bin={output}")
    run(command, cwd=repo)
    return output


def timed_run(executable: Path, repo: Path) -> tuple[float, float]:
    started = time.perf_counter_ns()
    completed = run([str(executable)], cwd=repo)
    elapsed = (time.perf_counter_ns() - started) / 1e9
    output = completed.stderr.strip() or completed.stdout.strip()
    return elapsed, float(output)


def measure_runtime(
    zig: str,
    repo: Path,
    temporary: Path,
) -> dict[str, float | int]:
    bombelli_binary = compile_runtime_binary(
        zig,
        repo,
        temporary,
        "runtime_bombelli.zig",
        "runtime-bombelli",
        True,
    )
    handwritten_binary = compile_runtime_binary(
        zig,
        repo,
        temporary,
        "runtime_handwritten.zig",
        "runtime-handwritten",
        False,
    )
    samples: dict[str, list[float]] = {"bombelli": [], "handwritten": []}
    totals: dict[str, float] = {}
    order = (
        ("bombelli", bombelli_binary),
        ("handwritten", handwritten_binary),
    )
    for round_index in range(8):
        for label, executable in (order if round_index % 2 == 0 else reversed(order)):
            elapsed, total = timed_run(executable, repo)
            totals[label] = total
            if round_index != 0:
                samples[label].append(elapsed)
    if not math.isclose(
        totals["bombelli"],
        totals["handwritten"],
        rel_tol=2e-13,
        abs_tol=2e-8,
    ):
        raise SystemExit("Bombelli and handwritten benchmark totals differ")
    iterations = 5_000_000
    bombelli_seconds = statistics.median(samples["bombelli"])
    handwritten_seconds = statistics.median(samples["handwritten"])
    result = {
        "iterations": iterations,
        "bombelli_median_seconds": round(bombelli_seconds, 6),
        "handwritten_median_seconds": round(handwritten_seconds, 6),
        "bombelli_ns_per_eval": round(bombelli_seconds * 1e9 / iterations, 3),
        "handwritten_ns_per_eval": round(
            handwritten_seconds * 1e9 / iterations,
            3,
        ),
        "ratio": round(bombelli_seconds / handwritten_seconds, 4),
    }
    print(
        "runtime: "
        f"{result['bombelli_ns_per_eval']} ns/eval Bombelli, "
        f"{result['handwritten_ns_per_eval']} ns/eval handwritten, "
        f"{result['ratio']}x",
        flush=True,
    )
    return result


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    zig = shutil.which("zig")
    if zig is None:
        raise SystemExit("zig was not found on PATH")
    with tempfile.TemporaryDirectory(prefix="bombelli-release-measurement-") as temp:
        temporary = Path(temp)
        report = {
            "machine": {
                "platform": platform.platform(),
                "processor": platform.processor(),
                "zig": run([zig, "version"], cwd=repo).stdout.strip(),
            },
            "compile_scaling": measure_scaling(zig, repo, temporary),
            "emission": measure_emission(zig, repo, temporary),
            "runtime": measure_runtime(zig, repo, temporary),
        }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
