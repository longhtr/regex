# Execution engines

This directory contains complete ordered execution, capture storage, assertion
context, static possible-match analysis, and private cross-engine qualification.
Optional specialized engines live in [`accelerate/`](accelerate/README.md).

The semantic rule for this layer is strict:

> Complete ordered NFA execution defines the answer. An optional engine may
> return the same answer or decline without answering.

`matcher.zig` owns fallback after a decline; engines do not silently reinterpret
resource exhaustion as a negative match.

## File map

| File | Responsibility |
|---|---|
| [`nfa.zig`](nfa.zig) | Complete ordered boolean, range, and match-ID execution |
| [`capture_nfa.zig`](capture_nfa.zig) | Complete ordered execution with capture row identities |
| [`capture_pool.zig`](capture_pool.zig) | Reference-counted copy-on-write capture-slot rows |
| [`closure_cursor.zig`](closure_cursor.zig) | Iterative traversal of nested Program priority lists |
| [`context.zig`](context.zig) | Complete-input zero-width assertion evaluation |
| [`possible_match.zig`](possible_match.zig) | Static bytewise lexical bounds for anchored full matches |
| [`equivalence_campaign.zig`](equivalence_campaign.zig) | Deterministic direct comparison of physical engines |
| [`equivalence_test.zig`](equivalence_test.zig) | Focused optimizer and forced-engine qualification |

## Ordered NFA model

Two queues represent states before and after one consumed byte. Closing a Program
root traverses semantic leaves in published order. Generation marks admit the
first arrival at each canonical item and position; because first arrival is
priority-sensitive, traversal and queue order must not change casually.

Unanchored search injects candidate starts from left to right. `.first` can commit
when no preferred work remains. `.longest` retains the earliest start while
considering farther endpoints.

Capture NFA adds a capture-row identity to each thread. Branches share rows until
a capture write requires a copy. Losing rows are released immediately; the
winning row is converted to optional public slots.

## Context and coordinates

All positions are absolute byte offsets in the complete input. Ranged search
restricts consumption but does not create a synthetic text boundary. Assertions
therefore inspect bytes outside the requested range when their semantics require
it.

Malformed UTF-8 is accepted as input data but cannot satisfy scalar-consuming
instructions. Byte-oriented `\C` and Latin-1 semantics remain explicit cases.

## Complexity and resources

Complete NFA work is bounded by input positions multiplied by published priority
items, with capture execution additionally weighted by slot-row work. Scratch is
allocated through Matcher policy and reused. No recursive traversal depends on
pattern or input depth.

## Safe changes

- Treat queue/list order as semantics, not an implementation detail.
- Keep assertion evaluation centralized in `context.zig`.
- Preserve clean restart behavior after every optional decline.
- Compare every accelerator completion with complete execution.
- Use independent public models for language semantics; cross-engine agreement
  alone cannot prove a shared Program interpretation.

## Related documentation

- [Engine Architecture](../../docs/architecture.md)
- [`accelerate/README.md`](accelerate/README.md)
- [`../execute/README.md`](../execute/README.md)
- [`../program/README.md`](../program/README.md)
- [`../testing/README.md`](../testing/README.md)
