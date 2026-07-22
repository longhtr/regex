# Benchmark implementation

This directory defines typed benchmark workloads and the ReleaseFast subprocess
adapter used by `benchmark.py`. Benchmarks measure qualified public operations;
they are not semantic tests, cross-engine rankings, or timing pass/fail gates.

Read [Benchmarking](../../docs/benchmark.md) before interpreting or extending the
catalog.

## Process architecture

```text
workloads.zig      reviewed declarative tasks and exact expectations
campaign.zig       deterministic generated scaling coordinates
adapter.zig        materialize, qualify, warm, time, verify, report
benchmark.py       isolate processes, calibrate, summarize, write benchmark.log
```

Each adapter process handles listing or one workload/sample command. Large
pattern and input generators are materialized outside the timed region. Reusable
match workloads retain warmed Regex/Matcher state; compile workloads construct and
destroy inside each timed iteration.

## File map

| File | Responsibility |
|---|---|
| [`workloads.zig`](workloads.zig) | Typed task union, compact sources, handwritten catalog, exact observations |
| [`campaign.zig`](campaign.zig) | Explicit geometric and boundary-focused scaling series |
| [`adapter.zig`](adapter.zig) | Public owner setup, qualification, timing, digest verification, metrics protocol |
| [`data/`](data/README.md) | Attributed external regression shapes and synthetic redistributable inputs |

## Qualification before timing

For one sample, the adapter:

1. materializes pattern and input;
2. constructs the required public owners;
3. checks the exact expected observation;
4. runs an untimed warm-up batch where the workload permits reuse;
5. times an equal operation batch;
6. verifies the timed digest;
7. records route and requested-resource snapshots.

Any expectation, digest, or cross-sample route disagreement aborts the benchmark
instead of recording ambiguous timing.

## Workload standards

- Names describe the operation and cost shape.
- Expected values are spans, groups, booleans, counts, or IDs—not values copied
  from an earlier benchmark run.
- Inputs and patterns are deterministic, finite, and self-contained.
- Task variants name public products, not requested physical engines.
- Materialization and reporting stay outside timing.
- Owned-result traversal and teardown stay inside timing when part of operation
  cost.
- Timing does not establish correctness or become a repository gate.
- External regression assets require provenance, license, transformation, and a
  redistributable input story.

Private route/resource observations enter only through `../internal.zig`. They
must not leak engine selection into the public API.

## Adding a workload

1. State the engineering question and choose one public operation.
2. Define compact deterministic pattern/input sources.
3. Write the expected observation directly and qualify it before timing.
4. Decide explicitly what setup, traversal, and teardown belong in the timed
   operation.
5. Add a handwritten workload or a finite scaling series.
6. Run semantic qualification before measurement.
7. Document any external provenance in `data/README.md`.

## Commands

```sh
zig build test-all
zig build benchmark
zig build benchmark -Dbenchmark-samples=3
```

`benchmark.log` is a local measurement. Compare logs only under controlled
machine, toolchain, process, power, and source conditions.

## Related documentation

- [Benchmarking](../../docs/benchmark.md)
- [Testing and Evidence](../../docs/testing.md)
- [`../testing/README.md`](../testing/README.md)
- [`data/README.md`](data/README.md)
