//! Qualification of syntax-arena scale, ownership, and capture metadata.
//!
//! Large concatenations establish iterative compact construction/teardown, while
//! named/duplicate capture cases check index order and leftmost name lookup. The
//! lower-level same-arena relocation test remains beside `regexp.zig` itself.

const std = @import("std");
const parser = @import("parser.zig");
const regexp_module = @import("regexp.zig");
const testing = std.testing;

fn parse(pattern: []const u8) !regexp_module.Regexp {
    const result = try parser.parse(testing.allocator, pattern, .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    return switch (result) {
        .success => |tree| tree,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

test "Qualification Regexp large concatenation is iterative" {
    const pattern = try testing.allocator.alloc(u8, 90_000);
    defer testing.allocator.free(pattern);
    @memset(pattern, 'x');

    var tree = try parse(pattern);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), tree.nodes.items.len);
    const root = tree.node(tree.root.?).*;
    try testing.expect(root == .literal);
    try testing.expectEqual(@as(u32, 90_000), root.literal.runes.len);
    try testing.expectEqual(@as(usize, 90_000), tree.literalRunes(root.literal.runes).len);
}

test "Qualification Regexp named captures preserve every index and leftmost lookup" {
    const pattern = "(?P<g1>a+)|(e)(?P<g2>w*)+(?P<g1>b+)";
    var tree = try parse(pattern);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), tree.capture_count);

    var named: [3]struct { index: u32, name: []const u8 } = undefined;
    var count: usize = 0;
    for (tree.nodes.items) |node| if (node == .capture) {
        if (node.capture.name) |span| {
            named[count] = .{
                .index = @intFromEnum(node.capture.index),
                .name = tree.captureName(span),
            };
            count += 1;
        }
    };
    try testing.expectEqual(@as(usize, 3), count);
    std.mem.sort(@TypeOf(named[0]), named[0..count], {}, struct {
        fn lessThan(_: void, left: @TypeOf(named[0]), right: @TypeOf(named[0])) bool {
            return left.index < right.index;
        }
    }.lessThan);
    try testing.expectEqual(@as(u32, 1), named[0].index);
    try testing.expectEqualStrings("g1", named[0].name);
    try testing.expectEqual(@as(u32, 3), named[1].index);
    try testing.expectEqualStrings("g2", named[1].name);
    try testing.expectEqual(@as(u32, 4), named[2].index);
    try testing.expectEqualStrings("g1", named[2].name);
}
