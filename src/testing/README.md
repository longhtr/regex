# Test models and qualification suites

This directory contains semantic evidence that exercises the public API or
independently models expected behavior. Colocated unit tests establish private
representation invariants; this directory establishes broader contracts without
asking the implementation under test to manufacture its own expected answers.

Read [Testing and Evidence](../../docs/testing.md) for commands, full-gate
composition, and interpretation of `testing.log`.

## Evidence layers

| Need | Preferred evidence |
|---|---|
| One private invariant | test beside the implementation module |
| One public behavior | reviewed case in `test_cases.zig` |
| Bounded semantic cross-product | independent model in this directory |
| Physical-engine agreement | `../engine/equivalence_*` |
| Malformed/random lifecycle safety | deterministic fuzz campaign in `../tools/` |
| Large finite boundary | scaling or concurrency qualification |

Cross-engine agreement is not an independent language oracle because all engines
consume the same Program. Independent models intentionally avoid production
parser, context, and executor helpers.

## File map

| File | Evidence provided |
|---|---|
| [`test_cases.zig`](test_cases.zig) | Reviewed readable public contracts and expected observations |
| [`conformance_test.zig`](conformance_test.zig) | Comptime expansion of each contract into a separate public test |
| [`match_model_test.zig`](match_model_test.zig) | Independent finite-language and ordered-range model |
| [`capture_model_test.zig`](capture_model_test.zig) | Independent capture participation and slot-value model |
| [`context_model_test.zig`](context_model_test.zig) | Assertions, ranges, malformed UTF-8, and scalar consumption model |
| [`collection_model_test.zig`](collection_model_test.zig) | Independent Set IDs and Filtered candidate-superset model |
| [`diagnostic_model_test.zig`](diagnostic_model_test.zig) | Reviewed diagnostic categories and exact source spans |
| [`semantic_qualification_test.zig`](semantic_qualification_test.zig) | Broad reviewed public semantic and regression cases |
| [`matcher_test.zig`](matcher_test.zig) | Dispatch, resource, ownership, route, and allocation qualification |
| [`dfa_qualification_test.zig`](dfa_qualification_test.zig) | Concurrent shared-DFA construction pressure |
| [`scaling_test.zig`](scaling_test.zig) | Large pattern/input boundaries without timing assertions |
| [`test_runner.zig`](test_runner.zig) | Grouped names, leak/error accounting, and process status |

[`../test_root.zig`](../test_root.zig) is the import manifest that makes every test
reachable to Zig. A new test module must be imported there or it does not exist in
the compiled suite.

## Oracle discipline

- Handwritten expected values must be readable and reviewed.
- Generated models implement a smaller independent vocabulary and evaluator.
- Production results cannot be copied into fixtures as expected answers.
- Route assertions accompany, never replace, public semantic assertions.
- Timing is not a correctness contract.
- Generated campaigns have explicit deterministic bounds and reproduction data.
- Every added public diagnostic category requires a reviewed model case.

## Choosing where to add a regression

Use the narrowest layer that proves the defect:

1. colocate a representation regression with its module;
2. add a `TestCase` for a small public contract;
3. extend an independent model only when the model remains inspectable;
4. add a forced-engine case for optional-versus-complete disagreement;
5. add a tool campaign case for large deterministic breadth.

Avoid duplicating the same assertion across layers unless each layer supplies a
distinct kind of evidence.

## Commands

```sh
zig build test       # quick Debug suite
zig build test-all   # Debug, ReleaseSafe, ReleaseFast, and campaigns
zig build check      # repository checks, docs, and examples
```

The full gate is deterministic and offline.

## Related documentation

- [Testing and Evidence](../../docs/testing.md)
- [`../tools/README.md`](../tools/README.md)
- [`../engine/README.md`](../engine/README.md)
- [`../benchmark/README.md`](../benchmark/README.md)
