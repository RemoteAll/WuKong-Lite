//! 文件拼接 —— 对应参考工程 `tools/scripts/merge_files.py`。
//! 按给定顺序把多个文件原样首尾相接；不做对齐、不填空洞。
const std = @import("std");

pub const Error = error{OutOfMemory};

/// 计算拼接后的总长度。
pub fn totalLength(parts: []const []const u8) usize {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    return total;
}

/// 按顺序拼接（调用者释放）。
pub fn merge(allocator: std.mem.Allocator, parts: []const []const u8) Error![]u8 {
    const out = try allocator.alloc(u8, totalLength(parts));
    var off: usize = 0;
    for (parts) |p| {
        @memcpy(out[off..][0..p.len], p);
        off += p.len;
    }
    return out;
}

test "merge：按顺序拼接且保留空文件" {
    const a = std.testing.allocator;
    const parts = [_][]const u8{ "abc", "", "de" };
    const out = try merge(a, &parts);
    defer a.free(out);
    try std.testing.expectEqualStrings("abcde", out);
}

test "merge：全空输入返回空切片" {
    const a = std.testing.allocator;
    const parts = [_][]const u8{};
    const out = try merge(a, &parts);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
