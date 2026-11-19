//! 固件加密（`mk_image.py` 的 `data_crypt` 段等价实现）—— **调用厂商 `firmware_security_encrypt`**。
//!
//! 参考 `mk_image.py::data_crypt_create_image()` 的调用方式：
//!   `firmware_security_encrypt --key <k> [--nonce <n>] [--tweak <t>] --infile <in> --outfile <out>`
//! 工具查找：`{script_dir}/firmware_security_encrypt[.exe]`，找不到则用 PATH 名。
//! 加密算法在 SDK 内**无源码**（只有预编译二进制），因此这里与 C 构建保持同样的用法：
//! 调同一个工具、同样的参数、同样的产物路径。
const std = @import("std");
const ext = @import("ext_tool.zig");

pub const Error = error{
    ToolNotFound,
    ToolFailed,
};

pub const Options = struct {
    key: []const u8,
    nonce: ?[]const u8 = null,
    tweak: ?[]const u8 = null,
    input: []const u8,
    output: []const u8,
    tool_dir: ?[]const u8 = null,
};

/// 拼参数（顺序与 `data_crypt_create_image()` 完全一致；长选项）。
pub fn buildArgv(
    allocator: std.mem.Allocator,
    tool: []const u8,
    opts: Options,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit(allocator);
    }
    const dupe = struct {
        fn add(al: std.mem.Allocator, l: *std.ArrayList([]const u8), s: []const u8) !void {
            try l.append(al, try al.dupe(u8, s));
        }
    };

    try dupe.add(allocator, &list, tool);
    try dupe.add(allocator, &list, "--key");
    try dupe.add(allocator, &list, opts.key);
    if (opts.nonce) |n| {
        try dupe.add(allocator, &list, "--nonce");
        try dupe.add(allocator, &list, n);
    }
    if (opts.tweak) |t| {
        try dupe.add(allocator, &list, "--tweak");
        try dupe.add(allocator, &list, t);
    }
    try dupe.add(allocator, &list, "--infile");
    try dupe.add(allocator, &list, opts.input);
    try dupe.add(allocator, &list, "--outfile");
    try dupe.add(allocator, &list, opts.output);
    return list.toOwnedSlice(allocator);
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
) !void {
    const tool = try ext.resolve(allocator, io, opts.tool_dir, "firmware_security_encrypt");
    defer allocator.free(tool);

    const argv = try buildArgv(allocator, tool, opts);
    defer freeArgv(allocator, argv);

    const outcome = ext.run(allocator, io, argv) catch |err| switch (err) {
        error.FileNotFound => return Error.ToolNotFound,
        else => return err,
    };
    defer outcome.deinit(allocator);
    if (outcome.code != 0) return Error.ToolFailed;
}

test "fwenc.buildArgv：长选项顺序与 data_crypt_create_image 一致" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, "firmware_security_encrypt.exe", .{
        .key = "keys/aes.key",
        .nonce = "keys/nonce.bin",
        .tweak = "0x3039",
        .input = "in.bin",
        .output = "out.bin",
    });
    defer freeArgv(allocator, argv);

    const expect = [_][]const u8{
        "firmware_security_encrypt.exe",
        "--key",
        "keys/aes.key",
        "--nonce",
        "keys/nonce.bin",
        "--tweak",
        "0x3039",
        "--infile",
        "in.bin",
        "--outfile",
        "out.bin",
    };
    try std.testing.expectEqual(expect.len, argv.len);
    for (expect, argv) |e, got| try std.testing.expectEqualStrings(e, got);
}

test "fwenc.buildArgv：无 nonce/tweak 时不出现对应选项" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, "fwenc", .{
        .key = "k.bin",
        .input = "i.bin",
        .output = "o.bin",
    });
    defer freeArgv(allocator, argv);

    // tool, --key, k, --infile, i, --outfile, o
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    for (argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "--nonce"));
}
