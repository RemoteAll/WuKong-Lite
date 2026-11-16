//! CRC32 (ISO-HDLC / 以太网多项式) —— 与 Luban-Lite `bsp/common/crc32/crc32.c` 等价。
//!
//! Luban-Lite 使用标准反射多项式 0xEDB88320、初始值 0xFFFFFFFF、结果取反，
//! `crc32(seed, buf, len)` 的语义与 U-Boot `env_crc32` 一致（镜像/环境变量/分区表通用）。
const std = @import("std");

/// 256 项查找表，在编译期按多项式生成，数值与 Luban-Lite 内置表完全一致。
pub const table: [256]u32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*slot, i| {
        var crc: u32 = @intCast(i);
        var bit: u5 = 0;
        while (bit < 8) : (bit += 1) {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
        }
        slot.* = crc;
    }
    break :blk t;
};

/// 增量更新 CRC。`crc_in` 是上一次的输出值（首次传 0）。
pub fn update(crc_in: u32, data: []const u8) u32 {
    var crc: u32 = crc_in ^ 0xFFFFFFFF;
    for (data) |b| {
        crc = table[@as(u8, @truncate(crc ^ b))] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

/// 一次算完整缓冲。
pub fn calc(data: []const u8) u32 {
    return update(0, data);
}

/// 与 `env_crc32()` 同名入口：U-Boot 环境变量镜像使用同一算法。
pub fn envCrc32(data: []const u8) u32 {
    return calc(data);
}

test "CRC32 标准校验向量" {
    // CRC-32/ISO-HDLC: "123456789" -> 0xCBF43926
    try std.testing.expectEqual(@as(u32, 0xCBF43926), calc("123456789"));
    // 空缓冲：初始值取反再取反
    try std.testing.expectEqual(@as(u32, 0), calc(""));
    // 增量与一次算完等价
    try std.testing.expectEqual(calc("hello world"), update(update(0, "hello "), "world"));
}
