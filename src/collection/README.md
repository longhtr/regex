# Multi-pattern collections

This directory implements the public `Set` and `Filtered` products. They solve
different workloads and deliberately retain different ownership models.

| Product | Representation | Best fit |
|---|---|---|
| `Set` | one combined captureless Program | patterns can share an automaton |
| `Filtered` | independent Regex values behind required-atom formulas | patterns need independent semantics and literals reject most candidates |

Neither product changes the correctness rule: final match results are exact and
remain in insertion order.

## File map

| File | Responsibility |
|---|---|
| [`set.zig`](set.zig) | Transactional combined syntax, Program, many-ID execution, shared DFA |
| [`filtered.zig`](filtered.zig) | Independent Regex ownership, scanning, candidate evaluation, exact verification |
| [`required_atoms.zig`](required_atoms.zig) | Conservative syntax-to-Boolean-formula analysis |
| [`filter_plan.zig`](filter_plan.zig) | Reachable formula compaction, atom deduplication, Teddy plan publication |

## Set lifecycle

Each successful Builder addition receives a dense insertion ID. A failed add
rolls all combined-arena arrays back and consumes no ID. Compilation alternates
roots in insertion order and attaches IDs to accepting leaves. `.unanchored`
uses ordinary search; `.both` requires complete-input coverage.

A Set Matcher owns ID-only complete NFA scratch, a dense matched bitmap, and a
sparse list of touched IDs. Optional shared DFA execution may decline under
contention or resource limits; fallback clears partial results before complete
execution. Publication always returns IDs in insertion order under the caller's
hard result limit.

## Filtered lifecycle

Each successful addition transactionally commits both a normal Regex and a
conservative required-atom formula. Compilation publishes normalized atoms, a
Teddy scanner, compact postorder formulas, and stable independent Regex owners.

Candidate APIs expose a conservative superset. Match APIs bind reusable boolean
scratch to each candidate Regex and verify it exactly. A false-positive atom or
formula may cost work; it may never authorize a final result. External scanners
must report every observed published atom—extra hits are safe, missed hits can
hide a real match.

## Core invariants

- Successful IDs are dense and follow insertion order.
- Failed additions are transactional and consume no ID.
- Required-atom analysis weakens to “always candidate” when proof is unavailable.
- Formula children precede parents in the published evaluation order.
- Candidate results are approximate; verified match results are exact.
- Collection and Matcher memory budgets are independent.
- Shared Regex/Set state outlives every borrowing Matcher.

## Safe changes

Use the independent collection model in
[`../testing/collection_model_test.zig`](../testing/collection_model_test.zig)
to qualify IDs and candidate supersets. Add false-positive and no-false-negative
cases for formula changes, transaction tests for Builder changes, and
contention/exhaustion tests for shared caches.

## Related documentation

- [Public API: Set and Filtered](../../docs/api.md)
- [Engine Architecture: higher-level products](../../docs/architecture.md)
- [`../literal/README.md`](../literal/README.md)
- [`../program/README.md`](../program/README.md)
