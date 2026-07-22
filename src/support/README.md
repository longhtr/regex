# Low-level support primitives

This directory contains small infrastructure modules shared across compilation,
execution, collections, and qualification. They encode safety and concurrency
policy that must remain consistent across products.

## File map

| File | Responsibility |
|---|---|
| [`budget_allocator.zig`](budget_allocator.zig) | Enforce and measure allocator-requested live bytes |
| [`checked_math.zig`](checked_math.zig) | Overflow-safe user-influenced size and admission arithmetic |
| [`try_rw_lock.zig`](try_rw_lock.zig) | Nonblocking reader/writer synchronization for optional shared artifacts |

## Requested-byte budgets

`BudgetAllocator` wraps a child allocator without adding per-allocation headers.
It tracks requested live bytes, peak bytes, and allocation count; these are not
allocator usable size or process RSS. Growth is checked before delegating.
Configured exhaustion is recorded separately so owners can distinguish policy
rejection from child `OutOfMemory`.

Unlimited budgets still measure. `reserve` and `release` charge owner storage
allocated directly through the child allocator. The wrapper object must remain
at a stable address for as long as any derived allocator can call its vtable.

## Checked arithmetic

Regex structure and input lengths influence queue, bitmap, cache, output, and work
sizes. `checked_math.zig` makes overflow an explicit planning failure instead of
allowing wrapped arithmetic to authorize a smaller allocation or weaker policy.
These checks belong before hot execution, after which validated dimensions can be
used directly.

## Nonblocking synchronization

`TryRwLock` stores writer ownership or a reader count in one atomic word. Acquire
and release ordering publishes immutable cache updates. It deliberately provides
no waiting, fairness, or queueing. Failure to acquire means the caller should use
Matcher-local complete fallback rather than couple correctness or latency to
another cache user.

The optional reader cap prevents excessive cache-line contention when local
fallback is preferable.

## Core invariants

- Requested-byte accounting changes only after successful allocator operations.
- Failed growth cannot corrupt live-byte totals.
- All user-influenced products and sums are checked before allocation/admission.
- Shared lazy state is published with acquire/release ordering.
- Lock failure is normal control flow, never a correctness failure.
- Support modules do not import higher-level regex representations.

## Safe changes

Allocator changes require resize/remap/free schedules, exact-boundary tests, child
OOM distinction, and all-allocation-failure lifecycle checks. Lock changes require
concurrent readers, writer exclusion, rollover/limit cases, and race-stress
coverage. Arithmetic helpers require edge cases at zero and integer maxima.

## Related documentation

- [Public API: resources](../../docs/api.md)
- [Engine Architecture: resources and concurrency](../../docs/architecture.md)
- [`../engine/accelerate/README.md`](../engine/accelerate/README.md)
