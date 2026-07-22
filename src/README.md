# Source tree

This directory contains the implementation, qualification code, private tools,
and benchmark adapter for `regex`. Public users should start with the
[API guide](../docs/api.md), [syntax guide](../docs/syntax.md), and
[examples](../examples/README.md). This document is for contributors who need to
find the owner of a behavior or follow data through the implementation.

## End-to-end map

```text
pattern bytes
  → syntax/           scan, parse, normalize, and diagnose
  → optimize/         apply narrowly proved syntax rewrites
  → program/          build Thompson graph and publish immutable Program
  → compiled.zig      publish stable shared State and lazy artifacts
  → execute/          attempt optional request-specific acceleration
  → engine/           execute complete or specialized automata
  → matcher.zig       expose query semantics and reusable scratch
  → regex.zig         expose compiled ownership and static observations
  → root.zig          public package boundary
```

[`match.zig`](match.zig) sits outside the physical pipeline. It defines public,
engine-independent coordinates and result ownership.

## Directory map

| Directory | Responsibility |
|---|---|
| [`syntax/`](syntax/README.md) | Pattern decoding, parser state, syntax arena, character classes, diagnostics |
| [`optimize/`](optimize/README.md) | Priority-safe syntax rewrites and exact direct-execution shape proofs |
| [`program/`](program/README.md) | Thompson construction, byte lowering, conservative facts, Program publication |
| [`engine/`](engine/README.md) | Complete ordered execution, captures, static lexical bounds |
| [`engine/accelerate/`](engine/accelerate/README.md) | Optional DFA, OnePass, BitState, and direct-count executors |
| [`execute/`](execute/README.md) | Request planning, acceleration protocols, and capture fallback orchestration |
| [`literal/`](literal/README.md) | Exact literal search and multi-atom scanning primitives |
| [`collection/`](collection/README.md) | `Set` and `Filtered` multi-pattern products |
| [`support/`](support/README.md) | Checked arithmetic, requested-byte budgets, nonblocking synchronization |
| [`testing/`](testing/README.md) | Independent semantic models and public qualification suites |
| [`tools/`](tools/README.md) | Deterministic full-gate campaigns and stress executables |
| [`benchmark/`](benchmark/README.md) | Typed benchmark workloads and subprocess adapter |
| [`unicode/`](unicode/README.md) | Embedded Unicode tables and allocation-free lookup |

## Root modules

| File | Role |
|---|---|
| [`root.zig`](root.zig) | Supported public import surface; aliases only |
| [`regex.zig`](regex.zig) | Owning compiled expression and static observations |
| [`matcher.zig`](matcher.zig) | Public query orchestration and reusable single-threaded scratch |
| [`match.zig`](match.zig) | Engine-independent ranges, matches, captures, and owned results |
| [`compiled.zig`](compiled.zig) | Transactional compilation and stable shared State |
| [`rewrite.zig`](rewrite.zig) | Compiled capture templates and bounded output construction |
| [`internal.zig`](internal.zig) | Private read-only observability for tests and benchmarks |
| [`test_root.zig`](test_root.zig) | Explicit manifest of the complete Zig test graph |
| [`tool_main.zig`](tool_main.zig) | Build-selected entry point for private campaigns |

## Architectural contracts

These rules apply across directory boundaries:

1. **The complete ordered NFA is semantic authority.** An accelerator returns an
   exact answer or declines. Decline is never interpreted as “no match.”
2. **Priority is observable.** Alternation order and greedy/lazy split order must
   survive parsing, optimization, compilation, publication, and every executor.
3. **Facts are conservative.** A required literal, anchor, shape, or prefilter may
   remove work only after proving that doing so cannot hide a match.
4. **Coordinates are bytes.** All public positions are absolute half-open byte
   offsets in the complete input, including UTF-8 mode and ranged requests.
5. **Construction is transactional.** A failed compile, publication, collection
   build, or owned-result operation releases every partial allocation.
6. **Resources are explicit.** User-influenced size arithmetic is checked and
   compile, DFA, scratch, result, output, and work limits remain distinct.
7. **Shared acceleration never blocks correctness.** Regex-level lazy artifacts
   use nonblocking synchronization; contention or exhaustion falls back locally.
8. **Ownership follows products.** Regex, Matcher, collections, capture copies,
   and rewrite outputs each have one documented owner and teardown point.

The detailed rationale is in the
[engine architecture guide](../docs/architecture.md).

## Dependency direction

Production code should depend toward lower-level representations, not back toward
public orchestration. In particular:

- `match.zig` imports no project module;
- syntax and Program construction do not import execution engines;
- accelerators do not invoke complete fallback themselves;
- `execute/` returns complete-or-decline results and `matcher.zig` owns fallback;
- benchmark, testing, and tool modules are not reachable from `root.zig`;
- physical engine selection is not part of the public API.

`build_checks.py` enforces important portions of this graph. Do not bypass a
boundary with a convenience import; move shared vocabulary to the lowest layer
that can own it without creating a cycle.

## Suggested reading paths

### Public request to executor

1. [`root.zig`](root.zig)
2. [`regex.zig`](regex.zig) and [`matcher.zig`](matcher.zig)
3. [`execute/request.zig`](execute/request.zig)
4. [`execute/search.zig`](execute/search.zig) or
   [`execute/capture.zig`](execute/capture.zig)
5. [`engine/nfa.zig`](engine/nfa.zig) and the relevant accelerator

### Pattern to immutable Program

1. [`syntax/parser.zig`](syntax/parser.zig)
2. [`syntax/regexp.zig`](syntax/regexp.zig)
3. [`program/compiler.zig`](program/compiler.zig)
4. [`program/graph.zig`](program/graph.zig)
5. [`program/publication.zig`](program/publication.zig)
6. [`program/program.zig`](program/program.zig)

### Captures

1. [`match.zig`](match.zig)
2. [`execute/capture.zig`](execute/capture.zig)
3. [`engine/accelerate/one_pass.zig`](engine/accelerate/one_pass.zig)
4. [`engine/accelerate/bit_state.zig`](engine/accelerate/bit_state.zig)
5. [`engine/capture_nfa.zig`](engine/capture_nfa.zig)
6. [`engine/capture_pool.zig`](engine/capture_pool.zig)

### Evidence for a change

Read [`testing/README.md`](testing/README.md) and
[Testing and Evidence](../docs/testing.md). Add the narrowest evidence that can
independently establish the behavior: a colocated invariant test, a handwritten
public contract, an independent model, forced-engine equivalence, or a bounded
campaign.

## Working in this tree

Every production `.zig` module begins with `//!` documentation stating its role,
ownership, and invariants. Directory READMEs explain relationships; module docs
remain authoritative for implementation details. Keep both current when moving a
responsibility across files.

Useful commands:

```sh
zig build test       # quick Debug qualification
zig build check      # formatting, source/docs checks, and all examples
zig build test-all   # complete deterministic multi-mode gate and campaigns
```

Benchmarking is intentionally separate; see
[`benchmark/README.md`](benchmark/README.md).
