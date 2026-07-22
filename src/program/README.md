# Program construction and publication

This directory converts parsed syntax into the immutable `Program` consumed by
all execution engines. Construction uses a readable mutable Thompson graph;
publication removes epsilon control flow and commits a compact validated runtime
representation.

## Representation stages

```text
syntax Regexp
  → compiler.zig + thompson.zig
  → builder.zig
  → temporary Graph with split/jump control
  → publication.zig
  → Program with ordered priority lists and semantic leaves
```

The distinction is intentional: compiler code can patch explicit graph edges,
while runtime code sees only validated lists and fixed-layout leaves.

## File map

| File | Responsibility |
|---|---|
| [`thompson.zig`](thompson.zig) | Fragment algebra for concatenation, alternation, and dangling exits |
| [`builder.zig`](builder.zig) | Mutable instructions and typed patch lists |
| [`compiler.zig`](compiler.zig) | Iterative syntax scheduling, captures, repetition, Set roots |
| [`graph.zig`](graph.zig) | Typed compile-only Thompson control-flow graph |
| [`byte_encoding.zig`](byte_encoding.zig) | Canonical UTF-8 sequence envelopes and encoding primitives |
| [`byte_lowering.zig`](byte_lowering.zig) | Rune literals/ranges to canonical byte automata |
| [`priority_lists.zig`](priority_lists.zig) | Ordered epsilon closure and nullable-loop priority preservation |
| [`byte_map.zig`](byte_map.zig) | Sound byte-equivalence partition for DFA transitions |
| [`facts.zig`](facts.zig) | Conservative prefixes, suffixes, anchors, capture and literal facts |
| [`publication.zig`](publication.zig) | Transactional Graph-to-Program ownership boundary |
| [`program.zig`](program.zig) | Validated immutable runtime representation |
| [`tour_test.zig`](tour_test.zig) | Concrete compiler tour for `(ab|a)+c` |
| [`compiler_qualification_test.zig`](compiler_qualification_test.zig) | Language, lowering, scale, and compactness qualification |

## Priority contract

Split arm order is semantic. It represents authored alternation and greedy/lazy
repetition priority. `priority_lists.zig` must retain that order while removing
split/jump traversal. First arrival at a canonical runtime item is meaningful to
ordered executors, so reordering equivalent-looking lists can change results.

Nullable repetition requires special care: an empty preferred path that commits
must not reintroduce a lower-priority alternative after looping. The dominator
publication policy exists to preserve this behavior.

## Fact contract

Program facts may avoid work only when true on every successful path. Returning
no fact is always safe. A false required prefix, suffix, anchor, byte plan, or
capture shape can hide a real match and is therefore a correctness defect.

The canonical priority lists remain complete when all facts and direct plans are
ignored.

## Ownership and validation

- Temporary `Graph` storage belongs to compilation and is not retained at runtime.
- `publication.zig` owns one rollback transaction until `finish` transfers the
  complete Program.
- All Program spans, roots, leaves, payloads, byte classes, and fact consistency
  are validated before engines receive the value.
- Reverse Programs deliberately omit forward-only facts.
- User-dependent expansion and work arithmetic is bounded and checked.

## Safe changes

When changing construction or layout:

1. preserve split/list priority explicitly;
2. update `Program.validate` before relying on a new invariant in hot code;
3. qualify UTF-8 boundaries and malformed-byte rejection for lowering changes;
4. compare optimized and unoptimized language/priority behavior;
5. add forced-engine evidence if runtime interpretation changes;
6. update the architecture guide when a representation stage changes.

Start with [`tour_test.zig`](tour_test.zig), then use the broader qualification
modules.

## Related documentation

- [Engine Architecture](../../docs/architecture.md)
- [`../syntax/README.md`](../syntax/README.md)
- [`../engine/README.md`](../engine/README.md)
- [`../optimize/README.md`](../optimize/README.md)
