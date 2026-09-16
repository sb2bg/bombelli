#!/usr/bin/env python3
"""Compare direct products with a simplified explicit Jacobian.

Each binary is compiled with ReleaseFast in a fresh local cache, sharing the
normal global compiler cache. Timings include process startup. Inputs and
seeds vary at runtime, and every output is kept observable. Results describe
this fixture and machine, not a general performance guarantee.
"""
from __future__ import annotations

import argparse
import json
import math
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def source(size: int, kind: str, strategy: str, iterations: int, shape: str) -> str:
    names = [f"x{i}" for i in range(size)]
    shared = "sin(" + "+".join(names) + ")"
    expressions = [
        f"{name}*{shared}" if shape == "shared" else f"sin({name}*{names[(i+1) % size]})+{name}^2"
        for i, name in enumerate(names)
    ]
    sources = ",".join(json.dumps(expression) for expression in expressions)
    variables = ",".join("." + name for name in names)
    fields = ",".join(f".{name} = t + {i / 100.0}" for i, name in enumerate(names))
    seed = ",".join(f"t + {(i+1)/50.0}" for i in range(size))
    if strategy == "explicit":
        declaration = "const compiled = model.jacobian().simplify();"
        evaluation = f"""
        const jacobian = compiled.eval(point);
        var result = [_]f64{{0}} ** {size};
        for (0..{size}) |row| {{
            for (0..{size}) |column| {{
                {'result[row] += jacobian[row][column] * seed[column];' if kind == 'jvp' else 'result[column] += jacobian[row][column] * seed[row];'}
            }}
        }}
"""
        method = '"explicit"'
        metrics = "compiled.metrics()"
    else:
        declaration = f"const compiled = model.compile{'Jvp' if kind == 'jvp' else 'Vjp'}(.{{ .strategy = .{strategy} }});"
        evaluation = "const result = compiled.eval(point, seed);"
        method = "@tagName(compiled.inspect().method)"
        metrics = "compiled.expression.metrics()"
    return f"""
const std = @import("std");
const bombelli = @import("bombelli");
const model = bombelli.model(.{{{sources}}}, .{{ .variables = .{{{variables}}} }});
{declaration}
pub fn main() void {{
    var state: u64 = 1234567;
    var total: f64 = 0;
    for (0..{iterations}) |_| {{
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const t = @as(f64, @floatFromInt(state >> 11)) / 9007199254740992.0;
        const point = .{{{fields}}};
        const seed = [{size}]f64{{{seed}}};
        {evaluation}
        std.mem.doNotOptimizeAway(result);
        for (result, 0..) |value, i| total += value * @as(f64, @floatFromInt(i+1));
    }}
    const metrics = comptime {metrics};
    std.debug.print("{{s}} {{d}} {{d}} {{d:.17}}\\n", .{{{method}, metrics.node_count, metrics.construction_peak_nodes, total}});
}}
"""


def run(command: list[str], repo: Path) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=repo, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=[4, 8, 16])
    parser.add_argument("--iterations", type=int, default=1_000_000)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--shape", choices=["shared", "sparse"], default="shared")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if min(args.sizes) < 2 or args.iterations < 1 or args.samples < 1:
        parser.error("sizes must be at least 2; iterations and samples must be positive")
    repo = Path(__file__).resolve().parents[1]
    zig = shutil.which("zig")
    if zig is None:
        raise SystemExit("zig is not on PATH")
    records = []
    report = dict(platform=platform.platform(), zig=run([zig, "version"], repo).stdout.strip(),
                  shape=args.shape, iterations=args.iterations, samples=args.samples,
                  complete=False, records=records)

    def save() -> None:
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="bombelli-products-") as directory:
        temporary = Path(directory)
        for size in args.sizes:
            for kind in ("jvp", "vjp"):
                reference = None
                for strategy in ("explicit", "direct", "auto"):
                    name = f"{size}-{kind}-{strategy}"
                    path = temporary / f"{name}.zig"
                    binary = temporary / name
                    path.write_text(source(size, kind, strategy, args.iterations, args.shape))
                    started = time.perf_counter()
                    command = [zig, "build-exe", "-O", "ReleaseFast", "--dep", "bombelli",
                               f"-Mroot={path}", f"-Mbombelli={repo / 'src/root.zig'}",
                               "--cache-dir", str(temporary / f"cache-{name}"),
                               f"-femit-bin={binary}"]
                    compilation = subprocess.run(command, cwd=repo, capture_output=True, text=True)
                    compile_seconds = time.perf_counter() - started
                    if compilation.returncode:
                        if strategy == "explicit" and "temporary arena limit" in compilation.stderr:
                            record = dict(size=size, kind=kind, strategy=strategy,
                                          status="construction_limit", compile_seconds=round(compile_seconds, 3))
                            records.append(record)
                            save()
                            print(json.dumps(record), flush=True)
                            continue
                        raise SystemExit(compilation.stdout + compilation.stderr)
                    run([str(binary)], repo)  # warm up the executable
                    samples = []
                    for _ in range(args.samples):
                        started = time.perf_counter()
                        completed = run([str(binary)], repo)
                        samples.append(time.perf_counter() - started)
                        method, nodes, peak, total = completed.stderr.split()
                        value = float(total)
                        if reference is None:
                            reference = value
                        if not math.isclose(value, reference, rel_tol=1e-10, abs_tol=1e-8):
                            raise SystemExit(f"checksum mismatch in {name}: {value} versus {reference}")
                    record = dict(size=size, kind=kind, strategy=strategy, status="ok", selected=method,
                                  nodes=int(nodes), construction_peak=int(peak),
                                  compile_seconds=round(compile_seconds, 3),
                                  ns_per_eval=round(statistics.median(samples)*1e9/args.iterations, 2),
                                  binary_bytes=binary.stat().st_size, checksum=value)
                    records.append(record)
                    save()
                    print(json.dumps(record), flush=True)
    report["complete"] = True
    save()


if __name__ == "__main__":
    main()
