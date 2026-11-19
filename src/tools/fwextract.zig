//! AIC.FW 镜像解包（`mk_image.py -i/--imgfile` 的 `extract_img_data` 等价实现）。
//!
//! 参考行为：
//!   1. 解包目录 = `dirname(img)/<镜像名去扩展名>`；
//!   2. 头 348 B（`FwHeader`）给出 `meta_offset` / `meta_size`；
//!   3. 元数据按 512 B 一项（`META_ALIGNED_SIZE`），共 `meta_size/512` 项；
//!   4. 每项的 `filename` + `offset_in_img` + `size_in_img` 决定写出的文件；
//!   5. 若组件名以 `.tar` 结尾 → 解包到同一目录（`make_untar`，带路径穿越防护）。
const std = @import("std");
const fw_image = @import("../bsp/common/fw_image.zig");

pub const Error = error{
    BadMagic,
    BadMeta,
    UnsafePath,
    UnsupportedTarEntry,
};

pub const Entry = struct {
    name: []u8,
    size: u32,
};

pub const Result = struct {
    out_dir: []u8,
    entries: []Entry,
    tar_entries: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.out_dir);
        for (self.entries) |e| allocator.free(e.name);
        allocator.free(self.entries);
    }
};

fn trimNul(bytes: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

/// 解包到 `out_dir`（为空则用 `dirname(img)/<stem>`）。
pub fn extract(
    allocator: std.mem.Allocator,
    io: std.Io,
    img_path: []const u8,
    out_dir: ?[]const u8,
) !Result {
    const blob = try std.Io.Dir.cwd().readFileAlloc(io, img_path, allocator, .unlimited);
    defer allocator.free(blob);

    const header = try fw_image.FwHeader.parse(blob);
    if (!std.mem.eql(u8, trimNul(&header.magic), "AIC.FW")) return Error.BadMagic;

    const dir: []u8 = if (out_dir) |d|
        try allocator.dupe(u8, d)
    else blk: {
        const parent = std.fs.path.dirname(img_path) orelse ".";
        const base = std.fs.path.basename(img_path);
        const stem = if (std.mem.findScalar(u8, base, '.')) |dot| base[0..dot] else base;
        break :blk try std.fs.path.join(allocator, &.{ parent, stem });
    };
    errdefer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| allocator.free(e.name);
        list.deinit(allocator);
    }

    var tar_entries: usize = 0;
    const count: usize = header.meta_size / fw_image.META_ALIGNED_SIZE;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off: usize = @as(usize, header.meta_offset) + i * fw_image.META_ALIGNED_SIZE;
        if (off + fw_image.META_STRUCT_SIZE > blob.len) return Error.BadMeta;
        const meta = try fw_image.Meta.parse(blob[off..]);
        if (!std.mem.eql(u8, trimNul(&meta.magic), "META")) return Error.BadMeta;

        const name = trimNul(&meta.filename);
        if (name.len == 0) continue;
        try checkSafePath(name);

        const data_off: usize = meta.offset_in_img;
        const data_len: usize = meta.size_in_img;
        if (data_off + data_len > blob.len) return Error.BadMeta;

        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blob[data_off..][0..data_len] });

        if (std.mem.endsWith(u8, name, ".tar")) {
            tar_entries += try extractTar(allocator, io, blob[data_off..][0..data_len], dir);
        }

        try list.append(allocator, .{ .name = try allocator.dupe(u8, name), .size = meta.size_in_img });
    }

    return .{
        .out_dir = dir,
        .entries = try list.toOwnedSlice(allocator),
        .tar_entries = tar_entries,
    };
}

/// 组件路径安全：拒绝绝对路径与 `..` 段（等价参考 tar 解包前的检查）。
fn checkSafePath(name: []const u8) !void {
    if (name.len == 0) return Error.UnsafePath;
    if (name[0] == '/' or name[0] == '\\') return Error.UnsafePath;
    if (name.len >= 2 and name[1] == ':') return Error.UnsafePath; // Windows 盘符
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return Error.UnsafePath;
    }
}

fn tarOctal(bytes: []const u8) u64 {
    // ustar 的数值字段以八进制 ASCII 存储，尾部 NUL/空格
    var v: u64 = 0;
    for (bytes) |c| {
        if (c == 0 or c == ' ') {
            if (v != 0) break;
            continue;
        }
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

/// 最小 ustar 解包：支持普通文件（`0`/`\0`）与目录（`5`），以及 GNU 长名（`L`）。
/// 符号链接/硬链接/设备文件返回 `UnsupportedTarEntry`（SDK 官方镜像里 0 处使用 .tar）。
fn extractTar(
    allocator: std.mem.Allocator,
    io: std.Io,
    tar: []const u8,
    out_dir: []const u8,
) !usize {
    var written: usize = 0;
    var pos: usize = 0;
    var long_name: ?[]const u8 = null;
    while (pos + 512 <= tar.len) {
        const hdr = tar[pos..][0..512];
        pos += 512;
        var all_zero = true;
        for (hdr) |c| {
            if (c != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) break; // 归档结束

        const size = tarOctal(hdr[124..136]);
        const typeflag = hdr[156];
        const name_area = trimNul(hdr[0..100]);
        const prefix = trimNul(hdr[345..500]);

        var name: []const u8 = undefined;
        var name_buf: ?[]u8 = null;
        defer if (name_buf) |b| allocator.free(b);
        if (typeflag == 'L') {
            // GNU longname：本块数据就是下一个条目的名字
            const len: usize = @intCast(size);
            if (pos + len > tar.len) return Error.BadMeta;
            long_name = trimNul(tar[pos..][0..len]);
            pos += std.mem.alignForward(usize, len, 512);
            continue;
        }
        if (long_name) |ln| {
            name = ln;
            long_name = null;
        } else if (prefix.len > 0) {
            name_buf = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name_area });
            name = name_buf.?;
        } else {
            name = name_area;
        }
        if (name.len == 0) continue;
        try checkSafePath(name);
        const path = try std.fs.path.join(allocator, &.{ out_dir, name });
        defer allocator.free(path);

        const len: usize = @intCast(size);
        if (pos + len > tar.len) return Error.BadMeta;

        switch (typeflag) {
            '0', 0 => {
                if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tar[pos..][0..len] });
                written += 1;
            },
            '5' => try std.Io.Dir.cwd().createDirPath(io, path),
            else => return Error.UnsupportedTarEntry,
        }
        pos += std.mem.alignForward(usize, len, 512);
    }
    return written;
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------
fn putTarOctal(dst: []u8, value: u64) void {
    @memset(dst, 0);
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{o}", .{value}) catch unreachable;
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
}

fn makeTarHeader(name: []const u8, size: u64, typeflag: u8) [512]u8 {
    var h: [512]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    putTarOctal(h[100..108], 0o644); // mode
    putTarOctal(h[124..136], size);
    h[156] = typeflag;
    @memcpy(h[257..262], "ustar");
    h[263] = '0';
    h[264] = '0';
    // 校验和：先按空格计算
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |c| sum += c;
    putTarOctal(h[148..156], sum);
    return h;
}

test "fwextract.extractTar：常规文件 + 目录 + 路径穿越拒绝" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = ".zig-cache/fwextract-test";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const body = "hello tar\n";
    var tar: std.ArrayList(u8) = .empty;
    defer tar.deinit(allocator);

    const h_dir = makeTarHeader("sub/", 0, '5');
    try tar.appendSlice(allocator, &h_dir);
    const h_file = makeTarHeader("sub/a.txt", body.len, '0');
    try tar.appendSlice(allocator, &h_file);
    try tar.appendSlice(allocator, body);
    var pad: [512]u8 = @splat(0);
    try tar.appendSlice(allocator, pad[0 .. 512 - body.len % 512]);
    // 结束标记：两个全零块
    try tar.appendSlice(allocator, &pad);
    try tar.appendSlice(allocator, &pad);

    const n = try extractTar(allocator, io, tar.items, dir);
    try std.testing.expectEqual(@as(usize, 1), n);

    const out = try std.fs.path.join(allocator, &.{ dir, "sub", "a.txt" });
    defer allocator.free(out);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, out, allocator, .unlimited);
    defer allocator.free(got);
    try std.testing.expectEqualStrings(body, got);

    // 路径穿越必须拒绝
    const h_bad = makeTarHeader("../evil.txt", 1, '0');
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(allocator);
    try bad.appendSlice(allocator, &h_bad);
    try bad.appendSlice(allocator, "x");
    try bad.appendSlice(allocator, pad[0..511]);    try std.testing.expectError(Error.UnsafePath, extractTar(allocator, io, bad.items, dir));
}

test "fwextract.checkSafePath：绝对路径/盘符/.. 一律拒绝" {
    try std.testing.expectError(Error.UnsafePath, checkSafePath("/abs.txt"));
    try std.testing.expectError(Error.UnsafePath, checkSafePath("C:/win.txt"));
    try std.testing.expectError(Error.UnsafePath, checkSafePath("a/../b.txt"));
    try checkSafePath("sub/ok.txt");
}
