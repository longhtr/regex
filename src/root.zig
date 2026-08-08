//! Public package boundary.
//!
//! A normal application needs two owners:
//!
//! 1. `Regex` compiles and retains immutable expression state.
//! 2. `Matcher` borrows that state and retains mutable execution scratch.
//!
//! Keeping those lifetimes separate makes compilation reusable and permits
//! independent Matchers to share one Regex concurrently. `Match`, capture, and
//! range types come from `match.zig`, where they remain independent of every
//! physical engine.
//!
//! `Rewrite`, `Set`, and `Filtered` are separate products rather than modes of
//! Matcher. Set builds one captureless multi-pattern automaton; Filtered keeps
//! independent Regex values behind a conservative literal prefilter; Rewrite
//! consumes ordinary capture results. None exposes DFA/NFA selection because an
//! accelerator is allowed to decline and therefore cannot be semantic policy.
//!
//! This file intentionally contains aliases only. For public lifetimes, read
//! `regex.zig`, `matcher.zig`, then `match.zig`. To follow implementation flow,
//! continue through `compiled.zig` into `program/compiler.zig` and return through
//! `execute/` to `matcher.zig`. Product-specific paths begin in `rewrite.zig`,
//! `collection/set.zig`, and `collection/filtered.zig`.

const parser = @import("syntax/parser.zig");
const regex = @import("regex.zig");
const matcher = @import("matcher.zig");
const match_types = @import("match.zig");
const rewrite = @import("rewrite.zig");
const set = @import("collection/set.zig");
const filtered = @import("collection/filtered.zig");

pub const Regex = regex.Regex;
pub const Matcher = matcher.Matcher;
pub const Match = regex.Match;
pub const SearchRange = match_types.SearchRange;
pub const MatchKind = regex.MatchKind;
pub const Anchor = regex.Anchor;
pub const CaptureView = regex.CaptureView;
pub const Captures = regex.Captures;
pub const Matches = match_types.Matches;

pub const CompileOptions = regex.CompileOptions;
pub const MatcherOptions = matcher.MatcherOptions;
pub const Encoding = regex.Encoding;
pub const Semantics = regex.Semantics;
pub const Diagnostic = parser.Diagnostic;

pub const Rewrite = rewrite.Rewrite;
pub const Set = set.Set;
pub const Filtered = filtered.Filtered;

pub const quoteMeta = rewrite.quoteMeta;
pub const quoteMetaWithLimit = rewrite.quoteMetaWithLimit;
