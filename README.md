# regex

[AI authorship disclaimer](AI_AUTHORSHIP_DISCLAIMER.md)

`regex` is a finite-automata regular-expression library for Zig. It provides
Perl-style and POSIX syntax, UTF-8 and Latin-1 matching, captures, replacement,
and multi-pattern search without recursive backtracking. Matching uses an
ordered Thompson NFA to preserve leftmost-first, greedy, and lazy semantics with
predictable worst-case behavior.

Compile an expression once and create reusable `Matcher` scratch for each thread.
Literal search, specialized byte loops, and lazy DFA, OnePass, and BitState
engines accelerate eligible requests; when an optimization cannot answer, the
library transparently falls back to complete ordered execution. Explicit memory,
work, and result limits make resource policy part of the API.

```zig
const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "item42 is ready";

    var expression = try regex.Regex.init(
        std.heap.page_allocator,
        "[A-Za-z]+[0-9]+",
    );
    defer expression.deinit();

    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    if (matcher.find(input)) |found| {
        const text = found.slice(input) orelse return error.InvalidMatchBounds;
        std.debug.print(
            \\matched text: {s}
            \\start byte offset: {d}
            \\end byte offset (exclusive): {d}
            \\
        , .{ text, found.start, found.end });
    } else {
        std.debug.print("no match found\n", .{});
    }
}
```

## Documentation

- [Examples](examples/README.md) — complete programs and guided learning paths
- [Public API](docs/api.md) — ownership, operations, errors, and limits
- [Pattern syntax](docs/syntax.md) — Perl/POSIX modes, Unicode, and diagnostics
- [Engine architecture](docs/architecture.md) — compilation, execution, and fallback
- [Testing](docs/testing.md) — evidence layers, CI, and failure triage
- [Benchmarking](docs/benchmark.md) — qualified workloads and measurement policy
- [Source map](src/README.md) — implementation directories and reading paths

## Build and qualification

The project requires Zig 0.16.0. Qualification scripts also require Python 3.
There are no external library or package dependencies.

Run `zig build --help` for the authoritative step and option list.

| Command | Purpose |
|---|---|
| `zig build` | Compile selected-mode tests and install the public examples |
| `zig build examples` | Build and install every example in the selected mode |
| `zig build examples-run` | Build and run every example without installing it |
| `zig build check` | Check formatting, repository rules, docs, examples, and benchmark compilation |
| `zig build test` | Run the quick Debug suite and overwrite `testing.log` |
| `zig build test-all` | Run all test modes and deterministic campaigns |
| `zig build benchmark` | Run qualified local measurements and overwrite `benchmark.log` |
| `zig build uninstall` | Remove artifacts from the selected install prefix |

Common variants include:

```sh
zig build examples -Doptimize=ReleaseFast
zig build test-all -Dfuzz-iterations=50000
zig build test-all -Drace=true
zig build benchmark -Dbenchmark-samples=3
zig build examples --prefix ./output
```

The default `zig-out` prefix contains:

```text
zig-out/bin/examples/regex-*       installed example executables
zig-out/docs/api/index.html        generated public API documentation
zig-out/bin/regex-benchmark        benchmark adapter
```

Examples are installed by `zig build` or `zig build examples`. API documentation
is installed by `zig build check`. The benchmark adapter is installed by
`zig build benchmark`; merely checking the repository compiles it into Zig's
cache without installing it.

## Use as a package

For a sibling checkout, add a local dependency to the application's
`build.zig.zon`:

```zig
.dependencies = .{
    .regex = .{ .path = "../regex" },
},
```

Then obtain the exported module in `build.zig`:

```zig
const dependency = b.dependency("regex", .{
    .target = target,
    .optimize = optimize,
});
const regex_module = dependency.module("regex");
```

Add `regex_module` to the importing module's `.imports` under the name `regex`.
Remote packages can be recorded with `zig fetch --save=regex <URL>`. See
[Add the package to an application](examples/README.md#add-the-package-to-an-application)
for a complete build-file example.

## License

Original project code and documentation are released under the
[Unlicense](LICENSE). Bundled Unicode data remains under the
[Unicode License V3](src/unicode/LICENSE); ReBar-derived benchmark data is
identified with its provenance and license in
[`src/benchmark/data/README.md`](src/benchmark/data/README.md).
