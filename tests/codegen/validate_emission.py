#!/usr/bin/env python3
"""Generate, inspect, compile, and execute standalone emitted Zig and C.

Every case is emitted for both targets from one shared definition in
``cases.zig``. The Zig target is checked by a Zig test harness that compares
the emitted callable against Bombelli's own evaluator; the C target is
compiled with strict warnings, executed, and compared against the values
``reference_emission.zig`` prints from that same evaluator.
"""

from __future__ import annotations

import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CASE_NAMES = tuple(
    (Path(__file__).with_name("case_names.txt")).read_text().splitlines()
)

FORBIDDEN = (
    '@import("bombelli")',
    "ast.Node",
    "Builder",
    "parser.",
    "switch (node",
    "allocator",
    ".alloc(",
)

# Emitted C must reach for nothing beyond these standard headers.
PERMITTED_INCLUDES = ("<math.h>", "<stddef.h>")

# Contraction is disabled so that a fused multiply-add cannot paper over, or
# manufacture, a difference between the emitted C and Bombelli's evaluator.
C_FLAGS = (
    "-std=c99",
    "-O2",
    "-ffp-contract=off",
    "-Wall",
    "-Wextra",
    "-Werror",
)

TOLERANCE = 1e-12


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit(f"command failed: {' '.join(command)}")
    return completed


def generate(zig: str, repo: Path, case: str, target: str) -> str:
    source = run(
        [
            zig,
            "run",
            "--dep",
            "bombelli",
            f"-Mroot={repo / 'tests' / 'codegen' / 'generate.zig'}",
            f"-Mbombelli={repo / 'src' / 'root.zig'}",
            "--",
            case,
            target,
        ],
        repo,
    ).stdout
    for forbidden in FORBIDDEN:
        if forbidden in source:
            raise SystemExit(
                f"{case}/{target} emitted forbidden runtime machinery: {forbidden}"
            )
    return source


def check_c_includes(generator: str, source: str) -> None:
    for line in source.splitlines():
        if not line.startswith("#include"):
            continue
        header = line[len("#include") :].strip()
        if header not in PERMITTED_INCLUDES:
            raise SystemExit(
                f"{generator} emitted C that is not standalone: {line}"
            )


def parse_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        label, _, value = line.partition(" ")
        values[label] = value.strip()
    return values


def compare(case: str, reference: dict[str, str], actual: dict[str, str]) -> None:
    if not actual:
        raise SystemExit(f"{case}: the C driver printed nothing")
    for label, printed in actual.items():
        if label not in reference:
            raise SystemExit(
                f"{case}: the C driver printed unknown label {label!r}"
            )
        expected = reference[label]
        if math.isclose(
            float(expected),
            float(printed),
            rel_tol=TOLERANCE,
            abs_tol=TOLERANCE,
        ):
            continue
        raise SystemExit(
            f"{case}: emitted C disagrees with Bombelli on {label}: "
            f"expected {expected}, computed {printed}"
        )


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    codegen = repo / "tests" / "codegen"
    zig = shutil.which("zig")
    if zig is None:
        raise SystemExit("zig was not found on PATH")

    reference = parse_values(
        run(
            [
                zig,
                "run",
                "--dep",
                "bombelli",
                f"-Mroot={codegen / 'reference_emission.zig'}",
                f"-Mbombelli={repo / 'src' / 'root.zig'}",
            ],
            repo,
        ).stdout
    )

    total_bytes = 0
    with tempfile.TemporaryDirectory(prefix="bombelli-emission-") as temp:
        temporary = Path(temp)
        for case in CASE_NAMES:
            zig_source = generate(zig, repo, case, "zig")
            unit = temporary / f"{case}_emission.zig"
            unit.write_text(zig_source)
            run(
                [
                    zig,
                    "test",
                    "--dep",
                    "generated",
                    "--dep",
                    "bombelli",
                    f"-Mroot={codegen / f'test_{case}_emission.zig'}",
                    f"-Mgenerated={unit}",
                    f"-Mbombelli={repo / 'src' / 'root.zig'}",
                ],
                repo,
            )

            c_source = generate(zig, repo, case, "c")
            check_c_includes(case, c_source)
            c_unit = f"generated_{case}.c"
            c_driver = f"drive_{case}.c"
            (temporary / c_unit).write_text(c_source)
            shutil.copy(codegen / c_driver, temporary / c_driver)
            executable = temporary / f"{case}_driver"
            run(
                [zig, "cc", *C_FLAGS, c_driver, "-o", str(executable), "-lm"],
                temporary,
            )
            compare(
                case,
                reference,
                parse_values(run([str(executable)], temporary).stdout),
            )

            emitted = len(zig_source.encode()) + len(c_source.encode())
            total_bytes += emitted
            print(
                f"{case}: {len(zig_source.encode())} bytes of Zig, "
                f"{len(c_source.encode())} bytes of C, "
                "standalone behavior passed for both targets",
                flush=True,
            )

    print(
        f"Standalone emission validation passed for {len(CASE_NAMES)} "
        f"callable types across 2 targets ({total_bytes} source bytes total)."
    )


if __name__ == "__main__":
    main()
