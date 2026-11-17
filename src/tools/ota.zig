//! OTA 子镜像归档 —— 对应参考工程 `tools/scripts/mkcpio.py`：
//!   1) 把 image_cfg.json 的 version 写回 ota-subimgs.cfg 第 3 行；
//!   2) 用 ota-subimgs.cfg 生成 512 字节的 ota_info.bin（mkenvimage -s 512）；
//!   3) 按 [file] 段文件列表生成 crc 格式 ota.cpio；
//!   4) 把 ota.cpio 的总大小回填到 ota_info.bin 内的 `size = "..."` 字段。
const std = @import("std");
const env_image = @import("../bsp/common/env_image.zig");
const cpio = @import("cpio.zig");
const image_cfg = @import("image_cfg.zig");

pub const Options = struct {
    ota_cfg: []const u8,
    image_cfg: []const u8,
    input_dir: []const u8,
    out_dir: []const u8,
    mtime: u32 = 0,
};

pub const Result = struct {
    version: []u8,
    cfg_text: []u8,
    ota_info: []u8,
    archive: []u8,
    files: usize,

    pub fn deinit(self: *Result, a: std.mem.Allocator) void {
        a.free(self.version);
        a.free(self.cfg_text);
        a.free(self.ota_info);
        a.free(self.archive);
    }
};

pub const Error = error{
    BadConfig,
    MissingVersion,
    MissingFileList,
    SizeFieldNotFound,
    MarkerNotFound,
    SizeFieldTooLong,
};

pub fn readVersion(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var cfg = try image_cfg.load(a, io, path);
    defer cfg.deinit();
    const root = image_cfg.asObject(cfg.root().*) orelse return Error.BadConfig;
    const image = image_cfg.getObj(root, "image") orelse return Error.MissingVersion;
    const info = image_cfg.getObj(image, "info") orelse return Error.MissingVersion;
    const ver = image_cfg.getStr(info, "version") orelse return Error.MissingVersion;
    return a.dupe(u8, ver);
}

/// 把第 3 行替换为 `version = "<version>";`（与 mkcpio.py 的 lines[2] 一致）。
pub fn setVersionLine(a: std.mem.Allocator, text: []const u8, version: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(a, line);
    if (lines.items.len < 3) return Error.BadConfig;

    const new_line = try std.fmt.allocPrint(a, "version = \"{s}\";", .{version});
    defer a.free(new_line);
    lines.items[2] = new_line;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (lines.items, 0..) |line, i| {
        if (i > 0) try out.append(a, '\n');
        try out.appendSlice(a, line);
    }
    return out.toOwnedSlice(a);
}

/// 解析 `[file]` 段的文件名（每行 `name:type;`，取第一个冒号前的内容）。
pub fn parseFileList(a: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var in_file = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_file = std.mem.eql(u8, line, "[file]");
            continue;
        }
        if (!in_file) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len > 0) try list.append(a, name);
    }
    if (list.items.len == 0) return Error.MissingFileList;
    return list;
}

/// 生成 512 字节 ota_info.bin（mkenvimage 默认非冗余模式）。
pub fn buildOtaInfo(a: std.mem.Allocator, cfg_text: []const u8) ![]u8 {
    const data = try env_image.textToData(a, cfg_text, "");
    defer a.free(data);
    return env_image.build(a, data, .{ .size = 512 });
}

/// 在归档中 `ota_info.bin` 之后 512 字节内回填 `size = "..."`。
pub fn patchSize(a: std.mem.Allocator, archive: []u8, total: usize) !void {
    const marker = "ota_info.bin";
    const idx = std.mem.find(u8, archive, marker) orelse return Error.MarkerNotFound;
    const search_start = idx + marker.len;
    const search_end = @min(archive.len, search_start + 512);
    const region = archive[search_start..search_end];
    const s = std.mem.find(u8, region, "size = \"") orelse return Error.SizeFieldNotFound;
    const val_start = search_start + s + "size = \"".len;
    const close_rel = std.mem.findScalar(u8, archive[val_start..search_end], '"') orelse return Error.SizeFieldNotFound;
    const val_end = val_start + close_rel;
    const width = val_end - val_start;

    const value = try std.fmt.allocPrint(a, "{d}", .{total});
    defer a.free(value);

    if (value.len <= width) {
        @memset(archive[val_start..val_end], ' ');
        @memcpy(archive[val_start..][0..value.len], value);
        return;
    }

    // 参考脚本在字段变长时把所在 512 字节块截断；这里保持归档总长不变。
    const delta = value.len - width;
    if (val_end + delta > archive.len) return Error.SizeFieldTooLong;
    var i: usize = archive.len - delta;
    while (i > val_end) {
        i -= 1;
        archive[i + delta] = archive[i];
    }
    @memcpy(archive[val_start..][0..value.len], value);
}

fn readInputFile(a: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ dir, name });
    defer a.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
}

fn buildArchive(
    a: std.mem.Allocator,
    io: std.Io,
    names: []const []const u8,
    ota_info: []const u8,
    input_dir: []const u8,
    mtime: u32,
) ![]u8 {
    var entries: std.ArrayList(cpio.Entry) = .empty;
    defer entries.deinit(a);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |d| a.free(d);
        owned.deinit(a);
    }

    for (names) |name| {
        const data = if (std.mem.eql(u8, name, "ota_info.bin"))
            ota_info
        else blk: {
            const d = try readInputFile(a, io, input_dir, name);
            try owned.append(a, d);
            break :blk d;
        };
        try entries.append(a, .{ .name = name, .data = data, .mtime = mtime });
    }
    return cpio.build(a, entries.items, .crc);
}

pub fn run(a: std.mem.Allocator, io: std.Io, opt: Options) !Result {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, opt.ota_cfg, a, .unlimited);
    defer a.free(raw);

    const version = try readVersion(a, io, opt.image_cfg);
    errdefer a.free(version);
    const cfg_text = try setVersionLine(a, raw, version);
    errdefer a.free(cfg_text);
    const ota_info = try buildOtaInfo(a, cfg_text);
    errdefer a.free(ota_info);
    var names = try parseFileList(a, cfg_text);
    defer names.deinit(a);

    try std.Io.Dir.cwd().createDirPath(io, opt.out_dir);
    const cfg_out = try std.fs.path.join(a, &.{ opt.out_dir, "ota-subimgs.cfg" });
    defer a.free(cfg_out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_out, .data = cfg_text });
    const info_out = try std.fs.path.join(a, &.{ opt.out_dir, "ota_info.bin" });
    defer a.free(info_out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = info_out, .data = ota_info });

    const archive = try buildArchive(a, io, names.items, ota_info, opt.input_dir, opt.mtime);
    errdefer a.free(archive);
    try patchSize(a, archive, archive.len);

    const cpio_out = try std.fs.path.join(a, &.{ opt.out_dir, "ota.cpio" });
    defer a.free(cpio_out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cpio_out, .data = archive });

    return .{
        .version = version,
        .cfg_text = cfg_text,
        .ota_info = ota_info,
        .archive = archive,
        .files = names.items.len,
    };
}

test "ota：版本行替换与文件列表" {
    const a = std.testing.allocator;
    const text = "[image]\nsize = \"\";\nversion = \"1.0.0\";\n\n[file]\nota_info.bin:file;\nd12p_os.itb:os;\n";
    const out = try setVersionLine(a, text, "2.3.4");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "version = \"2.3.4\";") != null);

    var names = try parseFileList(a, out);
    defer names.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("ota_info.bin", names.items[0]);
    try std.testing.expectEqualStrings("d12p_os.itb", names.items[1]);
}

test "ota：size 字段回填" {
    const a = std.testing.allocator;
    var buf: [64]u8 = @splat('x');
    const marker = "ota_info.bin";
    @memcpy(buf[0..marker.len], marker);
    const field = "size = \"\";";
    @memcpy(buf[16..][0..field.len], field);
    try patchSize(a, &buf, 12345);
    try std.testing.expect(std.mem.find(u8, &buf, "size = \"12345\";") != null);
}
