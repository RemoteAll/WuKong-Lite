//! UFFS 镜像（`makeuffs.py` 等价实现）—— **调用厂商 `mkuffs` 工具**。
//!
//! 参考 `tools/scripts/makeuffs.py`：
//!   1. 输入目录：优先 `dirname(outfile)/inputdir`（存在则用之）；
//!   2. 分区大小：读 `dirname(outfile)/partition_file_list.h` 的第 3 列
//!      （匹配规则：`imgname == name` 或 `imgname in name`）；
//!   3. `partblkcnt = partsize / (pagesize * blockpagecount)`；
//!   4. 执行 `mkuffs -t <partblkcnt> -p <page> -b <blockpages> -s <oob>
//!              -x auto -o 0 -f <outfile> -d <inputdir>`。
//!
//! UFFS 核心源码不在 SDK（只有 `mkuffs.exe` 与 `drv/spinand/uffs.c` 移植层），
//! 因此这里与 C 构建保持**同样的用法**：调用同一个工具、同样的参数。
const std = @import("std");
const ext = @import("ext_tool.zig");

pub const Error = error{
    ToolNotFound,
    ToolFailed,
    MissingPartitionSize,
    MissingInputDir,
};

pub const Options = struct {
    /// 输入目录（未带 outfile 同目录优先级）
    input_dir: []const u8,
    /// 输出镜像路径
    out_file: []const u8,
    /// 每块页数（对应 `-g/--blockpagecount`）
    block_pages: u64,
    /// 页大小（对应 `-p/--pagesize`）
    page_size: u64,
    /// OOB 大小（对应 `-s/--oobsize`）
    oob_size: u64,
    /// 工具目录（`-t/--tooldir`），空则用 PATH
    tool_dir: ?[]const u8 = null,
};

/// `partblkcnt = partsize / (pagesize * blockpagecount)`（参考整数除法，向下取整）。
pub fn partBlockCount(part_size: u64, page_size: u64, block_pages: u64) !u64 {
    const blk = std.math.mul(u64, page_size, block_pages) catch return error.MissingPartitionSize;
    if (blk == 0) return error.MissingPartitionSize;
    return part_size / blk;
}

/// 从 `partition_file_list.h` 取该镜像的分区大小（`<partition>,<file>,<size>`）。
pub fn partSizeFromList(
    allocator: std.mem.Allocator,
    io: std.Io,
    list_path: []const u8,
    img_name: []const u8,
) !u64 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, list_path, allocator, .unlimited) catch
        return Error.MissingPartitionSize;
    defer allocator.free(text);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var cols: [3][]const u8 = undefined;
        var ci: usize = 0;
        var cit = std.mem.splitScalar(u8, line, ',');
        while (cit.next()) |part| : (ci += 1) {
            if (ci < 3) cols[ci] = std.mem.trim(u8, part, " \t\r\"");
        }
        if (ci < 3) continue;
        const name = std.mem.trim(u8, cols[1], " \t\r\"*");
        if (std.mem.eql(u8, name, img_name) or std.mem.indexOf(u8, name, img_name) != null) {
            return std.fmt.parseInt(u64, cols[2], 0) catch Error.MissingPartitionSize;
        }
    }
    return Error.MissingPartitionSize;
}

/// 拼 `mkuffs` 参数（顺序与 `makeuffs.py` 完全一致）。
pub fn buildArgv(
    allocator: std.mem.Allocator,
    tool: []const u8,
    opts: Options,
    part_blocks: u64,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit(allocator);
    }
    const owned = struct {
        fn add(al: std.mem.Allocator, l: *std.ArrayList([]const u8), s: []const u8) !void {
            try l.append(al, try al.dupe(u8, s));
        }
    };

    try owned.add(allocator, &list, tool);
    try list.append(allocator, try std.fmt.allocPrint(allocator, "-t", .{}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{part_blocks}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "-p", .{}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{opts.page_size}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "-b", .{}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{opts.block_pages}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "-s", .{}));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{opts.oob_size}));
    try owned.add(allocator, &list, "-x");
    try owned.add(allocator, &list, "auto");
    try list.append(allocator, try std.fmt.allocPrint(allocator, "-o", .{}));
    try owned.add(allocator, &list, "0");
    try owned.add(allocator, &list, "-f");
    try owned.add(allocator, &list, opts.out_file);
    try owned.add(allocator, &list, "-d");
    try owned.add(allocator, &list, opts.input_dir);
    return list.toOwnedSlice(allocator);
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

pub const Result = struct { part_blocks: u64, part_size: u64, output: []u8 };

/// 生成 UFFS 镜像。`log` 用于透传工具输出摘要（失败时）。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
) !Result {
    // 1) 输入目录优先级：dirname(outfile)/inputdir
    const dir = std.fs.path.dirname(opts.out_file) orelse ".";
    const preferred = try std.fs.path.join(allocator, &.{ dir, opts.input_dir });
    defer allocator.free(preferred);
    const input_dir: []const u8 = blk: {
        if (std.Io.Dir.cwd().statFile(io, preferred, .{})) |_| break :blk preferred else |_| {}
        break :blk opts.input_dir;
    };

    // 2) 分区大小
    const base = std.fs.path.basename(opts.out_file);
    const list_path = try std.fs.path.join(allocator, &.{ dir, "partition_file_list.h" });
    defer allocator.free(list_path);
    const part_size = try partSizeFromList(allocator, io, list_path, base);
    const part_blocks = try partBlockCount(part_size, opts.page_size, opts.block_pages);

    // 3) 工具 + 参数
    const tool = try ext.resolve(allocator, io, opts.tool_dir, "mkuffs");
    defer allocator.free(tool);
    var opts2 = opts;
    opts2.input_dir = input_dir;
    const argv = try buildArgv(allocator, tool, opts2, part_blocks);
    defer freeArgv(allocator, argv);

    const outcome = ext.run(allocator, io, argv) catch |err| switch (err) {
        error.FileNotFound => return Error.ToolNotFound,
        else => return err,
    };
    defer outcome.deinit(allocator);
    if (outcome.code != 0) return Error.ToolFailed;

    const out = try allocator.dupe(u8, opts.out_file);
    return .{ .part_blocks = part_blocks, .part_size = part_size, .output = out };
}

test "uffs.partBlockCount：与参考整数除法一致" {
    // 16 MiB 分区、2048 B 页、64 页/块 → 2048*64=131072 → 16777216/131072 = 128
    try std.testing.expectEqual(@as(u64, 128), try partBlockCount(0x1000000, 2048, 64));
    // 除不尽向下取整
    try std.testing.expectEqual(@as(u64, 2), try partBlockCount(300000, 2048, 64));
    try std.testing.expectError(error.MissingPartitionSize, partBlockCount(4096, 0, 64));
}

test "uffs.buildArgv：参数顺序与 makeups.py 一致" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, "mkuffs.exe", .{
        .input_dir = "rootfs",
        .out_file = "out/data.uffs",
        .block_pages = 64,
        .page_size = 2048,
        .oob_size = 64,
    }, 128);
    defer freeArgv(allocator, argv);

    const expect = [_][]const u8{
        "mkuffs.exe", "-t",   "128", "-p", "2048", "-b",            "64", "-s",     "64",
        "-x",         "auto", "-o",  "0",  "-f",   "out/data.uffs", "-d", "rootfs",
    };
    try std.testing.expectEqual(expect.len, argv.len);
    for (expect, argv) |e, got| try std.testing.expectEqualStrings(e, got);
}
