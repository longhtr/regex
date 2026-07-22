# Testing and Evidence

This guide explains what each test layer proves, how the complete gate is
assembled, and how to interpret `testing.log`. The suite separates implementation
evidence from semantic oracles:

> A path may test its own representation invariants, but expected regex behavior
> must come from readable contracts, independent models, or comparison with an
> independently implemented complete path.

That distinction prevents a DFA test from “proving” itself by asking the same DFA
for the expected answer. Use the narrowest layer that can express a regression:

| Question | Evidence layer |
|---|---|
| Is one private representation invariant preserved? | colocated module test |
| Is one public behavior correct? | handwritten conformance case |
| Do many semantic combinations agree? | independent bounded model |
| Do optional engines equal complete execution? | forced-engine equivalence |
| Are malformed/random lifecycles safe? | deterministic fuzz campaign |
| Do limits, scale, or shared state remain safe? | scaling/concurrency evidence |

The complete gate is offline and deterministic: no test downloads a corpus,
invokes another regex engine, or requires a third-party Python package.

## Commands

```sh
zig build test       # quick Debug suite
zig build test-all   # complete offline qualification gate
zig build check      # formatting, architecture, docs, and examples
```

Use `zig build test` while iterating on a local change and `zig build test-all`
before treating the repository as qualified. Both commands overwrite
`testing.log`; copy it first if an earlier failure record matters. The full gate
runs:

1. repository checks and example compilation;
2. all unit tests in Debug, ReleaseSafe, and ReleaseFast;
3. deterministic public-API fuzzing (10,000 iterations by default);
4. forced-engine equivalence;
5. exact possible-match analysis checks;
6. concurrency stress with 1, 2, 4, and 8 workers.

Change the visible fuzz bound with `-Dfuzz-iterations=N`. Benchmark
qualification is separate: `zig build benchmark`.

## Continuous integration

GitHub Actions uses the exact Zig version declared by the package and pinned
action revisions. The workflow has three roles:

- **Complete qualification:** Ubuntu 24.04 runs an external package-consumer
  smoke test followed by `zig build test-all` on pushes to `main`, pull requests,
  scheduled runs, and manual runs.
- **Portability:** macOS 14 and Windows 2022 run `zig build check` and the quick
  Debug suite without duplicating every expensive campaign.
- **ThreadSanitizer:** a scheduled or manually requested Ubuntu job runs the
  complete gate with `-Drace=true`.

Feature-branch pushes are qualified through their pull request, avoiding a second
identical push workflow. A weekly schedule exercises portability and race-enabled
campaigns even when no pull request is active. Failed jobs retain `testing.log`
when one was created.

`ci/package_smoke.py` stages only files declared for publication, fetches that
staged directory through Zig's package manager, and compiles a separate consumer
that imports `dependency.module("regex")`. This catches missing package paths and
public-module wiring that an in-tree build cannot detect.

## How the gate is assembled

```text
src/test_root.zig                 imports the complete Zig test graph
src/testing/test_runner.zig       names, groups, runs, and leak-checks tests
build.zig                         compiles mode-specific tests and campaigns
testing.py                        runs subprocesses in order and writes testing.log
src/tools/*.zig                   standalone deterministic qualification campaigns
```

`test_root.zig` is a coverage manifest: Zig only discovers tests reachable from
an import, so every test module must remain in that graph. The custom runner
changes presentation and process status only; it does not supply expected
answers.

The fuzz, forced-engine, possible-match, and concurrency campaigns are standalone
private executables because they need process arguments, large finite loops, or
special engine access. `zig build test-all` passes their cache paths directly to
`testing.py`; they are not public utilities and need not be installed in
`zig-out/bin`.

## Reading `testing.log`

`testing.log` is a transcript of the most recent `zig build test` or
`zig build test-all`; each command overwrites the previous file. It contains no
timestamp, source revision, platform, or toolchain header, so preserve that
context separately when archiving a result. A quick run contains only
`unit tests / Debug`. A complete run normally contains, in order,
repository checks, unit tests in Debug/ReleaseSafe/ReleaseFast, the fuzz,
forced-engine, and possible-match campaigns, and four concurrency runs with 1,
2, 4, and 8 workers.

The driver stops at the first command that returns a failure. Consequently, a
missing later section in a failed log means **not run**, not passed. Every section
has a heading and an explicit `OK`, `FAIL`, or `TIMEOUT` footer. Output is streamed
directly into the file, and each subprocess has a ten-minute deadline, so a hung
section retains partial diagnostics instead of waiting for the outer CI timeout.
The build command's exit status remains the authoritative overall result.

### Unit-test sections

A unit-test section is grouped by source module:

```text
unit tests / Debug
==================
[syntax.parser]
  Groups are iterative and captures are numbered...OK
```

The bracketed value is the source-module group and the indented sentence is one
test. Generated public contract cases use their reviewed sentence from
`src/testing/test_cases.zig` rather than a compiler-generated type name. Test
outcomes are:

- `OK`: the function returned successfully, emitted no error-level log, and
  released all memory tracked by the testing allocator;
- `SKIP`: the function returned `error.SkipZigTest`; a skip is counted but does
  not by itself make the process fail;
- `FAIL (ErrorName)`: the function returned an error;
- `FAIL` without an error name: an error-level log or allocator leak can turn an
  otherwise successful return into a failure.

Failure diagnostics and Zig error-return traces are printed next to the failed
test. A warning-level log can be visible without changing `OK`; an error-level
log always changes the outcome to `FAIL`. Leaks are also reported in the final
summary and make the unit-test executable fail.

`All N tests passed.` means that optimization-mode run had no skips, failures,
or leaks. Otherwise the runner prints passed/skipped/failed counts and, when
applicable, a separate leak count. The Debug, ReleaseSafe, and ReleaseFast
sections execute the same catalog under different compiler safety and
optimization policies, so their counts should not be added as distinct tests.

### Gate and campaign sections

The `repository checks` section covers formatting, architecture and dependency
rules, documentation links, generated API documentation, example compilation,
and the ReleaseFast benchmark adapter. It appears only in the complete gate.

The remaining successful sections report finite coverage rather than individual
case lines:

- **Fuzz campaign:** `Seed` and `Starting iteration` identify the deterministic
  stream, while `Iterations` is the number checked. These values are the first
  information needed to replay a failure.
- **Forced-engine campaign:** pattern/case counters describe the generated range
  and capture cross-products. `Capture matches` counts matching capture cases;
  `OnePass eligible` and `OnePass ineligible` show route coverage.
- **Possible-match campaign:** `Patterns` is the generated pattern count,
  `Checks` is the finite pattern/input cross-product actually checked, and
  `Matches`, `Empty languages`, and `Unbounded languages` describe observed
  language categories.
- **Concurrency stress:** `Workers`, `Epochs`, and `Iterations per worker` are
  the run coordinates; `Operations` is their product. Separate sections cover
  1, 2, 4, and 8 workers and compare concurrent checksums with serial reference
  results.

Campaign `Elapsed` values are informational. They are neither benchmark results
nor pass/fail thresholds, and can vary substantially by machine and load.
A complete successful log ends with the 8-worker concurrency section marked
`OK`; a quick successful log ends with its Debug unit-test summary.

### Triaging a failure

1. Find the first `FAIL` section; later sections were not run.
2. Preserve `testing.log`, the source revision, Zig version, and command line.
3. For a unit failure, start from its source-module heading and readable test
   sentence; run the quick suite while iterating unless the defect is mode-only.
4. For a campaign failure, preserve seed, iteration, options, and minimized bytes
   printed by the tool. Reproduction identity matters more than elapsed time.
5. Decide which oracle should own the regression. Keep a minimized readable public
   case even when fuzzing or concurrency first exposed the defect.
6. Finish with `zig build test-all`; a local rerun of the failed section alone
   does not establish that later sections still pass.

Do not “fix” a route-specific failure by weakening/removing the route assertion.
First verify the public answer, then determine whether the accelerator should
complete, validly decline, or preserve a resource invariant.

## Test layers

### Local invariant tests

Most production modules contain focused tests beside the code. Examples include
range normalization, patch-list ownership, byte-map boundaries, priority-list
publication, cache collision identity, capture-row copy-on-write, and allocator
failure at every construction step.

These tests may inspect private representations because the invariant itself is
representation-specific.

### Handwritten public contracts

`src/testing/test_cases.zig` contains readable, typed cases. Each case gives a
sentence-case name, pattern, input, options, operation, and expected value.
Comptime expansion creates one Zig test per case; `test_runner.zig` replaces the
generic generated name with the human-readable one.

A case has no opaque ID, family label, or answer generated by the engine. The
operation itself states whether the case compiles, searches, captures, or full
matches.

### Independent bounded models

Modules under `src/testing/` model small semantic spaces without calling the
production executor to obtain expected answers:

| Module | Independent subject |
|---|---|
| `match_model_test.zig` | ordered regular-language matching and iteration |
| `capture_model_test.zig` | nested captures and priority |
| `context_model_test.zig` | assertions, encodings, ranges, malformed bytes |
| `collection_model_test.zig` | Set IDs and Filtered candidate supersets |
| `diagnostic_model_test.zig` | error categories and exact source spans |

Finite grammars and bounds are visible in source. This makes exhaustive crosses
small enough to understand and large enough to catch interactions that example
tables miss.

### Equivalence and campaigns

`engine/equivalence_test.zig` and `engine/equivalence_campaign.zig` force ordered
NFA, DFA, BitState, OnePass, and capture-NFA paths over the same generated cases.
They test the architectural promise that an accelerator cannot change an
answer.

`tools/fuzz_campaign.zig` generates valid structured patterns, deliberately
invalid patterns, and arbitrary bytes from a fixed seed. It checks public
lifecycles, diagnostics, semantic models, and failure safety. Other tools test
possible-match bounds and shared-cache concurrency. A failure prints enough
seed/index context to reproduce it.

### Scaling and resource boundaries

`scaling_test.zig` and focused module tests exercise large but finite cases:
Unicode repetition, deep grouping, large literal dictionaries, million-byte
inputs, optional-repeat limits, scratch ceilings, DFA exhaustion, retained
partial-cache reuse, required-interior-literal soundness, and exact compile
node/instruction boundaries.

Resource tests qualify both sides of a boundary and use requested-byte
accounting. Allocation-owning constructors use failure injection where
possible. Timing is never a semantic assertion.

## What the evidence does not prove

No single layer is treated as a complete oracle:

- local tests can freeze a representation but do not establish public semantics;
- handwritten contracts are readable but cannot enumerate every interaction;
- independent models are exhaustive only inside their visible finite grammar and
  input bounds;
- forced-engine comparisons share one compiled Program, so they detect executor
  disagreement but cannot independently validate parser/compiler language;
- deterministic fuzzing explores a reproducible finite stream, not every byte
  string or allocation schedule;
- scaling cases establish correctness at selected boundaries, not a timing or
  memory guarantee for every machine.

The layers overlap deliberately. A semantic defect should usually receive a
readable public regression even if a campaign first discovered it; an engine-route
defect should pair direct route evidence with the same public answer.

## Repository checks

`build_checks.py` enforces properties that the Zig compiler alone does not:

- every production module begins with a module comment;
- source imports are acyclic and respect layer boundaries;
- production cannot import testing, tools, or benchmark code;
- complete NFA engines cannot depend on accelerators, or vice versa;
- Matcher, capture dispatch, Set, and Filtered retain explicit complete
  fallbacks;
- `root.zig` exports exactly the reviewed public surface;
- every example is cataloged and compiled;
- local Markdown links resolve.

`src/test_root.zig` explicitly imports every test module, preventing an orphaned
file from looking tested merely because it exists.

## Adding evidence

Choose the narrowest durable level and place it where its oracle is visible:

1. put a representation invariant beside its production module;
2. add one readable public contract to `src/testing/test_cases.zig` when the case
   fits the table vocabulary;
3. use a focused `*_qualification_test.zig` when a reviewed matrix needs code;
4. extend an independent model in `src/testing/` for a bounded semantic
   cross-product;
5. add a standalone `src/tools/` campaign only when a table/model would become
   repetitive or process controls are essential;
6. add scaling coverage for arithmetic, ownership, admission, or route changes.

A good regression:

- fails for the original defect and passes for the intended reason;
- states its expected answer without issue-tracker or external-engine context;
- minimizes pattern, input, options, and physical assumptions;
- avoids timing thresholds and unspecified private layouts;
- checks the public semantic answer whenever it also checks a private route;
- includes both sides of a limit or ownership transition when applicable.

Run `zig build test` during iteration, then `zig build test-all`. Performance
questions belong in [Benchmarking](benchmark.md), where observations are
qualified before timing instead of becoming semantic pass/fail assertions.
