# Optional execution accelerators

This directory contains specialized executors that can answer eligible requests
faster or with a different state representation. None is semantic authority.
Each attempt must produce a complete exact answer or return a decline that lets
`matcher.zig` restart complete execution from clean state.

Admission policy is defined in [`../../execute/request.zig`](../../execute/request.zig);
shared-DFA protocol is in
[`../../execute/search.zig`](../../execute/search.zig); capture fallback is in
[`../../execute/capture.zig`](../../execute/capture.zig).

## File map

| File | Responsibility |
|---|---|
| [`dfa.zig`](dfa.zig) | Lazy ordered-subset DFA for existence, range, full, count, and IDs |
| [`dfa_state_cache.zig`](dfa_state_cache.zig) | Bounded state identity, item sequences, and sparse/dense transitions |
| [`shared_dfa.zig`](shared_dfa.zig) | Nonblocking synchronized forward, reverse, and full cache ownership |
| [`one_pass.zig`](one_pass.zig) | Immutable deterministic capture plan and exact-range executor |
| [`bit_state.zig`](bit_state.zig) | Bounded depth-first capture execution with visitation bitmap and undo log |
| [`count.zig`](count.zig) | Direct existence/count loops for fully proved repeated-byte languages |

## Accelerator contracts

- DFA states preserve ordered Program items; they are not unordered sets.
- Cache hash equality is confirmed by exact ordered item equality.
- Known transitions may be read under shared access; construction requires
  exclusive access.
- Locks never wait. Contention is a normal decline.
- Forward, reverse, and full DFA roles have stable independent budget shares.
- OnePass rejects any ambiguous byte-class route or unsupported assertion case.
- BitState bitmap dimensions use checked arithmetic and explicit policy ceilings.
- Direct count plans describe a complete language, not a heuristic candidate.
- Partial cache construction is never published as a complete result.

## DFA composition

Forward DFA search naturally discovers an endpoint. When a request needs the
leftmost start, `execute/search.zig` may lazily compile a reverse Program and scan
backward from that endpoint. Full matching uses a separate role cache so search
traffic cannot consume its complete allowance.

Construction may decline because caches are disabled, locks are busy, budgets or
state limits are exhausted, or productivity policy rejects further growth. These
conditions affect route and speed only.

## Capture chain

For a caller-proven exact range, capture execution may use:

```text
whole-range alias proof
  → OnePass
  → compressed BitState
  → complete capture NFA
```

Direct unanchored BitState search is separately admitted only when its stronger
bitmap and assertion requirements are satisfied.

## Safe changes

Every new completion path needs:

1. a proof that eligibility covers the complete requested semantics;
2. an explicit decline for every unproved or resource-limited case;
3. forced comparison with ordered NFA/capture NFA;
4. collision, exhaustion, and allocation-failure evidence where state is cached;
5. concurrency evidence for shared publication or mutation.

Never call complete fallback from an accelerator. Returning decline keeps policy
and restart ownership visible in the orchestration layer.

## Related documentation

- [Engine Architecture: acceleration](../../../docs/architecture.md)
- [`../README.md`](../README.md)
- [`../../execute/README.md`](../../execute/README.md)
- [`../../support/README.md`](../../support/README.md)
