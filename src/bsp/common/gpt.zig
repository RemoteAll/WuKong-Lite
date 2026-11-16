//! MBR + GPT 磁盘分区表 —— 对应 Luban-Lite `bsp/common/include/disk_part.h` 与
//! `bsp/common/partition/disk_part.c` 的结构定义。
//!
//! 实现内容：
//!   * 结构解析（512 字节 MBR、头部 CRC/分区表 CRC 校验）
//!   * 按分区列表生成可烧写的 GPT 镜像（主/备 GPT + 保护性 MBR）
const std = @import("std");
const crc32 = @import("crc32.zig");

pub const SECTOR_SIZE: u64 = 512;
pub const GPT_SIGNATURE: u64 = 0x5452415020494645; // 'EFI PART'
pub const GPT_REVISION: u32 = 0x0001_0000;
pub const GPT_HEADER_SIZE: u32 = 92;
pub const GPT_ENTRY_NUMBERS: u32 = 128;
pub const GPT_ENTRY_SIZE: u32 = 128;
pub const MBR_SIGNATURE: u16 = 0xAA55;
pub const MBR_BOOT_CODE_SIZE: u32 = 440;
pub const PMBR_OSTYPE_GPT: u8 = 0xEE;

/// 与 C 结构一致：16 字节 GUID 原始字节。
pub const Guid = [16]u8;

pub const DEFAULT_DISK_GUID: Guid = .{
    0x8E, 0x9B, 0x9F, 0xC0, 0x16, 0xAC, 0x2B, 0x44,
    0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xB0,
};

pub const BASIC_DATA_GUID: Guid = .{
    0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
    0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC0,
};

pub const GptHeader = struct {
    signature: u64 = GPT_SIGNATURE,
    revision: u32 = GPT_REVISION,
    header_size: u32 = GPT_HEADER_SIZE,
    header_crc32: u32 = 0,
    reserved: u32 = 0,
    my_lba: u64 = 1,
    alternate_lba: u64 = 0,
    first_usable_lba: u64 = 34,
    last_usable_lba: u64 = 0,
    disk_guid: Guid = DEFAULT_DISK_GUID,
    partition_entry_lba: u64 = 2,
    num_partition_entries: u32 = GPT_ENTRY_NUMBERS,
    sizeof_partition_entry: u32 = GPT_ENTRY_SIZE,
    partition_entry_array_crc32: u32 = 0,

    pub fn decode(buf: []const u8) !GptHeader {
        if (buf.len < GPT_HEADER_SIZE) return error.BufferTooSmall;
        var h: GptHeader = .{
            .signature = std.mem.readInt(u64, buf[0..8], .little),
            .revision = std.mem.readInt(u32, buf[8..][0..4], .little),
            .header_size = std.mem.readInt(u32, buf[12..][0..4], .little),
            .header_crc32 = std.mem.readInt(u32, buf[16..][0..4], .little),
            .reserved = std.mem.readInt(u32, buf[20..][0..4], .little),
            .my_lba = std.mem.readInt(u64, buf[24..][0..8], .little),
            .alternate_lba = std.mem.readInt(u64, buf[32..][0..8], .little),
            .first_usable_lba = std.mem.readInt(u64, buf[40..][0..8], .little),
            .last_usable_lba = std.mem.readInt(u64, buf[48..][0..8], .little),
            .disk_guid = undefined,
            .partition_entry_lba = std.mem.readInt(u64, buf[72..][0..8], .little),
            .num_partition_entries = std.mem.readInt(u32, buf[80..][0..4], .little),
            .sizeof_partition_entry = std.mem.readInt(u32, buf[84..][0..4], .little),
            .partition_entry_array_crc32 = std.mem.readInt(u32, buf[88..][0..4], .little),
        };
        @memcpy(&h.disk_guid, buf[56..72]);
        return h;
    }

    pub fn encode(h: GptHeader, out: *[SECTOR_SIZE]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u64, out[0..8], h.signature, .little);
        std.mem.writeInt(u32, out[8..][0..4], h.revision, .little);
        std.mem.writeInt(u32, out[12..][0..4], h.header_size, .little);
        std.mem.writeInt(u32, out[16..][0..4], h.header_crc32, .little);
        std.mem.writeInt(u32, out[20..][0..4], h.reserved, .little);
        std.mem.writeInt(u64, out[24..][0..8], h.my_lba, .little);
        std.mem.writeInt(u64, out[32..][0..8], h.alternate_lba, .little);
        std.mem.writeInt(u64, out[40..][0..8], h.first_usable_lba, .little);
        std.mem.writeInt(u64, out[48..][0..8], h.last_usable_lba, .little);
        @memcpy(out[56..72], &h.disk_guid);
        std.mem.writeInt(u64, out[72..][0..8], h.partition_entry_lba, .little);
        std.mem.writeInt(u32, out[80..][0..4], h.num_partition_entries, .little);
        std.mem.writeInt(u32, out[84..][0..4], h.sizeof_partition_entry, .little);
        std.mem.writeInt(u32, out[88..][0..4], h.partition_entry_array_crc32, .little);
    }

    /// 头部 CRC：crc 字段按 0 计算，覆盖 header_size 字节。
    pub fn calcHeaderCrc(h: GptHeader) u32 {
        var bytes: [SECTOR_SIZE]u8 = undefined;
        var copy = h;
        copy.header_crc32 = 0;
        copy.encode(&bytes);
        const size = @max(@as(usize, GPT_HEADER_SIZE), @as(usize, h.header_size));
        return crc32.calc(bytes[0..@min(size, SECTOR_SIZE)]);
    }

    pub fn verify(h: GptHeader) bool {
        if (h.signature != GPT_SIGNATURE) return false;
        if (h.header_size < GPT_HEADER_SIZE or h.header_size > SECTOR_SIZE) return false;
        return h.header_crc32 == calcHeaderCrc(h);
    }
};

pub const GptEntry = struct {
    type_guid: Guid,
    unique_guid: Guid,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64,
    name: [36]u16,

    pub fn empty() GptEntry {
        return .{
            .type_guid = @splat(0),
            .unique_guid = @splat(0),
            .starting_lba = 0,
            .ending_lba = 0,
            .attributes = 0,
            .name = @splat(0),
        };
    }

    pub fn isUsed(e: GptEntry) bool {
        for (e.type_guid) |b| if (b != 0) return true;
        return false;
    }

    pub fn setName(e: *GptEntry, name: []const u8) void {
        e.name = @splat(0);
        const n = @min(name.len, e.name.len - 1);
        for (name[0..n], 0..) |c, i| e.name[i] = c;
    }

    pub fn getName(e: GptEntry, buf: *[36]u8) []const u8 {
        var n: usize = 0;
        while (n < e.name.len and e.name[n] != 0) : (n += 1) {
            buf[n] = @truncate(e.name[n]);
        }
        return buf[0..n];
    }

    fn encode(e: GptEntry, out: []u8) void {
        @memset(out[0..GPT_ENTRY_SIZE], 0);
        @memcpy(out[0..16], &e.type_guid);
        @memcpy(out[16..32], &e.unique_guid);
        std.mem.writeInt(u64, out[32..][0..8], e.starting_lba, .little);
        std.mem.writeInt(u64, out[40..][0..8], e.ending_lba, .little);
        std.mem.writeInt(u64, out[48..][0..8], e.attributes, .little);
        for (e.name, 0..) |ch, i| std.mem.writeInt(u16, out[56 + i * 2 ..][0..2], ch, .little);
    }

    fn decode(buf: []const u8) GptEntry {
        var e = GptEntry.empty();
        @memcpy(&e.type_guid, buf[0..16]);
        @memcpy(&e.unique_guid, buf[16..32]);
        e.starting_lba = std.mem.readInt(u64, buf[32..][0..8], .little);
        e.ending_lba = std.mem.readInt(u64, buf[40..][0..8], .little);
        e.attributes = std.mem.readInt(u64, buf[48..][0..8], .little);
        for (0..36) |i| e.name[i] = std.mem.readInt(u16, buf[56 + i * 2 ..][0..2], .little);
        return e;
    }
};

pub const MbrPartition = struct {
    boot_ind: u8,
    sys_ind: u8,
    start_sect: u32,
    nr_sects: u32,
};

pub const DiskInfo = struct {
    header: GptHeader,
    /// 已使用条目（最多 128 个，剩余为 undefined）。
    entries: [GPT_ENTRY_NUMBERS]GptEntry = undefined,
    entry_count: usize = 0,
};

/// 解析磁盘头部 34 个扇区（512B 扇区）或至少 1 个扇区 + 条目区。
pub fn parse(buffer: []const u8) !DiskInfo {
    if (buffer.len < SECTOR_SIZE * 2) return error.BufferTooSmall;

    // 保护性 MBR 校验
    const mbr_sig = std.mem.readInt(u16, buffer[510..512], .little);
    if (mbr_sig != MBR_SIGNATURE) return error.BadMbrSignature;

    const header = try GptHeader.decode(buffer[SECTOR_SIZE..]);
    if (!header.verify()) return error.BadGptHeaderCrc;

    const entries_bytes = @as(usize, header.num_partition_entries) * @as(usize, header.sizeof_partition_entry);
    const entries_off = @as(usize, @intCast(header.partition_entry_lba)) * SECTOR_SIZE;
    if (entries_off + entries_bytes > buffer.len) return error.BufferTooSmall;

    const array = buffer[entries_off..][0..entries_bytes];
    if (header.partition_entry_array_crc32 != crc32.calc(array)) return error.BadGptEntriesCrc;

    var info = DiskInfo{ .header = header };
    var i: usize = 0;
    while (i < header.num_partition_entries and i < GPT_ENTRY_NUMBERS) : (i += 1) {
        const e = GptEntry.decode(array[i * GPT_ENTRY_SIZE ..]);
        if (!e.isUsed()) continue;
        info.entries[info.entry_count] = e;
        info.entry_count += 1;
    }
    return info;
}

pub const BuildEntry = struct {
    name: []const u8,
    first_lba: u64,
    last_lba: u64,
};

/// 生成 GPT 磁盘镜像（保护性 MBR + 主 GPT + 主条目区 + 备份条目区 + 备份 GPT）。
/// `total_lba` 为磁盘总扇区数；返回调用者拥有的缓冲（总长 total_lba*512）。
pub fn build(
    allocator: std.mem.Allocator,
    total_lba: u64,
    entries: []const BuildEntry,
) ![]u8 {
    if (total_lba < 68) return error.DiskTooSmall;
    if (entries.len > GPT_ENTRY_NUMBERS) return error.TooManyEntries;

    const total_bytes = total_lba * SECTOR_SIZE;
    const out = try allocator.alloc(u8, @intCast(total_bytes));
    errdefer allocator.free(out);
    @memset(out, 0);

    const entries_bytes: usize = GPT_ENTRY_NUMBERS * GPT_ENTRY_SIZE;
    const entries_sectors: u64 = (entries_bytes + SECTOR_SIZE - 1) / SECTOR_SIZE;
    const last_usable = total_lba - entries_sectors - 2;

    // 保护性 MBR
    std.mem.writeInt(u16, out[510..512], MBR_SIGNATURE, .little);
    out[446 + 4] = PMBR_OSTYPE_GPT;
    std.mem.writeInt(u32, out[446 + 8 ..][0..4], 1, .little);
    std.mem.writeInt(u32, out[446 + 12 ..][0..4], @intCast(total_lba - 1), .little);

    // 主条目区（LBA 2）
    var array: [GPT_ENTRY_NUMBERS * GPT_ENTRY_SIZE]u8 = undefined;
    @memset(&array, 0);
    for (entries, 0..) |e, i| {
        var ge = GptEntry.empty();
        ge.type_guid = BASIC_DATA_GUID;
        ge.unique_guid = BASIC_DATA_GUID;
        ge.unique_guid[15] ^= @intCast(i + 1); // 简单派生唯一 GUID
        ge.starting_lba = e.first_lba;
        ge.ending_lba = e.last_lba;
        ge.setName(e.name);
        ge.encode(array[i * GPT_ENTRY_SIZE ..][0..GPT_ENTRY_SIZE]);
    }
    const array_crc = crc32.calc(&array);
    @memcpy(out[2 * SECTOR_SIZE ..][0..entries_bytes], &array);

    // 主 GPT 头（LBA 1）
    var primary = GptHeader{
        .my_lba = 1,
        .alternate_lba = total_lba - 1,
        .first_usable_lba = 2 + entries_sectors,
        .last_usable_lba = last_usable,
        .partition_entry_lba = 2,
        .partition_entry_array_crc32 = array_crc,
        .header_crc32 = 0,
    };
    primary.header_crc32 = GptHeader.calcHeaderCrc(primary);
    var head_bytes: [SECTOR_SIZE]u8 = undefined;
    primary.encode(&head_bytes);
    @memcpy(out[SECTOR_SIZE..][0..SECTOR_SIZE], &head_bytes);

    // 备份条目区 + 备份头
    const backup_entries_lba = last_usable + 1;
    @memcpy(out[@as(usize, @intCast(backup_entries_lba * SECTOR_SIZE))..][0..entries_bytes], &array);

    var backup = primary;
    backup.my_lba = total_lba - 1;
    backup.alternate_lba = 1;
    backup.partition_entry_lba = backup_entries_lba;
    backup.header_crc32 = 0;
    backup.header_crc32 = GptHeader.calcHeaderCrc(backup);
    backup.encode(&head_bytes);
    @memcpy(out[@as(usize, @intCast((total_lba - 1) * SECTOR_SIZE))..][0..SECTOR_SIZE], &head_bytes);

    return out;
}

test "GPT 镜像生成后可解析" {
    const allocator = std.testing.allocator;
    const total_lba: u64 = 2048; // 1 MiB 测试盘
    const entries = [_]BuildEntry{
        .{ .name = "boot", .first_lba = 40, .last_lba = 439 },
        .{ .name = "rootfs", .first_lba = 440, .last_lba = 1999 },
    };
    const disk = try build(allocator, total_lba, &entries);
    defer allocator.free(disk);

    const info = try parse(disk);
    try std.testing.expectEqual(@as(usize, 2), info.entry_count);
    var name_buf: [36]u8 = undefined;
    try std.testing.expectEqualStrings("boot", info.entries[0].getName(&name_buf));
    try std.testing.expectEqual(@as(u64, 440), info.entries[1].starting_lba);
    try std.testing.expectEqual(@as(u64, 1999), info.entries[1].ending_lba);
}

test "GPT 头 CRC 被破坏时报错" {
    const allocator = std.testing.allocator;
    const entries = [_]BuildEntry{
        .{ .name = "data", .first_lba = 40, .last_lba = 1999 },
    };
    const disk = try build(allocator, 2048, &entries);
    defer allocator.free(disk);

    disk[SECTOR_SIZE + 16] ^= 0xFF; // header_crc32 字段
    try std.testing.expectError(error.BadGptHeaderCrc, parse(disk));
}
