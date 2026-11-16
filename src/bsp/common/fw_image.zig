//! AIC 固件包格式 —— 等价于 Luban-Lite `tools/scripts/mk_image.py` 生成的
//! `xxx.img`（烧录器镜像）与 SPI NAND 页表。
//!
//! 布局（所有整数字段小端）：
//!
//!   +0         struct artinchip_fw_hdr (348 字节，补齐到 2048)
//!   +2048      META 组件表，每项 512 字节（struct artinchip_fwc_meta，280 字节有效）
//!   file_offset 组件数据区，每个文件按 2048 字节对齐，空隙填 0x00
//!
//! 组件表第一项通常是 "image.info"（指向文件头所在的 2048 字节），
//! 其后是 updater（下载到 RAM 运行）与 target（烧写到 flash 分区）组件。
const std = @import("std");
const crc32 = @import("crc32.zig");
const checksum = @import("checksum.zig");
const utils = @import("utils.zig");

pub const DATA_ALIGNED_SIZE: u32 = 2048;
pub const META_ALIGNED_SIZE: u32 = 512;
pub const HEADER_STRUCT_SIZE: usize = 348;
pub const META_STRUCT_SIZE: usize = 280;
pub const PAGE_TABLE_MAX_ENTRY: u32 = 101;
pub const FW_MAGIC = "AIC.FW";
pub const META_MAGIC = "META";
pub const PAGE_TABLE_MAGIC = "AICP";

pub const FwHeader = struct {
    magic: [8]u8 = .{ 'A', 'I', 'C', '.', 'F', 'W', 0, 0 },
    platform: []const u8 = "",
    product: []const u8 = "",
    version: []const u8 = "",
    media_type: []const u8 = "",
    media_dev_id: [4]u8 = .{ 0, 0, 0, 0 },
    nand_array_org: []const u8 = "",
    meta_offset: u32 = DATA_ALIGNED_SIZE,
    meta_size: u32 = 0,
    file_offset: u32 = 0,
    file_size: u32 = 0,

    pub fn encode(h: FwHeader, out: []u8) void {
        std.debug.assert(out.len >= HEADER_STRUCT_SIZE);
        @memset(out[0..HEADER_STRUCT_SIZE], 0);
        utils.strToFixedBytes(out[0..8], &h.magic);
        utils.strToFixedBytes(out[8..72], h.platform);
        utils.strToFixedBytes(out[72..136], h.product);
        utils.strToFixedBytes(out[136..200], h.version);
        utils.strToFixedBytes(out[200..264], h.media_type);
        @memcpy(out[264..268], &h.media_dev_id);
        utils.strToFixedBytes(out[268..332], h.nand_array_org);
        std.mem.writeInt(u32, out[332..][0..4], h.meta_offset, .little);
        std.mem.writeInt(u32, out[336..][0..4], h.meta_size, .little);
        std.mem.writeInt(u32, out[340..][0..4], h.file_offset, .little);
        std.mem.writeInt(u32, out[344..][0..4], h.file_size, .little);
    }

    pub fn parse(bytes: []const u8) !FwHeader {
        if (bytes.len < HEADER_STRUCT_SIZE) return error.BufferTooSmall;
        var h = FwHeader{};
        @memcpy(&h.magic, bytes[0..8]);
        // 字符串视图指向入参缓冲
        h.platform = utils.fixedBytesToStr(bytes[8..72]);
        h.product = utils.fixedBytesToStr(bytes[72..136]);
        h.version = utils.fixedBytesToStr(bytes[136..200]);
        h.media_type = utils.fixedBytesToStr(bytes[200..264]);
        @memcpy(&h.media_dev_id, bytes[264..268]);
        h.nand_array_org = utils.fixedBytesToStr(bytes[268..332]);
        h.meta_offset = std.mem.readInt(u32, bytes[332..][0..4], .little);
        h.meta_size = std.mem.readInt(u32, bytes[336..][0..4], .little);
        h.file_offset = std.mem.readInt(u32, bytes[340..][0..4], .little);
        h.file_size = std.mem.readInt(u32, bytes[344..][0..4], .little);
        return h;
    }
};

pub const Meta = struct {
    magic: [8]u8 = .{ 'M', 'E', 'T', 'A', 0, 0, 0, 0 },
    name: [64]u8 = @splat(0),
    partition: [32]u8 = @splat(0),
    part_offset: u32 = 0,
    part_size: u32 = 0,
    dev_name: [20]u8 = @splat(0),
    dev_id: u32 = 0,
    offset_in_img: u32 = 0,
    size_in_img: u32 = 0,
    crc: u32 = 0,
    ram: u32 = 0xFFFFFFFF,
    attr: [64]u8 = @splat(0),
    filename: [64]u8 = @splat(0),

    pub fn encode(m: Meta, out: []u8) void {
        std.debug.assert(out.len >= META_STRUCT_SIZE);
        @memset(out[0..META_STRUCT_SIZE], 0);
        utils.strToFixedBytes(out[0..8], &m.magic);
        utils.strToFixedBytes(out[8..72], &m.name);
        utils.strToFixedBytes(out[72..104], &m.partition);
        std.mem.writeInt(u32, out[104..][0..4], m.part_offset, .little);
        std.mem.writeInt(u32, out[108..][0..4], m.part_size, .little);
        utils.strToFixedBytes(out[112..132], &m.dev_name);
        std.mem.writeInt(u32, out[132..][0..4], m.dev_id, .little);
        std.mem.writeInt(u32, out[136..][0..4], m.offset_in_img, .little);
        std.mem.writeInt(u32, out[140..][0..4], m.size_in_img, .little);
        std.mem.writeInt(u32, out[144..][0..4], m.crc, .little);
        std.mem.writeInt(u32, out[148..][0..4], m.ram, .little);
        utils.strToFixedBytes(out[152..216], &m.attr);
        utils.strToFixedBytes(out[216..280], &m.filename);
    }

    pub fn parse(bytes: []const u8) !Meta {
        if (bytes.len < META_STRUCT_SIZE) return error.BufferTooSmall;
        var m = Meta{};
        @memcpy(&m.magic, bytes[0..8]);
        @memcpy(&m.name, bytes[8..72]);
        @memcpy(&m.partition, bytes[72..104]);
        m.part_offset = std.mem.readInt(u32, bytes[104..][0..4], .little);
        m.part_size = std.mem.readInt(u32, bytes[108..][0..4], .little);
        @memcpy(&m.dev_name, bytes[112..132]);
        m.dev_id = std.mem.readInt(u32, bytes[132..][0..4], .little);
        m.offset_in_img = std.mem.readInt(u32, bytes[136..][0..4], .little);
        m.size_in_img = std.mem.readInt(u32, bytes[140..][0..4], .little);
        m.crc = std.mem.readInt(u32, bytes[144..][0..4], .little);
        m.ram = std.mem.readInt(u32, bytes[148..][0..4], .little);
        @memcpy(&m.attr, bytes[152..216]);
        @memcpy(&m.filename, bytes[216..280]);
        return m;
    }

    pub fn nameStr(m: *const Meta) []const u8 {
        return utils.fixedBytesToStr(&m.name);
    }
    pub fn attrStr(m: *const Meta) []const u8 {
        return utils.fixedBytesToStr(&m.attr);
    }
    pub fn partitionStr(m: *const Meta) []const u8 {
        return utils.fixedBytesToStr(&m.partition);
    }
    pub fn devNameStr(m: *const Meta) []const u8 {
        return utils.fixedBytesToStr(&m.dev_name);
    }
    pub fn fileStr(m: *const Meta) []const u8 {
        return utils.fixedBytesToStr(&m.filename);
    }

    pub fn isMeta(bytes: []const u8) bool {
        if (bytes.len < 8) return false;
        return std.mem.startsWith(u8, bytes[0..8], META_MAGIC);
    }
};

/// 打包时的一个组件。
pub const Component = struct {
    /// 组件名（不含 "image." 前缀，例如 `updater.psram` / `target.spl`）。
    name: []const u8,
    file_name: []const u8,
    data: []const u8,
    attr: []const u8,
    part: []const u8 = "",
    part_offset: u32 = 0,
    part_size: u32 = 0,
    dev_name: []const u8 = "ram",
    dev_id: u32 = 0,
    ram: u32 = 0xFFFFFFFF,
};

pub const PackOptions = struct {
    header: FwHeader,
    components: []const Component,
    /// image.info 组件插入位置（默认在 updater 之后由调用者指定，0 表示最前）。
    info_index: usize = 0,
};

/// 生成固件包（AIC.FW），返回调用者拥有的缓冲。
pub fn pack(allocator: std.mem.Allocator, opt: PackOptions) ![]u8 {
    const meta_count: u32 = @intCast(opt.components.len + 1);
    const meta_size: u32 = meta_count * META_ALIGNED_SIZE;
    const file_offset: u32 = DATA_ALIGNED_SIZE + meta_size;

    var file_size: u32 = 0;
    for (opt.components) |c| {
        file_size += @intCast(utils.roundUp(c.data.len, DATA_ALIGNED_SIZE));
    }

    var header = opt.header;
    header.meta_offset = DATA_ALIGNED_SIZE;
    header.meta_size = meta_size;
    header.file_offset = file_offset;
    header.file_size = file_size;

    const total: usize = @intCast(file_offset + file_size);
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);

    // 1) 文件头（其内容就是 image.info 组件，CRC 覆盖整个 2048 字节块）
    header.encode(out[0..DATA_ALIGNED_SIZE]);
    const info_crc = crc32.calc(out[0..DATA_ALIGNED_SIZE]);

    // 2) 组件表 + 数据区
    var meta_off: usize = DATA_ALIGNED_SIZE;
    var data_off: usize = file_offset;
    for (opt.components, 0..) |c, idx| {
        if (idx == opt.info_index) {
            const info_meta = Meta{
                .name = blk: {
                    var n: [64]u8 = @splat(0);
                    utils.strToFixedBytes(&n, "image.info");
                    break :blk n;
                },
                .dev_name = blk: {
                    var n: [20]u8 = @splat(0);
                    utils.strToFixedBytes(&n, "ram");
                    break :blk n;
                },
                .offset_in_img = 0,
                .size_in_img = DATA_ALIGNED_SIZE,
                .crc = info_crc,
                .ram = 0xFFFFFFFF,
                .attr = blk: {
                    var n: [64]u8 = @splat(0);
                    utils.strToFixedBytes(&n, "required");
                    break :blk n;
                },
                .filename = blk: {
                    var n: [64]u8 = @splat(0);
                    utils.strToFixedBytes(&n, "info.bin");
                    break :blk n;
                },
            };
            info_meta.encode(out[meta_off..]);
            meta_off += META_ALIGNED_SIZE;
        }

        var m = Meta{};
        utils.strToFixedBytes(&m.name, c.name);
        utils.strToFixedBytes(&m.partition, c.part);
        utils.strToFixedBytes(&m.dev_name, c.dev_name);
        utils.strToFixedBytes(&m.attr, c.attr);
        utils.strToFixedBytes(&m.filename, c.file_name);
        m.part_offset = c.part_offset;
        m.part_size = c.part_size;
        m.dev_id = c.dev_id;
        m.offset_in_img = @intCast(data_off);
        m.size_in_img = @intCast(c.data.len);
        m.crc = crc32.calc(c.data);
        m.ram = c.ram;
        m.encode(out[meta_off..]);

        @memcpy(out[data_off..][0..c.data.len], c.data);

        meta_off += META_ALIGNED_SIZE;
        data_off += @intCast(utils.roundUp(c.data.len, DATA_ALIGNED_SIZE));
    }

    // 若 info_index 恰在末尾，补写 info 项
    if (opt.info_index >= opt.components.len) {
        const info_meta = Meta{
            .offset_in_img = 0,
            .size_in_img = DATA_ALIGNED_SIZE,
            .crc = info_crc,
            .ram = 0xFFFFFFFF,
        };
        var m = info_meta;
        utils.strToFixedBytes(&m.name, "image.info");
        utils.strToFixedBytes(&m.dev_name, "ram");
        utils.strToFixedBytes(&m.attr, "required");
        utils.strToFixedBytes(&m.filename, "info.bin");
        m.encode(out[meta_off..]);
        meta_off += META_ALIGNED_SIZE;
    }

    return out;
}

pub fn headerIsValid(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    return std.mem.startsWith(u8, bytes[0..8], FW_MAGIC);
}

/// 读取全部组件表项（按 header.meta_size 计算数量）。
pub fn readMeta(allocator: std.mem.Allocator, image: []const u8) ![]Meta {
    const header = try FwHeader.parse(image);
    if (header.meta_offset + header.meta_size > image.len) return error.BadImage;
    const count: usize = header.meta_size / META_ALIGNED_SIZE;
    const list = try allocator.alloc(Meta, count);
    errdefer allocator.free(list);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = header.meta_offset + i * META_ALIGNED_SIZE;
        const m = try Meta.parse(image[off..]);
        if (!Meta.isMeta(image[off..@min(off + 8, image.len)])) return error.BadMeta;
        list[i] = m;
    }
    return list;
}

pub fn dump(writer: *std.Io.Writer, image: []const u8) !void {
    const h = try FwHeader.parse(image);
    if (!std.mem.startsWith(u8, &h.magic, FW_MAGIC)) return error.BadMagic;
    try writer.print("firmware     : {s}\n", .{utils.fixedBytesToStr(&h.magic)});
    try writer.print("platform     : {s}\n", .{h.platform});
    try writer.print("product      : {s}\n", .{h.product});
    try writer.print("version      : {s}\n", .{h.version});
    try writer.print("media type   : {s}\n", .{h.media_type});
    try writer.print("media dev id : {d},{d},{d},{d}\n", .{ h.media_dev_id[0], h.media_dev_id[1], h.media_dev_id[2], h.media_dev_id[3] });
    if (h.nand_array_org.len > 0) try writer.print("nand array   : {s}\n", .{h.nand_array_org});
    try writer.print("meta area    : off 0x{X:0>8} size 0x{X:0>8}\n", .{ h.meta_offset, h.meta_size });
    try writer.print("file area    : off 0x{X:0>8} size 0x{X:0>8}\n", .{ h.file_offset, h.file_size });

    const count: usize = h.meta_size / META_ALIGNED_SIZE;
    try writer.print("{s:<16} {s:>10} {s:>10} {s:>10} {s}\n", .{ "Name", "Offset", "Size", "Part", "File (crc)" });
    try writer.print("{s}\n", .{"----------------------------------------------------------------------------------------------------------------------------------------"});
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = h.meta_offset + i * META_ALIGNED_SIZE;
        if (off + META_STRUCT_SIZE > image.len) break;
        const m = try Meta.parse(image[off..]);
        try writer.print("{s:<16} 0x{X:0>8} 0x{X:0>8} 0x{X:0>8} {s} (0x{X:0>8})\n", .{
            m.nameStr(), m.offset_in_img, m.size_in_img, m.part_size, m.fileStr(), m.crc,
        });
    }
}

// ---------------------------------------------------------------------------
// SPI NAND 页表（与 mk_image.py `img_gen_page_table` 等价）
// ---------------------------------------------------------------------------

pub const ArrayOrg = struct {
    /// 页大小（KiB），例如 "2K" -> 2
    page_kib: u32,
    /// 块大小（KiB），例如 "128K" -> 128
    block_kib: u32,
    planes: u8 = 1,
};

pub const PageTable = struct {
    pub const HEAD_SIZE: usize = 20;
    pub const ENTRY_SIZE: usize = 20;

    /// 生成页表（一页大小），返回调用者拥有的缓冲。
    pub fn build(allocator: std.mem.Allocator, spl: []const u8, org: ArrayOrg) ![]u8 {
        if (org.page_kib == 0) return error.InvalidArrayOrg;
        const page_bytes: usize = @as(usize, org.page_kib) * 1024;
        const page_per_blk = org.block_kib / org.page_kib;

        const aligned = utils.roundUp(spl.len, DATA_ALIGNED_SIZE);
        const page_cnt: usize = @intCast(aligned / page_bytes);
        if (page_cnt + 1 > 2 * PAGE_TABLE_MAX_ENTRY) return error.SplTooLarge;

        const out = try allocator.alloc(u8, page_bytes);
        errdefer allocator.free(out);
        @memset(out, 0xFF);

        // 20 字节头
        @memcpy(out[0..4], PAGE_TABLE_MAGIC);
        std.mem.writeInt(u32, out[4..][0..4], @intCast(page_cnt + 1), .little);
        std.mem.writeInt(u16, out[8..][0..2], @intCast(page_bytes), .little);
        out[10] = @intCast(page_per_blk);
        out[11] = 0xFF;
        out[12] = org.planes;

        // 第一个表项：pageaddr1 = 0，pageaddr2 = 101
        var idx: usize = 0;
        // pageaddr1 = 0（< 101 但不对应有效页，checksum1 = 0）
        std.mem.writeInt(u32, out[20..][0..4], 0, .little);
        writeEntry2(out, 20, 0, PAGE_TABLE_MAX_ENTRY, page_cnt, spl, page_bytes);
        std.mem.writeInt(u32, out[36..][0..4], 0, .little);

        idx = 1;
        while (idx < PAGE_TABLE_MAX_ENTRY) : (idx += 1) {
            const entry_off = HEAD_SIZE + idx * ENTRY_SIZE;
            const pageaddr1: u32 = @intCast(idx);
            const pageaddr2: u32 = PAGE_TABLE_MAX_ENTRY + @as(u32, @intCast(idx));

            if (pageaddr1 <= page_cnt + 1) {
                std.mem.writeInt(u32, out[entry_off..][0..4], pageaddr1, .little);
            } else {
                std.mem.writeInt(u32, out[entry_off..][0..4], 0xFFFFFFFF, .little);
            }

            writeEntry2(out, entry_off, pageaddr1, pageaddr2, page_cnt, spl, page_bytes);

            if (pageaddr1 <= page_cnt + 1) {
                const off1 = (pageaddr1 - 1) * page_bytes;
                const cs1 = checksum.imageCalcChecksum(pageSlice(spl, off1, page_bytes));
                std.mem.writeInt(u32, out[entry_off + 16 ..][0..4], cs1, .little);
            } else {
                std.mem.writeInt(u32, out[entry_off + 16 ..][0..4], 0xFFFFFFFF, .little);
            }
        }

        // 整页校验和写入表头偏移 36（第一个表项的 checksum1 位置）
        std.mem.writeInt(u32, out[36..][0..4], 0, .little);
        const page_sum = checksum.imageCalcChecksum(out);
        std.mem.writeInt(u32, out[36..][0..4], ~page_sum, .little);
        return out;
    }

    fn pageSlice(spl: []const u8, off: usize, page_bytes: usize) []const u8 {
        if (off >= spl.len) return &.{};
        return spl[off..@min(off + page_bytes, spl.len)];
    }

    fn writeEntry2(out: []u8, entry_off: usize, pageaddr1: u32, pageaddr2: u32, page_cnt: usize, spl: []const u8, page_bytes: usize) void {
        _ = pageaddr1;
        if (pageaddr2 < 2 * PAGE_TABLE_MAX_ENTRY and pageaddr2 <= page_cnt + 1) {
            const off2 = (@as(usize, pageaddr2) - 1) * page_bytes;
            const cs2 = checksum.imageCalcChecksum(pageSlice(spl, off2, page_bytes));
            std.mem.writeInt(u32, out[entry_off + 4 ..][0..4], pageaddr2, .little);
            std.mem.writeInt(u32, out[entry_off + 8 ..][0..4], cs2, .little);
            std.mem.writeInt(u32, out[entry_off + 12 ..][0..4], 0xFFFFFFFF, .little);
        } else {
            std.mem.writeInt(u32, out[entry_off + 4 ..][0..4], 0xFFFFFFFF, .little);
            std.mem.writeInt(u32, out[entry_off + 8 ..][0..4], 0xFFFFFFFF, .little);
            std.mem.writeInt(u32, out[entry_off + 12 ..][0..4], 0xFFFFFFFF, .little);
        }
    }

    /// 校验整页校验和（写入时取反，校验时 sum+1==0）。
    pub fn verify(page: []const u8) bool {
        return checksum.verifyChecksum(page);
    }

    pub fn entries(page: []const u8) !u32 {
        if (page.len < HEAD_SIZE) return error.BufferTooSmall;
        return std.mem.readInt(u32, page[4..][0..4], .little);
    }
};

test "AIC.FW 打包与解析往返" {
    const allocator = std.testing.allocator;
    const fw1 = "firmware-one-data-firmware-one-data-firmware-one-data-firmware-one-data";
    const fw2 = "firmware-two-data-firmware-two-data-firmware-two-data-firmware-two-data";
    const comps = [_]Component{
        .{ .name = "updater.psram", .file_name = "psram.bin", .data = fw1, .attr = "required;run" },
        .{ .name = "target.spl", .file_name = "bootloader.aic", .data = fw2, .attr = "mtd;required", .part = "spl", .part_offset = 0, .part_size = 512 * 1024, .dev_name = "spi-nor", .dev_id = 0 },
    };
    const image = try pack(allocator, .{
        .header = .{
            .platform = "d13x",
            .product = "demo88-nor",
            .version = "1.0.0",
            .media_type = "spi-nor",
        },
        .components = &comps,
        .info_index = 1,
    });
    defer allocator.free(image);

    try std.testing.expect(headerIsValid(image));
    const h = try FwHeader.parse(image);
    try std.testing.expectEqualStrings("d13x", h.platform);
    try std.testing.expectEqual(@as(u32, 3 * META_ALIGNED_SIZE), h.meta_size);

    const metas = try readMeta(allocator, image);
    defer allocator.free(metas);
    try std.testing.expectEqual(@as(usize, 3), metas.len);
    try std.testing.expectEqualStrings("updater.psram", metas[0].nameStr());
    try std.testing.expectEqualStrings("image.info", metas[1].nameStr());
    try std.testing.expectEqualStrings("target.spl", metas[2].nameStr());
    try std.testing.expectEqualStrings("spl", metas[2].partitionStr());
    try std.testing.expectEqual(@as(u32, 512 * 1024), metas[2].part_size);

    // 组件数据必须能在镜像内按 offset 找到
    const m0 = metas[0];
    try std.testing.expectEqualStrings(fw1, image[m0.offset_in_img..][0..fw1.len]);
    // image.info 的 CRC 覆盖头部 2048 字节
    try std.testing.expectEqual(crc32.calc(image[0..DATA_ALIGNED_SIZE]), metas[1].crc);
}

test "NAND 页表生成与校验" {
    const allocator = std.testing.allocator;
    var spl: [32 * 1024]u8 = @splat(0);
    for (&spl, 0..) |*b, i| b.* = @truncate(i * 7);
    const page = try PageTable.build(allocator, &spl, .{ .page_kib = 2, .block_kib = 128, .planes = 1 });
    defer allocator.free(page);

    try std.testing.expectEqual(@as(usize, 2 * 1024), page.len);
    try std.testing.expect(PageTable.verify(page));
    try std.testing.expectEqual(@as(u32, 17), try PageTable.entries(page)); // 32K/2K + 1
    try std.testing.expect(std.mem.eql(u8, page[0..4], "AICP"));
}
