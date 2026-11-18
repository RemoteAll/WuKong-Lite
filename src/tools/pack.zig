//! 镜像打包流水线 —— 对应 Luban-Lite `mk_image.py` 的固件包生成部分：
//!
//!   image_cfg.json  +  数据目录
//!       -> AIC.FW 固件包（文件头 + META 组件表 + 数据区）
//!
//! 支持的组件来源：`image.updater.*` 与 `image.target.*`。
//! 说明：签名（RSA/SM2）、加密（AES-CBC）、ITB/FIT 与 SPI 屏加密不在本实现范围内，
//! 遇到相关配置会明确报错，避免生成不可用的镜像。
const std = @import("std");
const fw_image = @import("../bsp/common/fw_image.zig");
const image_cfg = @import("image_cfg.zig");
const partition_table = @import("partition_table.zig");
const utils = @import("../bsp/common/utils.zig");
const image = @import("../bsp/common/image.zig");

pub const HeaderInfo = struct {
    platform: []const u8,
    product: []const u8,
    version: []const u8,
    media_types: []const []const u8,
    dev_ids: [4]u8 = .{ 0, 0, 0, 0 },
    nand_array_org: []const u8 = "",
};

/// 纯函数：把已读入内存的组件打包为 AIC.FW（image.info 插在 updater 之后）。
pub fn packFromComponents(
    allocator: std.mem.Allocator,
    info: HeaderInfo,
    updater: []const fw_image.Component,
    target: []const fw_image.Component,
) ![]u8 {
    var comps: std.ArrayList(fw_image.Component) = .empty;
    defer comps.deinit(allocator);
    try comps.appendSlice(allocator, updater);
    try comps.appendSlice(allocator, target);

    var media_buf: std.Io.Writer.Allocating = .init(allocator);
    defer media_buf.deinit();
    for (info.media_types, 0..) |m, idx| {
        if (idx != 0) try media_buf.writer.writeByte(';');
        try media_buf.writer.writeAll(m);
    }

    const header = fw_image.FwHeader{
        .platform = info.platform,
        .product = info.product,
        .version = info.version,
        .media_type = media_buf.written(),
        .media_dev_id = info.dev_ids,
        .nand_array_org = info.nand_array_org,
    };

    return fw_image.pack(allocator, .{
        .header = header,
        .components = comps.items,
        .info_index = updater.len,
    });
}

const PartRange = struct {
    start: u64,
    size: u64,
    media_type: []const u8,
};

/// 从 image_cfg 构建“分区名 → 范围/介质”索引。
fn buildPartMap(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    media: []const image_cfg.Media,
) !std.StringHashMap(PartRange) {
    var map = std.StringHashMap(PartRange).init(allocator);
    errdefer map.deinit();
    for (media) |m| {
        const parts = try partition_table.layout(allocator, root, m.name);
        defer allocator.free(parts);
        for (parts) |p| {
            try map.put(p.name, .{ .start = p.start, .size = p.size, .media_type = m.media_type });
        }
    }
    return map;
}

fn resolveRam(comp: std.json.ObjectMap) u32 {
    if (image_cfg.getStr(comp, "ram")) |s| {
        return std.fmt.parseInt(u32, s, 0) catch 0xFFFFFFFF;
    }
    return 0xFFFFFFFF;
}

fn readComponentFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    file_name: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ datadir, file_name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ComponentFileNotFound,
        else => return err,
    };
}

/// 解析 `array_organization` 为 `P=2K,B=128K;...` 字符串（与 mk_image.py 一致）。
fn buildNandOrg(allocator: std.mem.Allocator, media: std.json.ObjectMap) ![]u8 {
    const arr = image_cfg.getArray(media, "array_organization") orelse return try allocator.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var first = true;
    for (arr.items) |item| {
        const obj = image_cfg.asObject(item) orelse continue;
        const page = image_cfg.getStr(obj, "page") orelse continue;
        const block = image_cfg.getStr(obj, "block") orelse continue;
        if (!first) try out.writer.writeByte(';');
        first = false;
        try out.writer.print("P={s},B={s}", .{ page, block });
    }
    return out.toOwnedSlice();
}

/// 逐字节对比两段固件包，返回差异数量与首个差异偏移。
pub const CompareResult = struct {
    ref_len: usize,
    zig_len: usize,
    diff: usize,
    first: ?usize,
};

pub fn compareBytes(ref: []const u8, zig: []const u8) CompareResult {
    const n = @min(ref.len, zig.len);
    var diff: usize = 0;
    var first: ?usize = null;
    for (ref[0..n], zig[0..n], 0..) |a, b, i| {
        if (a != b) {
            diff += 1;
            if (first == null) first = i;
        }
    }
    if (ref.len != zig.len) diff += if (ref.len > zig.len) ref.len - zig.len else zig.len - ref.len;
    return .{ .ref_len = ref.len, .zig_len = zig.len, .diff = diff, .first = first };
}

/// 读取 image_cfg.json 与数据目录，生成 AIC.FW 固件包。
pub fn buildFirmware(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg_path: []const u8,
    datadir: []const u8,
) ![]u8 {
    var cfg = try image_cfg.load(allocator, io, cfg_path);
    defer cfg.deinit();
    const root = cfg.root();
    const root_obj = image_cfg.asObject(root.*) orelse return error.BadConfig;

    const image_obj = image_cfg.getObj(root_obj, "image") orelse return error.BadConfig;
    const info_obj = image_cfg.getObj(image_obj, "info") orelse return error.BadConfig;
    const media_obj = image_cfg.getObj(info_obj, "media") orelse return error.BadConfig;

    // 拒绝未实现的加签/加密配置
    if (image_cfg.getObj(info_obj, "sign") != null or image_cfg.getObj(info_obj, "encrypt") != null) {
        return error.SigningOrEncryptionNotSupported;
    }

    const media = try image_cfg.mediaList(allocator, root.*);
    defer allocator.free(media);

    var media_types: std.ArrayList([]const u8) = .empty;
    defer media_types.deinit(allocator);
    var dev_ids: [4]u8 = .{ 0, 0, 0, 0 };
    for (media, 0..) |m, idx| {
        try media_types.append(allocator, m.media_type);
        if (idx < 4) dev_ids[idx] = @intCast(m.controller);
    }

    const nand_org = try buildNandOrg(allocator, media_obj);
    defer allocator.free(nand_org);

    var part_map = try buildPartMap(allocator, root.*, media);
    defer part_map.deinit();

    // 组件元数据（名称/attr/part）统一放在 arena，随函数结束释放
    var meta_arena = std.heap.ArenaAllocator.init(allocator);
    defer meta_arena.deinit();
    const meta_alloc = meta_arena.allocator();

    var data_allocs: std.ArrayList([]u8) = .empty;
    defer {
        for (data_allocs.items) |d| allocator.free(d);
        data_allocs.deinit(allocator);
    }

    const ComponentList = std.ArrayList(fw_image.Component);
    var updater: ComponentList = .empty;
    defer updater.deinit(allocator);
    var target: ComponentList = .empty;
    defer target.deinit(allocator);

    try collectSection(
        allocator,
        meta_alloc,
        io,
        datadir,
        image_obj,
        "updater",
        &part_map,
        &updater,
        &data_allocs,
    );
    try collectSection(
        allocator,
        meta_alloc,
        io,
        datadir,
        image_obj,
        "target",
        &part_map,
        &target,
        &data_allocs,
    );

    const header_info = HeaderInfo{
        .platform = image_cfg.getStr(info_obj, "platform") orelse "unknown",
        .product = image_cfg.getStr(info_obj, "product") orelse "unknown",
        .version = image_cfg.getStr(info_obj, "version") orelse "0.0.0",
        .media_types = media_types.items,
        .dev_ids = dev_ids,
        .nand_array_org = nand_org,
    };

    return packFromComponents(allocator, header_info, updater.items, target.items);
}

fn isOptionalComponent(comp: std.json.ObjectMap) bool {
    const v = comp.get("attr") orelse return false;
    switch (v) {
        .string => |s| return std.mem.find(u8, s, "optional") != null,
        .array => |arr| {
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| if (std.mem.eql(u8, s, "optional")) return true,
                    else => {},
                }
            }
        },
        else => {},
    }
    return false;
}

fn collectSection(
    allocator: std.mem.Allocator,
    meta_alloc: std.mem.Allocator,
    io: std.Io,
    datadir: []const u8,
    image_obj: std.json.ObjectMap,
    section: []const u8,
    part_map: *std.StringHashMap(PartRange),
    out: *std.ArrayList(fw_image.Component),
    data_allocs: *std.ArrayList([]u8),
) !void {
    const sect_obj = image_cfg.getObj(image_obj, section) orelse return;
    var it = sect_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const comp = image_cfg.asObject(entry.value_ptr.*) orelse return error.BadConfig;

        const file_name = image_cfg.getStr(comp, "file") orelse return error.MissingComponentFile;
        const data = readComponentFile(allocator, io, datadir, file_name) catch |err| switch (err) {
            error.ComponentFileNotFound => {
                if (isOptionalComponent(comp)) continue;
                return err;
            },
            else => return err,
        };
        try data_allocs.append(allocator, data);

        const attr = try image_cfg.attrString(meta_alloc, comp);
        const part = try image_cfg.partString(meta_alloc, comp);

        var part_offset: u32 = 0;
        var part_size: u32 = 0;
        var dev_name: []const u8 = "ram";
        const dev_id: u32 = 0;
        if (std.mem.eql(u8, section, "target")) {
            if (part.len > 0) {
                const first_part = if (std.mem.findScalar(u8, part, ';')) |idx| part[0..idx] else part;
                if (part_map.get(first_part)) |range| {
                    part_offset = @intCast(range.start);
                    part_size = @intCast(range.size);
                    dev_name = range.media_type;
                } else {
                    return error.PartitionNotFound;
                }
            }
        }

        var name_buf: std.Io.Writer.Allocating = .init(meta_alloc);
        try name_buf.writer.print("image.{s}.{s}", .{ section, key });

        try out.append(allocator, .{
            .name = try meta_alloc.dupe(u8, name_buf.written()),
            .file_name = file_name,
            .data = data,
            .attr = attr,
            .part = part,
            .part_offset = part_offset,
            .part_size = part_size,
            .dev_name = dev_name,
            .dev_id = dev_id,
            .ram = resolveRam(comp),
        });
    }
}

/// 生成单文件 AIC 可启动镜像（`wk image aic`）。
pub fn buildAicImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    load_addr: u32,
    entry: u32,
    head_ver: u32,
) ![]u8 {
    const fw = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(fw);
    return image.createV1(allocator, fw, load_addr, entry, null, head_ver);
}

/// 读取 env.txt（可带分区串前缀），生成 env.bin。
pub fn buildEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    txt_path: []const u8,
    size: usize,
    redundant: bool,
    prefix: []const u8,
) ![]u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, txt_path, allocator, .unlimited);
    defer allocator.free(text);
    const data = try @import("../bsp/common/env_image.zig").textToData(allocator, text, prefix);
    defer allocator.free(data);
    return @import("../bsp/common/env_image.zig").build(allocator, data, .{
        .size = size,
        .redundant = redundant,
    });
}

/// 计算某个 SPL 文件的 NAND 页表（`wk image pagetable`）。
pub fn buildPageTable(
    allocator: std.mem.Allocator,
    io: std.Io,
    spl_path: []const u8,
    page_kib: u32,
    block_kib: u32,
    planes: u8,
) ![]u8 {
    const spl = try std.Io.Dir.cwd().readFileAlloc(io, spl_path, allocator, .unlimited);
    defer allocator.free(spl);
    return fw_image.PageTable.build(allocator, spl, .{
        .page_kib = page_kib,
        .block_kib = block_kib,
        .planes = planes,
    });
}

test "packFromComponents 生成的组件顺序与元数据" {
    const allocator = std.testing.allocator;
    const updater = [_]fw_image.Component{
        .{
            .name = "image.updater.psram",
            .file_name = "psram.bin",
            .data = "PSRAMDATA",
            .attr = "required;run",
            .ram = 0x30044000,
        },
    };
    const target = [_]fw_image.Component{
        .{
            .name = "image.target.spl",
            .file_name = "bootloader.aic",
            .data = "BOOTLOADER",
            .attr = "mtd;required",
            .part = "spl",
            .part_offset = 0,
            .part_size = 512 * 1024,
            .dev_name = "spi-nor",
        },
    };
    const fw = try packFromComponents(allocator, .{
        .platform = "d13x",
        .product = "demo88-nor",
        .version = "1.0.0",
        .media_types = &.{"spi-nor"},
        .dev_ids = .{ 0, 0, 0, 0 },
    }, &updater, &target);
    defer allocator.free(fw);

    try std.testing.expect(fw_image.headerIsValid(fw));
    const header = try fw_image.FwHeader.parse(fw);
    try std.testing.expectEqualStrings("spi-nor", header.media_type);
    try std.testing.expectEqual(@as(u32, 3 * fw_image.META_ALIGNED_SIZE), header.meta_size);

    const metas = try fw_image.readMeta(allocator, fw);
    defer allocator.free(metas);
    try std.testing.expectEqualStrings("image.updater.psram", metas[0].nameStr());
    try std.testing.expectEqualStrings("image.info", metas[1].nameStr());
    try std.testing.expectEqualStrings("image.target.spl", metas[2].nameStr());
    try std.testing.expectEqualStrings("spi-nor", metas[2].devNameStr());
    try std.testing.expectEqual(@as(u32, 0x30044000), metas[0].ram);
    try std.testing.expectEqualStrings("BOOTLOADER", fw[metas[2].offset_in_img..][0..10]);
}

test "compareBytes：逐字节差异统计" {
    const a = [_]u8{ 1, 2, 3, 4, 5 };
    const b = [_]u8{ 1, 9, 3, 8, 5 };
    const r = compareBytes(&a, &b);
    try std.testing.expectEqual(@as(usize, 5), r.ref_len);
    try std.testing.expectEqual(@as(usize, 5), r.zig_len);
    try std.testing.expectEqual(@as(usize, 2), r.diff);
    try std.testing.expectEqual(@as(?usize, 1), r.first);

    const c = [_]u8{ 1, 2, 3 };
    const r2 = compareBytes(&a, &c);
    try std.testing.expectEqual(@as(usize, 2), r2.diff);
    try std.testing.expectEqual(@as(?usize, null), r2.first);
}
