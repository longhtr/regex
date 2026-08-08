//! Explicit root of the complete Zig test graph.
//!
//! Zig discovers tests through imports, so an unreferenced test file would vanish
//! silently from every build mode. The import list below is therefore a coverage
//! manifest: it walks support, syntax, optimization, Program construction,
//! engines/dispatch, products, independent models, and broad qualification in
//! roughly the same order a reader follows the implementation. The single test
//! references each import to keep that graph reachable.
//!
//! `testing/test_runner.zig` controls naming, grouping, leak reporting, and process
//! status after this root has assembled the test table. Production consumers use
//! `root.zig`; neither this manifest nor private engine-forcing tests enter the
//! public package graph.

const budget_allocator = @import("support/budget_allocator.zig");
const checked_math = @import("support/checked_math.zig");
const try_rw_lock = @import("support/try_rw_lock.zig");
const rune_range = @import("syntax/rune_range.zig");
const char_class = @import("syntax/char_class.zig");
const class_terms = @import("syntax/class_terms.zig");
const frame_reducer = @import("syntax/frame_reducer.zig");
const scanner = @import("syntax/scanner.zig");
const regexp = @import("syntax/regexp.zig");
const regexp_qualification_test = @import("syntax/regexp_qualification_test.zig");
const parser = @import("syntax/parser.zig");
const parser_qualification_test = @import("syntax/parser_qualification_test.zig");
const unicode_data = @import("unicode/data.zig");
const program = @import("program/program.zig");
const prog_builder = @import("program/builder.zig");
const prog_thompson = @import("program/thompson.zig");
const prog_byte_lowering = @import("program/byte_lowering.zig");
const prog_byte_map = @import("program/byte_map.zig");
const prog_publication = @import("program/publication.zig");
const compiler = @import("program/compiler.zig");
const compiler_qualification_test = @import("program/compiler_qualification_test.zig");
const prog_tour_test = @import("program/tour_test.zig");
const context = @import("engine/context.zig");
const closure_cursor = @import("engine/closure_cursor.zig");
const prefix = @import("literal/search.zig");
const prefix_qualification_test = @import("literal/search_qualification_test.zig");
const capture_pool = @import("engine/capture_pool.zig");
const capture_nfa = @import("engine/capture_nfa.zig");
const dispatch = @import("execute/request.zig");
const bit_state = @import("engine/accelerate/bit_state.zig");
const one_pass = @import("engine/accelerate/one_pass.zig");
const possible_match = @import("engine/possible_match.zig");
const nfa = @import("engine/nfa.zig");
const dfa_state_cache = @import("engine/accelerate/dfa_state_cache.zig");
const dfa = @import("engine/accelerate/dfa.zig");
const dfa_search = @import("execute/search.zig");
const capture_search = @import("execute/capture.zig");
const matcher_module = @import("matcher.zig");
const rewrite = @import("rewrite.zig");
const set = @import("collection/set.zig");
const filtered = @import("collection/filtered.zig");
const regex = @import("regex.zig");
const public_root = @import("root.zig");

test "Import all test modules" {
    _ = budget_allocator;
    _ = checked_math;
    _ = try_rw_lock;
    _ = rune_range;
    _ = char_class;
    _ = class_terms;
    _ = frame_reducer;
    _ = scanner;
    _ = regexp;
    _ = regexp_qualification_test;
    _ = @import("optimize/optimize.zig");
    _ = parser;
    _ = parser_qualification_test;
    _ = unicode_data;
    _ = program;
    _ = prog_builder;
    _ = prog_thompson;
    _ = prog_byte_lowering;
    _ = prog_byte_map;
    _ = prog_publication;
    _ = compiler;
    _ = compiler_qualification_test;
    _ = prog_tour_test;
    _ = context;
    _ = closure_cursor;
    _ = prefix;
    _ = prefix_qualification_test;
    _ = capture_pool;
    _ = capture_nfa;
    _ = dispatch;
    _ = bit_state;
    _ = one_pass;
    _ = possible_match;
    _ = nfa;
    _ = dfa_state_cache;
    _ = dfa;
    _ = dfa_search;
    _ = capture_search;
    _ = matcher_module;
    _ = rewrite;
    _ = set;
    _ = filtered;
    _ = regex;
    _ = public_root;
    _ = @import("engine/equivalence_test.zig");
    _ = @import("testing/dfa_qualification_test.zig");
    _ = @import("testing/matcher_test.zig");
    _ = @import("testing/match_model_test.zig");
    _ = @import("testing/capture_model_test.zig");
    _ = @import("testing/context_model_test.zig");
    _ = @import("testing/collection_model_test.zig");
    _ = @import("testing/diagnostic_model_test.zig");
    _ = @import("testing/conformance_test.zig");
    _ = @import("testing/semantic_qualification_test.zig");
    _ = @import("testing/scaling_test.zig");
}
