#!/usr/bin/env python3
"""Run the qualification gate and preserve a sectioned failure transcript."""

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
LOG = ROOT / "testing.log"
SECTION_TIMEOUT_SECONDS = 10 * 60


def append_log(path, text):
    """Append one driver record without sharing a buffered offset with children."""
    with path.open("a", encoding="utf-8") as log:
        log.write(text)
        log.flush()


def run(name, command, timeout=SECTION_TIMEOUT_SECONDS, log_path=LOG):
    """Run one section with child output appended directly to the transcript."""
    separator = "\n" if log_path.stat().st_size != 0 else ""
    append_log(log_path, f"{separator}{name}\n{'=' * len(name)}\n")

    try:
        # Append mode is deliberate: child and grandchild processes may write
        # through duplicated descriptors, and must never overwrite prior sections.
        with log_path.open("ab", buffering=0) as output:
            result = subprocess.run(
                command,
                cwd=ROOT,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
    except subprocess.TimeoutExpired:
        append_log(log_path, f"\n{name}: TIMEOUT ({timeout} seconds)\n")
        print(f"{name} timed out; see {LOG.name}", file=sys.stderr)
        return 124

    if result.returncode == 0:
        append_log(log_path, f"\n{name}: OK\n")
    else:
        append_log(log_path, f"\n{name}: FAIL ({result.returncode})\n")
        print(f"{name} failed; see {LOG.name}", file=sys.stderr)
    return result.returncode


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in {"quick", "full"}:
        print("invalid testing.py arguments", file=sys.stderr)
        return 2

    mode = sys.argv[1]
    debug = sys.argv[2]
    LOG.write_text("", encoding="utf-8")

    if mode == "quick":
        if len(sys.argv) != 3:
            return 2
        if run("unit tests / Debug", [debug]):
            return 1
    else:
        if len(sys.argv) != 10:
            return 2
        safe, fast, fuzz, fuzz_iterations, forced, possible, concurrency = sys.argv[3:]
        if run("repository checks", ["zig", "build", "check"]):
            return 1

        for build_mode, executable in (
            ("Debug", debug),
            ("ReleaseSafe", safe),
            ("ReleaseFast", fast),
        ):
            if run(f"unit tests / {build_mode}", [executable]):
                return 1

        campaigns = [
            (
                "fuzz campaign",
                [
                    fuzz,
                    "--seed",
                    "8243113891643328122",
                    "--iterations",
                    fuzz_iterations,
                ],
            ),
            ("forced-engine campaign", [forced, "--profile", "full"]),
            ("possible-match campaign", [possible]),
        ]
        for workers in (1, 2, 4, 8):
            worker_label = "worker" if workers == 1 else "workers"
            campaigns.append(
                (
                    f"concurrency stress / {workers} {worker_label}",
                    [
                        concurrency,
                        "--epochs",
                        "5",
                        "--workers",
                        str(workers),
                        "--iterations",
                        "1000",
                        "--seed",
                        hex(0xC011AB1E5EED + workers),
                    ],
                )
            )
        for name, command in campaigns:
            if run(name, command):
                return 1

    print(f"all tests passed; results written to {LOG.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
