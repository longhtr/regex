//! Nonblocking reader/writer lock for shared optional artifacts.
//!
//! One atomic word stores either a writer bit or a reader count. `tryLock` uses a
//! compare-exchange from zero to writer ownership. Readers increment only when no
//! writer is present and, for the limited form, while the configured reader cap
//! is not reached. Acquire/release ordering publishes immutable cache changes to
//! subsequent users.
//!
//! There is deliberately no waiting, queue, fairness, or condition variable.
//! Regex accelerators are optional: failure to acquire means the caller should
//! run matcher-local complete fallback rather than block behind cache
//! construction. The reader cap additionally avoids cache-line contention when
//! local fallback is cheaper than another shared reader.

const std = @import("std");

const writer_bit: u32 = 1 << 31;
const reader_mask: u32 = writer_bit - 1;

/// One-word lock state: high bit is exclusive ownership; low 31 bits are the
/// shared-reader count. Zero is unlocked.
pub const TryRwLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn tryLock(self: *@This()) bool {
        return self.state.cmpxchgStrong(0, writer_bit, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *@This()) void {
        std.debug.assert(self.state.load(.monotonic) == writer_bit);
        self.state.store(0, .release);
    }

    /// Caps nonblocking readers when local fallback is cheaper than reader-count
    /// cache-line contention. A zero limit is invalid.
    pub fn tryLockSharedLimited(self: *@This(), limit: u32) bool {
        std.debug.assert(limit > 0 and limit <= reader_mask);
        var current = self.state.load(.monotonic);
        while (current & writer_bit == 0 and current & reader_mask < limit) {
            if (self.state.cmpxchgWeak(
                current,
                current + 1,
                .acquire,
                .monotonic,
            )) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    pub fn tryLockShared(self: *@This()) bool {
        var current = self.state.load(.monotonic);
        while (current & writer_bit == 0 and current & reader_mask != reader_mask) {
            if (self.state.cmpxchgWeak(
                current,
                current + 1,
                .acquire,
                .monotonic,
            )) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    pub fn unlockShared(self: *@This()) void {
        const previous = self.state.fetchSub(1, .release);
        std.debug.assert(previous & writer_bit == 0 and previous & reader_mask != 0);
    }
};

test "Try reader writer lock admits readers and excludes mutation" {
    var lock: TryRwLock = .{};
    try std.testing.expect(lock.tryLockShared());
    try std.testing.expect(lock.tryLockShared());
    try std.testing.expect(!lock.tryLock());
    lock.unlockShared();
    lock.unlockShared();
    try std.testing.expect(lock.tryLock());
    try std.testing.expect(!lock.tryLock());
    try std.testing.expect(!lock.tryLockShared());
    lock.unlock();
    try std.testing.expect(lock.tryLockSharedLimited(2));
    try std.testing.expect(lock.tryLockSharedLimited(2));
    try std.testing.expect(!lock.tryLockSharedLimited(2));
    lock.unlockShared();
    lock.unlockShared();
    try std.testing.expect(lock.tryLockShared());
    lock.unlockShared();
}
