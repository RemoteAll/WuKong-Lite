//! 文件安装/清理 —— 对应参考工程 `tools/scripts/fsinstall.py`。
//!
//! `install`：把文件或目录内容安装到目标（可选 SDK 输出根目录前缀）；
//! `clean`：按逗号分隔的路径列表递归删除（可选 SDK 输出根目录前缀）。
const std = @import("std");

pub const Error = error{ MissingArgument, SourceNotExist };

fn endsWithSep(path: []const u8) bool {
    if (path.len == 0) return false;
    return path[path.len - 1] == '/' or path[path.len - 1] == '\\';
}

fn joinOut(a: std.mem.Allocator, sdkout: ?[]const u8, path: []const u8) ![]u8 {
    if (sdkout) |root| {
        if (root.len > 0) return std.fs.path.join(a, &.{ root, path });
    }
    return a.dupe(u8, path);
}

fn copyTree(
    a: std.mem.Allocator,
    io: std.Io,
    src: []const u8,
    dst: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const from = try std.fs.path.join(a, &.{ src, entry.path });
        defer a.free(from);
        const to = try std.fs.path.join(a, &.{ dst, entry.path });
        defer a.free(to);
        if (std.fs.path.dirname(to)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
        }
        const cwd = std.Io.Dir.cwd();
        try std.Io.Dir.copyFile(cwd, from, cwd, to, io, .{ .make_path = true, .replace = true });
    }
}

pub fn install(
    a: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_path: []const u8,
    sdkout: ?[]const u8,
) !void {
    if (src_path.len == 0 or dst_path.len == 0) return Error.MissingArgument;
    const st = std.Io.Dir.cwd().statFile(io, src_path, .{}) catch return Error.SourceNotExist;

    const dst = try joinOut(a, sdkout, dst_path);
    defer a.free(dst);

    if (st.kind == .directory) {
        try std.Io.Dir.cwd().createDirPath(io, dst);
        try copyTree(a, io, src_path, dst);
        return;
    }

    var final_dst = dst;
    var owned: ?[]u8 = null;
    defer if (owned) |p| a.free(p);
    if (endsWithSep(dst_path)) {
        const base = std.fs.path.basename(src_path);
        owned = try std.fs.path.join(a, &.{ dst, base });
        final_dst = owned.?;
    }
    if (std.fs.path.dirname(final_dst)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    const cwd = std.Io.Dir.cwd();
    try std.Io.Dir.copyFile(cwd, src_path, cwd, final_dst, io, .{ .make_path = true, .replace = true });
}

/// 删除逗号分隔的路径；`sdkout` 非空时先与每个路径拼接。
pub fn clean(
    a: std.mem.Allocator,
    io: std.Io,
    list: []const u8,
    sdkout: ?[]const u8,
) !void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r\n");
        if (p.len == 0) continue;
        const path = try joinOut(a, sdkout, p);
        defer a.free(path);
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }
}

test "fsinstall：目录递归安装与清理" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const src = try std.fs.path.join(a, &.{ root, "src" });
    defer a.free(src);
    const sub = try std.fs.path.join(a, &.{ src, "sub" });
    defer a.free(sub);
    try std.Io.Dir.cwd().createDirPath(io, sub);
    const src_file = try std.fs.path.join(a, &.{ sub, "a.txt" });
    defer a.free(src_file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src_file, .data = "hello fs" });

    const dst = try std.fs.path.join(a, &.{ root, "dst" });
    defer a.free(dst);
    try install(a, io, src, dst, null);

    const out = try std.fs.path.join(a, &.{ dst, "sub", "a.txt" });
    defer a.free(out);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .unlimited);
    defer a.free(data);
    try std.testing.expectEqualStrings("hello fs", data);

    try clean(a, io, dst, null);
    if (std.Io.Dir.cwd().statFile(io, dst, .{})) |_| {
        return error.TestExpectedMissing;
    } else |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    }
}

test "fsinstall：单文件安装到目录" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const src = try std.fs.path.join(a, &.{ root, "one.bin" });
    defer a.free(src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = "xyz" });
    const dst_dir = try std.fs.path.join(a, &.{ root, "out" });
    defer a.free(dst_dir);
    const dst = try std.fmt.allocPrint(a, "{s}{c}", .{ dst_dir, std.fs.path.sep });
    defer a.free(dst);

    try install(a, io, src, dst, null);
    const out = try std.fs.path.join(a, &.{ dst_dir, "one.bin" });
    defer a.free(out);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .unlimited);
    defer a.free(data);
    try std.testing.expectEqualStrings("xyz", data);
}
