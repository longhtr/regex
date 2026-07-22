const std = @import("std");
const builtin = @import("builtin");

/// Publishes the user-selected build plus independent qualification pipelines.
/// `check` runs every Debug example, compiles them in three modes, builds the
/// ReleaseFast benchmark adapter and API docs; Python drivers receive compiled
/// artifacts as explicit file
/// arguments so logging, process limits, and complete-suite policy stay outside
/// Zig's build graph.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const race = b.option(bool, "race", "Enable ThreadSanitizer") orelse false;
    const python = if (builtin.os.tag == .windows) "python" else "python3";

    // Public module and ordinary selected-mode compilation.
    const regex = b.addModule("regex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const selected_tests = testArtifact(b, target, optimize);
    b.default_step.dependOn(&selected_tests.step);

    const examples = b.step("examples", "Compile public examples in the selected mode");
    const run_examples = b.step("examples-run", "Build and run every public example");
    addExamples(b, target, optimize, regex, examples, run_examples, "");
    b.default_step.dependOn(examples);

    // Repository checks are also available independently of test execution.
    const check_step = b.step("check", "Run repository checks and compile examples, docs, and benchmark adapter");
    check_step.dependOn(run_examples);
    const format_check = b.addSystemCommand(&.{
        "zig", "fmt", "--check", "build.zig", "build.zig.zon", "src", "examples",
    });
    const architecture_check = b.addSystemCommand(&.{ python, "-B", "build_checks.py" });
    check_step.dependOn(&format_check.step);
    check_step.dependOn(&architecture_check.step);
    inline for (.{
        std.builtin.OptimizeMode.Debug,
        std.builtin.OptimizeMode.ReleaseSafe,
        std.builtin.OptimizeMode.ReleaseFast,
    }) |mode| {
        const mode_regex = regexModule(b, target, mode);
        addExamples(
            b,
            target,
            mode,
            mode_regex,
            check_step,
            null,
            b.fmt("-{s}", .{@tagName(mode)}),
        );
    }

    // Generated API documentation is part of repository qualification.
    const docs_object = b.addObject(.{ .name = "regex-docs", .root_module = regex });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_object.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });
    check_step.dependOn(&install_docs.step);

    // Quick tests and the complete gate both write testing.log.
    const test_step = b.step("test", "Run quick Debug tests and write testing.log");
    const quick_run = b.addSystemCommand(&.{ python, "-B", "testing.py", "quick" });
    const test_all_step = b.step("test-all", "Run the complete test gate and write testing.log");
    const testing_run = b.addSystemCommand(&.{ python, "-B", "testing.py", "full" });
    const debug_tests = testArtifact(b, target, .Debug);
    quick_run.addFileArg(debug_tests.getEmittedBin());
    testing_run.addFileArg(debug_tests.getEmittedBin());
    inline for (.{
        std.builtin.OptimizeMode.ReleaseSafe,
        std.builtin.OptimizeMode.ReleaseFast,
    }) |mode| {
        const mode_tests = testArtifact(b, target, mode);
        testing_run.addFileArg(mode_tests.getEmittedBin());
    }

    // Private engineering executables run only through the complete test command.
    const fuzz_executable = campaign(b, target, .ReleaseSafe, race, .{
        .name = "regex-fuzz-campaign",
        .kind = "fuzz",
    });

    const forced_executable = campaign(b, target, .ReleaseSafe, race, .{
        .name = "regex-forced-campaign",
        .kind = "equivalence",
    });
    const possible_executable = campaign(b, target, .ReleaseSafe, race, .{
        .name = "regex-possible-match-campaign",
        .kind = "possible-match",
    });
    const concurrency_executable = campaign(b, target, .ReleaseSafe, race, .{
        .name = "regex-concurrency-stress",
        .kind = "concurrency",
    });
    testing_run.addFileArg(fuzz_executable.getEmittedBin());
    testing_run.addArg(b.fmt("{d}", .{b.option(usize, "fuzz-iterations", "Deterministic fuzz iterations") orelse 10_000}));
    testing_run.addFileArg(forced_executable.getEmittedBin());
    testing_run.addFileArg(possible_executable.getEmittedBin());
    testing_run.addFileArg(concurrency_executable.getEmittedBin());

    // Typed benchmark workloads and process-level measurement runner.
    const internal = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const benchmark_executable = b.addExecutable(.{
        .name = "regex-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark/adapter.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "regex_internal", .module = internal }},
        }),
    });
    const install_benchmark = b.addInstallArtifact(benchmark_executable, .{});
    check_step.dependOn(&benchmark_executable.step);

    const benchmark_samples = b.fmt("{d}", .{
        b.option(usize, "benchmark-samples", "Benchmark samples per case") orelse 7,
    });
    const benchmark_run = b.addSystemCommand(&.{
        python, "-B", "benchmark.py", "--samples", benchmark_samples,
    });
    benchmark_run.step.dependOn(&install_benchmark.step);
    const benchmark = b.step("benchmark", "Benchmark every defined workload and write benchmark.log");
    benchmark.dependOn(&benchmark_run.step);
    test_step.dependOn(&quick_run.step);
    test_all_step.dependOn(&testing_run.step);
}

fn regexModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn testArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{
            .path = b.path("src/testing/test_runner.zig"),
            .mode = .simple,
        },
    });
}

/// Compiles the fixed public-example catalog against one module configuration.
/// The selected unsuffixed pass installs runnable binaries, while mode-suffixed
/// qualification passes depend only on compilation to avoid install collisions.
fn addExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    regex: *std.Build.Module,
    step: *std.Build.Step,
    run_step: ?*std.Build.Step,
    suffix: []const u8,
) void {
    inline for (.{
        "first_match",
        "query_methods",
        "batch_matching",
        "compile_diagnostics",
        "compile_options",
        "posix_syntax",
        "ranged_search",
        "iteration",
        "consume",
        "stored_matches",
        "result_limits",
        "captures",
        "typed_captures",
        "anchored_captures",
        "named_captures",
        "optional_captures",
        "full_captures",
        "owned_captures",
        "capture_iteration",
        "unicode",
        "byte_input",
        "quote_meta",
        "rewrite_extract",
        "rewrite_replace_first",
        "rewrite_replace",
        "work_limits",
        "memory_limits",
        "metrics",
        "set",
        "filtered",
        "filtered_external",
        "possible_match",
        "concurrency",
    }) |name| {
        const binary_name = std.mem.replaceOwned(
            u8,
            b.allocator,
            name,
            "_",
            "-",
        ) catch @panic("out of memory");
        const executable = b.addExecutable(.{
            .name = b.fmt("regex-{s}{s}", .{ binary_name, suffix }),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "regex", .module = regex }},
            }),
        });
        if (suffix.len == 0) {
            const install = b.addInstallArtifact(executable, .{
                .dest_dir = .{ .override = .{ .custom = "bin/examples" } },
            });
            step.dependOn(&install.step);
            if (run_step) |runs| {
                const run = b.addRunArtifact(executable);
                runs.dependOn(&run.step);
            }
        } else {
            step.dependOn(&executable.step);
        }
    }
}

const Campaign = struct {
    name: []const u8,
    kind: []const u8,
};

fn campaign(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    race: bool,
    config: Campaign,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "name", config.kind);
    return b.addExecutable(.{
        .name = config.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tool_main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = race,
            .link_libc = true,
            .imports = &.{.{ .name = "tool_campaign", .module = options.createModule() }},
        }),
    });
}
