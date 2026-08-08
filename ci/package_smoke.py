#!/usr/bin/env python3
"""Fetch this checkout as a package, then build and run an external consumer."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PUBLISHED_PATHS = (
    "build.zig",
    "build.zig.zon",
    "LICENSE",
    "README.md",
    "src",
    "examples",
    "docs",
    "benchmark.py",
    "build_checks.py",
    "testing.py",
)

BUILD_ZIG = r'''const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "regex-package-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "regex",
                .module = dependency.module("regex"),
            }},
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    const smoke = b.step("smoke", "Run the external package consumer");
    smoke.dependOn(&run.step);
}
'''

BUILD_ZON = r'''.{
    .name = .regex_package_smoke,
    .version = "0.0.0",
    .fingerprint = 0xae507d94f69af380,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
'''

MAIN_ZIG = r'''const std = @import("std");
const regex = @import("regex");

fn captureText(input: []const u8, found: ?regex.Match) ![]const u8 {
    const value = found orelse return error.MissingCapture;
    return value.slice(input) orelse error.InvalidMatchBounds;
}

fn addSetPattern(builder: *regex.Set.Builder, pattern: []const u8) !u32 {
    return switch (try builder.add(pattern)) {
        .success => |id| id,
        .diagnostic => error.InvalidPattern,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const input =
        "INFO user=alice id=42\n" ++
        "WARN user=bob id=7\n" ++
        "ERROR user=carol id=105";

    var expression = try regex.Regex.init(
        allocator,
        "(?P<level>INFO|WARN|ERROR) user=(?P<user>[A-Za-z]+) id=(?P<id>[0-9]+)",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();

    if (!matcher.isMatch(input)) return error.ExpectedPartialMatch;
    if (matcher.fullMatch(input)) return error.UnexpectedFullMatch;
    if (matcher.count(input) != 3) return error.UnexpectedMatchCount;

    const expected_users = [_][]const u8{ "alice", "bob", "carol" };
    var record_count: usize = 0;
    var id_sum: u32 = 0;
    var captures = matcher.captureIterator(input);
    while (try captures.next()) |view| {
        if (record_count >= expected_users.len) return error.TooManyRecords;
        const user = try captureText(input, expression.namedCapture(view, "user"));
        if (!std.mem.eql(u8, user, expected_users[record_count]))
            return error.UnexpectedUser;
        const id_text = try captureText(input, expression.namedCapture(view, "id"));
        id_sum += try std.fmt.parseInt(u32, id_text, 10);
        record_count += 1;
    }
    if (record_count != expected_users.len) return error.MissingRecords;
    if (id_sum != 154) return error.UnexpectedIdSum;

    var rewrite = try regex.Rewrite.compile(
        allocator,
        &expression,
        "\\g<user>#\\g<id>",
    );
    defer rewrite.deinit();
    var replacement = try rewrite.replaceAll(&matcher, allocator, input, 3);
    defer replacement.deinit();
    if (replacement.replacement_count != 3 or
        !std.mem.eql(u8, replacement.bytes, "alice#42\nbob#7\ncarol#105"))
        return error.UnexpectedReplacement;

    var set_builder = regex.Set.Builder.init(allocator, .{}, .unanchored);
    defer set_builder.deinit();
    if (try addSetPattern(&set_builder, "ERROR") != 0) return error.UnexpectedSetId;
    if (try addSetPattern(&set_builder, "WARN") != 1) return error.UnexpectedSetId;
    if (try addSetPattern(&set_builder, "DEBUG") != 2) return error.UnexpectedSetId;
    var set = try set_builder.compile();
    defer set.deinit();
    var set_matcher = try set.matcher(allocator);
    defer set_matcher.deinit();
    var set_ids = try set_matcher.allMatches(allocator, input, 3);
    defer set_ids.deinit();
    const expected_ids = [_]u32{ 0, 1 };
    if (!std.mem.eql(u32, set_ids.values(), &expected_ids))
        return error.UnexpectedSetMatches;

    var unicode_expression = try regex.Regex.init(allocator, "\\p{Greek}\\pL+");
    defer unicode_expression.deinit();
    var unicode_matcher = try regex.Matcher.init(allocator, &unicode_expression);
    defer unicode_matcher.deinit();
    const unicode_input = "status=Δelta";
    const unicode_match = unicode_matcher.find(unicode_input) orelse
        return error.ExpectedUnicodeMatch;
    const unicode_text = unicode_match.slice(unicode_input) orelse
        return error.InvalidMatchBounds;
    if (!std.mem.eql(u8, unicode_text, "Δelta"))
        return error.UnexpectedUnicodeMatch;

    const invalid = try regex.Regex.compile(allocator, "(unfinished", .{});
    switch (invalid) {
        .diagnostic => |diagnostic| {
            if (diagnostic.code != .missing_paren or
                diagnostic.start != 0 or diagnostic.end != 1)
                return error.UnexpectedDiagnostic;
        },
        .success => |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedDiagnostic;
        },
    }

    const report_file = try std.Io.Dir.cwd().createFile(
        init.io,
        "regex-report.txt",
        .{},
    );
    defer report_file.close(init.io);
    var report_buffer: [1024]u8 = undefined;
    var report_writer: std.Io.File.Writer = .init(
        report_file,
        init.io,
        &report_buffer,
    );
    try report_writer.interface.print(
        \\parsed record count: {d}
        \\parsed ID sum: {d}
        \\replacement count: {d}
        \\matched Set pattern count: {d}
        \\Unicode matched text: {s}
        \\package integration: OK
        \\
    , .{
        record_count,
        id_sum,
        replacement.replacement_count,
        set_ids.values().len,
        unicode_text,
    });
    try report_writer.interface.flush();
}
'''

EXPECTED_REPORT = """parsed record count: 3
parsed ID sum: 154
replacement count: 3
matched Set pattern count: 2
Unicode matched text: Δelta
package integration: OK
"""


def main():
    manifest = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    for relative in PUBLISHED_PATHS:
        if f'"{relative}"' not in manifest:
            raise RuntimeError(f"published package paths omit {relative}")

    with tempfile.TemporaryDirectory(prefix="regex-package-smoke-") as temporary:
        workspace = Path(temporary)
        package = workspace / "package"
        consumer = workspace / "consumer"
        cache = workspace / "cache"
        package.mkdir()
        consumer.mkdir()
        (consumer / "src").mkdir()

        # Stage only declared package content. This reproduces a clean archive and
        # prevents checkout-local caches from making a path dependency look valid.
        for relative in PUBLISHED_PATHS:
            source = ROOT / relative
            destination = package / relative
            if source.is_dir():
                shutil.copytree(source, destination)
            else:
                shutil.copy2(source, destination)

        (consumer / "build.zig").write_text(BUILD_ZIG, encoding="utf-8")
        (consumer / "build.zig.zon").write_text(BUILD_ZON, encoding="utf-8")
        (consumer / "src" / "main.zig").write_text(MAIN_ZIG, encoding="utf-8")
        environment = os.environ.copy()
        environment["ZIG_GLOBAL_CACHE_DIR"] = str(cache)

        subprocess.run(
            ["zig", "fetch", "--save=regex", str(package)],
            cwd=consumer,
            env=environment,
            check=True,
        )
        subprocess.run(
            ["zig", "build", "smoke", "--summary", "all"],
            cwd=consumer,
            env=environment,
            check=True,
        )
        report = (consumer / "regex-report.txt").read_text(encoding="utf-8")
        if report != EXPECTED_REPORT:
            raise RuntimeError(f"unexpected package consumer report:\n{report}")

    print("package consumer smoke test...OK")


if __name__ == "__main__":
    main()
