# Engine Architecture

This guide explains how pattern bytes become an immutable program and how public
requests execute that program. It is written for programmers who know basic
systems programming and the idea of a finite automaton; Thompson construction
and this engine's ordered execution model are introduced where they matter.

Use the guide in two ways:

- read sections 1–6 for the compilation pipeline and ownership boundaries;
- read sections 7–10 for exact execution, acceleration, captures, and fallback;
- use sections 11–13 to place higher-level products, resources, and source files.

The central design rule is:

> The complete ordered NFA defines the answer. An accelerator may return that
> same answer—including “no match”—or decline without answering. A decline must
> restart an exact path from clean state.

“Ordered” means that active automaton paths retain authored alternation order and
greedy/lazy repetition priority. This gives a non-backtracking implementation the
same observable path preference expected from leftmost-first matching. Boolean,
range, and capture requests retain different information, so the implementation
coordinates them separately instead of forcing every query through one universal
thread representation.

This document describes private implementation, not API stability. See
[Public API Guide](api.md) for supported interfaces and [Pattern Syntax](syntax.md)
for the accepted language.

## 1. End-to-end map

```text
pattern bytes
    │
    ▼
syntax/scanner.zig       decode scalars and escapes
syntax/parser.zig        iterative parsing and diagnostics
syntax/regexp.zig        arena-backed n-ary syntax tree
    │
    ├── optimize/        proven syntax rewrites for large captureless trees
    │
    ▼
program/compiler.zig     iterative Thompson construction
program/graph.zig        temporary split/jump graph
program/byte_lowering.zig Unicode ranges → byte automata
    │
    ▼
program/publication.zig  validate, derive facts, remove graph control flow
program/program.zig      immutable priority lists and semantic leaves
    │
    ▼
compiled.zig             stable shared state and lazy artifacts
    │
    ├── engine/nfa.zig           complete range/boolean executor
    ├── engine/capture_nfa.zig   complete capture executor
    ├── engine/accelerate/       DFA, OnePass, BitState, direct count
    └── literal/                 conservative search primitives
    │
    ▼
matcher.zig + execute/   request policy, fallback, scratch, iteration
regex.zig / root.zig     public ownership and package boundary
```

`src/match.zig` sits beside this pipeline. It defines representation-independent
concepts such as `Match`, `CaptureView`, and `SearchRange`; no execution engine
owns the public vocabulary.

Five similarly named objects mark different stages:

| Object | Lifetime and purpose |
|---|---|
| `Regexp` | mutable arena-backed syntax produced by parsing |
| `Graph` | temporary Thompson instructions with explicit split/jump control |
| `Program` | validated immutable priority lists consumed by every engine |
| `State` | stable shared allocation containing a Program and lazy artifacts |
| `Matcher` | one owner's reusable, single-threaded request scratch |

Keeping these stages distinct is central to the design: construction can use
readable mutable forms, while hot execution sees only validated compact data.

## 2. Syntax front end

### Scanning

`syntax/scanner.zig` decodes either canonical UTF-8 scalar values or Latin-1
bytes. It also parses numeric escapes and reports byte-accurate failures. A
pattern must be valid in its selected encoding. Matching input is less strict:
arbitrary bytes are accepted, but malformed UTF-8 cannot satisfy a
scalar-consuming instruction.

### Parsing without recursion

`syntax/parser.zig` is a state machine over the pattern. It delegates precedence
and group reduction to `syntax/frame_reducer.zig`, whose explicit frame and
piece stacks replace recursive descent. Deeply nested patterns therefore consume
bounded heap storage rather than the process stack.

Character classes are assembled by `syntax/char_class.zig` and
`syntax/class_terms.zig`. `syntax/rune_range.zig` normalizes ranges into sorted,
disjoint intervals and implements union, intersection, complement, and lookup.
`unicode/data.zig` supplies project-owned Unicode groups and simple-fold cycles.

### Syntax representation

`syntax/regexp.zig` stores a tree in parallel append-only arrays:

```text
nodes       tagged syntax nodes
children    child NodeIds for n-ary concat/alternate nodes
runes       literal scalar runs
ranges      normalized class intervals
names       capture-name bytes
```

A node refers to the other arrays through typed 32-bit spans. Concatenation and
alternation are n-ary, which avoids chains of binary nodes. Typed IDs prevent
accidentally mixing a node index, capture index, and instruction index.

The arena does not retain an allocator. Every operation receives one explicitly,
which keeps ownership in the surrounding compile transaction.

## 3. Syntax optimization

`optimize/optimize.zig` performs only semantics-proven rewrites. Production
compilation runs it for captureless trees with at least 32 nodes. Its important
constraint is that alternation order and greedy/lazy priority are observable in
leftmost-first matching.

The pass can remove identity repetitions, merge compatible simple repetitions,
and factor literal alternatives. `optimize/literal_factor.zig` builds a radix-like
form, but groups only adjacent branches with the same next scalar. That adjacency
rule preserves ordered-alternation priority. Its recursion depth is capped; the
fallback is an equivalent flat alternation.

Captured trees skip this production pass so capture numbering and path layout
remain straightforward. Optimization is not required for correctness.

## 4. Thompson compilation

### Temporary graph

`program/compiler.zig` walks the syntax arena with an explicit task stack. Each
completed subtree produces a Thompson `Fragment`:

```zig
start: InstId
outs:  patch list
nullable: bool
```

`program/builder.zig` owns unresolved edges and patch lists.
`program/thompson.zig` implements fragment concatenation and alternation.
The temporary `program/graph.zig` instruction set is:

```text
fail, byte_range, empty_width, capture, split, jump, match
```

The preferred arm of `split` records alternation and greediness priority. For
unanchored matching, the compiler adds a lower-priority loop that consumes one
byte and retries the expression. This turns search into automaton execution
rather than an outer loop that launches a new match at every byte.

### Scalar-to-byte lowering

The runtime consumes bytes. `program/byte_lowering.zig` converts scalar literals
and class ranges into byte-range fragments:

- Latin-1 uses one byte per scalar;
- UTF-8 literals become byte sequences;
- UTF-8 ranges are decomposed into canonical sequence ranges;
- shared sequence suffixes are represented by a trie-like graph;
- reverse compilation reverses encoded byte order as well as syntax order.

Malformed UTF-8 is excluded structurally: no scalar automaton path accepts an
overlong sequence, surrogate encoding, truncation, or invalid leading byte.
`\C` is different because it intentionally compiles to one unrestricted byte.

### A small graph example

For `(ab|a)+c`, the compiler emits semantic byte instructions for `a`, `b`, `a`,
and `c`; capture instructions surround the alternation; one split chooses `ab`
before `a`; another chooses another greedy iteration before `c`; and a final scan
loop provides unanchored search. `program/tour_test.zig` walks the resulting
12-instruction graph. Read it as a concrete construction tour, not as a promise
that every private instruction index is stable.

## 5. Publication: graph to runtime program

The compile graph is convenient to build but not ideal to execute. Split and
jump closures would be rediscovered at every input position. Publication moves
that work to compile time.

`program/priority_lists.zig` follows epsilon control flow and publishes canonical
ordered lists. A list item is either:

1. a reference to another priority list; or
2. a semantic leaf (`byte_range`, assertion, capture, fail, or match).

Equivalent leaves and lists are interned. Queue/list order retains the preferred
backtracking order. Nullable loops require special care: dominator roots stop a
lower-priority path from being revived after a higher-priority nullable path has
already committed.

`program/publication.zig` then derives and validates all immutable runtime data:

- anchored and unanchored list roots;
- compact 8-byte runtime leaves;
- byte equivalence classes used by the DFA;
- required prefix, bounded required suffix, and bounded interior literal;
- absolute-start, absolute-end, line-start, empty-match, and assertion facts;
- whole-capture and specialized repeated-byte facts;
- the number of bitmap rows needed by BitState.

Facts in `program/facts.zig` are conservative: a missing fact loses an
optimization, while a false fact could change an answer. A fact may reject or
skip work; it becomes an answer only when a classifier proves that it describes
the complete language shape. `Program.validate` checks every list span, root,
successor, leaf payload, byte class, capture slot, and summary invariant before
execution.

Publication is transactional. `ProgramBuild` owns every partial allocation and
releases it on failure; successful `finish` transfers one complete `Program`.
The temporary graph is then discarded.

## 6. Compiled and mutable state

A public `Regex` points to one stable `compiled.State` allocation:

```text
State
├── immutable Program
├── capture-name table
├── encoding and match policy
├── reverse-compilation recipe
├── optional lazy reverse Program
├── optional immutable OnePass plan
└── shared forward/reverse/full DFA caches
```

The stable allocation lets a `Regex` handle be moved without invalidating its
Matchers. The reverse program is compiled only when range recovery needs it.
OnePass planning is also lazy. Remaining compile memory is divided between
these two artifacts; DFA memory is separately partitioned by cache role, so
operation order cannot consume another role's allowance.

`compiled.BuildState` owns each partially constructed syntax tree, Program, and
capture-name allocation until publication succeeds. Its one teardown path rolls
back parser diagnostics, configured-limit failures, and allocator failures.
Successful publication transfers those owners into the stable State.

A public `Regex` is the unique owner of that State. Assignment may relocate the
handle only when the old location is abandoned; a bitwise copy is not a second
owner. A `Matcher` borrows State and owns all request-local mutable data:
ordered-NFA queues, capture engines, result slots, counters, and a budget
allocator. Matchers are single-threaded. Different Matchers may share one Regex
because only lazy plans and DFA caches are shared, under a nonblocking
reader/writer lock.

## 7. Complete ordered NFA

`engine/nfa.zig` is the complete captureless executor. It is a Pike-style virtual
machine: a “thread” is one lightweight automaton path, not an operating-system
thread. At each byte position the executor maintains an ordered queue of active
priority items.

The essential invariant is:

> At a fixed input position, the first arrival at an item is the highest-priority
> arrival.

At each position, closure follows non-consuming list/root edges until it reaches
a byte predicate, assertion, or acceptance. A generation-mark array deduplicates
later arrivals without clearing the whole array each step.
`engine/closure_cursor.zig` traverses nested priority lists with an explicit
continuation stack.

Unanchored search does not launch a separate VM for every start. The compiler's
unanchored root gives the expression priority, then consumes one byte and retries
at lower priority. Ranged search limits starts and consumption but still passes
absolute positions to `engine/context.zig`; range edges never masquerade as text
boundaries.

For leftmost-first matching, acceptance commits only after no preferred live
continuation can outrank it. For leftmost-longest matching, the executor retains
the earliest start and furthest end while using priority to resolve ties.
Worst-case captureless work is
`O(input bytes × priority items)` with `O(priority items)` scratch; there is no
recursive backtracking and no exponential path stack.

The same module contains an ID-only executor that records accepting pattern IDs
instead of match starts. `Set` uses it as complete multi-pattern fallback;
`Filtered` reuses its boolean form to verify conservative candidates.

## 8. Optional search acceleration

### Prefix and shape search

`literal/search.zig` implements scalar byte, pair, vector, and folded-ASCII
prefix search. A required prefix can skip impossible starts but never accept a
match by itself, except when publication proved that the complete language is
the literal prefix or that prefix followed by one closed byte range.

Required suffix, interior-literal, and anchoring facts similarly reject
impossible requests. An interior literal has no proven match-relative offset, so
Matcher may use it to reject a range but never to choose a candidate start. For
example, a pattern with a variable leading space run and a mandatory later token
can reject input lacking the token without assuming where the token belongs.
The specialized loops in `engine/accelerate/count.zig` run only for
compiler-proven ASCII byte-repeat shapes and return `null` for unsupported
Programs.

### Lazy DFA

The DFA in `engine/accelerate/dfa.zig` memoizes exact ordered-NFA subsets. A
state includes assertion context as well as the ordered item sequence; hash
matches are followed by exact equality checks. Instruction IDs use 16-bit
storage when possible and 32-bit storage otherwise.

`dfa_state_cache.zig` owns states, hash buckets, instruction storage, and sparse
or promoted transition rows. Byte equivalence classes reduce each transition
row to semantically distinct input classes. Once a known edge self-loops, the
forward or reverse executor skips equal-byte runs in portable vector blocks;
long `.*` regions therefore do not redispatch every byte.

A forward DFA naturally finds an endpoint but has discarded individual candidate
starts. To return an unanchored range, `execute/search.zig` may lazily compile the
reversed Program and run a reverse DFA from that endpoint to recover the leftmost
compatible start. Full matching uses a separate cache. Absolute-end facts can
begin directly at the only legal endpoint.

Shared cache access follows one protocol: try a nonblocking shared lock and use
only known state/edges; if construction is needed, release it and try the
exclusive lock without waiting. Cache state becomes visible only after complete
transactional publication.

DFA use is deliberately opportunistic. It declines on:

```text
disabled cache, lock contention, allocation failure,
state limit, or unproductive state construction
```

A decline is not “no match.” The caller restarts with the ordered NFA from clean
state. A productivity decline retains every exact state and edge already
published, allowing later warmed calls to amortize a large dictionary. Hard
allocation or state-limit failures still discard an unusable role cache. Known
transitions can be read concurrently; state construction requires the exclusive
lock. The configured cache allowance is lazy and split into stable role
partitions, so operation order cannot spend another role's ceiling.

## 9. Captures

Captures attach a start/end slot pair to each group, including group zero. An
unmatched group has absent slots; a participating empty group has equal present
offsets. Path identity now includes write history, making ordinary thread merging
more expensive than captureless execution.

`execute/capture.zig` therefore separates finding the winning range from replaying
that exact range when profitable, and uses this staged policy:

1. **Direct BitState search** for small assertion-free products.
2. Otherwise locate the semantic match range.
3. **Whole-range alias** when every group is proven equal to group zero.
4. **OnePass** when each state and byte has at most one viable route.
5. **Exact BitState replay** over a bounded already-known range.
6. **Capture NFA** as the complete fallback.

Each stage is exact when it completes; eligibility or resource failure advances
to the next stage rather than producing no-match. OnePass separates an immutable
shared plan from matcher-local execution scratch. BitState performs depth-first
ordered replay, marks admitted `(root, position)` pairs, and records reversible
slot updates. It is exact, but
its bitmap product is admitted only below explicit limits.

`engine/capture_nfa.zig` carries a capture-row ID with each ordered thread.
`engine/capture_pool.zig` implements reference-counted copy-on-write rows:
branches share a row until one writes a slot, then copy. Rows are recycled
between searches. This avoids copying every capture slot at every split while
retaining complete ordered semantics.

## 10. Request coordination

`execute/request.zig` contains typed policy decisions and decline reasons, not
engine calls. `execute/search.zig` owns shared-DFA protocols. `matcher.zig`
coordinates public operation families and names the fallback at each call site.
`execute/capture.zig` coordinates capture-specific scratch.

The result family determines how much state an engine must preserve:

| Request | Optional route | Complete route |
|---|---|---|
| existence | closed shape, direct plan, or forward DFA | ID/range NFA |
| range | closed shape or forward/reverse DFA composition | ordered range NFA |
| exact full match | dedicated full DFA | anchored-longest range NFA |
| count | exact byte plan or repeated endpoint DFA | ordinary range iteration |
| captures | alias, OnePass, or BitState | capture NFA |

A completed optional route may return a negative answer. Only typed decline moves
to the right-hand fallback, and fallback begins with clean queues/results rather
than attempting to continue partially built state.

This separation prevents two dangerous designs:

- an accelerator silently invoking a different engine with partially consumed
  state;
- a single giant switch that conflates boolean, range, full, and capture
  representations.

Empty-match iteration is handled at the Matcher layer. After an empty result it
advances one valid scalar, or one byte for malformed UTF-8, and suppresses a
duplicate adjacent empty result. Capture results add another lifetime boundary:
a `CaptureView` borrows Matcher result slots and is invalidated by the next
operation, while owned result types copy those offsets.

## 11. Collections and rewriting

The two collection products solve different workloads:

| Product | Compilation model | Final authority |
|---|---|---|
| `Set` | one captureless Program with accepting insertion IDs | combined DFA or ID-only NFA |
| `Filtered` | independent Regexes behind required-atom formulas | exact verification by each Regex |

`collection/set.zig` parses captureless patterns into one syntax arena and one
combined Program. Accepting leaves carry dense insertion-order IDs. A many-match
DFA may scan once; the ID-only NFA is complete fallback.

`collection/filtered.zig` keeps independent Regex objects. During construction,
`required_atoms.zig` derives conservative Boolean formulas over required
literals; `filter_plan.zig` interns and orders the published formula graph.
The built-in `literal/teddy.zig` scanner or an external scanner reports atom
IDs. Formula evaluation produces candidates, and every final match is verified
by its Regex. False positives cost time; false negatives are forbidden.

`rewrite.zig` parses replacement templates into literal and capture-reference
operations. It uses ordinary Matcher iteration and returns independently owned
output. It is a consumer of matching semantics, not an execution engine.

`engine/possible_match.zig` is a separate static analysis: for finite anchored
languages it computes bounded bytewise lexical minima and maxima. It does not
participate in matching.

## 12. Resources, failure, and concurrency

`support/budget_allocator.zig` wraps an allocator and tracks requested live and
peak bytes—not usable allocator size or process RSS. Compile memory, DFA caches,
matcher scratch, collection storage, rewrite output, result counts, and optional
work estimates have distinct policies. Checked arithmetic rejects dimensions
that cannot be represented. Defaults are finite; unlimited budgets are explicit.

The failure rule is:

- essential allocation failure is returned;
- crossing a configured hard limit returns its public limit error or diagnostic;
- optional accelerator failure causes a clean decline and complete fallback.

`support/try_rw_lock.zig` is nonblocking by design. Contention therefore affects
route and speed, not correctness. Published Regex, Set, and Filtered state may
be shared, but builders and Matchers may not.

## 13. Product boundary and reading order

`src/root.zig` is the only public module. `src/internal.zig` exposes private
measurements only to tests and benchmarks. Repository checks enforce an acyclic
import graph, layer boundaries, complete-engine independence from accelerators,
and explicit fallback ownership.

A productive reading order is:

1. `match.zig`, `root.zig`, `regex.zig` — public concepts and ownership;
2. `syntax/regexp.zig`, `frame_reducer.zig`, `parser.zig` — front end;
3. `program/tour_test.zig`, `graph.zig`, `builder.zig`, `compiler.zig` — Thompson
   construction;
4. `priority_lists.zig`, `publication.zig`, `program.zig` — runtime form;
5. `closure_cursor.zig`, `context.zig`, `nfa.zig` — semantic authority;
6. `dfa_state_cache.zig`, `dfa.zig`, `execute/search.zig` — memoized subsets;
7. `capture_pool.zig`, `capture_nfa.zig`, `bit_state.zig`, `one_pass.zig` —
   capture strategies;
8. `matcher.zig` — how public requests compose all paths;
9. `collection/` and `rewrite.zig` — higher-level products;
10. `testing/` and `engine/equivalence_test.zig` — executable evidence.

Keep this checklist beside the source:

- **Order is semantic.** Alternation, greediness, first arrival, and nullable-loop
  commitment cannot be casually reordered.
- **Coordinates are absolute bytes.** Encoding affects consumption, while ranged
  assertions still inspect the complete input.
- **Facts are one-sided proofs.** Unless a shape is proven complete, a fact may
  reject or skip work but may not invent an answer.
- **Decline is not rejection.** Optional engines return a typed no-answer and the
  coordinator restarts exact execution from clean state.
- **Ownership is explicit.** Every allocation is transferred once or released by
  one rollback/teardown path; borrowed views do not become owners.
- **Contention changes speed only.** Shared optional artifacts never require a
  public request to wait or accept a weaker result.

Continue with [Testing and Evidence](testing.md) to see how independent models,
forced-engine comparisons, allocation schedules, and concurrency stress exercise
these claims. For declaration-level detail, follow the `//!` module maps and `///`
contracts in the reading order above.
