# Pattern Syntax

This document specifies the pattern language accepted by `Regex`. Patterns
compile to finite automata and execute without recursive backtracking. The
supported grammar deliberately excludes backreferences, capture-dependent
control, recursion, and look-around rather than attempting partial compatibility
with backtracking-oriented dialects.

Three compile choices are independent:

| Choice | Controls |
|---|---|
| `encoding` | whether pattern/input scalars are UTF-8 or Latin-1 bytes |
| `semantics` | available spelling and initial flags (`.perl` or `.posix`) |
| `match_kind` | leftmost-first versus leftmost-longest result selection |

Changing syntax mode does not silently change result priority. All pattern
diagnostics and match ranges use half-open byte offsets, even in UTF-8 mode.
Patterns must be valid in their selected encoding; input may contain arbitrary
bytes, with malformed UTF-8 behavior described under [Encodings](#encodings).

Use the quick reference to find a construct, then read its section for mode,
encoding, and priority details.

## Quick reference

| Form | Meaning |
|---|---|
| `x` | literal scalar or byte |
| `.` | any scalar except newline by default |
| `\C` | any one input byte (Perl mode) |
| `xy` | concatenation |
| `x\|y` | ordered alternation |
| `(x)` | capturing group |
| `(?:x)` | noncapturing group (Perl mode) |
| `(?P<name>x)`, `(?<name>x)` | named capture (Perl mode) |
| `x*`, `x+`, `x?` | repetition |
| `x{n}`, `x{n,}`, `x{n,m}` | counted repetition |
| `x*?`, `x+?`, `x??`, `x{n,m}?` | lazy repetition (Perl mode) |
| `[abc]`, `[a-z]`, `[^a-z]` | character class |
| `^`, `$` | text or line assertion, according to flags |
| `\A`, `\z` | absolute input start/end (Perl mode) |
| `\b`, `\B` | ASCII-word boundary/non-boundary |
| `\d`, `\s`, `\w` | ASCII Perl classes (enabled by mode/options) |
| `\p{Name}`, `\P{Name}` | Unicode group/complement (Perl mode) |
| `(?i:x)`, `(?m:x)`, `(?s:x)`, `(?U:x)` | scoped flags |

Precedence, from low to high, is alternation, concatenation, then postfix
repetition. Thus `ab|cd+` means `(ab)|(c(d+))`. Empty patterns, groups, and
alternatives are valid.

## Perl and POSIX modes

`CompileOptions.semantics` selects syntax spelling and initial flags. It does
not choose result priority; `match_kind` independently selects leftmost-first or
leftmost-longest.

### Perl mode

Perl mode is the default. It enables noncapturing/named groups, inline flags,
lazy repetition, `\A`, `\z`, `\C`, `\Q...\E`, Perl classes, word boundaries,
and Unicode group escapes. `^` and `$` initially mean absolute text start/end.

“Perl” names the supported regular subset, not the entire Perl language.
Backreferences and look-around are not supported.

### POSIX mode

POSIX mode supports capturing groups, alternation, repetition, bracket
expressions, and POSIX named classes. `^` and `$` are line-oriented initially;
`text_anchors = true` makes them absolute.

Perl group operators, inline flags, lazy suffixes, `\A`, `\z`, `\C`,
`\Q...\E`, and Unicode group escapes are rejected. `perl_classes` and
`word_boundary` can opt the ASCII Perl classes and boundaries into POSIX mode.
The implementation does not provide locale-dependent collation.

## Literals, escapes, and quoting

Outside a character class, these bytes are metacharacters:

```text
. ^ $ * + ? { [ ( ) | \
```

Escape punctuation to make it literal, such as `\.` or `\+`. An unknown escaped
ASCII letter or digit is an error; it is not silently treated as a literal.

Perl mode's `\Q` starts literal quoting through `\E` or the end of the pattern:

```text
\Qprice: $5.00\E
```

`CompileOptions.literal = true` disables all metasyntax for the complete
pattern, although the pattern must still be valid in the selected encoding.

### Character escapes

| Escape | Value |
|---|---:|
| `\a` | bell, `0x07` |
| `\f` | form feed, `0x0c` |
| `\n` | newline, `0x0a` |
| `\r` | carriage return, `0x0d` |
| `\t` | tab, `0x09` |
| `\v` | vertical tab, `0x0b` |
| `\xHH` | exactly two hexadecimal digits |
| `\x{H...}` | one or more hexadecimal digits |
| `\0`, `\0NN`, `\NN`, `\NNN` | one to three octal digits |

A lone nonzero octal digit such as `\1` is rejected to avoid a backreference-like
spelling. Two- and three-digit octal forms are accepted when in range. Numeric
escapes may not denote a surrogate, a value above `U+10FFFF`, or a value above
`0xff` in Latin-1 mode.

## Alternation and match priority

Alternatives are ordered. With `.first`, the engine chooses the earliest start
and then the first successful path according to alternation order and
repetition greediness. With `.longest`, it chooses the earliest start and
furthest end; pattern order resolves remaining ties.

For example, on input `ab`, `a|ab` returns `a` with `.first` and `ab` with
`.longest`. Greedy/lazy order matters after the start has been chosen; it never
allows a later start to outrank an earlier one. These are execution semantics,
not different pattern grammars.

## Groups and captures

Plain parentheses capture and are numbered in opening-parenthesis order from
one. Group zero is always the whole match.

```text
([A-Za-z]+)-([0-9]+)
(?:noncapturing)
(?P<word>[A-Za-z]+)
(?<word>[A-Za-z]+)
```

The latter three forms require Perl mode. A capture name is nonempty and every
scalar must belong to one of these Unicode categories:

```text
Lu Ll Lt Lm Lo Nl Mn Mc Nd Pc
```

Digits may therefore appear first; punctuation such as `-` may not. Duplicate
names are accepted. Name lookup returns the leftmost group, while indexed access
retains all declarations.

A group that does not participate is reported as `null`; a participating empty
group has equal start/end offsets. When a group participates several times under
repetition, its final participating iteration supplies the reported range. Group
zero always covers the selected whole match.

`capture_groups = false` makes ordinary parentheses noncapturing. Explicit named
groups still capture. Capture declarations are bounded by `max_captures` and the
other compile limits.

## Repetition

| Form | Minimum | Maximum |
|---|---:|---:|
| `x*` | 0 | unbounded |
| `x+` | 1 | unbounded |
| `x?` | 0 | 1 |
| `x{n}` | n | n |
| `x{n,}` | n | unbounded |
| `x{n,m}` | n | m |

Decimal bounds have no leading zero except zero itself. A complete repeat is
rejected when `m < n` or either value exceeds `max_repeat` (1,000 by default).
A brace sequence that is not a complete repeat form is parsed literally.

Repetition is greedy by default: among paths at the same start, it prefers
another iteration before exit. In Perl mode a trailing `?` makes exit preferred.
The `U` flag reverses this default, so the trailing `?` then makes a repetition
greedy. These preferences affect `.first`; `.longest` still chooses the furthest
endpoint before using path order to break ties.

Applying another repetition operator to an already repeated expression is
rejected in Perl mode. Possessive repetition is unsupported. Nullable repetition
terminates without recursive backtracking or an infinite empty loop.

## Character classes

A bracket expression matches one scalar from the union of its terms:

```text
[abc]
[a-zA-Z0-9_]
[^\n]
[]a]
[-a]
```

`^` negates only immediately after `[`. `]` is literal in the first term, and
`-` is literal at an edge. A range may not descend. Overlapping and adjacent
ranges are normalized. Class intersection, subtraction, equivalence classes,
and collating symbols are not implemented.

In case-insensitive mode the positive set is closed under Unicode simple folding
before negation. Thus `(?i)[^a]` excludes both `a` and `A` (and any other simple
fold peers). `exclude_newline` is applied after complement, so a negated class
cannot reintroduce newline.

Escaped literals and enabled named classes can be mixed:

```text
[A-F\d]
[\p{Greek}_]
```

`\b` inside a class is rejected; use `\x08` for backspace.

### Perl classes

These definitions are ASCII, even in UTF-8 mode:

| Class | Positive set |
|---|---|
| `\d` | `[0-9]` |
| `\s` | tab, newline, form feed, carriage return, space |
| `\w` | `[0-9A-Za-z_]` |

`\D`, `\S`, and `\W` complement those sets over the selected encoding universe.
They are enabled by default in Perl mode and by `perl_classes` in POSIX mode.

### POSIX named classes

Named classes appear inside brackets; `^` before the name complements that one
term:

```text
[[:alpha:]]
[[:^digit:]]
```

| Name | Exact positive set |
|---|---|
| `alnum` | ASCII letters and digits |
| `alpha` | ASCII letters |
| `ascii` | `0x00..0x7f` |
| `blank` | tab and space |
| `cntrl` | `0x00..0x1f` and `0x7f` |
| `digit` | `0..9` |
| `graph` | `0x21..0x7e` |
| `lower` | `a..z` |
| `print` | `0x20..0x7e` |
| `punct` | ASCII punctuation |
| `space` | `0x09..0x0d` and space |
| `upper` | `A..Z` |
| `word` | ASCII letters, digits, underscore |
| `xdigit` | ASCII hexadecimal digits |

Names are lowercase and case-sensitive. Case-insensitive mode adds Unicode
simple-fold equivalents of foldable letters.

## Unicode groups and folding

Perl mode accepts:

```text
\p{Greek}  \P{Greek}  \pL  \p{Nd}  \p{Any}
```

A leading `^` inside braces toggles negation, so `\p{^Greek}` equals
`\P{Greek}`. Names are exact and case-sensitive. The project embeds Unicode
17.0.0 general categories and scripts. Canonical names such as `L`, `Lu`, `Nd`,
`Latin`, `Greek`, `Han`, `Common`, and `Inherited` are accepted. Aliases and
property assignments such as `Letter`, `latin`, `Latn`, and `sc=Latin` are not.
`Any` is the full selected scalar universe.

Case-insensitive matching uses Unicode simple folding. It does not perform
multi-scalar full folding or locale-specific folding. Under Latin-1, groups and
fold results are clipped to `0x00..0xff`.

## Assertions

Assertions consume no bytes.

| Form | Meaning |
|---|---|
| `\A` | absolute input start |
| `\z` | absolute input end |
| `^` | text or line start, according to mode/flags |
| `$` | text or line end, according to mode/flags |
| `\b` | transition between ASCII word and nonword context |
| `\B` | absence of that transition |

Word context is `[0-9A-Za-z_]`; non-ASCII letters are nonword. In default Perl
mode, `$` means exact input end, not the position before a final newline. `m`
changes `^` and `$` to line assertions: line start is input start or immediately
after `\n`, and line end is input end or immediately before `\n`. Carriage return
has no special line-boundary status. POSIX mode starts with line assertions;
`text_anchors` makes them absolute. `\A` and `\z` are always absolute.

During ranged search, assertions inspect the complete input surrounding the
range. `Anchor.start` is an additional requirement at the requested range start,
not a replacement for pattern assertions.

## Dot, newline policy, and raw bytes

`.` consumes one scalar and excludes newline by default. `dot_matches_newline`
or Perl flag `s` includes newline. `exclude_newline` takes precedence and makes
newline unavailable to scalar literals, classes, and dot—even inside a scoped
`s` region.

Perl `\C` consumes exactly one byte. It can consume malformed UTF-8 or newline
because it bypasses scalar semantics.

## Inline flags

Perl mode supports global edits and scoped edits:

```text
(?i)rest
(?i:scoped)
(?im-s:scoped)
(?-i:case-sensitive)
```

| Flag | Enabled meaning |
|---|---|
| `i` | Unicode simple-fold matching |
| `m` | line-oriented `^` and `$` |
| `s` | dot includes newline |
| `U` | repetition is lazy by default |

`-` disables following flags in the same edit. Scoped edits restore outer flags
at `)`, while unscoped edits affect the rest of their group. Compile options set
the initial `i`, `m`/anchor, and `s` state; inline edits then apply at their source
position. `exclude_newline` is a separate hard policy and cannot be undone by
`s`.

Unknown flags, empty edits, repeated `-`, and unterminated edits are rejected.
There is no `x` whitespace/comment mode, so unescaped spaces in a pattern are
literal.

## Encodings

### UTF-8

Pattern bytes must be canonical Unicode scalar UTF-8. Overlong encodings,
surrogates, truncation, malformed continuation bytes, and values above
`U+10FFFF` produce `bad_utf8` diagnostics.

Input may be arbitrary bytes. Literals, classes, dot, and other scalar consumers
do not match malformed sequences; `\C` may match one malformed byte. Empty-match
iteration advances one scalar or one malformed byte, so it cannot stall.

### Latin-1

Every pattern and input byte is one scalar in `0x00..0xff`. Class complements,
Unicode groups, and numeric escapes use that universe. All offsets remain byte
offsets.

## Diagnostics

`Regex.compile` returns a diagnostic value with a code and exact half-open
pattern byte span. Slice the original pattern with `[start..end]` to highlight the
relevant bytes; an empty span identifies an insertion/end position. In UTF-8 the
indices are still bytes, so diagnostics can be passed directly to byte-oriented
editors without scalar-index conversion.

| Code | Meaning |
|---|---|
| `bad_escape` | malformed, unknown, unavailable, or out-of-range escape |
| `bad_char_range` | invalid class range, term, or Unicode group |
| `missing_bracket` | unterminated bracket expression |
| `missing_paren` | unterminated group |
| `unexpected_paren` | unmatched closing parenthesis |
| `trailing_backslash` | pattern or class ends after `\` |
| `repeat_argument` | repetition or Perl-group syntax lacks a valid operand/form |
| `repeat_size` | invalid or policy-exceeding counted repeat |
| `repeat_operator` | repeated postfix operator in Perl mode |
| `bad_perl_operator` | invalid flag edit or unsupported look-around |
| `bad_utf8` | malformed UTF-8 pattern or truncated scalar form |
| `bad_named_capture` | absent or invalid capture name |
| `resource_limit` | configured pattern, node, capture, instruction, or memory limit |

Allocator failure is an error, not a syntax diagnostic. `Regex.init` and
`initWithOptions` intentionally collapse these detailed codes to concise
`InvalidPattern` or `ResourceLimit` errors; use `Regex.compile` in user-facing
parsers and editors.

## Deliberately unsupported

The engine rejects backreferences, look-ahead and look-behind, recursion,
subroutines, conditionals, atomic and branch-reset groups, possessive repeats,
capture-dependent matching, class intersection/subtraction, locale collation,
embedded code, and callouts.

When migrating a pattern:

- replace a finite backreference case with explicit alternatives, or capture and
  compare in application code;
- split look-around into a regular match plus a separate prefix/suffix check;
- replace atomic/possessive tuning with ordinary regular structure—the engine has
  no catastrophic recursive backtracking to suppress;
- perform locale-sensitive classification outside the regex or provide explicit
  classes.

Unsupported spelling is diagnosed rather than silently assigned different
semantics.

See [Public API Guide](api.md) for compile options, diagnostic handling, ranged
matching, and capture lifetimes. See [Engine Architecture](architecture.md) for
how ordered priority and scalar-to-byte lowering implement these rules. Runnable
syntax examples are under `examples/`, while reviewed semantic cases live in
`src/testing/test_cases.zig`.
