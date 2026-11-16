//! AIC 镜像头 —— 等价于 Luban-Lite `bsp/common/include/aic_image.h` 与
//! `bsp/common/image/image.c`。
//!
//! 两种头版本：
//!   * V1 `struct image_header`      —— 64 字节，普通可启动镜像（loader / pbp）
//!   * V2 `struct aic_image_header`  —— 80 字节，增加 private_data / pbp 资源字段
//!
//! 所有字段小端。magic 为 `'AIC '`（0x20434941）。
const std = @import("std");
const checksum = @import("checksum.zig");

pub const MAGIC: u32 = 0x20434941; // 'AIC '
pub const PBP2_MAGIC: u32 = 0x32504250; // 'PBP2'
pub const PDAT_MAGIC: u32 = 0x54414450; // 'PDAT'

/// 镜像第一块大小，bootloader 按此对齐读取。
pub const FW_BLOCK1_SIZE: u32 = 256;

pub const SignAlgo = enum(u32) {
    none = 0,
    rsa2048 = 1,
    _,
};

pub const EncryptAlgo = enum(u32) {
    none = 0,
    aes_cbc = 1,
    _,
};

pub const HEAD_VER_1_0_0: u32 = 0x0001_0000;

/// V1 头：与 `struct image_header` 字段一一对应（64 字节）。
pub const HeaderV1 = struct {
    magic: u32 = MAGIC,
    checksum: u32 = 0,
    head_ver: u32 = HEAD_VER_1_0_0,
    image_len: u32 = 0,
    fwver_counter: u8 = 0,
    fwver_revision: u8 = 0,
    fwver_minor: u8 = 0,
    fwver_major: u8 = 0,
    firmware_len: u32 = 0,
    load_address: u32 = 0,
    entry_point: u32 = 0,
    sign_algo: u32 = 0,
    encrypt_algo: u32 = 0,
    sign_data_offset: u32 = 0,
    sign_data_len: u32 = 0,
    sign_key_offset: u32 = 0,
    sign_key_len: u32 = 0,
    iv_data_offset: u32 = 0,
    iv_data_len: u32 = 0,
};

pub const SIZE_V1: usize = 64;

/// V2 头：与 `struct aic_image_header` 对应（80 字节）。
pub const HeaderV2 = struct {
    base: HeaderV1 = .{},
    private_data_offset: u32 = 0,
    private_data_len: u32 = 0,
    pbp_offset: u32 = 0,
    pbp_len: u32 = 0,
};

pub const SIZE_V2: usize = 80;

fn putU32(out: []u8, offset: usize, v: u32) void {
    std.mem.writeInt(u32, out[offset..][0..4], v, .little);
}

fn getU32(in: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, in[offset..][0..4], .little);
}

pub fn encodeV1(h: HeaderV1, out: *[SIZE_V1]u8) void {
    @memset(out, 0);
    putU32(out, 0, h.magic);
    putU32(out, 4, h.checksum);
    putU32(out, 8, h.head_ver);
    putU32(out, 12, h.image_len);
    out[16] = h.fwver_counter;
    out[17] = h.fwver_revision;
    out[18] = h.fwver_minor;
    out[19] = h.fwver_major;
    putU32(out, 20, h.firmware_len);
    putU32(out, 24, h.load_address);
    putU32(out, 28, h.entry_point);
    putU32(out, 32, h.sign_algo);
    putU32(out, 36, h.encrypt_algo);
    putU32(out, 40, h.sign_data_offset);
    putU32(out, 44, h.sign_data_len);
    putU32(out, 48, h.sign_key_offset);
    putU32(out, 52, h.sign_key_len);
    putU32(out, 56, h.iv_data_offset);
    putU32(out, 60, h.iv_data_len);
}

pub fn decodeV1(in: []const u8) !HeaderV1 {
    if (in.len < SIZE_V1) return error.BufferTooSmall;
    return .{
        .magic = getU32(in, 0),
        .checksum = getU32(in, 4),
        .head_ver = getU32(in, 8),
        .image_len = getU32(in, 12),
        .fwver_counter = in[16],
        .fwver_revision = in[17],
        .fwver_minor = in[18],
        .fwver_major = in[19],
        .firmware_len = getU32(in, 20),
        .load_address = getU32(in, 24),
        .entry_point = getU32(in, 28),
        .sign_algo = getU32(in, 32),
        .encrypt_algo = getU32(in, 36),
        .sign_data_offset = getU32(in, 40),
        .sign_data_len = getU32(in, 44),
        .sign_key_offset = getU32(in, 48),
        .sign_key_len = getU32(in, 52),
        .iv_data_offset = getU32(in, 56),
        .iv_data_len = getU32(in, 60),
    };
}

pub fn encodeV2(h: HeaderV2, out: *[SIZE_V2]u8) void {
    var base: [SIZE_V1]u8 = undefined;
    encodeV1(h.base, &base);
    @memcpy(out[0..SIZE_V1], &base);
    @memset(out[SIZE_V1..], 0);
    putU32(out, 64, h.private_data_offset);
    putU32(out, 68, h.private_data_len);
    putU32(out, 72, h.pbp_offset);
    putU32(out, 76, h.pbp_len);
}

pub fn decodeV2(in: []const u8) !HeaderV2 {
    if (in.len < SIZE_V2) return error.BufferTooSmall;
    return .{
        .base = try decodeV1(in),
        .private_data_offset = getU32(in, 64),
        .private_data_len = getU32(in, 68),
        .pbp_offset = getU32(in, 72),
        .pbp_len = getU32(in, 76),
    };
}

/// `image_verify_magic()`：镜像开头 4 字节是否等于期望 magic。
pub fn verifyMagic(image: []const u8, magic: u32) bool {
    if (image.len < 4) return false;
    return std.mem.readInt(u32, image[0..4], .little) == magic;
}

pub fn entryPoint(image: []const u8) !u32 {
    const h = try decodeV1(image);
    return h.entry_point;
}

pub fn loadAddress(image: []const u8) !u32 {
    const h = try decodeV1(image);
    return h.load_address;
}

/// 构造 V1 可启动镜像：64 字节头 + 固件（补齐到 4 字节），checksum 自动计算。
pub fn createV1(
    allocator: std.mem.Allocator,
    firmware: []const u8,
    load_addr: u32,
    entry: u32,
    fwver: ?[4]u8,
    head_ver: u32,
) ![]u8 {
    const fw_len = std.mem.alignForward(usize, firmware.len, 4);
    const total = SIZE_V1 + fw_len;
    const image = try allocator.alloc(u8, total);
    errdefer allocator.free(image);
    @memset(image, 0);

    var h = HeaderV1{
        .head_ver = head_ver,
        .image_len = @intCast(total),
        .firmware_len = @intCast(firmware.len),
        .load_address = load_addr,
        .entry_point = entry,
    };
    if (fwver) |v| {
        h.fwver_counter = v[0];
        h.fwver_revision = v[1];
        h.fwver_minor = v[2];
        h.fwver_major = v[3];
    }
    // 先以 checksum=0 写头，再拷固件，最后整镜像求和取反
    var head: [SIZE_V1]u8 = undefined;
    encodeV1(h, &head);
    @memcpy(image[0..SIZE_V1], &head);
    @memcpy(image[SIZE_V1..][0..firmware.len], firmware);

    var sealed = h;
    sealed.checksum = checksum.makeChecksum(image);
    var sealed_bytes: [SIZE_V1]u8 = undefined;
    encodeV1(sealed, &sealed_bytes);
    @memcpy(image[0..SIZE_V1], &sealed_bytes);
    return image;
}

/// 校验完整镜像（magic + 长度 + checksum）。
pub fn verify(image: []const u8) !void {
    if (!verifyMagic(image, MAGIC)) return error.BadMagic;
    const h = try decodeV1(image);
    if (h.image_len > image.len or h.image_len < SIZE_V1) return error.BadImageLength;
    if (!checksum.verifyChecksum(image[0..h.image_len])) return error.BadChecksum;
}

/// 打印头部（`wk image dump` 使用）。
pub fn dump(writer: *std.Io.Writer, image: []const u8) !void {
    const h = try decodeV1(image);
    try writer.print("magic        : 0x{X:0>8} ({s})\n", .{ h.magic, if (h.magic == MAGIC) "AIC " else "????" });
    try writer.print("checksum     : 0x{X:0>8}\n", .{h.checksum});
    try writer.print("head_ver     : 0x{X:0>8}\n", .{h.head_ver});
    try writer.print("image_len    : 0x{X:0>8} ({d} bytes)\n", .{ h.image_len, h.image_len });
    try writer.print("fw version   : {d}.{d}.{d} (counter {d})\n", .{ h.fwver_major, h.fwver_minor, h.fwver_revision, h.fwver_counter });
    try writer.print("firmware_len : 0x{X:0>8} ({d} bytes)\n", .{ h.firmware_len, h.firmware_len });
    try writer.print("load_address : 0x{X:0>8}\n", .{h.load_address});
    try writer.print("entry_point  : 0x{X:0>8}\n", .{h.entry_point});
    try writer.print("sign_algo    : {d}\n", .{h.sign_algo});
    try writer.print("encrypt_algo : {d}\n", .{h.encrypt_algo});
}

test "AIC 镜像头 V1 编解码往返" {
    const h = HeaderV1{
        .head_ver = HEAD_VER_1_0_0,
        .image_len = 0x1234,
        .fwver_major = 1,
        .fwver_minor = 2,
        .fwver_revision = 3,
        .firmware_len = 0x1000,
        .load_address = 0x40100000,
        .entry_point = 0x40100100,
    };
    var bytes: [SIZE_V1]u8 = undefined;
    encodeV1(h, &bytes);
    const back = try decodeV1(&bytes);
    try std.testing.expectEqual(h.image_len, back.image_len);
    try std.testing.expectEqual(h.load_address, back.load_address);
    try std.testing.expectEqual(h.entry_point, back.entry_point);
    try std.testing.expectEqual(@as(u8, 1), back.fwver_major);
}

test "AIC 镜像构造与校验" {
    const allocator = std.testing.allocator;
    const fw = "this is a fake firmware payload!";
    const img = try createV1(allocator, fw, 0x40100000, 0x40100040, .{ 1, 0, 2, 1 }, HEAD_VER_1_0_0);
    defer allocator.free(img);

    try verify(img);
    try std.testing.expect(verifyMagic(img, MAGIC));
    try std.testing.expectEqual(@as(u32, 0x40100040), try entryPoint(img));

    // 篡改一个字节后 checksum 必须失败
    img[std.mem.alignForward(usize, SIZE_V1, 4)] ^= 0xFF;
    try std.testing.expectError(error.BadChecksum, verify(img));
}

test "V2 头包含 private/pbp 字段" {
    const h = HeaderV2{
        .base = .{ .image_len = 0x200 },
        .private_data_offset = 0x40,
        .private_data_len = 0x20,
        .pbp_offset = 0x60,
        .pbp_len = 0x100,
    };
    var bytes: [SIZE_V2]u8 = undefined;
    encodeV2(h, &bytes);
    const back = try decodeV2(&bytes);
    try std.testing.expectEqual(@as(u32, 0x60), back.pbp_offset);
    try std.testing.expectEqual(@as(u32, 0x100), back.pbp_len);
    try std.testing.expectEqual(@as(u32, 0x200), back.base.image_len);
}
