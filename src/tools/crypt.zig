//! AES-128-CBC 工具 —— 对应 Luban-Lite 镜像加密流程中的对称加密部分
//! （`firmware_security_encrypt` 使用 AES-CBC + IV）。
//!
//! 仅实现纯数据加/解密，不处理密钥管理：
//!   * 输入长度必须是 16 的整数倍（`--pad` 可补 padding）；
//!   * 与 `openssl enc -aes-128-cbc -nopad -K ... -iv ...` 输出完全一致。
const std = @import("std");

pub const BlockSize = 16;

pub const Pad = enum { none, zero, pkcs7 };

fn xorBlock(dst: *[BlockSize]u8, block: *const [BlockSize]u8) void {
    for (dst, block) |*d, b| d.* ^= b;
}

fn padData(allocator: std.mem.Allocator, data: []const u8, pad: Pad) ![]u8 {
    switch (pad) {
        .none => {
            if (data.len % BlockSize != 0) return error.LengthNotAligned;
            return allocator.dupe(u8, data);
        },
        .zero => {
            const len = std.mem.alignForward(usize, data.len, BlockSize);
            const out = try allocator.alloc(u8, len);
            @memset(out, 0);
            @memcpy(out[0..data.len], data);
            return out;
        },
        .pkcs7 => {
            const padding: usize = BlockSize - (data.len % BlockSize);
            const out = try allocator.alloc(u8, data.len + padding);
            @memcpy(out[0..data.len], data);
            @memset(out[data.len..], @intCast(padding));
            return out;
        },
    }
}

/// AES-128-CBC 加密（返回调用者拥有的缓冲）。
pub fn encrypt(
    allocator: std.mem.Allocator,
    data: []const u8,
    key: [16]u8,
    iv: [16]u8,
    pad: Pad,
) ![]u8 {
    const input = try padData(allocator, data, pad);
    defer allocator.free(input);

    const out = try allocator.alloc(u8, input.len);
    errdefer allocator.free(out);

    var ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var prev: [BlockSize]u8 = iv;
    var i: usize = 0;
    while (i < input.len) : (i += BlockSize) {
        var block: [BlockSize]u8 = undefined;
        @memcpy(&block, input[i..][0..BlockSize]);
        xorBlock(&block, &prev);
        ctx.encrypt(out[i..][0..BlockSize], &block);
        @memcpy(&prev, out[i..][0..BlockSize]);
    }
    return out;
}

/// AES-128-CBC 解密（输入必须是 16 的整数倍）。
pub fn decrypt(
    allocator: std.mem.Allocator,
    data: []const u8,
    key: [16]u8,
    iv: [16]u8,
) ![]u8 {
    if (data.len % BlockSize != 0) return error.LengthNotAligned;
    const out = try allocator.alloc(u8, data.len);
    errdefer allocator.free(out);

    var ctx = std.crypto.core.aes.Aes128.initDec(key);
    var prev: [BlockSize]u8 = iv;
    var i: usize = 0;
    while (i < data.len) : (i += BlockSize) {
        var block: [BlockSize]u8 = undefined;
        ctx.decrypt(&block, data[i..][0..BlockSize]);
        xorBlock(&block, &prev);
        @memcpy(out[i..][0..BlockSize], &block);
        @memcpy(&prev, data[i..][0..BlockSize]);
    }
    return out;
}

/// 解析 32 位十六进制字符串为 16 字节密钥/IV。
pub fn parseHex16(text: []const u8) ![16]u8 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    const hex = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s[2..] else s;
    if (hex.len != 32) return error.InvalidHex16;
    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHex16;
    return out;
}

test "AES-128-CBC NIST SP800-38A 向量" {
    const allocator = std.testing.allocator;
    const key = try parseHex16("2b7e151628aed2a6abf7158809cf4f3c");
    const iv = try parseHex16("000102030405060708090a0b0c0d0e0f");

    var plain: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&plain, "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");

    const cipher = try encrypt(allocator, &plain, key, iv, .none);
    defer allocator.free(cipher);

    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2");
    try std.testing.expectEqualSlices(u8, &expected, cipher);

    const back = try decrypt(allocator, cipher, key, iv);
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u8, &plain, back);
}

test "padding 与长度检查" {
    const allocator = std.testing.allocator;
    const key: [16]u8 = @splat(0);
    const iv: [16]u8 = @splat(0);

    try std.testing.expectError(error.LengthNotAligned, encrypt(allocator, "abc", key, iv, .none));

    const zero = try encrypt(allocator, "abc", key, iv, .zero);
    defer allocator.free(zero);
    try std.testing.expectEqual(@as(usize, 16), zero.len);

    const pkcs = try encrypt(allocator, "0123456789abcdef", key, iv, .pkcs7);
    defer allocator.free(pkcs);
    try std.testing.expectEqual(@as(usize, 32), pkcs.len);
}

