#!/usr/bin/env python3
"""Benchmark every project workload with independent adapter processes."""

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
from pathlib import Path

try:
    import resource
except ImportError:
    resource = None

ROOT = Path(__file__).resolve().parent
DEFAULT_ADAPTER = ROOT / "zig-out/bin/regex-benchmark"


def decode_patterns(encoded):
    kind, separator, payload = encoded.partition(":")
    if not separator or kind not in {"s", "l"}:
        raise RuntimeError("invalid catalog pattern encoding")
    values = [payload] if kind == "s" else ([] if not payload else payload.split(","))
    try:
        patterns = [bytes.fromhex(value).decode("utf-8") for value in values]
    except (UnicodeDecodeError, ValueError) as error:
        raise RuntimeError("invalid catalog pattern encoding") from error
    return patterns[0] if kind == "s" else patterns


def catalog(adapter):
    output = subprocess.run(
        [str(adapter), "--list"], check=True, capture_output=True, text=True
    ).stdout
    workloads = []
    indexes = set()
    for line in output.splitlines():
        fields = line.split("\t", 3)
        if len(fields) != 4:
            raise RuntimeError(f"invalid catalog row: {line!r}")
        index, operation, name, patterns = fields
        if not index or index in indexes or not operation or not name:
            raise RuntimeError(f"invalid or duplicate workload: {line!r}")
        indexes.add(index)
        workloads.append(
            {
                "index": index,
                "operation": operation,
                "name": name,
                "pattern": decode_patterns(patterns),
            }
        )
    if not workloads:
        raise RuntimeError("benchmark catalog is empty")
    return workloads


def parse_measurement(index, output):
    fields = dict(item.split("=", 1) for item in output.strip().split())
    if fields.pop("case", None) != index:
        raise RuntimeError(f"workload {index}: invalid adapter result")
    route = fields.pop("route")
    values = {key: int(value) for key, value in fields.items()}
    values["route"] = route
    if values["iterations"] <= 0 or values["elapsed_ns"] < 0:
        raise RuntimeError(f"workload {index}: invalid timing result")
    return values


def execute(adapter, index, iterations, timeout, memory_bytes):
    def limit_memory():
        resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))

    completed = subprocess.run(
        [str(adapter), "--run", index, str(iterations)],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
        preexec_fn=limit_memory if resource is not None else None,
    )
    return parse_measurement(index, completed.stdout)


def calibrate(adapter, index, target_ns, timeout, memory_bytes):
    iterations = 1
    while True:
        result = execute(adapter, index, iterations, timeout, memory_bytes)
        elapsed = max(result["elapsed_ns"], 1)
        if elapsed >= target_ns // 5 or iterations == 10_000_000:
            return max(1, min(10_000_000, round(iterations * target_ns / elapsed)))
        iterations = min(10_000_000, iterations * 10)


def benchmark(adapter, workload, samples, target_ns, timeout, memory_bytes):
    index = workload["index"]
    iterations = calibrate(adapter, index, target_ns, timeout, memory_bytes)
    measurements = [
        execute(adapter, index, iterations, timeout, memory_bytes)
        for _ in range(samples)
    ]
    routes = {value["route"] for value in measurements}
    checksums = {value["checksum"] for value in measurements}
    if len(routes) != 1 or len(checksums) != 1:
        raise RuntimeError(
            f"{workload['name']}: unstable route or checksum: routes={routes} checksums={checksums}"
        )
    timings = [value["elapsed_ns"] / iterations for value in measurements]
    median = statistics.median(timings)
    result = {
        "type": "workload",
        **workload,
        "iterations": iterations,
        "samples_ns": timings,
        "median_ns": median,
        "mad_ns": statistics.median(abs(value - median) for value in timings),
        "route": routes.pop(),
    }
    for key in measurements[0]:
        if key not in {"elapsed_ns", "iterations", "checksum", "route"}:
            result[key] = max(value[key] for value in measurements)
    return result


def format_ns(value):
    if value < 1_000:
        return f"{value:.3f} ns"
    if value < 1_000_000:
        return f"{value / 1_000:.3f} μs"
    if value < 1_000_000_000:
        return f"{value / 1_000_000:.3f} ms"
    return f"{value / 1_000_000_000:.3f} s"


def format_bytes(value):
    if value < 1024:
        return f"{value} B"
    if value < 1024 * 1024:
        return f"{value / 1024:.2f} KiB"
    return f"{value / (1024 * 1024):.2f} MiB"


def format_patterns(patterns):
    def format_pattern(pattern):
        if len(pattern) <= 200:
            return json.dumps(pattern, ensure_ascii=False)
        prefix = json.dumps(pattern[:100], ensure_ascii=False)
        suffix = json.dumps(pattern[-100:], ensure_ascii=False)
        return f"{prefix} ++ [{len(pattern) - 200} omitted characters] ++ {suffix}"

    if isinstance(patterns, str):
        return format_pattern(patterns)
    return "[" + ", ".join(format_pattern(pattern) for pattern in patterns) + "]"


def format_record(record):
    if record["type"] == "metadata":
        return "\n".join(
            [
                "Regex benchmark",
                "===============",
                f"source SHA-256:         {record['benchmark_source_sha256']}",
                f"platform:               {record['platform']}",
                f"machine:                {record['machine']}",
                f"logical CPUs:           {record['logical_cpus']}",
                f"Zig:                    {record['zig']}",
                f"Python:                 {record['python']}",
                f"samples per workload:   {record['samples']}",
                f"target sample time:     {record['target_ms']} ms",
                f"timeout:                {record['timeout_seconds']} s",
                f"process memory limit:   {record['memory_limit_mib']} MiB",
                f"memory limit supported: {record['memory_limit_supported']}",
                "",
            ]
        )
    if record["type"] == "complete":
        return "\n".join(
            [
                "Benchmark complete",
                "==================",
                f"workloads: {record['workloads']}",
                "status:    pass",
                "",
            ]
        )

    samples = ", ".join(format_ns(value) for value in record["samples_ns"])
    return "\n".join(
        [
            f"[{record['name']}]",
            f"  operation:    {record['operation']}",
            f"  result:       {format_ns(record['median_ns'])}/op (MAD {format_ns(record['mad_ns'])})",
            f"  samples:      {samples}",
            f"  iterations:   {record['iterations']} per sample",
            f"  route:        {record['route']}",
            f"  input:        {format_bytes(record['input_bytes'])}",
            f"  pattern:      {format_patterns(record['pattern'])}",
            f"  memory:       {format_bytes(record['retained_bytes'])} retained, {format_bytes(record['peak_bytes'])} peak",
            f"  allocations:  {record['allocations']}",
            f"  DFA cache:    {format_bytes(record['dfa_cache_live_bytes'])} live, {format_bytes(record['dfa_cache_peak_bytes'])} peak, exhausted={bool(record['dfa_exhausted'])}",
            f"  DFA contents: {record['dfa_states']} states, {record['dfa_instruction_ids']} instruction IDs, {record['dfa_transition_slots']} transition slots, {format_bytes(record['dfa_hash_bytes'])} hash storage",
            "",
        ]
    )


def source_digest():
    digest = hashlib.sha256()
    digest.update((ROOT / "benchmark.py").read_bytes())
    benchmark_root = ROOT / "src/benchmark"
    for path in sorted(value for value in benchmark_root.rglob("*") if value.is_file()):
        digest.update(path.relative_to(benchmark_root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--adapter", type=Path, default=DEFAULT_ADAPTER)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--target-ms", type=int, default=200)
    parser.add_argument("--timeout-seconds", type=int, default=120)
    parser.add_argument("--memory-mib", type=int, default=2048)
    args = parser.parse_args()
    if args.samples <= 0 or args.target_ms <= 0 or args.memory_mib <= 0:
        parser.error("samples, target-ms, and memory-mib must be positive")

    metadata = {
        "type": "metadata",
        "benchmark_source_sha256": source_digest(),
        "zig": subprocess.run(
            ["zig", "version"], check=True, capture_output=True, text=True
        ).stdout.strip(),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "logical_cpus": os.cpu_count(),
        "samples": args.samples,
        "target_ms": args.target_ms,
        "timeout_seconds": args.timeout_seconds,
        "memory_limit_mib": args.memory_mib,
        "memory_limit_supported": resource is not None,
    }
    memory_bytes = args.memory_mib * 1024 * 1024
    output_path = ROOT / "benchmark.log"
    with output_path.open("w") as output:

        def emit(record):
            output.write(format_record(record) + "\n")
            output.flush()
            if record["type"] == "workload":
                print(
                    f"{record['name']}: {format_ns(record['median_ns'])}/op",
                    flush=True,
                )
            else:
                print(format_record(record), flush=True)

        emit(metadata)
        workloads = catalog(args.adapter)
        for workload in workloads:
            emit(
                benchmark(
                    args.adapter,
                    workload,
                    args.samples,
                    args.target_ms * 1_000_000,
                    args.timeout_seconds,
                    memory_bytes,
                )
            )
        emit({"type": "complete", "workloads": len(workloads)})


if __name__ == "__main__":
    main()
