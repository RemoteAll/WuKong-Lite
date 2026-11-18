//! 生成带 PBP 头的预启动程序 —— 对应参考工程 `tools/scripts/mk_prebootprog.py`。
//!
//! PBP 布局（小端）：
//!   0x00 magic[4]（默认 "PBP2"）
//!   0x04 checksum（全镜像 32 位字求和取反，使总和为 0）
//!   0x08 head_ver = 0x00010001
//!   0x0C sign_offset = 256 对齐后的总长度
//!   0x10 pad[16]
//!   0x20 PBP 数据（可选 PNK 派生 AES-128-ECB 加密）
const std = @import("std");
const des = @import("des.zig");

pub const Error = error{
    BadMagic,
    BadPnk,
    InputTooLarge,
    ChecksumMismatch,
};

pub const Options = struct {
    input: []const u8,
    output: []const u8,
    magic: []const u8 = "PBP2",
    pnk: ?[]const u8 = null,
};

pub const Result = struct {
    input_size: u64,
    padded_size: u64,
    encrypted: bool,
};

fn roundUp(value: u64, alignment: u64) u64 {
    return alignment * ((value + alignment - 1) / alignment);
}

fn checksum(bytes: []const u8) u32 {
    var total: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        total +%= std.mem.readInt(u32, bytes[i..][0..4], .little);
    }
    return ~total;
}

/// PNK（8 字节 DES 密钥）→ AES-128 密钥：DES-ECB 加密 4 份原始长度。
pub fn deriveAesKey(pnk: [8]u8, input_len: u32) [16]u8 {
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, input_len, .little);
    var block: [16]u8 = undefined;
    @memcpy(block[0..4], &seed);
    @memcpy(block[4..8], &seed);
    @memcpy(block[8..12], &seed);
    @memcpy(block[12..16], &seed);
    var b0: [8]u8 = block[0..8].*;
    var b1: [8]u8 = block[8..16].*;
    des.encryptBlock(pnk, &b0);
    des.encryptBlock(pnk, &b1);
    var key: [16]u8 = undefined;
    @memcpy(key[0..8], &b0);
    @memcpy(key[8..16], &b1);
    return key;
}

fn aesEcbEncrypt(data: []u8, key: [16]u8) void {
    var ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        var block: [16]u8 = data[i..][0..16].*;
        ctx.encrypt(data[i..][0..16], &block);
    }
}

pub fn build(a: std.mem.Allocator, io: std.Io, opt: Options) !Result {
    if (opt.magic.len != 4) return Error.BadMagic;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, opt.input, a, .unlimited);
    defer a.free(input);
    if (input.len > std.math.maxInt(u32)) return Error.InputTooLarge;

    const total = roundUp(32 + @as(u64, input.len), 256);
    const data_len: usize = @intCast(total - 32);
    const out = try a.alloc(u8, @intCast(total));
    defer a.free(out);
    @memset(out, 0);
    @memcpy(out[32..][0..input.len], input);

    var encrypted = false;
    if (opt.pnk) |pnk_path| {
        const pnk_data = std.Io.Dir.cwd().readFileAlloc(io, pnk_path, a, .unlimited) catch return Error.BadPnk;
        defer a.free(pnk_data);
        if (pnk_data.len != 8) return Error.BadPnk;
        const key = deriveAesKey(pnk_data[0..8].*, @intCast(input.len));
        aesEcbEncrypt(out[32..][0..data_len], key);
        encrypted = true;
    }

    @memcpy(out[0..4], opt.magic);
    // checksum 先写 0，head_ver / sign_offset / pad
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], 0x00010001, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(total), .little);
    @memset(out[16..32], 0);

    const cs = checksum(out);
    std.mem.writeInt(u32, out[4..8], cs, .little);
    if (checksum(out) != 0) return error.ChecksumMismatch;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opt.output, .data = out });
    return .{ .input_size = input.len, .padded_size = total, .encrypted = encrypted };
}

test "pbp：头部、256 对齐与校验和" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const in_path = try std.fs.path.join(a, &.{ root, "pbp.bin" });
    defer a.free(in_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = in_path, .data = "abc" });
    const out_path = try std.fs.path.join(a, &.{ root, "pbp2.bin" });
    defer a.free(out_path);

    const r = try build(a, io, .{ .input = in_path, .output = out_path });
    try std.testing.expectEqual(@as(u64, 3), r.input_size);
    try std.testing.expectEqual(@as(u64, 256), r.padded_size);
    try std.testing.expect(!r.encrypted);

    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, a, .unlimited);
    defer a.free(out);
    try std.testing.expectEqualStrings("PBP2", out[0..4]);
    try std.testing.expectEqual(@as(u32, 0x00010001), std.mem.readInt(u32, out[8..12], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, out[12..16], .little));
    try std.testing.expectEqualStrings("abc", out[32..35]);
    try std.testing.expectEqual(@as(u32, 0), checksum(out));
}

test "pbp：AES-128-ECB NIST 向量" {
    var data = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    };
    aesEcbEncrypt(&data, .{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F });
    try std.testing.expectEqualSlices(u8, &.{
        0x69, 0xC4, 0xE0, 0xD8, 0x6A, 0x7B, 0x04, 0x30,
        0xD8, 0xCD, 0xB7, 0x80, 0x70, 0xB4, 0xC5, 0x5A,
    }, &data);
}

test "pbp：PNK 派生 AES 密钥并加密" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const in_path = try std.fs.path.join(a, &.{ root, "plain.bin" });
    defer a.free(in_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = in_path, .data = "0123456789abcdef" });
    const pnk_path = try std.fs.path.join(a, &.{ root, "pnk.bin" });
    defer a.free(pnk_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pnk_path, .data = &.{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF } });
    const out_path = try std.fs.path.join(a, &.{ root, "enc.bin" });
    defer a.free(out_path);

    const r = try build(a, io, .{ .input = in_path, .output = out_path, .pnk = pnk_path });
    try std.testing.expect(r.encrypted);
    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, a, .unlimited);
    defer a.free(out);
    try std.testing.expect(!std.mem.eql(u8, out[32..48], "0123456789abcdef"));
    try std.testing.expectEqual(@as(u32, 0), checksum(out));
}
