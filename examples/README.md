# Examples

This directory is the practical guide to the public `regex` API. Every `.zig`
file is a complete program that can be built and run as written. Use the examples
to learn the ownership model, choose the smallest API for a task, and copy a
known-good workflow into an application.

The examples are intentionally narrow: each program teaches one decision rather
than combining unrelated features. For exhaustive signatures and error sets, use
the [Public API Guide](../docs/api.md). For supported pattern spelling, use the
[Pattern Syntax Guide](../docs/syntax.md).

## Start here

If this is your first time using the library, read these in order:

1. [`first_match.zig`](first_match.zig) — compile one expression, create Matcher
   scratch, and locate one match.
2. [`query_methods.zig`](query_methods.zig) — choose between partial matching,
   full matching, and counting.
3. [`batch_matching.zig`](batch_matching.zig) — reuse compiled state across many
   sequential inputs.
4. [`iteration.zig`](iteration.zig) — process non-overlapping matches without
   allocating a result collection.
5. [`captures.zig`](captures.zig) — read group zero and explicit capture groups.
6. [`typed_captures.zig`](typed_captures.zig) — turn captured bytes into string
   and integer application values.
7. [`optional_captures.zig`](optional_captures.zig) — handle a group that did not
   participate.
8. [`unicode.zig`](unicode.zig) — match Unicode text while working with byte
   offsets.
9. [`rewrite_replace_first.zig`](rewrite_replace_first.zig) — compile and apply a
   capture-based replacement template.

After this path, choose focused recipes from the catalog below.

## The model shared by every example

A normal application has two long-lived objects:

```text
Regex    immutable compiled expression; may be shared
  └─ Matcher    mutable reusable execution scratch; one per thread
```

Compile once, reuse the Matcher for sequential requests, then destroy the Matcher
before its Regex:

```zig
var expression = try regex.Regex.init(allocator, pattern);
defer expression.deinit();

var matcher = try regex.Matcher.init(allocator, &expression);
defer matcher.deinit();
```

The second `defer` executes first, which gives the required teardown order. A
Regex can be shared across threads, but a Matcher is single-threaded and
non-reentrant. [`concurrency.zig`](concurrency.zig) shows the complete concurrent
lifecycle.

### Results and lifetimes

The result type tells you what must remain alive and what must be released:

| Result | What it contains | Lifetime and teardown |
|---|---|---|
| `bool`, count | immediate value | independent |
| `Match` | two absolute byte offsets | no teardown; input is required to slice it |
| `CaptureView` | borrowed capture slots | invalidated on Matcher reuse; input required |
| `Captures` | owned copy of capture slots | call `deinit`; input is still required |
| `Matches` | owned array of match offsets | call `deinit`; input is still required |
| `Rewrite.Text` | owned output bytes | call `deinit` |
| `Rewrite.Replacement` | owned output and replacement count | call `deinit` |
| `Set.Ids`, `Filtered.Ids` | owned pattern-ID results | call `deinit` |

Offsets are always absolute, half-open byte offsets into the original input. An
end offset is exclusive, including in UTF-8 mode. Slicing a valid `Match` is
therefore:

```zig
const text = found.slice(input) orelse return error.InvalidMatchBounds;
```

### Absence, rejection, and errors

Keep these outcomes separate:

- No match, no full match, or no participating group is `false` or `null`.
- Invalid runtime patterns are diagnostic values when using `Regex.compile`.
- Allocation, invalid ranges, and configured hard limits are errors.
- Optional acceleration failure is internal; matching falls back exactly.

See [`compile_diagnostics.zig`](compile_diagnostics.zig),
[`result_limits.zig`](result_limits.zig), and
[`work_limits.zig`](work_limits.zig) for explicit handling patterns.

## Choose the smallest matching query

Use the cheapest method that returns the information the application needs:

| Question | Method | Result |
|---|---|---|
| Does a match occur anywhere? | `isMatch` | `bool` |
| Where is the first selected match? | `find` | `?Match` |
| Does the expression cover the complete input? | `fullMatch` | `bool` |
| How many non-overlapping matches occur? | `count` | `usize` |
| Process matches immediately | `iterator` | streaming `Match` values |
| Retain every match location | `findAll` | owned `Matches` |
| Read groups from the first match | `captures` | borrowed `?CaptureView` |
| Require complete coverage and read groups | `fullCaptures` | borrowed `?CaptureView` |

Ranged variants preserve complete-input context while restricting the requested
region. Work-limited variants conservatively admit or reject a request before
execution.

Selection is consistent across these families. The earliest start wins;
`.match_kind = .first` preserves authored alternation and greedy/lazy priority,
while `.longest` selects the farthest endpoint at that start.

## Complete example catalog

### Compilation and ordinary matching

- [`first_match.zig`](first_match.zig) — `find`, optional absence, `Match.slice`,
  and absolute byte offsets.
- [`query_methods.zig`](query_methods.zig) — `isMatch`, `fullMatch`, and `count`
  on one reusable Matcher.
- [`batch_matching.zig`](batch_matching.zig) — one Regex and one Matcher reused
  across a sequential input batch.
- [`compile_diagnostics.zig`](compile_diagnostics.zig) — preserve a stable
  diagnostic category and exact source-byte span for a rejected runtime pattern.
- [`compile_options.zig`](compile_options.zig) — configure case folding and
  leftmost-longest selection at compilation.
- [`posix_syntax.zig`](posix_syntax.zig) — select POSIX syntax and compare
  line-oriented with absolute anchors.
- [`ranged_search.zig`](ranged_search.zig) — compare unanchored and start-anchored
  matching in an absolute `SearchRange`.
- [`iteration.zig`](iteration.zig) — stream non-overlapping matches without an
  owned result array.
- [`consume.zig`](consume.zig) — anchor at a cursor, parse one token, and advance
  using the absolute end offset.
- [`stored_matches.zig`](stored_matches.zig) — retain an owned collection of
  offsets with `findAll`.
- [`result_limits.zig`](result_limits.zig) — handle `ResultLimitExceeded` without
  accepting a partial collection.

### Captures and parsing

- [`captures.zig`](captures.zig) — group zero, numbered groups, borrowed slots,
  and checked slicing.
- [`typed_captures.zig`](typed_captures.zig) — named capture lookup followed by
  explicit string borrowing and integer parsing.
- [`named_captures.zig`](named_captures.zig) — capture-name metadata, name-to-index
  lookup, and `namedCapture`.
- [`optional_captures.zig`](optional_captures.zig) — distinguish overall match
  success from optional-group participation.
- [`full_captures.zig`](full_captures.zig) — validate complete input coverage and
  extract groups in one request.
- [`anchored_captures.zig`](anchored_captures.zig) — combine capture extraction
  with unanchored, range-start, and full-range policies.
- [`owned_captures.zig`](owned_captures.zig) — copy capture slots when they must
  survive Matcher reuse.
- [`capture_iteration.zig`](capture_iteration.zig) — process one borrowed capture
  view per non-overlapping match.

Captured strings are input slices; the regex library does not infer application
types. Parse numbers, enums, dates, and domain values explicitly so conversion
and overflow policy remain visible.

### Text, bytes, quoting, and rewriting

- [`unicode.zig`](unicode.zig) — Unicode properties, UTF-8 input, and byte-based
  offsets.
- [`byte_input.zig`](byte_input.zig) — Latin-1 plus literal mode for arbitrary
  bytes, including invalid UTF-8 and NUL.
- [`quote_meta.zig`](quote_meta.zig) — escape user text before embedding it as a
  literal pattern fragment.
- [`rewrite_extract.zig`](rewrite_extract.zig) — emit only the first capture
  template expansion.
- [`rewrite_replace_first.zig`](rewrite_replace_first.zig) — replace one match and
  understand the owned no-match result.
- [`rewrite_replace.zig`](rewrite_replace.zig) — replace every match under output
  and replacement-count limits.

A `Rewrite` is compiled once against a Regex's capture layout. Its operations
reuse the same Matcher but return independently owned output. Compile templates
before request processing so invalid capture references are rejected once.

### Resource policy and observation

- [`work_limits.zig`](work_limits.zig) — reject conservatively excessive work
  before execution.
- [`memory_limits.zig`](memory_limits.zig) — set independent compilation, shared
  DFA-cache, and Matcher-scratch budgets.
- [`metrics.zig`](metrics.zig) — observe requested retained, peak, and live bytes
  without selecting an internal engine.

Limits are contracts, not tuning hints. Exceeding a result, work, scratch,
replacement, or output limit produces an explicit error; successful operations
do not publish partial results.

### Many patterns, static analysis, and concurrency

- [`set.zig`](set.zig) — compile many captureless patterns into one automaton and
  map ascending insertion IDs to application names.
- [`filtered.zig`](filtered.zig) — compare conservative atom candidates with
  exactly verified independent Regex matches.
- [`filtered_external.zig`](filtered_external.zig) — supply complete atom hits
  from an external multi-literal scanner.
- [`possible_match.zig`](possible_match.zig) — derive conservative bytewise
  lexical bounds without executing against an input.
- [`concurrency.zig`](concurrency.zig) — share one Regex across workers while each
  worker owns its own Matcher.

Choose `Set` when patterns are captureless and can share one combined automaton.
Choose `Filtered` when patterns must remain independent and proved literals can
avoid most exact verification. Candidate APIs are approximate; match APIs verify
and return exact results.

## Guide for RE2 users

The object model is explicit—`Regex` owns immutable compilation and `Matcher`
owns reusable scratch—but the common workflows have direct counterparts:

| RE2 workflow | `regex` workflow | Example |
|---|---|---|
| `PartialMatch` | `Matcher.isMatch` or `captures` | [`query_methods.zig`](query_methods.zig) |
| repeated `PartialMatch` | reuse one Matcher | [`batch_matching.zig`](batch_matching.zig) |
| `FullMatch` | `Matcher.fullMatch` or `fullCaptures` | [`full_captures.zig`](full_captures.zig) |
| typed output arguments | slice, then parse | [`typed_captures.zig`](typed_captures.zig) |
| `Consume` | `capturesIn(..., .start)` plus cursor advancement | [`consume.zig`](consume.zig) |
| `FindAndConsume` | match iterators | [`capture_iteration.zig`](capture_iteration.zig) |
| `RE2::Match` anchors | ranged capture methods | [`anchored_captures.zig`](anchored_captures.zig) |
| `Replace` | `Rewrite.replaceFirst` | [`rewrite_replace_first.zig`](rewrite_replace_first.zig) |
| `GlobalReplace` | `Rewrite.replaceAll` | [`rewrite_replace.zig`](rewrite_replace.zig) |
| `Extract` | `Rewrite.extract` | [`rewrite_extract.zig`](rewrite_extract.zig) |
| `QuoteMeta` | `quoteMeta` | [`quote_meta.zig`](quote_meta.zig) |
| `RE2::Set` | `Set` | [`set.zig`](set.zig) |
| `FilteredRE2` | `Filtered` | [`filtered.zig`](filtered.zig) |
| `PossibleMatchRange` | `Regex.possibleMatchRange` | [`possible_match.zig`](possible_match.zig) |

Typed capture conversion is deliberately not performed by the matching API.
This keeps parsing rules, overflow behavior, ownership, and domain validation in
application code.

## Build and run

From the repository root, compile every example in the selected build mode:

```sh
zig build examples
```

Run the complete catalog:

```sh
zig build examples-run
```

Source underscores become hyphens in installed executable names. After building,
run one lesson directly:

```sh
./zig-out/bin/examples/regex-first-match
./zig-out/bin/examples/regex-typed-captures
./zig-out/bin/examples/regex-rewrite-replace-first
```

Choose another optimization mode when needed:

```sh
zig build examples -Doptimize=ReleaseSafe
```

Run the repository qualification gate before submitting example changes:

```sh
zig build check
```

That gate runs every example in Debug, compiles every example in Debug,
ReleaseSafe, and ReleaseFast, checks formatting and catalog completeness, and
builds the generated API documentation and benchmark adapter.

## Continue reading

- [Public API Guide](../docs/api.md) — complete signatures, ownership, errors,
  limits, and products.
- [Pattern Syntax](../docs/syntax.md) — Perl/POSIX modes, Unicode, repetition,
  anchors, and diagnostics.
- [Engine Architecture](../docs/architecture.md) — compilation, ordered matching,
  accelerators, fallback, and concurrency.
- [Testing](../docs/testing.md) — qualification strategy and complete test gate.
- [Benchmarking](../docs/benchmark.md) — workload definitions and measurement
  policy.
