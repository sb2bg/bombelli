#!/usr/bin/env python3
"""Compare compiler cost and identical emitted source against a saved checkout.

Fresh local Zig caches, shared global cache, sequential runs. Compiler timings
include executable generation/linking. Peak RSS comes from the system time tool.
Also compares optimized C kernels before/after conservative scratch-slot reuse.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def fixture(kind: str, size: int, target: str) -> str:
    names = [f"x{i}" for i in range(size)]
    tags = ",".join("." + n for n in names)
    if kind == "jacobian":
        shared = "sin(" + "+".join(names) + ")"
        expressions = ",".join(json.dumps(n + "*" + shared) for n in names)
        declaration = f"const model = b.model(.{{{expressions}}}, .{{ .variables = .{{{tags}}} }});\nconst program = model.jacobian().simplify();"
    else:
        residual = "+".join(n + f"*t^{i}" for i, n in enumerate(names)) + "-y"
        declaration = f"const program = b.residualModel(.{{{json.dumps(residual)}}}, .{{ .variables = .{{{tags}}}, .data = .{{.t,.y}} }}).leastSquares().compile(.{{}});"
    return f'''const std = @import("std");
const b = @import("bombelli");
{declaration}
const source = program.emit(.{{ .target = .{target}, .name = "kernel" }});
pub fn main() void {{ std.debug.print("{{s}}", .{{source}}); }}
'''


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def reused_source(source: str) -> tuple[str, int, int]:
    pattern = re.compile(r"^    const double n(\d+) = (.*);$", re.M)
    nodes = list(pattern.finditer(source))
    count = len(nodes)
    assert count and [int(m[1]) for m in nodes] == list(range(count))
    last = list(range(count))
    for i, node in enumerate(nodes):
        for child in re.findall(r"\bn(\d+)\b", node[2]):
            last[int(child)] = i
    # Outputs stay pinned through the final result copy, including duplicates.
    for child in re.findall(r"\bn(\d+)\b", source[nodes[-1].end():]):
        last[int(child)] = count
    slots, ends = [], []
    for i in range(count):
        slot = next((j for j, end in enumerate(ends) if end < i), len(ends))
        if slot == len(ends):
            ends.append(last[i])
        else:
            ends[slot] = last[i]
        slots.append(slot)
    body = source[nodes[0].start():]
    body = pattern.sub(lambda m: f"    n{m[1]} = {m[2]};", body)
    body = re.sub(r"\bn(\d+)\b", lambda m: f"scratch[{slots[int(m[1])]}]", body)
    result = source[:nodes[0].start()] + f"    double scratch[{len(ends)}];\n" + body
    return result, count, len(ends)


def kernel_assembly(path: Path) -> str:
    text = path.read_text()
    match = re.search(r"^_?kernel:.*?\.cfi_endproc", text, re.M | re.S)
    if not match:
        raise RuntimeError("could not locate kernel in generated assembly")
    return match[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("samples must be positive")
    repo = Path(__file__).resolve().parents[1]
    report = dict(platform=platform.platform(), zig=run(["zig", "version"], repo).stdout.strip(),
                  samples=args.samples, cc=run(["cc", "--version"], repo).stdout.splitlines()[0],
                  records=[], slot_reuse=[], complete=False)
    fixtures = [("jacobian", 8, "c"), ("jacobian", 16, "c"), ("fitter", 12, "c"), ("jacobian", 16, "zig")]
    with tempfile.TemporaryDirectory(prefix="bombelli-compiler-") as tmp:
        directory = Path(tmp)
        for kind, size, target in fixtures:
            reference = None
            for label, root in [("before", args.baseline.resolve()), ("after", repo)]:
                elapsed, memory = [], []
                for sample in range(args.samples):
                    name = f"{kind}-{size}-{target}-{label}-{sample}"
                    src, binary = directory / (name + ".zig"), directory / name
                    src.write_text(fixture(kind, size, target))
                    timing = directory / (name + ".time")
                    timer = ["/usr/bin/time", "-l", "-o", str(timing)] if platform.system() == "Darwin" else ["/usr/bin/time", "-f", "%M", "-o", str(timing)]
                    command = ["zig", "build-exe", "-O", "ReleaseFast", "--dep", "bombelli",
                               f"-Mroot={src}", f"-Mbombelli={root / 'src/root.zig'}",
                               "--cache-dir", str(directory / (name + "-cache")), f"-femit-bin={binary}"]
                    started = time.perf_counter()
                    run(timer + command, root)
                    elapsed.append(time.perf_counter() - started)
                    stats = timing.read_text()
                    rss = int(re.search(r"(\d+)\s+maximum resident set size", stats)[1]) if platform.system() == "Darwin" else int(stats.strip()) * 1024
                    memory.append(rss)
                    generated = run([str(binary)], root).stderr
                    digest = hashlib.sha256(generated.encode()).hexdigest()
                    if reference is None:
                        reference = digest
                    assert digest == reference, f"emitted source changed: {name}"
                record = dict(kind=kind, size=size, target=target, version=label,
                              seconds=round(statistics.median(elapsed), 3), peak_rss_bytes=int(statistics.median(memory)),
                              seconds_samples=elapsed, peak_rss_samples=memory,
                              source_bytes=len(generated.encode()), source_sha256=digest)
                report["records"].append(record)
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps(record), flush=True)
            if kind == "jacobian" and target == "c":
                reused, nodes, slots = reused_source(generated)
                assemblies = []
                for label, source in [("ssa", generated), ("slots", reused)]:
                    cpath, asm = directory / (label + ".c"), directory / (label + ".s")
                    cpath.write_text(source)
                    run(["cc", "-O2", "-ffp-contract=off", "-S", str(cpath), "-o", str(asm)], repo)
                    assemblies.append(kernel_assembly(asm))
                result = dict(size=size, logical_nodes=nodes, scratch_slots=slots,
                              identical_optimized_kernel=assemblies[0] == assemblies[1])
                report["slot_reuse"].append(result)
                print(json.dumps(result), flush=True)
    report["complete"] = True
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
