# ReBar dictionary regression data

This directory contains the two committed assets needed to reproduce the shape of
a severe large-literal-alternation regression without redistributing the original
subtitle corpus.

## Files

- `rebar-english-length-15.regex` is a literal-escaped alternation derived from
  ReBar's `benchmarks/regexes/dictionary/english/length-15.txt`.
- `rebar-english-length-15-decoys.txt` is a synthetic high-density near-miss
  corpus followed by the known final dictionary entry `Zubeneschamali's`.

The expected corpus observation is one match: the final complete entry. The
preceding decoys are one-byte-short prefixes selected so that none contains a
complete source word as a substring. This retains dense deep-prefix pressure while
avoiding imported copyrighted subtitle text.

## Provenance and transformation

- Upstream project: ReBar, <https://github.com/BurntSushi/rebar>
- Upstream revision: `463d00f318`
- Upstream license: Unlicense
- Source dictionary: `benchmarks/regexes/dictionary/english/length-15.txt`
- Regex transformation: ReBar `literal = true, per-line = "alternate"`
- Synthetic corpus transformation: drop the final byte of each source word and
  retain only strings containing no complete source word as a substring; append
  the known final source entry

The synthetic corpus replaces ReBar's OpenSubtitles haystack. No subtitle text is
committed here.

## Maintenance rules

These files are regression inputs, not general benchmark corpora. Changes must:

1. preserve or deliberately update the independently known expected observation;
2. document the exact source revision and deterministic transformation;
3. retain upstream and local licensing/provenance information;
4. explain why replacement data reproduces the intended cost shape;
5. avoid adding source text that cannot be redistributed;
6. update the corresponding typed workload and benchmark documentation together.

Do not normalize, sort, rewrap, or deduplicate the assets merely for readability;
their byte layout is benchmark input.

## Related documentation

- [`../README.md`](../README.md)
- [Benchmarking](../../../docs/benchmark.md)
- [`../../../LICENSE`](../../../LICENSE)
