//! 公共工具：尺寸字符串、对齐、hexdump、定长字符串 —— 对应 Luban-Lite
//! `bsp/common/utils/*` 与 `tools/scripts/*.py` 中反复用到的小函数。
const std = @import("std");

/// `size_str_to_int()`：支持 `512k` / `2m` / `1g` / `0x1000` / `-`（表示剩余空间，返回 0）。
/// 与 Python 版本一致：先判 k/m/g 后缀（只取数字部分），再判 `0x`，再判 `-`，最后十进制。
pub fn sizeStrToInt(str_in: []const u8) !u64 {
    const s = std.mem.trim(u8, str_in, " \t");
    if (s.len == 0) return error.InvalidSize;

    var has_suffix = false;
    var mult: u64 = 1;
    for (s) |c| {
        switch (c) {
            'k', 'K' => {
                has_suffix = true;
                mult = 1024;
            },
            'm', 'M' => {
                has_suffix = true;
                mult = 1024 * 1024;
            },
            'g', 'G' => {
                has_suffix = true;
                mult = 1024 * 1024 * 1024;
            },
            else => {},
        }
    }

    if (has_suffix) {
        var digits: [32]u8 = undefined;
        var n: usize = 0;
        for (s) |c| {
            if (std.ascii.isDigit(c) and n < digits.len) {
                digits[n] = c;
                n += 1;
            }
        }
        if (n == 0) return error.InvalidSize;
        const v = try std.fmt.parseInt(u64, digits[0..n], 10);
        return v * mult;
    }

    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        return std.fmt.parseInt(u64, s, 0);
    }
    if (std.mem.indexOfScalar(u8, s, '-') != null and s.len == 1) return 0;
    return std.fmt.parseInt(u64, s, 10);
}

/// 向上对齐（支持任意整数类型，返回与 x 同类型）。
pub fn roundUp(x: anytype, y: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const yy: T = @intCast(y);
    if (yy == 0) return x;
    return (x + yy - 1) / yy * yy;
}

pub fn alignForward(comptime T: type, x: T, y: T) T {
    if (y == 0) return x;
    return (x + y - 1) / y * y;
}

/// 写入定长字段：不足补 0，超出截断（对应 Python `str_to_nbytes`）。
pub fn strToFixedBytes(dst: []u8, s: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
}

/// 读取以 NUL 结尾的定长字符串视图。
pub fn fixedBytesToStr(bytes: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0)) |idx| return bytes[0..idx];
    return bytes;
}

/// 标准 hexdump（偏移 + 16 字节 + ASCII）。
pub fn hexdump(writer: *std.Io.Writer, data: []const u8, base_addr: u64) !void {
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        const line = data[off..@min(off + 16, data.len)];
        try writer.print("{X:0>8}: ", .{base_addr + off});
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (i < line.len) {
                try writer.print("{X:0>2} ", .{line[i]});
            } else {
                try writer.writeAll("   ");
            }
            if (i == 7) try writer.writeByte(' ');
        }
        try writer.writeAll(" |");
        for (line) |b| {
            try writer.writeByte(if (b >= 0x20 and b < 0x7F) b else '.');
        }
        try writer.writeAll("|\n");
    }
}

test "sizeStrToInt 与 Python 版语义一致" {
    try std.testing.expectEqual(@as(u64, 512 * 1024), try sizeStrToInt("512k"));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), try sizeStrToInt("2m"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try sizeStrToInt("1G"));
    try std.testing.expectEqual(@as(u64, 0x1000), try sizeStrToInt("0x1000"));
    try std.testing.expectEqual(@as(u64, 0), try sizeStrToInt("-"));
    try std.testing.expectEqual(@as(u64, 4096), try sizeStrToInt("4096"));
}

test "roundUp" {
    try std.testing.expectEqual(@as(u64, 2048), roundUp(1, 2048));
    try std.testing.expectEqual(@as(u64, 2048), roundUp(2048, 2048));
    try std.testing.expectEqual(@as(u64, 4096), roundUp(2049, 2048));
}

test "定长字符串写入与读取" {
    var buf: [8]u8 = undefined;
    strToFixedBytes(&buf, "abc");
    try std.testing.expectEqualStrings("abc", fixedBytesToStr(&buf));
    try std.testing.expectEqual(@as(u8, 0), buf[3]);
    strToFixedBytes(&buf, "0123456789");
    try std.testing.expectEqualStrings("01234567", fixedBytesToStr(&buf));
}
