# Proven syntax optimization

This directory contains optional compile-time simplification and exact classifiers
for direct byte execution. Optimization must preserve language, authored path
priority, capture behavior, and configured resource limits. Returning an
unoptimized tree or no plan is always valid.

## File map

| File | Responsibility |
|---|---|
| [`optimize.zig`](optimize.zig) | Iterative priority-preserving rebuild into a fresh syntax arena |
| [`literal_factor.zig`](literal_factor.zig) | Ordered radix-style factoring of adjacent captureless literal branches |
| [`shapes.zig`](shapes.zig) | Exact classifiers for repeated ASCII byte-language shapes |
| [`plans.zig`](plans.zig) | Compact allocation-free descriptors consumed by direct execution |

## Simplification boundary

`compiled.zig` invokes simplification only for captureless syntax trees at or
above its node threshold. The optimizer never mutates parser output. It rebuilds
reachable nodes in explicit postorder, then compacts the result so syntax retained
for possible reverse compilation contains no orphaned rewrite intermediates.

Supported rewrites are deliberately narrow:

- remove repeat identities such as `{0}` and `{1,1}`;
- merge compatible adjacent literal runs;
- coalesce adjacent repeats only when greediness and bounds compose safely;
- merge eligible single-rune alternatives into a class;
- factor adjacent literal prefixes without sorting or crossing priority boundaries.

Captures make path structure observable and therefore disable this simplification
pipeline. Cases outside a local proof are copied unchanged.

## Direct shape proofs

`shapes.zig` recognizes complete languages that simple byte loops can execute:
repeated ASCII byte classes, optional fixed-prefix placement, and one supported
leading-class form. A shape includes every semantic condition needed by the
executor, including repetition bounds and supported word boundaries.

`plans.zig` stores the published descriptor. A zero range count means no direct
plan. [`../engine/accelerate/count.zig`](../engine/accelerate/count.zig) validates
and consumes the plan; canonical Program lists remain complete fallback.

## Core invariants

- Adjacent alternation order is never sorted or globally regrouped.
- Greedy/lazy priority is preserved.
- Captures and folding boundaries are not crossed without proof.
- Arithmetic composition is checked before rewriting bounds.
- Output node limits apply to the rebuilt arena.
- Partial output is released transactionally.
- A shape classifies the complete language or returns `null`.

## Safe changes

Every new rewrite needs a local semantic proof plus generated optimized-versus-
unoptimized comparison. Exercise prefix alternatives, empty branches, greedy and
lazy repeats, folding, both match kinds, and configured node limits. Every new
shape needs direct-executor comparison with complete NFA over matching and
rejecting inputs.

## Related documentation

- [Engine Architecture: optimization](../../docs/architecture.md)
- [`../syntax/README.md`](../syntax/README.md)
- [`../program/README.md`](../program/README.md)
- [`../engine/accelerate/README.md`](../engine/accelerate/README.md)
