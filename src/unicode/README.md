# Embedded Unicode data

This directory provides the allocation-free Unicode metadata used by parsing,
case folding, byte lowering, and Filtered normalization. The committed data
version is **Unicode 17.0.0**.

## Files

| File | Role |
|---|---|
| [`data.zig`](data.zig) | Typed, bounds-aware access to groups, ranges, fold cycles, and lowercase mappings |
| `generated.bin` | Versioned little-endian table embedded at compile time |
| [`LICENSE`](LICENSE) | Unicode Data Files and Software License, version 3 |

## Binary layout and validation

`data.zig` embeds `generated.bin` with `@embedFile`. The blob begins with the
`REGXUCD1` magic and a fixed little-endian header, followed by:

1. sorted group records;
2. normalized rune ranges;
3. sorted simple-fold pairs;
4. group-name bytes;
5. page-indexed fold targets;
6. lowercase mapping pairs.

Comptime checks reject bad magic or an inconsistent total size. Runtime accessors
use explicit little-endian reads and bounds established by the validated layout.
Returned names and ranges borrow the embedded blob for process lifetime; lookup
allocates nothing.

## Semantic boundaries

- Group names use exact, case-sensitive project names and binary search.
- Range sets are normalized and may include surrogate-category metadata because
  syntax range algebra works over Unicode code points.
- UTF-8 Program lowering separately excludes non-scalar surrogate values.
- `foldNext` follows Unicode simple-fold cycles.
- `toLower` supplies a stable canonical mapping for conservative prefilter
  normalization; it is not locale-sensitive casing.
- Public matching offsets remain bytes; Unicode tables do not change coordinates.

## Updating the data

The repository currently commits the generated blob but does not contain its
generator. Do not hand-edit binary offsets or change `version` independently.
A Unicode update must arrive as one reviewed transaction that:

1. regenerates `generated.bin` from the intended Unicode release;
2. updates `data.zig`'s version and layout reader if necessary;
3. preserves the `REGXUCD1` format or introduces an explicitly versioned format;
4. verifies sorted names, normalized ranges, fold cycles, lowercase mappings, and
   representative newly added scripts/categories;
5. reruns parser, folding, UTF-8 lowering, Filtered, and full qualification;
6. confirms license and provenance requirements.

Because generation tooling is not present, reproducibility of a data refresh must
be supplied and reviewed with the change rather than inferred from this tree.

## Qualification

Colocated tests verify sorting, normalization, lookup, version, scripts, and fold
behavior. Broader evidence lives in syntax, Program-lowering, semantic-model, and
Filtered tests.

## Related documentation

- [Pattern Syntax: Unicode classes](../../docs/syntax.md)
- [Engine Architecture](../../docs/architecture.md)
- [`../syntax/README.md`](../syntax/README.md)
- [`../collection/README.md`](../collection/README.md)
