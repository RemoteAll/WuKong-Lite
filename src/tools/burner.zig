//! 量产烧写镜像 —— 对应 Luban-Lite `mk_image.py -b/--burner`（`BURNER` 分支）：
//!
//!   每个 flash 设备产出一份「整片镜像 bin」+ 一份「分区烧写表 bin」：
//!
//!   * 整片镜像按设备容量填 0xFF，组件数据写到各自 `part_offset`；
//!   * spi-nand 设备先在镜像开头写 AICP 页表（SPL 引导用）；
//!   * 分区烧写表每项 16 B：起始块号 / 末块号 / 占用块数 / 0xFFFFFFFF，末尾再补 16 B 0xFF；
//!   * 块号换算 `_calc_block_info()`：spi-nor 64 KiB、spi-nand 取 `array_organization` 的块大小、
//!     mmc 512 B 扇区（跨块判定仍用 512 KiB，参考如此，照抄）。
//!
//! 参考的 spi-nand 多 `array_organization` 情形会为每个组织各出一套产物
//! （`fixup_spinand_ubi_fwc_name`：product 加 `_page_2k_block_128k`、分区表名加 `(page_2k_block_128k)`）。
const std = @import("std");
const fw_image = @import("../bsp/common/fw_image.zig");
const image_cfg = @import("image_cfg.zig");
const utils = @import("../bsp/common/utils.zig");

/// 参考 `BIN_FILE_MAX_SIZE`：整片镜像上限 300 MiB。
pub const BIN_FILE_MAX_SIZE: u64 = 300 * 1024 * 1024;
/// 参考在 main 里硬编码注入的分区表文件名。
pub const DEFAULT_PART_TABLE = "image_part_table.bin";

pub const Error = error{
    BadConfig,
    PartitionNotFound,
    SplFileNotFound,
    SplTooLarge,
    ComponentTooLarge,
    MediaTooLarge,
    UnsupportedMedia,
};

pub const ArrayOrg = struct {
    page_kib: u32 = 0,
    block_kib: u32 = 0,
    planes: u8 = 1,
};

pub const PartRange = struct {
    start: u64,
    size: u64,
    device: []const u8,
    media_type: []const u8,
};

pub const BlockInfo = struct {
    start: u32,
    last: u32,
    used: u32,
    total: u32,
};

/// `_calc_block_info()`：把字节偏移/长度换算成介质块号。
/// 注意 mmc 分支：起始/占用按 512 B 扇区，但「是否需要补一块」按 512 KiB 判断（参考如此）。
pub fn calcBlockInfo(media_type: []const u8, part_offset: u64, part_size: u64, filesize: u64, block_kib_in: u32) BlockInfo {
    if (std.mem.eql(u8, media_type, "spi-nand")) {
        const blk: u64 = @as(u64, block_kib_in) * 1024;
        if (blk == 0) return .{ .start = 0, .last = 0, .used = 0, .total = 0 };
        const start: u32 = @intCast(part_offset / blk);
        var used: u32 = @intCast(filesize / blk);
        if (filesize % blk != 0) used += 1;
        const total: u32 = @intCast(part_size / blk);
        return .{ .start = start, .last = start +% total -% 1, .used = used, .total = total };
    }
    if (std.mem.eql(u8, media_type, "spi-nor")) {
        const blk: u64 = 64 * 1024;
        const start: u32 = @intCast(part_offset / blk);
        var used: u32 = @intCast(filesize / blk);
        if (filesize % blk != 0) used += 1;
        return .{ .start = start, .last = start +% used -% 1, .used = used, .total = 0 };
    }
    if (std.mem.eql(u8, media_type, "mmc")) {
        const sector: u64 = 512;
        const start: u32 = @intCast(part_offset / sector);
        var used: u32 = @intCast(filesize / sector);
        if (filesize % (sector * 1024) != 0) used += 1;
        return .{ .start = start, .last = start +% used -% 1, .used = used, .total = 0 };
    }
    return .{ .start = 0, .last = 0, .used = 0, .total = 0 };
}

/// 参考 `int(re.sub(r"[^0-9]", "", s))`。
fn digitsOnly(s: []const u8) u32 {
    var v: u64 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') v = v * 10 + (c - '0');
    }
    if (v > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v);
}

/// Python `str.replace(old, new)`（全部替换）。
pub fn pyReplace(allocator: std.mem.Allocator, s: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return allocator.dupe(u8, s);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (std.mem.find(u8, s[i..], old)) |rel| {
        const at = i + rel;
        try out.writer.writeAll(s[i..at]);
        try out.writer.writeAll(new);
        i = at + old.len;
    }
    try out.writer.writeAll(s[i..]);
    return out.toOwnedSlice();
}

/// `array_organization` + `planes`（`img_gen_page_table` / `img_write_fwc_file_to_binfile` 用）。
pub fn parseOrgs(allocator: std.mem.Allocator, media_obj: std.json.ObjectMap) ![]ArrayOrg {
    var list: std.ArrayList(ArrayOrg) = .empty;
    errdefer list.deinit(allocator);

    var planes: u8 = 1;
    if (media_obj.get("planes")) |v| {
        planes = switch (v) {
            .integer => |n| @intCast(@max(1, @min(n, 2))),
            .float => |f| @intCast(@max(1, @min(@as(i64, @intFromFloat(f)), 2))),
            .string => |s| @intCast(@max(1, @min(std.fmt.parseInt(i64, s, 10) catch 1, 2))),
            else => 1,
        };
        const raw: i64 = switch (v) {
            .integer => |n| n,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch 1,
            else => 1,
        };
        if (raw > 2) return Error.BadConfig; // 参考：planes > 2 → exit(1)
    }

    const arr = image_cfg.getArray(media_obj, "array_organization") orelse return list.toOwnedSlice(allocator);
    for (arr.items) |item| {
        const obj = image_cfg.asObject(item) orelse continue;
        const page = image_cfg.getStr(obj, "page") orelse continue;
        const block = image_cfg.getStr(obj, "block") orelse continue;
        try list.append(allocator, .{
            .page_kib = digitsOnly(page),
            .block_kib = digitsOnly(block),
            .planes = planes,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// `img_gen_fw_file_name()`：`<platform>_<product>_v<version>[_c<counter>].img`，空格换下划线。
pub fn fwFileName(allocator: std.mem.Allocator, info_obj: std.json.ObjectMap, product: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const platform = image_cfg.getStr(info_obj, "platform") orelse "unknown";
    const version = image_cfg.getStr(info_obj, "version") orelse "0.0.0";
    try out.writer.print("{s}_{s}_v{s}", .{ platform, product, version });
    if (image_cfg.getStr(info_obj, "anti-rollback")) |c| try out.writer.print("_c{s}", .{c});
    try out.writer.writeAll(".img");
    for (out.written()) |*c| {
        if (c.* == ' ') c.* = '_';
    }
    return out.toOwnedSlice();
}

/// `_page_2k_block_128k`（参考 `"_page_{}_block_{}".format(page, block).lower()`）。
fn orgParam(allocator: std.mem.Allocator, org: ArrayOrg) ![]u8 {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "_page_{d}k_block_{d}k", .{ org.page_kib, org.block_kib });
    return allocator.dupe(u8, s);
}

pub const Variant = struct {
    product: []const u8,
    part_table: []const u8,
    org: ArrayOrg,
};

/// 构造变体列表。
///
/// 参考 `get_spinand_image_list()`：**只要介质是 spi-nand**，就会按 `array_organization`
/// 逐项产出镜像（`imglist` 非空即走 `fixup_spinand_ubi_fwc_name`），因此 product 与分区表名
/// 都会带 `_page_2k_block_128k` / `(page_2k_block_128k)` 后缀 —— 与组织项数量无关。
fn buildVariants(
    allocator: std.mem.Allocator,
    info_obj: std.json.ObjectMap,
    media: []const image_cfg.Media,
    orgs: []const ArrayOrg,
) ![]Variant {
    const product = image_cfg.getStr(info_obj, "product") orelse "unknown";
    const nand = media.len > 0 and std.mem.eql(u8, media[0].media_type, "spi-nand");

    if (nand) {
        if (orgs.len == 0) return Error.BadConfig; // 参考此时会在页表生成处崩
        var list: std.ArrayList(Variant) = .empty;
        errdefer list.deinit(allocator);
        for (orgs) |org| {
            const param = try orgParam(allocator, org);
            const prod = try std.fmt.allocPrint(allocator, "{s}{s}", .{ product, param });
            // 参考：`"{}({})".format(backup, paramstr[1:])`
            const table = try std.fmt.allocPrint(allocator, DEFAULT_PART_TABLE ++ "({s})", .{param[1..]});
            try list.append(allocator, .{ .product = prod, .part_table = table, .org = org });
        }
        return list.toOwnedSlice(allocator);
    }

    const single = [_]Variant{.{
        .product = try allocator.dupe(u8, product),
        .part_table = try allocator.dupe(u8, DEFAULT_PART_TABLE),
        .org = if (orgs.len > 0) orgs[0] else .{},
    }};
    return allocator.dupe(Variant, &single);
}

fn isSupportedMedia(t: []const u8) bool {
    return std.mem.eql(u8, t, "spi-nor") or std.mem.eql(u8, t, "spi-nand") or std.mem.eql(u8, t, "mmc");
}

/// 分区索引（含 UBI 卷名 `part:vol`）——等价 `img_get_part_size()` 的 partition_table。
fn collectParts(
    arena: std.mem.Allocator,
    map: *std.StringHashMap(PartRange),
    root: std.json.Value,
    m: image_cfg.Media,
) !void {
    if (!isSupportedMedia(m.media_type)) return Error.UnsupportedMedia;
    const root_obj = image_cfg.asObject(root) orelse return Error.BadConfig;
    const dev = image_cfg.getObj(root_obj, m.name) orelse return Error.BadConfig;
    const total: u64 = if (image_cfg.getStr(dev, "size")) |s| try utils.sizeStrToInt(s) else 0;
    const parts_obj = image_cfg.getObj(dev, "partitions") orelse return Error.BadConfig;

    var cursor: u64 = 0;
    var it = parts_obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const obj = image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig;
        const size_str = image_cfg.getStr(obj, "size") orelse return Error.BadConfig;
        var size: u64 = try utils.sizeStrToInt(size_str);
        if (std.mem.eql(u8, std.mem.trim(u8, size_str, " \t"), "-")) {
            size = if (total > cursor) total - cursor else 0;
        }
        if (image_cfg.getStr(obj, "offset")) |off| cursor = try utils.sizeStrToInt(off);

        if (image_cfg.getObj(obj, "ubi")) |vols| {
            var voff = cursor;
            var vit = vols.iterator();
            while (vit.next()) |vent| {
                const vobj = image_cfg.asObject(vent.value_ptr.*) orelse return Error.BadConfig;
                const vsize_str = image_cfg.getStr(vobj, "size") orelse return Error.BadConfig;
                var vsize: u64 = try utils.sizeStrToInt(vsize_str);
                if (std.mem.eql(u8, std.mem.trim(u8, vsize_str, " \t"), "-")) vsize = size;
                if (image_cfg.getStr(vobj, "offset")) |voff_str| voff = try utils.sizeStrToInt(voff_str);
                const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ name, vent.key_ptr.* });
                try map.put(key, .{ .start = voff, .size = vsize, .device = m.name, .media_type = m.media_type });
                voff += vsize;
            }
            cursor = voff;
        } else {
            try map.put(name, .{ .start = cursor, .size = size, .device = m.name, .media_type = m.media_type });
            cursor += size;
        }
    }
}

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(allocator, &b);
}

fn ensureLen(list: *std.ArrayList(u8), allocator: std.mem.Allocator, len: usize) !void {
    if (list.items.len >= len) return;
    const old = list.items.len;
    try list.resize(allocator, len);
    @memset(list.items[old..], 0xFF);
}

pub const Result = struct {
    files: [][]u8,
    /// 每个 bin 文件写入的整片长度（供汇报与断言）
    sizes: []u64,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
        allocator.free(self.sizes);
    }
};

/// 生成 burner 产物到 `<out_dir>/burner/`。
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg_path: []const u8,
    datadir: []const u8,
    out_dir: []const u8,
) !Result {
    var cfg = try image_cfg.load(allocator, io, cfg_path);
    defer cfg.deinit();
    const root = cfg.root();
    const root_obj = image_cfg.asObject(root.*) orelse return Error.BadConfig;

    const image_obj = image_cfg.getObj(root_obj, "image") orelse return Error.BadConfig;
    const info_obj = image_cfg.getObj(image_obj, "info") orelse return Error.BadConfig;
    const media_obj = image_cfg.getObj(info_obj, "media") orelse return Error.BadConfig;
    const target_obj = image_cfg.getObj(image_obj, "target") orelse return Error.BadConfig;

    const media = try image_cfg.mediaList(allocator, root.*);
    defer allocator.free(media);
    if (media.len == 0) return Error.BadConfig;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parts = std.StringHashMap(PartRange).init(a);
    for (media) |m| try collectParts(a, &parts, root.*, m);

    const orgs = try parseOrgs(a, media_obj);
    const variants = try buildVariants(a, info_obj, media, orgs);

    const burner_dir = try std.fs.path.join(allocator, &.{ out_dir, "burner" });
    defer allocator.free(burner_dir);
    try std.Io.Dir.cwd().createDirPath(io, burner_dir);

    var files: std.ArrayList([]u8) = .empty;
    var sizes: std.ArrayList(u64) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
        sizes.deinit(allocator);
    }

    for (variants) |v| {
        for (media, 0..) |m, idx| {
            const suffix: []const u8 = if (media.len > 1 and idx > 0)
                try std.fmt.allocPrint(a, "_{s}", .{m.name})
            else
                "";

            const img_name = try fwFileName(a, info_obj, v.product);
            const bin_name = try pyReplace(a, img_name, ".img", try std.fmt.allocPrint(a, "{s}.bin", .{suffix}));
            const table_name = try pyReplace(a, v.part_table, ".bin", try std.fmt.allocPrint(a, "{s}.bin", .{suffix}));

            const bin_path = try std.fs.path.join(a, &.{ burner_dir, bin_name });
            const table_path = try std.fs.path.join(a, &.{ burner_dir, table_name });

            const dev_obj = image_cfg.getObj(root_obj, m.name) orelse return Error.BadConfig;
            const media_size_raw: u64 = if (image_cfg.getStr(dev_obj, "size")) |s| try utils.sizeStrToInt(s) else 0;
            const media_size = @min(media_size_raw, BIN_FILE_MAX_SIZE);
            if (media_size == 0) return Error.BadConfig;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.resize(allocator, @intCast(media_size));
            @memset(buf.items, 0xFF);

            // spi-nand：镜像开头写 AICP 页表（SPL 需要）
            if (std.mem.eql(u8, m.media_type, "spi-nand")) {
                if (v.org.page_kib == 0 or v.org.block_kib == 0) return Error.BadConfig;
                const spl_name = blk: {
                    const spl = image_cfg.getObj(target_obj, "spl") orelse return Error.SplFileNotFound;
                    break :blk image_cfg.getStr(spl, "file") orelse return Error.SplFileNotFound;
                };
                const spl_path = try std.fs.path.join(a, &.{ datadir, spl_name });
                const spl_data = std.Io.Dir.cwd().readFileAlloc(io, spl_path, a, .unlimited) catch return Error.SplFileNotFound;
                const page = fw_image.PageTable.build(a, spl_data, .{
                    .page_kib = v.org.page_kib,
                    .block_kib = v.org.block_kib,
                    .planes = v.org.planes,
                }) catch |err| switch (err) {
                    error.SplTooLarge => return Error.SplTooLarge,
                    else => return err,
                };
                if (page.len > buf.items.len) return Error.MediaTooLarge;
                @memcpy(buf.items[0..page.len], page);
            }

            var table: std.ArrayList(u8) = .empty;
            defer table.deinit(allocator);

            const page_table_size: u64 = @as(u64, v.org.page_kib) * 1024;

            var tit = target_obj.iterator();
            while (tit.next()) |te| {
                const key = te.key_ptr.*;
                const comp = image_cfg.asObject(te.value_ptr.*) orelse return Error.BadConfig;
                const file_name = image_cfg.getStr(comp, "file") orelse return Error.BadConfig;

                // 参考会把 `.ubifs` 换成 `.ubi`（UBI 卷镜像由 ubinize 产出）
                const name_owned: []const u8 = if (std.mem.find(u8, file_name, ".ubifs") != null)
                    try pyReplace(a, file_name, ".ubifs", ".ubi")
                else
                    file_name;
                const path = try std.fs.path.join(a, &.{ datadir, name_owned });
                const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch continue;
                if (data.len == 0) continue;

                const part = try image_cfg.partString(a, comp);
                const first_part = if (std.mem.findScalar(u8, part, ';')) |i| part[0..i] else part;
                if (first_part.len == 0) continue;

                const range = parts.get(first_part) orelse return Error.PartitionNotFound;
                if (!std.mem.eql(u8, range.device, m.name)) continue;

                var part_offset = range.start;
                const part_size = range.size;
                var filesize: u64 = utils.roundUp(data.len, fw_image.DATA_ALIGNED_SIZE);

                const is_spl_nand = std.mem.eql(u8, key, "spl") and std.mem.eql(u8, range.media_type, "spi-nand");
                if (is_spl_nand) filesize += page_table_size;

                const info = calcBlockInfo(range.media_type, part_offset, part_size, filesize, v.org.block_kib);
                try appendU32(&table, allocator, info.start);
                try appendU32(&table, allocator, info.last);
                try appendU32(&table, allocator, info.used);
                try appendU32(&table, allocator, 0xFFFFFFFF);

                if (is_spl_nand) {
                    part_offset += page_table_size;
                    filesize -= page_table_size;
                }
                try ensureLen(&buf, allocator, @intCast(part_offset + data.len));
                @memcpy(buf.items[@intCast(part_offset)..][0..data.len], data);

                if (is_spl_nand) filesize += page_table_size;
                if (part_size < filesize) return Error.ComponentTooLarge;
                // 参考随后把分区剩余空间填 0xFF（整片已预填，这里只需保证文件长度）
                try ensureLen(&buf, allocator, @intCast(range.start + part_size));
            }

            try table.appendNTimes(allocator, 0xFF, 16);

            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = buf.items });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = table_path, .data = table.items });
            try files.append(allocator, try std.fs.path.join(allocator, &.{ "burner", bin_name }));
            try sizes.append(allocator, buf.items.len);
        }
    }

    return .{ .files = try files.toOwnedSlice(allocator), .sizes = try sizes.toOwnedSlice(allocator) };
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------

test "burner.calcBlockInfo：四种介质块号换算" {
    // spi-nor：64 KiB 块
    const nor = calcBlockInfo("spi-nor", 512 * 1024, 2 * 1024 * 1024, 200 * 1024, 0);
    try std.testing.expectEqual(@as(u32, 8), nor.start); // 512K / 64K
    try std.testing.expectEqual(@as(u32, 4), nor.used); // 200K 上取整 = 4 块
    try std.testing.expectEqual(@as(u32, 11), nor.last);

    // spi-nand：128 KiB 块，分区大小决定 total_block
    const nand = calcBlockInfo("spi-nand", 0, 4 * 1024 * 1024, 300 * 1024, 128);
    try std.testing.expectEqual(@as(u32, 0), nand.start);
    try std.testing.expectEqual(@as(u32, 3), nand.used);
    try std.testing.expectEqual(@as(u32, 32), nand.total);
    try std.testing.expectEqual(@as(u32, 31), nand.last);

    // mmc：512 B 扇区；跨块判定用 512 KiB
    const mmc = calcBlockInfo("mmc", 1024 * 1024, 8 * 1024 * 1024, 4096, 0);
    try std.testing.expectEqual(@as(u32, 2048), mmc.start);
    try std.testing.expectEqual(@as(u32, 9), mmc.used); // 4096/512=8，再按 512KiB 判定 +1
    try std.testing.expectEqual(@as(u32, 2056), mmc.last);
}

test "burner.pyReplace / fwFileName / digitsOnly" {
    const allocator = std.testing.allocator;
    {
        const s = try pyReplace(allocator, "a.img.bin", ".img", ".bin");
        defer allocator.free(s);
        try std.testing.expectEqualStrings("a.bin.bin", s);
    }
    {
        const s = try pyReplace(allocator, "firmware.bin", ".img", ".bin");
        defer allocator.free(s);
        try std.testing.expectEqualStrings("firmware.bin", s);
    }
    try std.testing.expectEqual(@as(u32, 2), digitsOnly("2K"));
    try std.testing.expectEqual(@as(u32, 128), digitsOnly("128k"));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"platform":"d13x","product":"demo 88-nor","version":"1.0.0"}
    , .{});
    defer parsed.deinit();
    const obj = image_cfg.asObject(parsed.value).?;
    const name = try fwFileName(allocator, obj, "demo 88-nor");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("d13x_demo_88-nor_v1.0.0.img", name);
}

test "burner.parseOrgs：page/block/planes 解析与上限校验" {
    const allocator = std.testing.allocator;
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
            \\{"array_organization":[{"page":"2K","block":"128K"},{"page":"4K","block":"256K"}],"planes":"1"}
        , .{});
        defer parsed.deinit();
        const obj = image_cfg.asObject(parsed.value).?;
        const orgs = try parseOrgs(allocator, obj);
        defer allocator.free(orgs);
        try std.testing.expectEqual(@as(usize, 2), orgs.len);
        try std.testing.expectEqual(@as(u32, 2), orgs[0].page_kib);
        try std.testing.expectEqual(@as(u32, 128), orgs[0].block_kib);
        try std.testing.expectEqual(@as(u32, 4), orgs[1].page_kib);
        try std.testing.expectEqual(@as(u8, 1), orgs[1].planes);
    }
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
            \\{"planes":4}
        , .{});
        defer parsed.deinit();
        const obj = image_cfg.asObject(parsed.value).?;
        try std.testing.expectError(Error.BadConfig, parseOrgs(allocator, obj));
    }
}
