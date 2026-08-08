# Syntax front end

This directory turns pattern bytes into a compact, normalized `Regexp` arena or a
byte-accurate diagnostic. It owns grammar and syntax-option behavior; it does not
choose an execution engine or define runtime match priority beyond preserving the
ordered structure authored by the pattern.

See the public [Pattern Syntax guide](../../docs/syntax.md) for the supported
language. This document describes implementation responsibilities.

## Pipeline

```text
pattern bytes
  → scanner.zig          decode runes and numeric escapes
  → parser.zig           recognize grammar and option-dependent operators
  → frame_reducer.zig    reduce groups, concatenation, and alternation
  → char_class.zig       normalize class terms and folding
  → regexp.zig           publish arena-backed syntax
```

Parsing is iterative. Deep pattern nesting consumes bounded allocator-backed
stacks rather than the process stack.

## File map

| File | Responsibility |
|---|---|
| [`scanner.zig`](scanner.zig) | Stateless UTF-8/Latin-1 rune decoding, escapes, decimal scanning, cursor movement |
| [`parser.zig`](parser.zig) | Grammar, syntax modes, flags, capture numbering, limits, diagnostics |
| [`frame_reducer.zig`](frame_reducer.zig) | Explicit-stack precedence and group reduction |
| [`regexp.zig`](regexp.zig) | Typed append-only arena for nodes, children, runes, ranges, and names |
| [`char_class.zig`](char_class.zig) | Mutable class union, folding closure, complement, newline exclusion |
| [`class_terms.zig`](class_terms.zig) | Perl, POSIX, and Unicode named-class expansion |
| [`rune_range.zig`](rune_range.zig) | Allocation-free normalized interval algebra |
| [`parser_qualification_test.zig`](parser_qualification_test.zig) | Syntax-mode boundaries and diagnostic spans |
| [`regexp_qualification_test.zig`](regexp_qualification_test.zig) | Arena scale, ownership, and capture metadata |

## Core invariants

- Diagnostics use absolute half-open byte spans in the original pattern.
- UTF-8 patterns decode only canonical scalar values; Latin-1 maps one byte to
  one scalar.
- `Regexp` IDs and spans are typed 32-bit domains and are checked before append.
- Concatenation and alternation are n-ary, avoiding deep binary syntax chains.
- Character-class ranges are normalized, sorted, disjoint, and nonadjacent.
- Folding occurs before class negation so complete fold cycles are excluded.
- Perl/POSIX spelling is grammar policy; `.match_kind` remains independent.
- Failure leaves no partially published syntax owner.

## Safe changes

A grammar change normally requires:

1. a readable update to `docs/syntax.md`;
2. parser/scanner tests for accepted spelling and exact rejected spans;
3. compiler and public semantic evidence for the new node behavior;
4. limit and malformed-input cases when user-controlled scanning changes.

Do not encode execution shortcuts in syntax nodes. New syntax should describe
language and priority; conservative optimization belongs in `../optimize/`, and
byte automata belong in `../program/`.

## Related documentation

- [Pattern Syntax](../../docs/syntax.md)
- [Engine Architecture: syntax front end](../../docs/architecture.md#2-syntax-front-end)
- [`../program/README.md`](../program/README.md)
- [`../testing/README.md`](../testing/README.md)
