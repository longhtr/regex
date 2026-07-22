//! Typed benchmark specification and reviewed handwritten workload catalog.
//!
//! A Workload is declarative data: a readable name, lazily materialized pattern
//! and input source, public compile options, and one operation with an exact
//! expected observation. Pattern/input unions keep large cases compact without
//! hiding their generation rule. Task variants mirror public products rather than
//! physical engines.
//!
//! Expectations are spans, capture groups, counts, booleans, or IDs—not opaque
//! checksums copied from a previous engine run. The adapter derives a checksum
//! only after direct qualification, for detecting instability across timed
//! iterations.
//!
//! The stable catalog below represents authored usage, adversarial costs, and
//! named regression shapes imported from external qualification suites. Generated
//! geometric series live in `campaign.zig`. Workload identity is its
//! descriptive name; numeric indices exist only in the process protocol.

const regex = @import("regex_internal");

pub const Span = struct { start: usize, end: usize };

/// Compact deterministic constructors for patterns too large/repetitive to store
/// as authored literals.
pub const PatternGenerator = union(enum) {
    ambiguous_suffix,
    nullable_suffix,
    bounded_optional: usize,
    shared_alternation: struct { count: usize, width: usize },
    mixed_dictionary: usize,
    deep_groups: usize,
    many_captures: usize,
};

/// Authored pattern bytes or one deterministic generator invocation.
pub const PatternSource = union(enum) {
    literal: []const u8,
    generated: PatternGenerator,
};

/// Authored or generated insertion-order pattern collection for Set/Filtered.
pub const PatternSetSource = union(enum) {
    list: []const []const u8,
    numbered: struct {
        prefix: []const u8,
        width: usize,
        suffix: []const u8,
        count: usize,
    },
};

/// Lazily materialized benchmark input; every variant has an obvious exact byte
/// count and deterministic content.
pub const InputSource = union(enum) {
    literal: []const u8,
    fill: struct { byte: u8, count: usize },
    fill_suffix: struct { byte: u8, count: usize, suffix: []const u8 },
    repeat: struct { unit: []const u8, count: usize },
    repeat_suffix: struct { unit: []const u8, count: usize, suffix: []const u8 },
    /// Prefix and suffix surround a repeated byte without storing a large literal.
    fill_between: struct { prefix: []const u8, byte: u8, count: usize, suffix: []const u8 },
    stable_identifier: struct { bytes: usize, seed: u64 },
};

/// Expected optional range; explicit tags keep absence readable in catalog data.
pub const MatchExpected = union(enum) {
    none,
    some: Span,
};

/// Whole-match range and reviewed explicit group ranges for capture workloads.
pub const CaptureExpected = struct {
    whole: Span,
    groups: []const ?Span,
};

/// Compact expectation for a repeated unit containing the same relative spans.
pub const RepeatedSpans = struct {
    unit_bytes: usize,
    unit_spans: []const Span,
    count: usize,
};

/// Iteration expectation represented explicitly or by a compact regular sequence.
pub const IterationExpected = union(enum) {
    exact: []const Span,
    repeated: RepeatedSpans,
    empty_every_byte: usize,
};

pub const CompileTask = struct { capture_count: u32 };
pub const FindTask = struct { expected: MatchExpected };
pub const CapturesTask = struct { expected: ?CaptureExpected };
pub const FullTask = struct { expected: bool };
pub const CountTask = struct { expected: usize };
pub const IterateTask = struct { expected: IterationExpected };
/// ReBar-compatible line model: split lines, enumerate every match's captures,
/// and count only participating whole/explicit groups.
pub const GrepCapturesTask = struct {
    capture_count: u32,
    expected_participating: usize,
};
/// Set operation and the ascending insertion-order pattern IDs it must return.
pub const SetTask = struct {
    patterns: PatternSetSource,
    expected_pattern_ids: []const u32,
};

/// Filtered operation and its lowest matching insertion-order pattern ID.
pub const FilteredTask = struct {
    patterns: PatternSetSource,
    expected_pattern_id: ?u32,
};

/// Timed public operation and its independently stated expected observation.
pub const Task = union(enum) {
    compile: CompileTask,
    find: FindTask,
    captures: CapturesTask,
    full: FullTask,
    count: CountTask,
    iterate: IterateTask,
    grep_captures: GrepCapturesTask,
    set: SetTask,
    filtered: FilteredTask,
};

/// Complete declarative workload. `name` is stable human identity; catalog index
/// is process-local launch plumbing only.
pub const Workload = struct {
    name: []const u8,
    pattern: PatternSource = .{ .literal = "" },
    input: InputSource = .{ .literal = "" },
    options: regex.CompileOptions = .{},
    task: Task,
};

pub const RouteSummary = regex.BenchmarkRoute;

/// Private engineering snapshot attached to a public-operation timing sample.
pub const DfaMeasurement = struct {
    states: usize = 0,
    cache_live_bytes: usize = 0,
    cache_peak_bytes: usize = 0,
    instruction_ids: usize = 0,
    transition_slots: usize = 0,
    hash_bytes: usize = 0,
    exhausted: bool = false,
};

/// One adapter-process sample before Python derives per-operation statistics.
pub const Measurement = struct {
    elapsed_ns: i128,
    checksum: u64,
    pattern_bytes: usize,
    input_bytes: usize,
    retained_bytes: usize,
    peak_bytes: usize,
    allocations: usize,
    route: RouteSummary,
    dfa: DfaMeasurement = .{},
};

const no_pattern_ids = [_]u32{};
const last_of_32_pattern_ids = [_]u32{31};
const last_of_32_pattern_id: ?u32 = 31;
const dense_patterns = [_][]const u8{ "a", "a+", "[a]", "(?:a)", "a*", "[ab]+", "a|b", "." };
const dense_pattern_ids = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
const collision_patterns = [_][]const u8{
    "token[0-9]+", "token42", "token(?:4|5)[0-9]", "token.*", "unrelated",
};
const ambiguous_capture_groups = [_]?Span{
    .{ .start = 0, .end = 4095 },
    .{ .start = 4094, .end = 4095 },
};
const bit_state_capture_groups = [_]?Span{
    .{ .start = 0, .end = 65536 },
    .{ .start = 65535, .end = 65536 },
};

const url_groups = [_]?Span{
    .{ .start = 0, .end = 5 },
    .{ .start = 8, .end = 19 },
    .{ .start = 20, .end = 24 },
    .{ .start = 24, .end = 37 },
};
const http_groups = [_]?Span{
    .{ .start = 0, .end = 3 },
    .{ .start = 4, .end = 27 },
    .{ .start = 33, .end = 36 },
};
const english_long_word_spans = [_]Span{
    .{ .start = 0, .end = 12 },
    .{ .start = 13, .end = 28 },
    .{ .start = 33, .end = 53 },
};
const security_keyword_spans = [_]Span{
    .{ .start = 11, .end = 16 },
    .{ .start = 31, .end = 37 },
    .{ .start = 45, .end = 53 },
};
const cloudflare_long_span = [_]Span{.{ .start = 0, .end = 10_000 }};
const rebar_dictionary_pattern = @embedFile("data/rebar-english-length-15.regex");
const rebar_dictionary_decoys = @embedFile("data/rebar-english-length-15-decoys.txt");

const common_log_groups = [_]?Span{
    .{ .start = 0, .end = 9 },
    .{ .start = 10, .end = 11 },
    .{ .start = 12, .end = 17 },
    .{ .start = 19, .end = 45 },
    .{ .start = 48, .end = 51 },
    .{ .start = 52, .end = 63 },
    .{ .start = 74, .end = 77 },
    .{ .start = 78, .end = 82 },
};

pub const workloads = [_]Workload{
    .{
        .name = "Measures warmed compile and teardown latency for a small literal",
        .pattern = .{ .literal = "needle" },
        .task = .{ .compile = .{ .capture_count = 0 } },
    },
    .{
        .name = "Measures Unicode group expansion and simple-fold compilation",
        .pattern = .{ .literal = "(?i)[\\p{Greek}]+" },
        .task = .{ .compile = .{ .capture_count = 0 } },
    },
    .{
        .name = "Measures compilation of nested and alternate capture declarations",
        .pattern = .{ .literal = "((alpha|beta)+)-([0-9]+)(?:/([^/]+))?" },
        .task = .{ .compile = .{ .capture_count = 4 } },
    },
    .{
        .name = "Measures shared-prefix factoring for a large literal alternation",
        .pattern = .{ .generated = .{ .shared_alternation = .{ .count = 1000, .width = 4 } } },
        .task = .{ .compile = .{ .capture_count = 0 } },
    },
    .{
        .name = "Measures a required literal accepted at the end of a 64 KiB input",
        .pattern = .{ .literal = "needle" },
        .input = .{ .fill_suffix = .{ .byte = 'a', .count = 65536, .suffix = "needle" } },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 65530, .end = 65536 } } } },
    },
    .{
        .name = "Measures required-literal rejection over a 64 KiB input",
        .pattern = .{ .literal = "needle" },
        .input = .{ .fill = .{ .byte = 'x', .count = 65536 } },
        .task = .{ .find = .{ .expected = .none } },
    },
    .{
        .name = "Measures one long ASCII class repetition over deterministic identifier text",
        .pattern = .{ .literal = "[A-Za-z_][A-Za-z_0-9]*" },
        .input = .{ .stable_identifier = .{ .bytes = 65536, .seed = 0x5eed2025 } },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = 65536 } } } },
    },
    .{
        .name = "Measures anchored Unicode-group repetition over canonical UTF-8 scalars",
        .pattern = .{ .literal = "[\\p{Greek}]+$" },
        .input = .{ .repeat = .{ .unit = "αβγ", .count = 8192 } },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = 49152 } } } },
    },
    .{
        .name = "Measures bounded ambiguous alternation with a required accepting suffix",
        .pattern = .{ .literal = "(a|aa)*b" },
        .input = .{ .fill_suffix = .{ .byte = 'a', .count = 4096, .suffix = "b" } },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = 4096 } } } },
    },
    .{
        .name = "Measures complete rejection of overlapping alternatives without backtracking",
        .pattern = .{ .literal = "(a|aa)*b" },
        .input = .{ .fill = .{ .byte = 'a', .count = 4096 } },
        .task = .{ .find = .{ .expected = .none } },
    },
    .{
        .name = "Measures complete fallback after the optional DFA is explicitly disabled",
        .pattern = .{ .literal = "(a|aa)*b" },
        .input = .{ .fill_suffix = .{ .byte = 'a', .count = 65536, .suffix = "b" } },
        .options = .{ .dfa_memory = .disabled },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = 65536 } } } },
    },
    .{
        .name = "Measures rejection through nested nullable repetition",
        .pattern = .{ .literal = "(a*)*b" },
        .input = .{ .fill = .{ .byte = 'a', .count = 4096 } },
        .task = .{ .find = .{ .expected = .none } },
    },
    .{
        .name = "Measures repeated deterministic capture extraction on a warmed matcher",
        .pattern = .{ .literal = "(a+)(b+)" },
        .input = .{ .literal = "aaaaabbbbb" },
        .task = .{ .captures = .{ .expected = .{ .whole = .{ .start = 0, .end = 10 }, .groups = &.{ .{ .start = 0, .end = 5 }, .{ .start = 5, .end = 10 } } } } },
    },
    .{
        .name = "Measures long range location followed by exact capture extraction",
        .pattern = .{ .literal = "(a+)(needle)" },
        .input = .{ .fill_suffix = .{ .byte = 'a', .count = 65536, .suffix = "needle" } },
        .task = .{ .captures = .{ .expected = .{ .whole = .{ .start = 0, .end = 65536 }, .groups = &.{ .{ .start = 0, .end = 65530 }, .{ .start = 65530, .end = 65536 } } } } },
    },
    .{
        .name = "Measures nested capture publication without excess group observation",
        .pattern = .{ .literal = "((ab)+)(c)?" },
        .input = .{ .literal = "abab" },
        .task = .{ .captures = .{ .expected = .{ .whole = .{ .start = 0, .end = 4 }, .groups = &.{ .{ .start = 0, .end = 4 }, .{ .start = 2, .end = 4 }, null } } } },
    },
    .{
        .name = "Measures capture priority through a long overlapping alternation",
        .pattern = .{ .literal = "((a|aa)*)b" },
        .input = .{ .fill_suffix = .{ .byte = 'a', .count = 4096, .suffix = "b" } },
        .task = .{ .captures = .{ .expected = .{
            .whole = .{ .start = 0, .end = 4096 },
            .groups = &ambiguous_capture_groups,
        } } },
    },
    .{
        .name = "Measures bounded exact capture replay when the DFA is disabled",
        .pattern = .{ .literal = "((q|qq|qqq|qqqq|qqqqq|qqqqqq|qqqqqqq|qqqqqqqq)*)z" },
        .input = .{ .fill_suffix = .{ .byte = 'q', .count = 65537, .suffix = "z" } },
        .options = .{ .dfa_memory = .disabled },
        .task = .{ .captures = .{ .expected = .{
            .whole = .{ .start = 0, .end = 65537 },
            .groups = &bit_state_capture_groups,
        } } },
    },
    .{
        .name = "Measures a no-match capture request after a long required-suffix rejection",
        .pattern = .{ .literal = "(a+)(needle)" },
        .input = .{ .fill = .{ .byte = 'a', .count = 65536 } },
        .task = .{ .captures = .{ .expected = null } },
    },
    .{
        .name = "Measures a large bounded optional/full-match program without recursion",
        .pattern = .{ .literal = "(?:a?){1000}a{1000}" },
        .input = .{ .fill = .{ .byte = 'a', .count = 1000 } },
        .task = .{ .full = .{ .expected = true } },
    },
    .{
        .name = "Measures full matching for a representative timestamp grammar",
        .pattern = .{ .literal = "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})" },
        .input = .{ .literal = "2026-07-20T22:30:15.123Z" },
        .task = .{ .full = .{ .expected = true } },
    },
    .{
        .name = "Measures specialized counting over many separated ASCII runs",
        .pattern = .{ .literal = "[A-Za-z]+" },
        .input = .{ .repeat = .{ .unit = "word ", .count = 16384 } },
        .task = .{ .count = .{ .expected = 16384 } },
    },
    .{
        .name = "Measures general count iteration for a closed literal alternation",
        .pattern = .{ .literal = "hello|world|test" },
        .input = .{ .repeat = .{ .unit = "hello x testworld ", .count = 1024 } },
        .task = .{ .count = .{ .expected = 3072 } },
    },
    .{
        .name = "Measures case-insensitive Cyrillic keyword counting in authored log-like text",
        .pattern = .{ .literal = "ошибка|предупреждение|отказ" },
        .input = .{ .repeat = .{
            .unit = "Запрос выполнен. ОШИБКА сети; ПРЕДУПРЕЖДЕНИЕ: повтор. отказ узла.\n",
            .count = 4096,
        } },
        .options = .{ .case_sensitive = false },
        .task = .{ .count = .{ .expected = 3 * 4096 } },
    },
    .{
        .name = "Measures CJK literal-alternation counting in authored status text",
        .pattern = .{ .literal = "错误|警告|成功" },
        .input = .{ .repeat = .{
            .unit = "任务成功。检测到错误，随后发出警告。\n",
            .count = 8192,
        } },
        .task = .{ .count = .{ .expected = 3 * 8192 } },
    },
    .{
        .name = "Measures complete span iteration for authored mixed-length English words",
        .pattern = .{ .literal = "[A-Za-z]{12,}" },
        .input = .{ .repeat = .{
            .unit = "encyclopedia synchronization cat internationalization x ",
            .count = 8192,
        } },
        .task = .{ .iterate = .{ .expected = .{ .repeated = .{
            .unit_bytes = 56,
            .unit_spans = &english_long_word_spans,
            .count = 8192,
        } } } },
    },
    .{
        .name = "Measures complete keyword spans in authored security-record text",
        .pattern = .{ .literal = "token|secret|password" },
        .input = .{ .repeat = .{
            .unit = "user=alice token=abc status=ok secret=hidden password=guess\n",
            .count = 8192,
        } },
        .task = .{ .iterate = .{ .expected = .{ .repeated = .{
            .unit_bytes = 60,
            .unit_spans = &security_keyword_spans,
            .count = 8192,
        } } } },
    },
    .{
        .name = "Measures ReBar dictionary prefix pressure with one late match",
        .pattern = .{ .literal = rebar_dictionary_pattern },
        .input = .{ .literal = rebar_dictionary_decoys },
        .options = .{ .encoding = .latin1 },
        .task = .{ .count = .{ .expected = 1 } },
    },
    .{
        .name = "Measures default-DFA-cache rejection for a large heterogeneous dictionary",
        .pattern = .{ .generated = .{ .mixed_dictionary = 3072 } },
        .input = .{ .fill = .{ .byte = 'x', .count = 1024 * 1024 } },
        .task = .{ .count = .{ .expected = 0 } },
    },
    .{
        .name = "Measures ReBar Cloudflare long self-loop span iteration",
        .pattern = .{ .literal = ".*.*=.*" },
        .input = .{ .fill_between = .{
            .prefix = "x=",
            .byte = 'x',
            .count = 9998,
            .suffix = "\n",
        } },
        .task = .{ .iterate = .{ .expected = .{ .exact = &cloudflare_long_span } } },
    },
    .{
        .name = "Measures ReBar Ruff sparse line capture rejection",
        .pattern = .{ .literal = "(\\s*)((?:# [Nn][Oo][Qq][Aa])(?::\\s?(([A-Z]+[0-9]+(?:[,\\s]+)?)+))?)" },
        .input = .{ .repeat_suffix = .{
            .unit = "def ordinary_function(value): return value + 1\n",
            .count = 200_000,
            .suffix = "# noqa\n",
        } },
        .options = .{ .perl_classes = true },
        .task = .{ .grep_captures = .{
            .capture_count = 4,
            .expected_participating = 3,
        } },
    },
    .{
        .name = "Measures encoding-aware progress through dense empty matches",
        .pattern = .{ .literal = "a*" },
        .input = .{ .fill = .{ .byte = 'b', .count = 4096 } },
        .task = .{ .iterate = .{ .expected = .{ .empty_every_byte = 4096 } } },
    },
    .{
        .name = "Measures sparse insertion-order Set results for a late literal match",
        .input = .{ .fill_suffix = .{ .byte = 'x', .count = 65536, .suffix = "rule0031-suffix" } },
        .task = .{ .set = .{
            .patterns = .{ .numbered = .{ .prefix = "rule", .width = 4, .suffix = "-suffix", .count = 32 } },
            .expected_pattern_ids = &last_of_32_pattern_ids,
        } },
    },
    .{
        .name = "Measures complete Set rejection with no result allocation ambiguity",
        .input = .{ .fill = .{ .byte = 'x', .count = 65536 } },
        .task = .{ .set = .{
            .patterns = .{ .numbered = .{ .prefix = "rule", .width = 4, .suffix = "-suffix", .count = 32 } },
            .expected_pattern_ids = &no_pattern_ids,
        } },
    },
    .{
        .name = "Measures dense insertion-order publication when every Set pattern matches",
        .input = .{ .literal = "a" },
        .task = .{ .set = .{
            .patterns = .{ .list = &dense_patterns },
            .expected_pattern_ids = &dense_pattern_ids,
        } },
    },
    .{
        .name = "Measures integrated atom scanning and verification for a late match",
        .input = .{ .fill_suffix = .{ .byte = 'x', .count = 65536, .suffix = "token031-42" } },
        .task = .{ .filtered = .{
            .patterns = .{ .numbered = .{ .prefix = "token", .width = 3, .suffix = "-[0-9]+", .count = 32 } },
            .expected_pattern_id = last_of_32_pattern_id,
        } },
    },
    .{
        .name = "Measures integrated atom-scan rejection across a small rule collection",
        .input = .{ .fill = .{ .byte = 'x', .count = 65536 } },
        .task = .{ .filtered = .{
            .patterns = .{ .numbered = .{ .prefix = "token", .width = 3, .suffix = "-[0-9]+", .count = 32 } },
            .expected_pattern_id = null,
        } },
    },
    .{
        .name = "Measures shared-atom candidate collisions followed by exact verification",
        .input = .{ .literal = "prefix token42 suffix" },
        .task = .{ .filtered = .{
            .patterns = .{ .list = &collision_patterns },
            .expected_pattern_id = 0,
        } },
    },
    .{
        .name = "Measures optional and repeated captures in a representative URL",
        .pattern = .{ .literal = "([A-Za-z][A-Za-z0-9+.-]*)://([^/:?#]+)(?::([0-9]+))?([^?# ]*)" },
        .input = .{ .literal = "https://example.org:8443/api/v1/items" },
        .task = .{ .captures = .{ .expected = .{ .whole = .{ .start = 0, .end = 37 }, .groups = &url_groups } } },
    },
    .{
        .name = "Measures method, target, and version captures in an HTTP request line",
        .pattern = .{ .literal = "([A-Z]+) ([^ ]+) HTTP/([0-9]+\\.[0-9]+)" },
        .input = .{ .literal = "GET /assets/app.js?build=42 HTTP/1.1" },
        .task = .{ .captures = .{ .expected = .{ .whole = .{ .start = 0, .end = 36 }, .groups = &http_groups } } },
    },
    .{
        .name = "Measures all eight captures in a representative common-log record",
        .pattern = .{ .literal = "([^ ]+) ([^ ]+) ([^ ]+) \\[([^]]+)\\] \"([A-Z]+) ([^ ]+) HTTP/[^\"]+\" ([0-9]{3}) ([0-9]+|-)" },
        .input = .{ .literal = "127.0.0.1 - alice [20/Jul/2026:22:30:15 +0000] \"GET /index.html HTTP/1.1\" 200 1234" },
        .task = .{ .captures = .{ .expected = .{ .whole = .{ .start = 0, .end = 82 }, .groups = &common_log_groups } } },
    },
    .{
        .name = "Measures late multiline severity extraction in a production-sized log stream",
        .pattern = .{ .literal = "(?m)^(?:ERROR|WARN|FATAL)[ :]+[^\\n]*$" },
        .input = .{ .repeat_suffix = .{
            .unit = "INFO worker=17 request completed status=200 latency=3ms\n",
            .count = 19000,
            .suffix = "ERROR: upstream timeout status=504 latency=30000ms\n",
        } },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 1064000, .end = 1064050 } } } },
    },
    .{
        .name = "Measures late structured-key lookup in newline-delimited JSON-like records",
        .pattern = .{ .literal = "\"(?:request_id|trace_id|span_id)\"[ \\t]*:[ \\t]*\"[0-9A-Fa-f-]+\"" },
        .input = .{ .repeat_suffix = .{
            .unit = "{\"level\":\"info\",\"message\":\"ok\",\"count\":17}\n",
            .count = 11000,
            .suffix = "{\"trace_id\":\"550e8400-e29b-41d4-a716-446655440000\"}\n",
        } },
        .task = .{ .find = .{ .expected = .{ .some = .{ .start = 473001, .end = 473050 } } } },
    },
    .{
        .name = "Measures counting validated production metrics lines",
        .pattern = .{ .literal = "(?m)^[A-Za-z_:][A-Za-z0-9_:]*(?:\\{[^}\\n]*\\})?[ \\t]+[+-]?[0-9]+(?:\\.[0-9]+)?$" },
        .input = .{ .repeat = .{ .unit = "http_requests_total{method=\"GET\",status=\"200\"} 1729\n", .count = 9000 } },
        .task = .{ .count = .{ .expected = 9000 } },
    },
};
