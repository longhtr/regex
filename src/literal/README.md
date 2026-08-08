# Literal search primitives

This directory provides exact byte-search building blocks used by required-prefix
startup, direct plans, Set, and Filtered. These routines are optimizations or
candidate scanners; they do not independently define regular-expression
semantics.

## File map

| File | Responsibility |
|---|---|
| [`search.zig`](search.zig) | Bounded exact and proved ASCII-folded literal search |
| [`teddy.zig`](teddy.zig) | Portable many-atom Teddy-family scanner with full candidate verification |
| [`search_qualification_test.zig`](search_qualification_test.zig) | Exhaustive prefix/scanner qualification over ranges and encodings |

## Exact literal search

`search.zig` selects among scalar one-byte search, sparse first-byte candidates,
first/last pair filtering, portable vector comparisons, and standard-library
Boyer-Moore-Horspool for suitable long needles. Every route has the same contract:
search starts in `[start, end)`, never reads beyond `end`, allocates nothing, and
returns an input byte offset.

ASCII-folded search is available only when publication proved that lowering both
needle and input bytes is conservative for the configured encoding and folding
semantics. A search hit is generally a candidate; Matcher still executes regex
semantics unless a separate closed-language proof makes the literal authoritative.

## Multi-atom scanning

`teddy.zig` hashes published atoms into 64 buckets and intersects positional
nibble masks to reject impossible starts. Every surviving bucket candidate is
compared with the complete atom bytes. Hash or nibble collisions can therefore
cost work but cannot invent an atom occurrence.

Small atom sets use direct search. ASCII-folded scanning returns a completion flag:
encountering non-ASCII declines that path so Filtered can normalize with Unicode
data and run exact atom scanning again.

The scanner reports atom occurrence bits only. Required-formula evaluation and
final Regex verification remain in `../collection/`.

## Core invariants

- Search bounds and returned coordinates are bytes.
- No implementation reads outside the requested input range.
- Folded search is used only under a published proof.
- Every Teddy candidate is verified against complete bytes.
- Atom hits do not by themselves authorize a regex match.
- Route selection changes performance only.

## Safe changes

Compare every route against exhaustive candidate offsets, including empty/tiny
ranges, repeated prefixes, non-ASCII input, malformed UTF-8 bytes, and folded
ASCII. Scanner changes also need collision cases and Filtered no-false-negative
qualification.

## Related documentation

- [`../collection/README.md`](../collection/README.md)
- [`../program/README.md`](../program/README.md)
- [Engine Architecture](../../docs/architecture.md)
