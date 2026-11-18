//! littlefs 镜像生成 —— 主机侧编排对应 `tools/scripts/makelittlefs.py` + `mklittlefs`。
//!
//! 复用上游 littlefs 2.5 实现（`third_party/littlefs`，BSD-1-Clause）：
//! Zig 侧只负责参数解析、目录遍历、内存块设备与最终镜像裁剪，格式/元数据
//! 语义完全交给上游，避免自写格式产生与设备端不兼容的镜像。
const std = @import("std");
const image_cfg = @import("image_cfg.zig");

const c = @import("lfs");

pub const Error = error{
    BadArgument,
    InputNotDir,
    LfsFormat,
    LfsMount,
    LfsMkdir,
    LfsFileOpen,
    LfsFileWrite,
    LfsFileClose,
    LfsSetAttr,
    LfsUnmount,
    MissingPartitionSize,
};

pub const Options = struct {
    input_dir: []const u8,
    output: []const u8,
    block_size: u32,
    page_size: u32 = 256,
    image_size: ?u32 = null,
    reserved: ?u32 = null,
    add_all: bool = false,
};

const Flash = struct {
    data: []u8,
    block_size: u32,
};

fn flashRead(
    cfg: [*c]const c.struct_lfs_config,
    block: c.lfs_block_t,
    off: c.lfs_off_t,
    buffer: ?*anyopaque,
    size: c.lfs_size_t,
) callconv(.c) c_int {
    const self: *Flash = @ptrCast(@alignCast(cfg.*.context.?));
    const dst = @as([*]u8, @ptrCast(buffer.?))[0..size];
    const base: usize = @as(usize, block) * self.block_size + off;
    if (base + size > self.data.len) return -1;
    @memcpy(dst, self.data[base .. base + size]);
    return 0;
}

fn flashProg(
    cfg: [*c]const c.struct_lfs_config,
    block: c.lfs_block_t,
    off: c.lfs_off_t,
    buffer: ?*const anyopaque,
    size: c.lfs_size_t,
) callconv(.c) c_int {
    const self: *Flash = @ptrCast(@alignCast(cfg.*.context.?));
    const src = @as([*]const u8, @ptrCast(buffer.?))[0..size];
    const base: usize = @as(usize, block) * self.block_size + off;
    if (base + size > self.data.len) return -1;
    @memcpy(self.data[base .. base + size], src);
    return 0;
}

fn flashErase(cfg: [*c]const c.struct_lfs_config, block: c.lfs_block_t) callconv(.c) c_int {
    const self: *Flash = @ptrCast(@alignCast(cfg.*.context.?));
    const base: usize = @as(usize, block) * self.block_size;
    // 与 mklittlefs 的 flash 回调保持一致：擦除为 0x00，空白区为初始 0xFF。
    @memset(self.data[base .. base + self.block_size], 0);
    return 0;
}

fn flashSync(_: [*c]const c.struct_lfs_config) callconv(.c) c_int {
    return 0;
}

fn lfsConfig(flash: *Flash) c.struct_lfs_config {
    var cfg: c.struct_lfs_config = std.mem.zeroes(c.struct_lfs_config);
    cfg.context = flash;
    cfg.read = flashRead;
    cfg.prog = flashProg;
    cfg.erase = flashErase;
    cfg.sync = flashSync;
    cfg.read_size = 64;
    cfg.prog_size = 64;
    cfg.block_size = flash.block_size;
    cfg.block_count = @intCast(flash.data.len / flash.block_size);
    cfg.block_cycles = 16;
    cfg.cache_size = 64;
    cfg.lookahead_size = 64;
    return cfg;
}

fn check(ret: c_int, comptime err: Error) Error!void {
    if (ret < 0) return err;
}

fn setTimes(fs: *c.lfs_t, a: std.mem.Allocator, path: []const u8, mtime_sec: u64) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var sec: u32 = @intCast(@min(mtime_sec, std.math.maxInt(u32)));
    try check(c.lfs_setattr(fs, z, 't', &sec, @sizeOf(u32)), Error.LfsSetAttr);
    try check(c.lfs_setattr(fs, z, 'c', &sec, @sizeOf(u32)), Error.LfsSetAttr);
}

fn mkdirIfNeeded(fs: *c.lfs_t, a: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return;
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    _ = c.lfs_mkdir(fs, z);
}

fn addFile(
    fs: *c.lfs_t,
    a: std.mem.Allocator,
    io: std.Io,
    host_path: []const u8,
    image_path: []const u8,
    mtime_sec: u64,
) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, host_path, a, .unlimited);
    defer a.free(data);

    const z = try a.dupeSentinel(u8, image_path, 0);
    defer a.free(z);

    var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try check(c.lfs_file_open(fs, &file, z, c.LFS_O_CREAT | c.LFS_O_TRUNC | c.LFS_O_WRONLY), Error.LfsFileOpen);

    var written: usize = 0;
    while (written < data.len) {
        const n = c.lfs_file_write(fs, &file, data.ptr + written, @intCast(data.len - written));
        if (n <= 0) {
            _ = c.lfs_file_close(fs, &file);
            return Error.LfsFileWrite;
        }
        written += @intCast(n);
    }
    try check(c.lfs_file_close(fs, &file), Error.LfsFileClose);
    try setTimes(fs, a, image_path, mtime_sec);
}

fn isIgnored(name: []const u8, add_all: bool) bool {
    if (add_all) return false;
    return std.mem.eql(u8, name, ".DS_Store") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".gitignore") or
        std.mem.eql(u8, name, ".gitmodules");
}

fn addTree(
    fs: *c.lfs_t,
    a: std.mem.Allocator,
    io: std.Io,
    host_dir: []const u8,
    image_dir: []const u8,
    add_all: bool,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, host_dir, .{ .iterate = true }) catch return Error.InputNotDir;
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (isIgnored(entry.name, add_all)) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names.items) |name| {
        const host_path = try std.fs.path.join(a, &.{ host_dir, name });
        defer a.free(host_path);
        const image_path = if (image_dir.len == 0)
            try a.dupe(u8, name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ image_dir, name });
        defer a.free(image_path);

        const st = std.Io.Dir.cwd().statFile(io, host_path, .{}) catch continue;
        const sec: u64 = if (st.mtime.nanoseconds > 0)
            @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s))
        else
            0;

        switch (st.kind) {
            .directory => {
                try mkdirIfNeeded(fs, a, image_path);
                setTimes(fs, a, image_path, sec) catch {};
                try addTree(fs, a, io, host_path, image_path, add_all);
            },
            .file => try addFile(fs, a, io, host_path, image_path, sec),
            else => {},
        }
    }
}

/// 从 `partition_file_list.h` 找到与输出文件同名的分区大小。
fn partitionSizeForOutput(a: std.mem.Allocator, io: std.Io, output: []const u8) !?u64 {
    const dir = std.fs.path.dirname(output) orelse ".";
    const list_path = try std.fs.path.join(a, &.{ dir, "partition_file_list.h" });
    defer a.free(list_path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, list_path, a, .unlimited) catch return null;
    defer a.free(text);
    const base = std.fs.path.basename(output);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var cols: [3][]const u8 = undefined;
        var ci: usize = 0;
        var cit = std.mem.splitScalar(u8, line, ',');
        while (cit.next()) |part| : (ci += 1) {
            if (ci < 3) cols[ci] = std.mem.trim(u8, part, " \t\r");
        }
        if (ci < 3) continue;
        var name = cols[1];
        for ([_][]const u8{ ".sparse.enc", ".sparse", ".enc" }) |suffix| {
            if (std.mem.endsWith(u8, name, suffix)) {
                name = name[0 .. name.len - suffix.len];
                break;
            }
        }
        if (!std.mem.eql(u8, name, base)) continue;
        return std.fmt.parseInt(u64, cols[2], 10) catch null;
    }
    return null;
}

fn isNftlPart(a: std.mem.Allocator, io: std.Io, output: []const u8) bool {
    const dir = std.fs.path.dirname(output) orelse ".";
    const path = std.fs.path.join(a, &.{ dir, "partition.json" }) catch return false;
    defer a.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return false;
    defer a.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return false;
    defer parsed.deinit();
    const root = image_cfg.asObject(parsed.value) orelse return false;
    const partitions = image_cfg.getObj(root, "partitions") orelse return false;
    const nftl = image_cfg.getStr(partitions, "nftl") orelse return false;

    const base = std.fs.path.basename(output);
    const dot = std.mem.findScalar(u8, base, '.') orelse base.len;
    const prefix = std.fmt.allocPrint(a, "{s}:", .{base[0..dot]}) catch return false;
    defer a.free(prefix);
    return std.mem.find(u8, nftl, prefix) != null;
}

fn alignUp(value: u64, alignment: u64) u64 {
    if (alignment == 0) return value;
    return alignment * ((value + alignment - 1) / alignment);
}

fn resourceSize(a: std.mem.Allocator, io: std.Io, root: []const u8, block: u64) !u64 {
    var total: u64 = 0;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(a, &.{ root, entry.path });
        defer a.free(full);
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        total += alignUp(st.size, block);
    }
    return total;
}

fn trimTrailingFf(a: std.mem.Allocator, io: std.Io, path: []const u8, alignment: usize) !u64 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    defer a.free(data);
    const original = data.len;
    var last: ?usize = null;
    var i = data.len;
    while (i > 0) {
        i -= 1;
        if (data[i] != 0xFF) {
            last = i;
            break;
        }
    }
    var size: usize = if (last) |p| alignUp(p + 1, alignment) else alignment;
    if (size > original) size = original;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data[0..size] });
    return size;
}

pub const Result = struct {
    image_size: u64,
    trimmed_size: u64,
};

pub fn build(a: std.mem.Allocator, io: std.Io, opt: Options) !Result {
    if (opt.block_size == 0) return Error.BadArgument;

    var input = opt.input_dir;
    var fallback: ?[]u8 = null;
    defer if (fallback) |f| a.free(f);

    const dir = std.fs.path.dirname(opt.output) orelse ".";
    const sibling = try std.fs.path.join(a, &.{ dir, input });
    defer a.free(sibling);
    if (std.Io.Dir.cwd().openDir(io, sibling, .{ .iterate = true })) |d| {
        d.close(io);
        input = sibling;
    } else |_| {
        if (std.Io.Dir.cwd().openDir(io, input, .{ .iterate = true })) |d| {
            d.close(io);
        } else |_| {
            // 与参考一致：输入目录不存在时使用空的 `empty` 目录。
            const empty = try std.fs.path.join(a, &.{ dir, "empty" });
            fallback = empty;
            std.Io.Dir.cwd().createDir(io, empty, .default_dir) catch {};
            input = empty;
        }
    }

    var image_size: u64 = 0;
    if (opt.image_size) |s| {
        image_size = s;
    } else if (try partitionSizeForOutput(a, io, opt.output)) |s| {
        image_size = s;
    }
    if (image_size == 0) {
        image_size = try resourceSize(a, io, input, opt.block_size);
        image_size += 4 * opt.block_size;
    }

    if (isNftlPart(a, io, opt.output)) {
        const blocks: u64 = if (opt.reserved) |r| (if (r > 50) r + 1 else 51) else 51;
        const reserved = blocks * 64 * 2048;
        if (image_size <= reserved) return Error.MissingPartitionSize;
        image_size -= reserved;
        image_size = alignUp(image_size, opt.block_size);
    }
    image_size = alignUp(image_size, opt.block_size);
    if (image_size == 0 or image_size > std.math.maxInt(u32)) return Error.BadArgument;

    const buf = try a.alloc(u8, @intCast(image_size));
    defer a.free(buf);
    @memset(buf, 0xFF);

    var flash = Flash{ .data = buf, .block_size = opt.block_size };
    var cfg = lfsConfig(&flash);
    var fs: c.lfs_t = std.mem.zeroes(c.lfs_t);
    try check(c.lfs_format(&fs, &cfg), Error.LfsFormat);
    try check(c.lfs_mount(&fs, &cfg), Error.LfsMount);
    defer _ = c.lfs_unmount(&fs);

    try addTree(&fs, a, io, input, "", opt.add_all);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opt.output, .data = buf });
    const trimmed = try trimTrailingFf(a, io, opt.output, opt.block_size);
    return .{ .image_size = image_size, .trimmed_size = trimmed };
}

test "littlefs：空目录生成可挂载镜像" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const out = try std.fs.path.join(a, &.{ root, "empty.lfs" });
    defer a.free(out);

    const result = try build(a, std.testing.io, .{
        .input_dir = root,
        .output = out,
        .block_size = 4096,
        .image_size = 64 * 1024,
    });
    try std.testing.expect(result.trimmed_size >= 4096);

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out, a, .unlimited);
    defer a.free(data);
    try std.testing.expect(data.len >= 8192);
    // 超级块魔数 "littlefs"
    try std.testing.expectEqualStrings("littlefs", data[8..16]);
}
