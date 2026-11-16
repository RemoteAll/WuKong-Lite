//! cpio `newc` / `crc` 归档 —— 对应参考工程 `mkcpio.py` 里
//! `cpio -ov -H crc` 生成的 OTA 子镜像归档。
//!
//! 字段口径（与 GNU/msys cpio 一致）：
//!   * 110 字节 ASCII 头（magic + 13 个 8 位十六进制字段，大写）；
//!   * magic `070701`（newc）/ `070702`（crc，check = 数据字节和）；
//!   * 名字与数据都按 4 字节对齐，末尾 `TRAILER!!!`，整档再按 512 对齐。
//!   * ino/dev/uid/gid 固定（参考工具取宿主 inode/dev，无法跨机复刻）；
//!     权限固定为 `100644` / `40755`，mtime 由调用者给（默认 0，保证可复现）。
const std = @import("std");

pub const Format = enum { newc, crc };

pub const Entry = struct {
    name: []const u8,
    data: []const u8 = &.{},
    is_dir: bool = false,
    mtime: u32 = 0,
};

pub const Error = error{
    BadMagic,
    BadHeader,
    Truncated,
};

pub const ParsedEntry = struct {
    name: []const u8,
    data: []const u8,
    is_dir: bool,
    mtime: u32,
    mode: u32,
    check: u32,
};

fn hex8(buf: *[8]u8, value: u32) void {
    var i: usize = 8;
    var v = value;
    while (i > 0) {
        i -= 1;
        const d: u8 = @intCast(v & 0xF);
        buf[i] = if (d < 10) '0' + d else 'A' + (d - 10);
        v >>= 4;
    }
}

fn appendHeader(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    format: Format,
    ino: u32,
    mode: u32,
    nlink: u32,
    mtime: u32,
    size: u32,
    name_size: u32,
    check: u32,
) !void {
    var h: [110]u8 = @splat('0');
    @memcpy(h[0..6], if (format == .crc) "070702" else "070701");
    const fields = [_]struct { off: usize, val: u32 }{
        .{ .off = 6, .val = ino },
        .{ .off = 14, .val = mode },
        .{ .off = 22, .val = 0 }, // uid
        .{ .off = 30, .val = 0 }, // gid
        .{ .off = 38, .val = nlink },
        .{ .off = 46, .val = mtime },
        .{ .off = 54, .val = size },
        .{ .off = 62, .val = 0 }, // devmajor
        .{ .off = 70, .val = 0 }, // devminor
        .{ .off = 78, .val = 0 }, // rdevmajor
        .{ .off = 86, .val = 0 }, // rdevminor
        .{ .off = 94, .val = name_size },
        .{ .off = 102, .val = check },
    };
    for (fields) |f| {
        var fbuf: [8]u8 = undefined;
        hex8(&fbuf, f.val);
        @memcpy(h[f.off .. f.off + 8], &fbuf);
    }
    try out.appendSlice(a, &h);
}

fn pad4(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    while (out.items.len % 4 != 0) try out.append(a, 0);
}

fn sumBytes(data: []const u8) u32 {
    var sum: u32 = 0;
    for (data) |b| sum +%= b;
    return sum;
}

/// 生成归档（调用者释放）。
pub fn build(allocator: std.mem.Allocator, entries: []const Entry, format: Format) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var ino: u32 = 1;
    for (entries) |e| {
        const name_len: u32 = @intCast(e.name.len + 1);
        const size: u32 = @intCast(e.data.len);
        const mode: u32 = if (e.is_dir) 0o40755 else 0o100644;
        const nlink: u32 = if (e.is_dir) 2 else 1;
        const check: u32 = if (format == .crc) sumBytes(e.data) else 0;

        try appendHeader(&out, allocator, format, ino, mode, nlink, e.mtime, size, name_len, check);
        ino += 1;
        try out.appendSlice(allocator, e.name);
        try out.append(allocator, 0);
        try pad4(&out, allocator);
        if (!e.is_dir) {
            try out.appendSlice(allocator, e.data);
            try pad4(&out, allocator);
        }
    }

    // TRAILER!!!
    const trailer = "TRAILER!!!";
    try appendHeader(&out, allocator, format, 0, 0, 1, 0, 0, trailer.len + 1, 0);
    try out.appendSlice(allocator, trailer);
    try out.append(allocator, 0);
    try pad4(&out, allocator);

    // 整档按 512 对齐（参考 cpio 输出总长 1024）
    while (out.items.len % 512 != 0) try out.append(allocator, 0);
    return out.toOwnedSlice(allocator);
}

fn parseHex(h: []const u8) !u32 {
    return std.fmt.parseInt(u32, h, 16) catch Error.BadHeader;
}

/// 解析归档（返回条目，name/data 指向 `archive`；TRAILER 不返回）。
pub fn parse(entries: *std.ArrayList(ParsedEntry), allocator: std.mem.Allocator, archive: []const u8) !void {
    var pos: usize = 0;
    while (true) {
        if (pos + 110 > archive.len) return Error.Truncated;
        const h = archive[pos .. pos + 110];
        if (!std.mem.eql(u8, h[0..6], "070701") and !std.mem.eql(u8, h[0..6], "070702")) return Error.BadMagic;
        const mode = try parseHex(h[14..22]);
        const mtime = try parseHex(h[46..54]);
        const size = try parseHex(h[54..62]);
        const name_size = try parseHex(h[94..102]);
        const check = try parseHex(h[102..110]);
        pos += 110;

        if (pos + name_size > archive.len) return Error.Truncated;
        const name = archive[pos .. pos + name_size - 1];
        pos += name_size;
        pos = (pos + 3) & ~@as(usize, 3);

        if (std.mem.eql(u8, name, "TRAILER!!!")) return;

        if (pos + size > archive.len) return Error.Truncated;
        const data = archive[pos .. pos + size];
        pos += size;
        pos = (pos + 3) & ~@as(usize, 3);

        try entries.append(allocator, .{
            .name = name,
            .data = data,
            .is_dir = (mode & 0o170000) == 0o040000,
            .mtime = mtime,
            .mode = mode,
            .check = check,
        });
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
test "cpio crc：头字段、校验和与解析往返" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .name = "a.txt", .data = "hello cpio\n", .mtime = 0x6AF00000 },
        .{ .name = "sub", .is_dir = true },
        .{ .name = "sub/b.bin", .data = "xyz", .mtime = 7 },
    };
    const blob = try build(allocator, &entries, .crc);
    defer allocator.free(blob);

    try std.testing.expect(blob.len % 512 == 0);
    try std.testing.expectEqualStrings("070702", blob[0..6]);
    try std.testing.expectEqual(@as(u32, 0o100644), try parseHex(blob[14..22]));
    try std.testing.expectEqual(@as(u32, 0x6AF00000), try parseHex(blob[46..54]));
    try std.testing.expectEqual(@as(u32, 11), try parseHex(blob[54..62]));
    try std.testing.expectEqualStrings("a.txt\x00", blob[110..116]);
    // 'hello cpio\n' 校验和
    try std.testing.expectEqual(@as(u32, 1001), try parseHex(blob[102..110]));

    var parsed: std.ArrayList(ParsedEntry) = .empty;
    defer parsed.deinit(allocator);
    try parse(&parsed, allocator, blob);
    try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    try std.testing.expectEqualStrings("a.txt", parsed.items[0].name);
    try std.testing.expectEqualStrings("hello cpio\n", parsed.items[0].data);
    try std.testing.expect(parsed.items[1].is_dir);
    try std.testing.expectEqualStrings("sub/b.bin", parsed.items[2].name);
    try std.testing.expectEqual(@as(usize, 3), parsed.items[2].data.len);
}

test "cpio newc：check 恒为 0" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{.{ .name = "x", .data = "AB" }};
    const blob = try build(allocator, &entries, .newc);
    defer allocator.free(blob);
    try std.testing.expectEqualStrings("070701", blob[0..6]);
    try std.testing.expectEqual(@as(u32, 0), try parseHex(blob[102..110]));
}
