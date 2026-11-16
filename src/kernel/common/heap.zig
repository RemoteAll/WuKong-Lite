//! 堆统计包装 —— 用于 shell 的 `free` 命令（等价 RT-Thread `list_mem` / `free` 输出）。
//! 只统计 malloc 请求的字节数，不改变上层分配器语义。
const std = @import("std");

pub const Counting = struct {
    parent: std.mem.Allocator,
    used: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    peak: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    alloc_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    free_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(parent: std.mem.Allocator) Counting {
        return .{ .parent = parent };
    }

    pub fn allocator(self: *Counting) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free_impl,
            },
        };
    }

    pub fn usedBytes(self: *Counting) usize {
        return self.used.load(.monotonic);
    }

    pub fn peakBytes(self: *Counting) usize {
        return self.peak.load(.monotonic);
    }

    pub fn allocCount(self: *Counting) usize {
        return self.alloc_count.load(.monotonic);
    }

    pub fn freeCount(self: *Counting) usize {
        return self.free_count.load(.monotonic);
    }

    fn updatePeak(self: *Counting, value: usize) void {
        var cur = self.peak.load(.monotonic);
        while (value > cur) {
            cur = self.peak.cmpxchgWeak(cur, value, .monotonic, .monotonic) orelse break;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        const now = self.used.fetchAdd(len, .monotonic) + len;
        self.updatePeak(now);
        _ = self.alloc_count.fetchAdd(1, .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            const now = self.used.fetchAdd(new_len - memory.len, .monotonic) + (new_len - memory.len);
            self.updatePeak(now);
        } else {
            _ = self.used.fetchSub(memory.len - new_len, .monotonic);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) {
            const now = self.used.fetchAdd(new_len - memory.len, .monotonic) + (new_len - memory.len);
            self.updatePeak(now);
        } else {
            _ = self.used.fetchSub(memory.len - new_len, .monotonic);
        }
        return ptr;
    }

    fn free_impl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        _ = self.used.fetchSub(memory.len, .monotonic);
        _ = self.free_count.fetchAdd(1, .monotonic);
    }
};

test "统计分配器记录使用量与峰值" {
    var counting = Counting.init(std.testing.allocator);
    const a = counting.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expect(counting.usedBytes() >= 100);
    try std.testing.expect(counting.peakBytes() >= 100);
    a.free(buf);
    try std.testing.expectEqual(@as(usize, 0), counting.usedBytes());
    try std.testing.expectEqual(@as(usize, 1), counting.allocCount());
    try std.testing.expectEqual(@as(usize, 1), counting.freeCount());
}
