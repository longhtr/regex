# Use regex as a package

This guide builds a complete application that fetches `regex` from GitHub,
imports its public Zig module, performs a match, and writes the result to a file.
It also explains how to adapt an existing build and how to use a local checkout.

## Requirements

- Zig 0.16.0. Confirm with `zig version`.
- Network access for the first GitHub fetch.

The application does not need a separate checkout of this repository when using
the GitHub dependency.

## Create a new application

Create an application directory and let Zig generate its initial files:

```sh
mkdir my-app
cd my-app
zig init
```

Run every remaining command in this guide from `my-app`. The complete build file
below uses `src/main.zig` directly; the generated `src/root.zig` is not needed by
this example and may be left in place or deleted.

## Fetch the dependency

Add the package to the application's `build.zig.zon`:

```sh
zig fetch --save=regex git+https://github.com/longhtr/regex.git
```

Zig resolves the repository's default branch to a specific commit and writes a
dependency named `regex`, including its URL and package content hash. The new
`build.zig.zon` entry has this shape; the generated values are longer than the
placeholders shown here:

```text
.dependencies = .{
    .regex = .{
        .url = "git+https://github.com/longhtr/regex.git#<resolved-commit>",
        .hash = "<generated-content-hash>",
    },
},
```

The commit after `#` pins the Git revision. The content hash lets Zig verify the
fetched package. Do not copy or edit either generated value manually.

The name supplied to `--save` connects the package files:

```text
--save=regex               build.zig: b.dependency("regex", ...)
public module "regex"       source:    @import("regex")
```

Rerunning the same `zig fetch --save=regex` command checks whether the saved
GitHub dependency is current and updates its commit and content hash when needed.
An application continues to use its recorded commit until that dependency entry
is updated.

## Configure `build.zig`

Replace the generated `build.zig` with this file:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const regex_dependency = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });

    const executable = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport(
        "regex",
        regex_dependency.module("regex"),
    );
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    const run_step = b.step("run", "Run my-app");
    run_step.dependOn(&run.step);
}
```

`b.dependency` loads the package recorded in `build.zig.zon`.
`addImport("regex", ...)` makes its public module visible to `src/main.zig` as
`@import("regex")`. The explicit run directory ensures that the example's output
file is created in the application directory rather than in Zig's cache.

## Use the library

Replace `src/main.zig` with:

```zig
const std = @import("std");
const regex = @import("regex");

pub fn main(init: std.process.Init) !void {
    var expression = try regex.Regex.init(init.gpa, "item[0-9]+");
    defer expression.deinit();

    var matcher = try regex.Matcher.init(init.gpa, &expression);
    defer matcher.deinit();

    const output = try std.Io.Dir.cwd().createFile(
        init.io,
        "match-result.txt",
        .{},
    );
    defer output.close(init.io);

    var buffer: [256]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(output, init.io, &buffer);
    try file_writer.interface.print(
        "item42 matched: {}\n",
        .{matcher.fullMatch("item42")},
    );
    try file_writer.interface.flush();
}
```

`Regex` owns the compiled expression. `Matcher` owns reusable execution scratch.
Both must remain alive while matching and are released with `deinit`. Reuse them
when processing multiple inputs instead of compiling the same expression for
every request.

## Build, run, and verify

Run the application:

```sh
zig build run
```

The program creates `match-result.txt` in `my-app`. Display it with the command
for the current shell:

```sh
cat match-result.txt
```

Windows Command Prompt uses:

```bat
type match-result.txt
```

The file must contain:

```text
item42 matched: true
```

A normal `zig build` compiles and installs the executable as
`zig-out/bin/my-app`; use `zig build run` when following this example so that the
program actually executes and creates the result file.

## Adapt an existing application

Do not replace a working build file. After its `target` and `optimize` values are
defined, load the dependency:

```zig
const regex_dependency = b.dependency("regex", .{
    .target = target,
    .optimize = optimize,
});
```

Add the public module to the specific application module whose source contains
`@import("regex")`:

```zig
application_module.addImport(
    "regex",
    regex_dependency.module("regex"),
);
```

For an executable created with `b.addExecutable`, its root module is available
as `executable.root_module`:

```zig
executable.root_module.addImport(
    "regex",
    regex_dependency.module("regex"),
);
```

Using `addImport` preserves all imports already configured by the application.
If `@import("regex")` appears in a separate library module rather than the
executable's root source, add the import to that library module instead.

## Use a local checkout

For a sibling checkout at `../regex`, skip the GitHub fetch and add a path
dependency to the application's `build.zig.zon`:

```zig
.dependencies = .{
    .regex = .{ .path = "../regex" },
},
```

Keep any other existing dependency entries. If `regex` is already recorded as a
GitHub dependency, replace only its `.regex` entry with the path entry. The path
is resolved relative to the application's `build.zig.zon`.

No build or source changes are required: both dependency forms expose the same
public module named `regex`.

## Troubleshooting

- **`no dependency named 'regex'`:** run the fetch command from the directory
  containing the application's `build.zig.zon`, and keep the name
  `--save=regex` consistent with `b.dependency("regex", ...)`.
- **`no module named 'regex' available within module`:** call `addImport` on the
  module that compiles the source containing `@import("regex")`.
- **Zig API or build-file errors:** confirm that `zig version` reports `0.16.0`.
  Build APIs from earlier Zig releases are not compatible with this guide.
- **`match-result.txt` is missing:** use `zig build run`, not only `zig build`,
  and retain `run.setCwd(b.path("."))` from the complete build file.
- **A local path cannot be found:** remember that `.path` is relative to
  `build.zig.zon`, not to the shell's current directory.

## Next steps

- [Examples](../examples/README.md) provides complete recipes for matching,
  captures, replacement, sets, filtering, limits, and concurrency.
- [Public API](api.md) documents ownership, operations, errors, and limits.
- [Pattern syntax](syntax.md) documents supported expression syntax.
