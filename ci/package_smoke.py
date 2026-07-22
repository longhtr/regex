#!/usr/bin/env python3
"""Fetch this checkout as a package and compile a minimal external consumer."""

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
    "AI_AUTHORSHIP_DISCLAIMER.md",
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

pub fn main() !void {
    var expression = try regex.Regex.init(std.heap.page_allocator, "item[0-9]+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();
    if (!matcher.fullMatch("item42")) return error.ExpectedMatch;
}
'''


def main():
    manifest = (ROOT / "build.zig.zon").read_text()
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

        (consumer / "build.zig").write_text(BUILD_ZIG)
        (consumer / "build.zig.zon").write_text(BUILD_ZON)
        (consumer / "src" / "main.zig").write_text(MAIN_ZIG)
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

    print("package consumer smoke test...OK")


if __name__ == "__main__":
    main()
