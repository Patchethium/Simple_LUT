const std = @import("std");
const lut_math = @import("lut_math.zig");
const Allocator = std.mem.Allocator;
const Lut = lut_math.Lut;

/// A small LRU cache of parsed LUTs keyed by path and file modification stamp. It does no
/// locking: callers hold their own lock from `get` until they stop using the returned LUT,
/// because the next `get` may evict it.
pub fn Cache(comptime Char: type, comptime slot_count: usize) type {
    return struct {
        slots: [slot_count]?Entry = @splat(null),
        clock: u64 = 0,

        const Self = @This();
        const Entry = struct { path: []Char, stamp: u64, lut: Lut, used: u64 };

        /// Returns the cached LUT for `path`, loading it with `loader.load(allocator, path)` on a
        /// miss or when `stamp` (e.g. the file's last-write time) changed. A failed load leaves
        /// the cache unchanged.
        pub fn get(self: *Self, allocator: Allocator, path: []const Char, stamp: u64, loader: anytype) !*const Lut {
            self.clock += 1;
            var target: usize = 0;
            for (&self.slots, 0..) |*slot, index| {
                if (slot.*) |*entry| {
                    if (std.mem.eql(Char, entry.path, path)) {
                        if (entry.stamp == stamp) {
                            entry.used = self.clock;
                            return &entry.lut;
                        }
                        target = index;
                        break;
                    }
                    if (self.slots[target]) |current| {
                        if (entry.used < current.used) target = index;
                    }
                } else if (self.slots[target] != null) {
                    target = index;
                }
            }

            var lut = try loader.load(allocator, path);
            errdefer lut.deinit(allocator);
            const owned_path = try allocator.dupe(Char, path);
            if (self.slots[target]) |*old| release(allocator, old);
            self.slots[target] = .{ .path = owned_path, .stamp = stamp, .lut = lut, .used = self.clock };
            return &self.slots[target].?.lut;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (&self.slots) |*slot| {
                if (slot.*) |*entry| release(allocator, entry);
                slot.* = null;
            }
        }

        fn release(allocator: Allocator, entry: *Entry) void {
            allocator.free(entry.path);
            entry.lut.deinit(allocator);
        }
    };
}
