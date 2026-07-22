//! Portable Teddy-family scanner for many required literal atoms.
//!
//! Construction hashes each atom into a bucket and precomputes, for the first
//! few byte positions, tables from low/high nibble to bucket bit masks. During a
//! scan, intersecting those masks quickly rejects positions that cannot begin any
//! bucket. Surviving bucket candidates are always verified against complete atom
//! bytes, so nibble/hash collisions cannot invent an atom hit.
//!
//! Small collections use a simpler direct loop when table setup offers no
//! advantage. `scanAsciiFolded` lowercases ASCII input during comparison and
//! returns false upon encountering non-ASCII, asking Filtered to normalize the
//! full input with encoding-aware Unicode lowercase and retry `scan`.
//!
//! Scanner reports exact atom occurrence bits but does not evaluate regex
//! formulas. Filtered separately reduces atom hits to conservative candidates and
//! verifies each candidate Regex. The implementation uses scalar portable tables,
//! avoiding architecture-specific SIMD requirements.

const std = @import("std");

pub const bucket_count = 64;
pub const dispatch_atom_count = 8;
const max_depth = 3;

/// Atom-byte span stored per hash bucket; zero length means unused bucket.
const Span = struct { start: u32 = 0, len: u32 = 0 };

/// Owned verified atoms plus nibble-mask tables for one immutable atom catalog.
pub const Scanner = struct {
    allocator: std.mem.Allocator,
    masks: []u64 = &.{},
    bucket_atoms: []u32 = &.{},
    buckets: [bucket_count]Span = [_]Span{.{}} ** bucket_count,
    depth: u2 = 0,

    /// Copies bucket metadata/bytes and precomputes positional nibble masks.
    /// Atom IDs remain the caller's published order even though buckets hash.
    pub fn init(
        allocator: std.mem.Allocator,
        atoms: []const []const u8,
    ) error{OutOfMemory}!Scanner {
        if (atoms.len < dispatch_atom_count) return .{ .allocator = allocator };

        var minimum_len: usize = max_depth;
        for (atoms) |atom| minimum_len = @min(minimum_len, atom.len);
        if (minimum_len == 0) return .{ .allocator = allocator };
        const depth: u2 = @intCast(minimum_len);
        const masks = try allocator.alloc(u64, @as(usize, depth) * 256);
        errdefer allocator.free(masks);
        @memset(masks, 0);
        const bucket_atoms = try allocator.alloc(u32, atoms.len);
        errdefer allocator.free(bucket_atoms);

        var counts = [_]u32{0} ** bucket_count;
        for (atoms) |atom| counts[bucket(atom)] += 1;
        var starts = [_]u32{0} ** bucket_count;
        var total: u32 = 0;
        for (&starts, counts) |*start, count| {
            start.* = total;
            total += count;
        }
        var writes = starts;
        for (atoms, 0..) |atom, atom_id| {
            const bucket_id = bucket(atom);
            bucket_atoms[writes[bucket_id]] = @intCast(atom_id);
            writes[bucket_id] += 1;
            const bit = @as(u64, 1) << @intCast(bucket_id);
            for (0..depth) |position| {
                const byte = atom[position];
                masks[position * 256 + byte] |= bit;
            }
        }
        var result: Scanner = .{
            .allocator = allocator,
            .masks = masks,
            .bucket_atoms = bucket_atoms,
            .depth = depth,
        };
        for (&result.buckets, starts, counts) |*span, start, count|
            span.* = .{ .start = start, .len = count };
        return result;
    }

    pub fn deinit(self: *Scanner) void {
        if (self.bucket_atoms.len != 0) self.allocator.free(self.bucket_atoms);
        if (self.masks.len != 0) self.allocator.free(self.masks);
        self.* = undefined;
    }

    /// Scans ASCII input while folding bytes in registers. Returns false on
    /// non-ASCII input so the caller can normalize Unicode and retry.
    pub fn scanAsciiFolded(
        self: *const Scanner,
        atoms: []const []const u8,
        input: []const u8,
        matched: []bool,
    ) bool {
        if (self.depth == 0) return false;
        std.debug.assert(atoms.len == matched.len);
        @memset(matched, false);
        const depth: usize = self.depth;
        if (input.len < depth) {
            for (input) |byte| if (byte >= 0x80) return false;
            return true;
        }
        var position: usize = 0;
        const last = input.len - depth;
        while (position <= last) : (position += 1) {
            var candidates: u64 = std.math.maxInt(u64);
            for (0..depth) |offset| {
                const raw = input[position + offset];
                if (raw >= 0x80) return false;
                candidates &= self.masks[offset * 256 + std.ascii.toLower(raw)];
                if (candidates == 0) break;
            }
            while (candidates != 0) {
                const bucket_id: u6 = @intCast(@ctz(candidates));
                candidates &= candidates - 1;
                const span = self.buckets[bucket_id];
                const start: usize = span.start;
                for (self.bucket_atoms[start..][0..span.len]) |atom_id| {
                    if (matched[atom_id]) continue;
                    const atom = atoms[atom_id];
                    if (atom.len > input.len - position) continue;
                    var equal = true;
                    for (atom, input[position..][0..atom.len]) |wanted, raw| {
                        if (raw >= 0x80) return false;
                        if (wanted != std.ascii.toLower(raw)) {
                            equal = false;
                            break;
                        }
                    }
                    if (equal) matched[atom_id] = true;
                }
            }
        }
        for (input[last + 1 ..]) |byte| if (byte >= 0x80) return false;
        return true;
    }

    /// Marks every atom occurring in normalized input. Complete-literal
    /// verification makes the result exact even when buckets collide.
    pub fn scan(
        self: *const Scanner,
        atoms: []const []const u8,
        input: []const u8,
        matched: []bool,
    ) void {
        std.debug.assert(atoms.len == matched.len);
        @memset(matched, false);
        if (self.depth == 0) {
            for (atoms, matched) |atom, *found|
                found.* = std.mem.indexOf(u8, input, atom) != null;
            return;
        }
        const depth: usize = self.depth;
        if (input.len < depth) return;
        var position: usize = 0;
        const last = input.len - depth;
        while (position <= last) : (position += 1) {
            var candidates: u64 = std.math.maxInt(u64);
            for (0..depth) |offset| {
                const byte = input[position + offset];
                candidates &= self.masks[offset * 256 + byte];
                if (candidates == 0) break;
            }
            while (candidates != 0) {
                const bucket_id: u6 = @intCast(@ctz(candidates));
                candidates &= candidates - 1;
                const span = self.buckets[bucket_id];
                const start: usize = span.start;
                for (self.bucket_atoms[start..][0..span.len]) |atom_id| {
                    if (matched[atom_id]) continue;
                    const atom = atoms[atom_id];
                    if (atom.len <= input.len - position and
                        std.mem.eql(u8, atom, input[position..][0..atom.len]))
                        matched[atom_id] = true;
                }
            }
        }
    }
};

fn bucket(atom: []const u8) usize {
    return @intCast(std.hash.Wyhash.hash(0, atom) & (bucket_count - 1));
}

const testing = std.testing;

test "Teddy marks complete literals and rejects nibble collisions" {
    const atoms = [_][]const u8{
        "alpha",    "alpine",  "beta", "gamma", "delta", "omega", "theta", "zeta",
        "alphabet", "betamax",
    };
    var scanner = try Scanner.init(testing.allocator, &atoms);
    defer scanner.deinit();
    var matched = [_]bool{false} ** atoms.len;
    scanner.scan(&atoms, "an alphabet has betamax and omega", &matched);
    try testing.expect(matched[0]);
    try testing.expect(matched[2]);
    try testing.expect(matched[5]);
    try testing.expect(matched[8]);
    try testing.expect(matched[9]);
    try testing.expect(!matched[1]);
    try testing.expect(!matched[3]);
}

test "Teddy direct mode handles small collections" {
    const atoms = [_][]const u8{ "foo", "bar" };
    var scanner = try Scanner.init(testing.allocator, &atoms);
    defer scanner.deinit();
    var matched = [_]bool{false} ** atoms.len;
    scanner.scan(&atoms, "xxbarxx", &matched);
    try testing.expectEqualSlices(bool, &.{ false, true }, &matched);
}
