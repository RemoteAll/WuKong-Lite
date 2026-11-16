//! U-Boot 环境变量镜像 —— 与 Luban-Lite 自带 `tools/scripts/mkenvimage` 行为完全一致：
//!
//! 布局（`-r` 冗余模式）：
//!   +0  u32 crc32(data)   // 覆盖整个数据区（含 0xFF 填充）
//!   +4  u8 flags          // 1 = active，0 = obsolete
//!   +5  data[size-5]
//!
//! 非冗余模式：
//!   +0  u32 crc32(data)
//!   +4  data[size-4]
//!
//! 说明（与参考工具实测对齐）：
//!   * `-s` 是镜像**总大小**（冗余模式也只输出一份，第二份由 bootloader 生成）；
//!   * 未使用的尾部用 **0xFF** 填充（可通过 `-p` 改，但 SDK 脚本不传）；
//!   * 数据区为 `name=value` 以 NUL 分隔，末尾双 NUL；
//!   * mk_image.py 会把 `MTD=...` / `GPT=...` 分区串放在环境变量之前。
const std = @import("std");
const crc32 = @import("crc32.zig");

pub const ACTIVE_FLAG: u8 = 1;
pub const OBSOLETE_FLAG: u8 = 0;
pub const DEFAULT_FILL: u8 = 0xFF;

pub const Options = struct {
    /// 镜像总大小（含头部；冗余模式同样为总大小）。
    size: usize,
    redundant: bool = false,
    /// 是否在环境变量前面附加 `MTD=...` / `GPT=...` 分区串（与 mk_image.py 一致）。
    prefix: []const u8 = "",
};

/// 把多行 `name=value` 文本转换为环境变量数据区（NUL 分隔 + 双 NUL 结尾）。
/// 空行与 `#` 注释行被忽略。
pub fn textToData(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (prefix.len > 0) try out.appendSlice(allocator, prefix);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, 0);
    }
    // 至少要有结尾的双 NUL
    if (out.items.len == 0 or out.items[out.items.len - 1] != 0) try out.append(allocator, 0);
    try out.append(allocator, 0);
    return out.toOwnedSlice(allocator);
}

/// 生成 env 镜像（尾部 0xFF 填充）。
pub fn build(allocator: std.mem.Allocator, data: []const u8, opt: Options) ![]u8 {
    const header_len: usize = if (opt.redundant) 5 else 4;
    if (opt.size <= header_len) return error.SizeTooSmall;
    const payload_cap = opt.size - header_len;
    if (data.len > payload_cap) return error.DataTooLarge;

    const out = try allocator.alloc(u8, opt.size);
    errdefer allocator.free(out);
    @memset(out, DEFAULT_FILL);

    @memcpy(out[header_len..][0..data.len], data);
    if (opt.redundant) out[4] = ACTIVE_FLAG;

    // CRC 覆盖整个数据区（含 0xFF 填充），与 mkenvimage 一致
    const crc = crc32.calc(out[header_len..]);
    std.mem.writeInt(u32, out[0..4], crc, .little);
    return out;
}

pub const Parsed = struct {
    data: []const u8,
    redundant: bool,
    flags: u8 = 0,
};

/// 校验并取出环境变量数据区（自动识别是否带 flags 字节）。
pub fn parse(image: []const u8) !Parsed {
    if (image.len < 8) return error.ImageTooSmall;
    const stored = std.mem.readInt(u32, image[0..4], .little);

    // 冗余模式：flags 必须是 0 或 1，且 CRC 覆盖 data 区
    if (image.len > 5) {
        const flags = image[4];
        if ((flags == ACTIVE_FLAG or flags == OBSOLETE_FLAG) and stored == crc32.calc(image[5..])) {
            return .{ .data = image[5..], .redundant = true, .flags = flags };
        }
    }
    // 非冗余模式
    if (stored == crc32.calc(image[4..])) {
        return .{ .data = image[4..], .redundant = false };
    }
    return error.BadCrc;
}

/// 按 `name=value` 逐行打印（遇到第一个空项即停止）。
pub fn printData(writer: *std.Io.Writer, data: []const u8) !void {
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) break;
        try writer.print("{s}\n", .{entry});
    }
}

test "env 单份镜像 CRC 与内容往返" {
    const allocator = std.testing.allocator;
    const data = try textToData(allocator, "foo=bar\nbaz=1\n", "MTD=spi0.0:1m(spl),-(data)\n");
    defer allocator.free(data);

    const img = try build(allocator, data, .{ .size = 4096 });
    defer allocator.free(img);
    try std.testing.expectEqual(@as(usize, 4096), img.len);
    // 尾部必须是 0xFF 填充
    try std.testing.expectEqual(@as(u8, 0xFF), img[img.len - 1]);

    const parsed = try parse(img);
    try std.testing.expect(!parsed.redundant);
    try std.testing.expectEqualSlices(u8, data, parsed.data[0..data.len]);
}

test "env 冗余镜像带 flags 且 CRC 覆盖填充区" {
    const allocator = std.testing.allocator;
    const data = try textToData(allocator, "a=b\n", "");
    defer allocator.free(data);

    const img = try build(allocator, data, .{ .size = 64, .redundant = true });
    defer allocator.free(img);

    // 与参考 mkenvimage 实测向量一致：
    // mkenvimage -r -s 64 <a=b> -> 6d9aecc2 01 61 3d 62 00 00 ff...
    try std.testing.expectEqual(@as(usize, 64), img.len);
    try std.testing.expectEqual(@as(u32, 0xC2EC9A6D), std.mem.readInt(u32, img[0..4], .little));
    try std.testing.expectEqual(@as(u8, ACTIVE_FLAG), img[4]);
    try std.testing.expectEqualSlices(u8, "a=b\x00\x00", img[5..10]);

    const parsed = try parse(img);
    try std.testing.expect(parsed.redundant);
    try std.testing.expectEqual(ACTIVE_FLAG, parsed.flags);
    try std.testing.expectEqualSlices(u8, data, parsed.data[0..data.len]);
}

test "env 数据超过容量报错" {
    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u8, 100);
    defer allocator.free(big);
    @memset(big, 'x');
    try std.testing.expectError(error.DataTooLarge, build(allocator, big, .{ .size = 64 }));
    try std.testing.expectError(error.DataTooLarge, build(allocator, big, .{ .size = 64, .redundant = true }));
}
