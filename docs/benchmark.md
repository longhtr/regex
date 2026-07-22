# Benchmarking

This suite answers engineering questions about this implementation: which public
operation became faster or slower, whether its execution route changed, and what
requested memory/cache state accompanied the change. It is not a cross-engine
leaderboard, aggregate score, or semantic test suite.

Every workload contains an independently reviewed expected observation. The
adapter qualifies that answer before timing, warms reusable state, measures one
well-defined public operation, and rechecks a digest afterward. A recorded sample
therefore means “this exact operation produced the expected answer through this
observed route,” not merely “some loop ran for N nanoseconds.”

Use [Testing and Evidence](testing.md) to establish correctness first. Use this
document to run the catalog, understand `benchmark.log`, and add cost shapes
without turning timing into a pass/fail contract.

## Running it

```sh
zig build test-all                          # qualify semantics first
zig build benchmark
zig build benchmark -Dbenchmark-samples=3   # quicker/noisier; default: 7
```

The command builds a ReleaseFast adapter, runs each sample in a fresh process,
prints one median per workload, and overwrites `benchmark.log`. On platforms
with Python's `resource` module, each calibration/sample adapter process receives
a 2 GiB address-space limit. The harness targets roughly 200 ms per sample and
calibrates iteration counts before collecting samples; calibration executions
are not included among the reported samples.

`benchmark.log` is a local observation, not a portable baseline. A complete run
can take substantial time because every workload is calibrated and sampled in
fresh processes. Compare logs only when machine, Zig version, power state,
process policy, and benchmark-source hash are suitably controlled.

## Implementation

```text
benchmark.py                    process isolation and statistics
src/benchmark/workloads.zig     typed tasks and stable handwritten catalog
src/benchmark/campaign.zig      deterministic generated scaling series
src/benchmark/adapter.zig       materialization, qualification, timing, metrics
src/benchmark/data/             attributed external regression shapes
```

Production modules cannot import benchmark code. The adapter accesses private
route metrics through `src/internal.zig`; workloads themselves use public
operations.

A workload contains a readable name, pattern source, input source, compile
options, and one typed task:

```text
compile, find, captures, full, count, iterate, grep-captures, Set, or Filtered
```

Expected observations are ordinary spans, booleans, counts, capture groups, or
IDs. Generated inputs and patterns have explicit finite scales in
`campaign.zig`; no runtime download or opaque expected checksum is permitted.
Small externally derived regression assets may be committed only with provenance,
license, a reproducible transformation, and a synthetic replacement for source
text that should not be redistributed. `src/benchmark/data/README.md` documents
the dictionary data and its provenance.

## What one sample means

For each workload the adapter performs:

```text
materialize pattern/input
  → build expression and matcher
  → check the exact expected observation
  → run an untimed warm-up batch
  → run an equal-sized timed batch
  → verify the timed digest
  → snapshot route and requested resources
```

Materialization, process startup, qualification, and reporting are outside the
timed region. Match workloads reuse warmed Regex and Matcher state. Compile
workloads compile and tear down inside every timed iteration. If a public
operation returns owned output, traversal and teardown stay inside timing when
they are part of that operation's cost.

Independent sample processes must agree on both route and observation checksum;
otherwise the benchmark aborts instead of recording ambiguous timing.

## Reading `benchmark.log`

A complete log has three parts: run metadata, one section per workload, and a
`Benchmark complete` footer. If the footer is absent, the run was interrupted or
failed and later workloads were not recorded. `status: pass` means every workload
completed qualification and all independent samples agreed on route and result
checksum; it is not a performance threshold.

### Run metadata

The header records the platform, machine architecture, logical CPU count, Zig
and Python versions, sample count, target sample duration, per-process timeout,
and address-space limit. `memory limit supported: False` means the Python
platform could not install that process limit.

`source SHA-256` identifies `benchmark.py` plus the files under
`src/benchmark/`. Matching hashes establish that the workload catalog and
benchmark harness match; they do **not** identify the complete regex engine
source tree. Record the repository revision separately when comparing engine
changes. Machine, toolchain, power policy, and system load must also be
comparable.

### Workload identity and operation

Each bracketed heading is the workload's stable descriptive name. A `(scale N)`
suffix is one coordinate of a generated finite series, not an iteration count.
The `operation` line defines what one `/op` means:

| Operation | One measured operation |
|---|---|
| `compile` | compile the pattern and tear the resulting Regex down |
| `find` | make one search request over the complete listed input |
| `captures` | make one capture request and consume the observed groups |
| `full` | make one whole-input match request |
| `count` | count all non-overlapping matches in one complete input pass |
| `iterate` | create and exhaust one match iterator |
| `grep_captures` | split the input into lines, exhaust captures on every line, and count participating groups |
| `set` | collect, consume, and release all matching Set pattern IDs |
| `filtered` | scan and verify the first matching Filtered pattern ID |

Except for `compile`, compilation, matcher construction, qualification, and
warm-up are outside the timed interval. Thus `/op` is not a primitive engine
step: it is one complete public action listed above. For example, `800 ns/op` on
a `find` workload with `input: 64 KiB` means about 800 ns for one complete search
of that 64 KiB input.

`input` is the number of bytes presented by each operation. `pattern` is a
JSON-quoted regex string; Set and Filtered workloads show a JSON-like array in
insertion order. A pattern longer than 200 characters displays its first and
last 100 characters as:

```text
"prefix" ++ [1234 omitted characters] ++ "suffix"
```

The `++` and omission count are report notation outside the quoted pattern
fragments, so they cannot be mistaken for regex syntax.

### Timing lines

`iterations` is the calibrated number of operations executed inside each timed
sample. The harness chooses it to approach the target sample duration, up to its
iteration cap. It is not an input-size or semantic-complexity measure.

Every value under `samples` is:

```text
timed batch elapsed time / iterations in that batch
```

Each sample comes from a fresh adapter process. `result` is the median of the
per-operation sample values (and need not equal one raw value when the sample
count is even); `/op` means per operation. `MAD` is the median absolute deviation:

```text
median(abs(sample - median))
```

A small MAD indicates tightly grouped samples; a large MAD warns that noise or
an outlier affected the run. MAD is a dispersion summary, not a confidence
interval. With one sample MAD is necessarily zero. Inspect the raw samples rather
than treating a small change in the median as meaningful by itself.

### Route and resource lines

`route` is a comma-separated cumulative set of private route bits observed over
qualification, warm-up, and timed use of the matcher. Several bits can be
present because a request can locate a range with one path and replay captures
with another, or because an optional path declined to a complete fallback. The
bits are observations, not user-selectable controls:

| Route bit | Meaning |
|---|---|
| `capture_direct` | direct first-match BitState capture search completed |
| `capture_alias` | every capture was published by aliasing the known whole-match range |
| `capture_one_pass` | deterministic OnePass exact capture replay completed |
| `capture_bit_state` | bounded BitState exact capture replay completed |
| `capture_nfa` | the complete capture NFA completed |
| `dfa` | at least one DFA attempt occurred |
| `dfa_range` | a DFA range-location attempt occurred |
| `dfa_full` | a DFA whole-input attempt occurred |
| `dfa_decline` | at least one DFA attempt declined to another complete path |
| `dfa_decline_disabled` | DFA use was disabled by workload options |
| `dfa_decline_cache_busy` | shared cache construction was busy |
| `dfa_decline_allocation` | optional DFA allocation failed |
| `dfa_decline_state_limit` | DFA state admission limit was reached |
| `dfa_decline_unproductive` | state construction advanced too little input to remain worthwhile |
| `none` | none of these private route bits was observed; work may still use literals, an NFA, or collection-specific paths |

`memory` reports requested bytes retained by the warmed owners and the requested
peak tracked by their allocators. These values are accounting metrics, not RSS,
resident pages, or process-wide peaks. `allocations` is the reported allocation
count associated with owner construction and warmed state; it is not divided by
iterations and does not mean that many allocations occur on every operation.
Resource values are the maximum reported across sample processes.

`DFA cache` reports requested live/peak cache bytes and whether any physical DFA
cache exhausted its configured resource. `DFA contents` sums the visible
forward, reverse, and full-match caches: state count, stored instruction IDs,
transition slots, and hash-table storage. Zeroes can be correct when no DFA was
attempted, when it declined before retaining state, or when another route handled
the workload. A decline bit and `exhausted=False` are compatible—for example,
disabled, busy, or unproductive declines are not cache exhaustion.

### Comparing logs

Because every run overwrites `benchmark.log`, preserve each complete log under a
name that records revision and environment. A defensible comparison workflow is:

1. keep machine, power policy, background load, Zig/Python versions, sample count,
   timeout, and process memory policy fixed;
2. verify both logs have the completion footer and the same benchmark source
   hash; separately record the repository revisions because engine source is not
   included in that hash;
3. compare the same workload identity, operation, exact pattern, input size, and
   generated scale coordinate;
4. inspect raw samples and MAD before interpreting median movement;
5. inspect route, retained/peak requested bytes, allocations, and DFA contents;
6. repeat complete runs when the change is near observed noise or alters route.

A faster median with a different route or larger cache is a different engineering
tradeoff, not a pure instruction-level improvement. Scaling series should be read
as curves: a crossover or changed slope can matter more than one coordinate.
The suite intentionally has no aggregate score.

## Coverage

The stable catalog covers compilation, positive and rejecting search, full
matching, captures, count, exact and empty iteration, Set, Filtered,
multilingual text, structured records, logs, dictionaries, keywords, and
adversarial expressions. Externally derived regression shapes specifically
preserve:

- deep false-prefix pressure in a 2,663-word literal dictionary;
- sparse line-by-line Ruff `# noqa` capture extraction;
- Cloudflare's long `.*.*=.*` self-loop;
- default-cache rejection for a large heterogeneous alternation.

Generated series vary:

- input length through 64 B, 1 KiB, 16 KiB, 256 KiB, and 1 MiB;
- overlapping alternatives and nested-nullable rejection;
- malformed UTF-8 and Latin-1 scanning;
- bounded optional repetition around engine route transitions;
- homogeneous and mixed-prefix dictionaries;
- capture replay and collection size;
- parser depth and capture count.

The purpose is to expose scaling shape and route changes, not to award one
aggregate score.

## Adding a benchmark

Choose the narrowest catalog layer:

- add a reviewed standalone case to `src/benchmark/workloads.zig` for a distinct
  public operation, regression shape, or representative workload;
- add a finite series to `src/benchmark/campaign.zig` only when explicit scales
  reveal a crossover or asymptotic shape;
- change `src/benchmark/adapter.zig` only when introducing a new typed operation
  or changing exactly what belongs inside its timed interval.

Every addition must have:

1. a descriptive stable name—numeric catalog indices are process plumbing, not
   workload identity;
2. deterministic pattern/input materialization outside the timed region;
3. an expected span, capture set, count, boolean, or ID result derived without
   first running the implementation under measurement;
4. a task boundary that corresponds to a recognizable public action;
5. finite scales chosen before observing timing, never tuned until a graph looks
   favorable;
6. provenance and license documentation for any externally derived shape/data.

Prefer a scaling **test** instead when the question is correctness at a limit,
arithmetic safety, teardown, or admission. Prefer a benchmark when elapsed time,
allocation/cache growth, or route crossover is the observation.

Before interpreting results:

1. run `zig build test-all` for semantic qualification;
2. run the complete benchmark catalog, not an isolated hand-timed loop;
3. inspect route and resource changes alongside time;
4. compare raw samples and MAD, not only the median;
5. rerun suspicious changes under the same environment.

Benchmarks locate costs. Tests and bounded models remain the semantic authority.
Use [Engine Architecture](architecture.md) to interpret route changes and
[Public API Guide](api.md) to verify that a proposed workload times a meaningful
public lifecycle.
