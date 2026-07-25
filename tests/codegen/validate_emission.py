#!/usr/bin/env python3
"""Generate, inspect, compile, and execute standalone emitted Zig."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


GENERATORS = (
    "generate_expression_emission.zig",
    "generate_quadrature_emission.zig",
    "generate_newton_emission.zig",
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


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    zig = shutil.which("zig")
    if zig is None:
        raise SystemExit("zig was not found on PATH")

    total_bytes = 0
    with tempfile.TemporaryDirectory(prefix="bombelli-emission-") as temp:
        temporary = Path(temp)
        for generator_name in GENERATORS:
            generator = repo / "tests" / "codegen" / generator_name
            generated = run(
                [
                    zig,
                    "run",
                    "--dep",
                    "bombelli",
                    f"-Mroot={generator}",
                    f"-Mbombelli={repo / 'src' / 'root.zig'}",
                ],
                repo,
            ).stdout
            for forbidden in FORBIDDEN:
                if forbidden in generated:
                    raise SystemExit(
                        f"{generator_name} emitted forbidden runtime machinery: "
                        f"{forbidden}"
                    )

            output = temporary / generator_name.replace("generate_", "")
            output.write_text(generated)
            run([zig, "test", str(output)], repo)
            total_bytes += len(generated.encode())
            print(
                f"{generator_name}: {len(generated.encode())} bytes, "
                "standalone behavior passed",
                flush=True,
            )

    print(
        f"Standalone emission validation passed for {len(GENERATORS)} "
        f"callable types ({total_bytes} source bytes total)."
    )


if __name__ == "__main__":
    main()
