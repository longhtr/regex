# Private qualification tools

This directory contains deterministic standalone campaigns used by the complete
test gate. They are engineering executables, not public package utilities, and
are selected through [`../tool_main.zig`](../tool_main.zig).

`zig build test-all` builds and runs these tools through `testing.py`; ordinary
package users never import them.

## File map

| File | Campaign |
|---|---|
| [`fuzz_campaign.zig`](fuzz_campaign.zig) | Structured valid, malformed, and arbitrary-byte public-API fuzzing with reduction |
| [`equivalence_batch.zig`](equivalence_batch.zig) | CLI wrapper around generated direct cross-engine equivalence |
| [`possible_match_campaign.zig`](possible_match_campaign.zig) | Generated lexical-bound containment and exact-extrema checks |
| [`concurrency_stress.zig`](concurrency_stress.zig) | Shared Regex, independent Matcher, deterministic multi-worker stress |

## Campaign contracts

### Fuzzing

SplitMix64 and explicit finite iteration counts make every case reproducible.
Valid generators track small independent semantic families; malformed and
arbitrary-byte modes add panic-freedom, diagnostics, and ownership pressure.
Failures retain a typed mismatch and are reduced only while preserving that same
classification.

### Engine equivalence

The thin batch wrapper selects a finite profile and delegates generation and
direct physical execution to `../engine/equivalence_campaign.zig`. This proves
optional completions agree with complete execution; it is not an independent
regex-language oracle.

### Possible-match analysis

Finite literal/alternation languages provide independently known members and
extrema. The campaign verifies containment, exact finite bounds where applicable,
and empty/unbounded outcomes without using production matches as its oracle.

### Concurrency

The main thread computes reviewed single-thread reference checksums. Workers share
only Regex State, create independent Matchers, and compare deterministic operation
mixes while lazy caches are read, built, contended, exhausted, or bypassed.

## Core invariants

- Every campaign is deterministic for its seed/profile/arguments.
- Bounds are finite and visible; no network or third-party corpus is required.
- Failure output contains enough state to reproduce the case.
- Mutable Matcher scratch and borrowed capture views never cross worker threads.
- Campaign expectations are independent where semantic authority is required.
- Tools remain unreachable from the public `root.zig` graph.

## Safe changes

Keep command-line arguments stable enough for `testing.py`, preserve nonzero exit
status on any mismatch, and update [Testing and Evidence](../../docs/testing.md)
when campaign order, bounds, or output sections change.

## Related documentation

- [Testing and Evidence](../../docs/testing.md)
- [`../testing/README.md`](../testing/README.md)
- [`../engine/README.md`](../engine/README.md)
