# Request execution orchestration

This directory is the policy seam between public Matcher operations and physical
engines. It classifies requests, attempts optional execution, and returns either
a complete answer or a typed decline. It does not define regex language semantics
and does not hide fallback inside accelerator modules.

## File map

| File | Responsibility |
|---|---|
| [`request.zig`](request.zig) | Allocation-free request plans, admission thresholds, complete-or-decline types |
| [`search.zig`](search.zig) | Shared-DFA protocol for boolean, range, count, and full requests |
| [`capture.zig`](capture.zig) | Matcher-local capture scratch and exact fallback chain |

## Complete-or-decline protocol

`OptimizerAttempt(T)` distinguishes two fundamentally different outcomes:

- `.complete(value)` means the optimizer answered, including `false` or `null`;
- `.decline(reason)` means it did not answer.

Collapsing decline into a negative result is a correctness bug. `matcher.zig`
receives the attempt and visibly starts complete NFA execution when required.

## Search protocol

Shared DFA attempts use nonblocking locks:

1. decline immediately when the role is disabled;
2. try known transitions under shared access;
3. release shared access when construction is needed;
4. try exclusive access without waiting;
5. construct within the role budget;
6. return complete or a classified decline.

Range search may compose forward endpoint discovery with reverse start recovery.
All assertion positions remain absolute in the complete input.

## Capture protocol

`capture.zig` owns lazily initialized Matcher-local executors and result storage.
Direct search is conservatively admitted. Otherwise Matcher first locates the
semantic range and exact replay follows this chain:

```text
whole-capture alias → OnePass → BitState → capture NFA
```

Only the final complete capture NFA turns essential allocation or scratch-budget
failure into a public error. Optional setup/execution failure declines to the next
exact path. Returned `CaptureView` values borrow this scratch and are invalidated
by Matcher reuse.

## Policy boundaries

- Thresholds belong in `request.zig`, not scattered through hot loops.
- Request plans may inspect published conservative facts but cannot invent facts.
- Engines implement attempts; Matcher chooses fallback.
- Work-limit admission is a separate pre-execution public policy.
- Shared-state contention must not block request correctness.

## Safe changes

Add table-driven policy tests when changing a crossover or eligibility predicate.
Add forced-engine equivalence when changing the meaning of a completed attempt.
Add exact scratch-budget tests when retaining new Matcher-local storage.

## Related documentation

- [Engine Architecture](../../docs/architecture.md)
- [`../matcher.zig`](../matcher.zig)
- [`../engine/README.md`](../engine/README.md)
- [`../engine/accelerate/README.md`](../engine/accelerate/README.md)
