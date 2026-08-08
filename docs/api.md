# Public API Guide

This guide covers the supported surface exported by `src/root.zig`. Start with
`Regex` and `Matcher` for one expression; choose `Rewrite`, `Set`, or `Filtered`
only when the workload needs a higher-level product.

| Need | Start with |
|---|---|
| search, full match, count, iteration, or captures | `Regex` + `Matcher` |
| reusable capture-based replacement | `Rewrite` + the same Matcher |
| many captureless patterns in one combined automaton | `Set` |
| many independent patterns behind literal prefiltering | `Filtered` |
| conservative lexical bounds without input matching | `Regex.possibleMatchRange` |

The normal lifecycle is compile once, create reusable scratch, issue many
requests, then destroy scratch before its compiled owner.

```zig
const regex = @import("regex");

var expression = try regex.Regex.init(allocator, "[A-Za-z]+[0-9]+");
defer expression.deinit();

var matcher = try regex.Matcher.init(allocator, &expression);
defer matcher.deinit();

if (matcher.find(input)) |found| {
    const bytes = found.slice(input).?;
    _ = bytes;
}
```

The example intentionally separates immutable compiled state (`Regex`) from
mutable request state (`Matcher`). See `examples/` for complete programs. Pattern
syntax is specified in [Pattern Syntax](syntax.md); engine internals and fallback
behavior are explained in [Engine Architecture](architecture.md).

## 1. Ownership, borrowing, and threads

Zig does not make allocation-owning structs move-only, so ownership is a caller
contract:

- call `deinit` exactly once on each owning value;
- assignment may relocate a value only if the old location is abandoned;
- never treat a bitwise copy as a second owner;
- destroy every Matcher before its Regex, Set, or Filtered;
- borrowed views and slices are valid only for their documented lifetime.

A Regex may be shared by independent Matchers on different threads. The
allocator used to create it must be safe for any thread that may initialize a
shared lazy artifact. Each thread needs its own Matcher. A Matcher, builder, or
active iterator is single-threaded and non-reentrant; a borrowed capture view
must not cross into concurrent use.

```text
Regex ────────────────┐
  Matcher A            │ must end first
  Matcher B            │
Regex.deinit() ◀────────┘
```

`Captures`, `Matches`, `Rewrite.Text`, `Rewrite.Replacement`, `Set.Ids`, and
`Filtered.Ids` own independent allocations and follow their own `deinit` calls.
Plain `Match`/`SearchRange` values own nothing. `CaptureView` borrows Matcher
scratch and has no teardown.

### Error conventions

The API distinguishes four kinds of failure:

| Kind | Representation |
|---|---|
| malformed pattern or compile-policy rejection | diagnostic value, or concise compile error |
| backing allocator failure | `error.OutOfMemory` |
| configured hard result/scratch/work limit | a specific `*LimitExceeded` error |
| ordinary absence of a match/group | `false` or `null`, never an error |

Optional accelerators are not observable failures: if one cannot answer, Matcher
uses a complete path. Errors documented by an operation therefore describe
caller input, configured policy, or essential allocation—not “the DFA gave up.”

## 2. Compilation

### Concise compilation

```zig
var expression = try regex.Regex.init(allocator, pattern);
var configured = try regex.Regex.initWithOptions(allocator, pattern, options);
```

These map all invalid syntax to `error.InvalidPattern` and all configured
compile limits to `error.ResourceLimit`. Allocation failure remains
`error.OutOfMemory`.

### Diagnostic compilation

Use `Regex.compile` when the exact source span matters:

```zig
const result = try regex.Regex.compile(allocator, pattern, options);
switch (result) {
    .success => |value| { /* value owns a Regex */ },
    .diagnostic => |d| {
        // d.code, d.start, and d.end; [start, end) is a pattern byte span
    },
}
```

Diagnostics are values; only allocator failure is returned as an error.
`Diagnostic.code` is one of the categories listed in
[Pattern Syntax](syntax.md#diagnostics).

### Compile options

Defaults are UTF-8, Perl-style regular syntax, leftmost-first matching,
case-sensitive matching, captures enabled, and finite resource limits.

| Option | Default | Role |
|---|---:|---|
| `encoding` | `.utf8` | UTF-8 scalar or Latin-1 byte semantics |
| `semantics` | `.perl` | Perl or POSIX spelling/initial flags |
| `match_kind` | `.first` | leftmost-first or leftmost-longest selection |
| `case_sensitive` | `true` | initial Unicode simple-fold policy |
| `dot_matches_newline` | `false` | initial dot policy |
| `exclude_newline` | `false` | remove newline from scalar predicates |
| `text_anchors` | `false` | make POSIX `^`/`$` absolute |
| `literal` | `false` | treat the entire pattern as literal |
| `capture_groups` | `true` | ordinary parentheses capture |
| `perl_classes` | `false` | opt Perl classes into POSIX mode |
| `word_boundary` | `false` | opt word boundaries into POSIX mode |
| `max_pattern_bytes` | 1 MiB | source size |
| `max_nodes` | 100,000 | syntax arena size |
| `max_captures` | 1,000 | explicit groups |
| `max_repeat` | 1,000 | finite repeat bound |
| `max_instructions` | 100,000 | compile graph size |
| `compile_memory` | 64 MiB | initial and lazy compile allocation |
| `dfa_memory` | 64 MiB | shared lazy DFA caches |

Memory budgets use `.bytes = n` or `.unlimited`; DFA memory additionally accepts
`.disabled`. `compile_memory` covers initial retained state and reserves stable
shares of what remains for lazy reverse compilation and OnePass planning.
`dfa_memory` is partitioned among forward, reverse, and full-match caches. It is
an upper bound, not an eager reservation: ordinary expressions allocate only the
states they observe. The 64 MiB default prevents large literal dictionaries from
repeatedly falling back after exhausting a small role partition.

`Regex.compileMetrics()` reports pattern bytes, Program bytes, retained/peak
requested bytes, and allocation count for initial compilation.

### Capture metadata and static analysis

```zig
expression.captureCount();
expression.captureIndex("name");       // leftmost group with that name
expression.captureName(group_index);   // borrowed until Regex.deinit
expression.namedCapture(view, "name");
```

Duplicate names are legal; indexed lookup keeps every group while name lookup
selects the leftmost.

`Regex.possibleMatchRange(allocator, max_len)` analyzes anchored full matches and
returns one of:

- `.range` with owned bytewise lexical `minimum` and `maximum` bounds;
- `.empty_language`;
- `.no_finite_max`.

The analysis is length-bounded. When a true extremum is longer than `max_len`, a
returned bound may be a safe rounded lexical boundary rather than a string in the
language—for example, it may return the successor that contains every longer
maximum below it. Treat the pair as containment bounds, not guaranteed example
matches. Ordering is unsigned bytewise ordering, independent of locale.

Deinitialize a returned `.range`. `max_len == 0` produces
`error.InvalidMaxLength`.

## 3. Matcher lifecycle, input borrowing, and resources

```zig
var matcher = try regex.Matcher.init(allocator, &expression);
// or:
var bounded = try regex.Matcher.initWithOptions(allocator, &expression, .{
    .scratch_memory = .{ .bytes = 4 * 1024 * 1024 },
});
```

The default scratch ceiling is 64 MiB. Initialization or later capture-scratch
growth may report `OutOfMemory` or `ScratchLimitExceeded`. Optional DFA failure
never changes a result; execution falls back to a complete engine.

`matcher.metrics()` reports requested live/peak scratch bytes and allocation
count. Metrics count requested sizes, not allocator usable size or process RSS.

Matcher operations borrow their input only for the duration of the call or
iterator. `Match` and capture values store offsets, not copied input bytes.
Every matcher operation may invalidate a previous `CaptureView`. Do not call a
second operation while a range or capture iterator is active.

The hot non-capture operations do not allocate after Matcher initialization.
Capture scratch is created lazily and reused, so the first capture call can fail
even when Matcher initialization succeeded.

## 4. Boolean, range, and full matching

| Operation | Result | Allocation/error behavior |
|---|---|---|
| `isMatch` | whether any unanchored match exists | no error after initialization |
| `find` | first selected `?Match` | no error after initialization |
| `fullMatch` | whether the expression covers all input | no error after initialization |
| `count` | number of non-overlapping matches | no error after initialization |
| `captures` / `fullCaptures` | borrowed `?CaptureView` | may grow capture scratch |
| `findAll` / `copyCaptures` | owned result | allocates with the supplied allocator |

```zig
matcher.isMatch(input);
matcher.find(input);
matcher.fullMatch(input);
matcher.count(input);
```

`Match` stores absolute half-open byte offsets. `found.slice(input)` returns the
corresponding bytes or `null` for invalid manually constructed bounds. UTF-8 mode
still reports bytes, not scalar indices.

Selection always prefers the earliest start. With `.first`, authored alternation
and greedy/lazy order choose the path; with `.longest`, the furthest endpoint wins
and path order resolves remaining ties. These options affect all operation
families consistently.

Ranged methods use:

```zig
const range = regex.SearchRange{ .start = 10, .end = 40 };
try matcher.isMatchIn(input, range, .unanchored);
try matcher.findIn(input, range, .start);
try matcher.fullMatchIn(input, range);
```

A null `end` means `input.len`. Invalid bounds return `error.InvalidRange`.
Offsets remain absolute. `Anchor.start` requires the match to begin at the
requested range start; it does not pretend that the range is the whole input.
Consequently `^`, `$`, `\A`, `\z`, and word boundaries still inspect complete
input context.

Input slices may contain arbitrary bytes. In UTF-8 mode malformed sequences do
not satisfy scalar-consuming syntax such as `.`, literals, or character classes;
iteration makes one-byte progress across malformed input. Perl-mode `\C`
intentionally consumes one unrestricted byte. Latin-1 mode treats every byte as
one scalar.

Each operation family has a `*WithWorkLimit` form. It first admits a conservative
worst-case estimate and returns `WorkLimitExceeded` before execution if the
bound is too small. The estimate deliberately covers complete fallback, so it
may reject a request that a warm accelerator would finish cheaply. Ordinary
methods do not execute per-step work-limit branches.

## 5. Iteration and stored matches

```zig
var it = matcher.iterator(input);
while (it.next()) |found| {
    _ = found.slice(input).?;
}

var stored = try matcher.findAll(allocator, input, max_matches);
defer stored.deinit();
for (stored.values()) |found| { /* offsets only */ }
```

Both produce non-overlapping matches. After an empty UTF-8 match, iteration
advances one valid scalar or one malformed byte and suppresses a duplicate
adjacent empty result. `findAll` returns `ResultLimitExceeded` instead of
exceeding its count limit. Stored offsets contain no input bytes and survive
Matcher and Regex teardown.

## 6. Captures

Group zero is the whole match. Explicit groups start at one. An unmatched,
out-of-range, or invalid group is `null`; a group that participated without
consuming bytes is a non-null `Match` whose start equals its end.

```zig
if (try matcher.captures(input)) |view| {
    const whole = view.group(0).?;
    const first = view.group(1);
    _ = whole;
    _ = first;
}

if (try matcher.fullCaptures(input)) |view| {
    // present only when the expression covers the complete input
    _ = view;
}
```

Available forms are `captures`, `capturesIn`, `fullCaptures`,
`fullCapturesIn`, and their work-limited variants. `copyCaptures` combines a
search with an independent slot copy.

A `CaptureView` borrows matcher scratch. Copy it when it must survive another
operation:

```zig
var owned = try view.copy(allocator);
defer owned.deinit();
_ = owned.group(1);
```

Capture iteration is also non-overlapping:

```zig
var it = matcher.captureIterator(input);
while (try it.next()) |view| {
    // this view lasts only until the next next() call
    _ = view.group(0).?;
}
```

## 7. Rewriting and quoting

A `Rewrite` is a compiled replacement template tied semantically to a Regex's
capture layout:

```zig
var replacement = try regex.Rewrite.compile(
    allocator,
    &expression,
    "name=\\g<name>, whole=\\0",
);
defer replacement.deinit();

var output = try replacement.replaceAll(
    &matcher,
    allocator,
    input,
    1000,
);
defer output.deinit();
```

Template forms are:

| Form | Meaning |
|---|---|
| `\0` … `\9` | one-digit group reference |
| `\g<12>` | arbitrary numbered group |
| `\g<name>` | named group |
| `\\` | literal backslash |

`\12` means group 1 followed by literal `2`; it is not group 12. Unmatched
groups expand to empty bytes.

Operations are `extract`, `replaceFirst`, `replaceAll`, and `*WithOptions`
forms. `extract` returns only the expanded template. Replacement operations
include unmatched input and report `replacement_count`. Returned `Text` and
`Replacement` values own their bytes.

`Rewrite.Options` bounds output bytes and replacement count before unbounded
output can accumulate. Limit failures release partial output. `quoteMeta` and
`quoteMetaWithLimit` allocate pattern bytes that match arbitrary input literally;
the caller frees the returned slice with the supplied allocator.

## 8. Set: one program, many pattern IDs

Use `Set` when many captureless patterns should be matched by one combined
automaton.

```zig
var builder = regex.Set.Builder.init(allocator, .{}, .unanchored);
defer builder.deinit();

const foo = try builder.add("foo");
const numbered_bar = try builder.add("bar[0-9]+");
if (foo != .success or numbered_bar != .success)
    return error.InvalidPattern;

var set = try builder.compile();
defer set.deinit();

var matcher = try set.matcher(allocator);
defer matcher.deinit();

var ids = try matcher.allMatches(allocator, input, set.count());
defer ids.deinit();
```

`add` returns `.success = id` or a syntax `.diagnostic`. Successful IDs are dense
in insertion order; an invalid add consumes no ID. `.unanchored` searches
anywhere, while `.both` requires each pattern to cover the complete input.
Compilation consumes further builder use.

`Set.Matcher.isMatch` answers whether any pattern matches. `allMatches` returns
all matching IDs in ascending insertion order under a hard result limit.
Use `Builder.initWithCollectionMemory` to set the retained collection ceiling and
`matcherWithOptions` to set matcher scratch independently. `isMatchWithWorkLimit`
admits a conservative complete-fallback work bound. Collection and Matcher
metrics report requested bytes, not process RSS.

## 9. Filtered: atoms plus exact verification

Use `Filtered` when an external or built-in multi-literal scan can discard most
of many independent expressions.

```zig
var builder = regex.Filtered.Builder.init(allocator, .{}, 2);
defer builder.deinit();
const error_rule = try builder.add("error: [0-9]+");
const warning_rule = try builder.add("warning: [A-Za-z]+");
if (error_rule != .success or warning_rule != .success)
    return error.InvalidPattern;

var filtered = try builder.compile();
defer filtered.deinit();

var matcher = try filtered.matcher(allocator);
defer matcher.deinit();
const first = try matcher.firstMatchScanned(input);
```

`min_atom_len` controls which conservative required literals are worth
publishing. `filtered.atoms()` exposes normalized atom bytes and IDs for an
external scanner. External methods accept the IDs observed in the input:

```text
firstMatch / allMatches       evaluate candidates, then verify Regexes
allCandidates                 return the conservative superset only
```

The corresponding `*Scanned` methods use the built-in scanner. Candidate
results may contain false positives. Verified match results may not: every
candidate is run through its independent Regex. If no useful atom can be proved,
the formula conservatively keeps that Regex as a candidate.

Use `Builder.initWithCollectionMemory` for retained collection policy and
`matcherWithOptions` for matcher scratch. First-match APIs also have
work-limited forms. All ID collections have hard result limits and independent
ownership.

## 10. Teardown checklist

| Value | Lifetime rule |
|---|---|
| builders | call `deinit` whether adding/compilation succeeds or fails |
| `Regex`, `Set`, `Filtered` | destroy only after all child Matchers |
| Matcher | destroy after iterators and borrowed views stop being used |
| `CaptureView` | borrowed; no `deinit`; invalidated by Matcher reuse |
| `Captures`, `Matches` | independent owner; `deinit` exactly once |
| `Rewrite` | owns the compiled template; `deinit` after use |
| `Text`, `Replacement` | own output; `deinit` exactly once |
| `Set.Ids`, `Filtered.Ids` | own ID results; `deinit` exactly once |
| `quoteMeta` result | free with the allocator passed to `quoteMeta` |

For a runnable, ordered tour of these lifecycles and products, start with
[`examples/README.md`](../examples/README.md). Continue with
[Pattern Syntax](syntax.md) when choosing a pattern spelling, or
[Engine Architecture](architecture.md) when reasoning about resource and fallback
behavior.
