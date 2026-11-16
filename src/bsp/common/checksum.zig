//! 镜像校验和 —— 等价于 Luban-Lite `bsp/common/image/image.c` 的
//! `image_calc_checksum` / `image_verify_checksum`。
//!
//! 算法：把镜像按 32 位小端字相加（尾部不足 4 字节按小端补 0），
//! 生成时把 header 的 checksum 字段清零后求和并取反存入；
//! 校验时整镜像求和后应满足 `sum + 1 == 0`（即 0xFFFFFFFF）。
const std = @import("std");

/// 32 位累加和（小端口径，与 ROM/Bootloader 一致）。
pub fn imageCalcChecksum(buf: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    const cnt = buf.len / 4;

    // C 版本对非对齐指针做字节拼接，对对齐指针直接读 u32；
    // Zig 里统一按小端读，结果一致。
    while (i < cnt) : (i += 1) {
        sum +%= std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
    }

    // 余下不足 4 字节：val += p[i] << (i * 8)
    const rest = buf.len - cnt * 4;
    var val: u32 = 0;
    var j: usize = 0;
    while (j < rest) : (j += 1) {
        val +%= @as(u32, buf[cnt * 4 + j]) << @intCast(j * 8);
    }
    sum +%= val;
    return sum;
}

/// 校验整镜像：`sum + 1 == 0`（无符号回绕）。
pub fn verifyChecksum(image: []const u8) bool {
    const sum = imageCalcChecksum(image);
    return sum +% 1 == 0;
}

/// 生成放在 header 中的 checksum 值：对“checksum 字段为 0”的缓冲求和后取反。
pub fn makeChecksum(buf_with_zero_checksum: []const u8) u32 {
    return ~imageCalcChecksum(buf_with_zero_checksum);
}

test "checksum: 生成后整镜像校验通过" {
    var buf: [37]u8 = @splat(0);
    for (&buf, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    // 生成 checksum 时 header 的 checksum 字段必须为 0
    @memset(buf[0..4], 0);
    const cs = makeChecksum(&buf);
    // 把 checksum 写到开头 4 字节再整体校验
    std.mem.writeInt(u32, buf[0..4], cs, .little);
    try std.testing.expect(verifyChecksum(&buf));
}

test "checksum: 非对齐长度按小端拼接" {
    const buf = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(@as(u32, 0x030201), imageCalcChecksum(&buf));
}
