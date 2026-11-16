//! 分区表生成 —— 对应 Luban-Lite `tools/scripts/gen_partition_table.py`：
//!
//!   * `--json`  输出结构化分区表（供 partition_check.py 工具链使用）
//!   * `--outfile` 输出 C 头文件：
//!         #define IMAGE_CFG_JSON_PARTS_MTD "spi0.0:512k(spl),..."
//!         #define IMAGE_CFG_JSON_PARTS_UBI "..."
//!         #define IMAGE_CFG_JSON_PARTS_GPT "..."
//!         FAL_PART_TABLE { ... }
//!
//! 偏移计算规则与 mk_image.py 一致：
//!   * 分区顺序累加；`offset` 字段可显式覆盖；
//!   * `size` 为 `-` 时取设备剩余空间。
const std = @import("std");
const utils = @import("../bsp/common/utils.zig");
const image_cfg = @import("image_cfg.zig");

pub const PartInfo = struct {
    name: []const u8,
    start: u64,
    size: u64,
    /// 配置中的原始 size 字符串（保留 "512k" 之类写法）
    size_str: []const u8 = "",
    has_explicit_offset: bool = false,
};

/// 计算某个设备的分区布局（按配置顺序）。
pub fn layout(allocator: std.mem.Allocator, root: std.json.Value, device_name: []const u8) ![]PartInfo {
    const root_obj = image_cfg.asObject(root) orelse return error.BadConfig;
    const dev = image_cfg.getObj(root_obj, device_name) orelse return error.DeviceNotFound;
    const device_size: u64 = if (image_cfg.getStr(dev, "size")) |s| try utils.sizeStrToInt(s) else 0;

    const parts_obj = image_cfg.getObj(dev, "partitions") orelse return error.NoPartitions;

    var list: std.ArrayList(PartInfo) = .empty;
    errdefer list.deinit(allocator);

    var cursor: u64 = 0;
    var it = parts_obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const part_obj = image_cfg.asObject(entry.value_ptr.*) orelse return error.BadConfig;

        const size_str = image_cfg.getStr(part_obj, "size") orelse return error.MissingPartitionSize;
        var size: u64 = try utils.sizeStrToInt(size_str);
        var explicit = false;
        if (image_cfg.getStr(part_obj, "offset")) |off_str| {
            cursor = try utils.sizeStrToInt(off_str);
            explicit = true;
        }
        if (std.mem.eql(u8, std.mem.trim(u8, size_str, " \t"), "-")) {
            size = if (device_size > cursor) device_size - cursor else 0;
        }
        try list.append(allocator, .{
            .name = name,
            .start = cursor,
            .size = size,
            .size_str = size_str,
            .has_explicit_offset = explicit,
        });
        cursor +%= size;
    }
    return list.toOwnedSlice(allocator);
}

fn appendItem(w: *std.Io.Writer, part: PartInfo) !void {
    try w.writeAll(part.size_str);
    if (part.has_explicit_offset) {
        try w.print("@{X}", .{part.start});
    }
    try w.print("({s})", .{part.name});
}

/// 生成 C 头文件正文（不含 include guard 注释头）。
pub fn generateHeader(allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
    const media = try image_cfg.mediaList(allocator, root);
    defer allocator.free(media);

    var mtd_devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (mtd_devs.items) |s| allocator.free(s);
        mtd_devs.deinit(allocator);
    }
    var ubi_devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (ubi_devs.items) |s| allocator.free(s);
        ubi_devs.deinit(allocator);
    }
    var gpt_devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (gpt_devs.items) |s| allocator.free(s);
        gpt_devs.deinit(allocator);
    }

    var fal_entries: std.Io.Writer.Allocating = .init(allocator);
    defer fal_entries.deinit();

    var spi_nor_index: u32 = 0;
    const root_obj = image_cfg.asObject(root) orelse return error.BadConfig;

    for (media) |m| {
        const parts = try layout(allocator, root, m.name);
        defer allocator.free(parts);

        const is_mtd = std.mem.eql(u8, m.media_type, "spi-nor") or std.mem.eql(u8, m.media_type, "spi-nand");
        if (is_mtd) {
            var dev_str: std.Io.Writer.Allocating = .init(allocator);
            defer dev_str.deinit();
            try dev_str.writer.print("spi{d}.0:", .{m.controller});
            for (parts, 0..) |p, idx| {
                if (idx != 0) try dev_str.writer.writeByte(',');
                try appendItem(&dev_str.writer, p);
            }
            try mtd_devs.append(allocator, try dev_str.toOwnedSlice());

            // UBI 卷
            if (image_cfg.getObj(root_obj, m.name)) |dev_obj| {
                if (image_cfg.getObj(dev_obj, "partitions")) |parts_obj| {
                    var pit = parts_obj.iterator();
                    while (pit.next()) |entry| {
                        const part_obj = image_cfg.asObject(entry.value_ptr.*) orelse continue;
                        const volumes = image_cfg.getObj(part_obj, "ubi") orelse continue;
                        var ubi_str: std.Io.Writer.Allocating = .init(allocator);
                        defer ubi_str.deinit();
                        try ubi_str.writer.print("{s}:", .{entry.key_ptr.*});
                        var vit = volumes.iterator();
                        var first = true;
                        while (vit.next()) |vent| {
                            if (!first) try ubi_str.writer.writeByte(',');
                            first = false;
                            const vol = image_cfg.asObject(vent.value_ptr.*) orelse continue;
                            const vsize = image_cfg.getStr(vol, "size") orelse "-";
                            try ubi_str.writer.print("{s}({s})", .{ vsize, vent.key_ptr.* });
                        }
                        try ubi_devs.append(allocator, try ubi_str.toOwnedSlice());
                    }
                }
            }

            // FAL 分区表（仅 spi-nor）
            if (std.mem.eql(u8, m.media_type, "spi-nor")) {
                for (parts) |p| {
                    try fal_entries.writer.print("    {{FAL_PART_MAGIC_WORD, \"{s}\",", .{p.name});
                    if (spi_nor_index > 0) {
                        try fal_entries.writer.print("FAL_USING_NOR_FLASH_DEV_NAME{d}, ", .{spi_nor_index});
                    } else {
                        try fal_entries.writer.writeAll("FAL_USING_NOR_FLASH_DEV_NAME, ");
                    }
                    try fal_entries.writer.print("{d},{d},0}}, \\\n", .{ p.start, p.size });
                }
                spi_nor_index += 1;
            }
        } else if (std.mem.eql(u8, m.media_type, "mmc")) {
            var gpt_str: std.Io.Writer.Allocating = .init(allocator);
            defer gpt_str.deinit();
            for (parts, 0..) |p, idx| {
                if (idx != 0) try gpt_str.writer.writeByte(',');
                try appendItem(&gpt_str.writer, p);
            }
            try gpt_devs.append(allocator, try gpt_str.toOwnedSlice());
        } else {
            return error.UnsupportedMedia;
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (mtd_devs.items.len > 0) {
        try w.writeAll("#define IMAGE_CFG_JSON_PARTS_MTD \"");
        for (mtd_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeAll("\"\n");
    }
    if (ubi_devs.items.len > 0) {
        try w.writeAll("#define IMAGE_CFG_JSON_PARTS_UBI \"");
        for (ubi_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeAll("\"\n");
    }
    if (gpt_devs.items.len > 0) {
        try w.writeAll("#define IMAGE_CFG_JSON_PARTS_GPT \"");
        for (gpt_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeAll("\"\n");
    }
    if (fal_entries.written().len > 0) {
        try w.writeAll("\n#ifdef FAL_PART_HAS_TABLE_CFG\n#define FAL_PART_TABLE \\\n{ \\\n");
        try w.writeAll(fal_entries.written());
        try w.writeAll("}\n#endif\n");
    }
    return out.toOwnedSlice();
}

/// 生成 JSON 分区表（与 `gen_partition_table.py --json` 输出格式一致）。
pub fn generateJson(allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
    const media = try image_cfg.mediaList(allocator, root);
    defer allocator.free(media);

    const StringList = std.ArrayList([]const u8);
    var mtd_list: StringList = .empty;
    defer freeList(allocator, &mtd_list);
    var ubi_list: StringList = .empty;
    defer freeList(allocator, &ubi_list);
    var nftl_list: StringList = .empty;
    defer freeList(allocator, &nftl_list);
    var levelx_list: StringList = .empty;
    defer freeList(allocator, &levelx_list);
    var gpt_list: StringList = .empty;
    defer freeList(allocator, &gpt_list);

    var part_types: std.ArrayList([]const u8) = .empty;
    defer part_types.deinit(allocator);

    const root_obj = image_cfg.asObject(root) orelse return error.BadConfig;

    for (media) |m| {
        const parts = try layout(allocator, root, m.name);
        defer allocator.free(parts);

        const is_mtd = std.mem.eql(u8, m.media_type, "spi-nor") or std.mem.eql(u8, m.media_type, "spi-nand");
        if (is_mtd) {
            var dev_str: std.Io.Writer.Allocating = .init(allocator);
            defer dev_str.deinit();
            try dev_str.writer.print("spi{d}.0:", .{m.controller});
            for (parts, 0..) |p, idx| {
                if (idx != 0) try dev_str.writer.writeByte(',');
                try appendItem(&dev_str.writer, p);
            }
            try mtd_list.append(allocator, try dev_str.toOwnedSlice());
            try addPartType(&part_types, allocator, "mtd");

            // ubi / nftl / levelx 卷
            if (image_cfg.getObj(root_obj, m.name)) |dev_obj| {
                if (image_cfg.getObj(dev_obj, "partitions")) |parts_obj| {
                    var pit = parts_obj.iterator();
                    while (pit.next()) |entry| {
                        const part_obj = image_cfg.asObject(entry.value_ptr.*) orelse continue;
                        inline for (.{ .{ "ubi", &ubi_list }, .{ "nftl", &nftl_list }, .{ "levelx", &levelx_list } }) |pair| {
                            const key = pair[0];
                            const list: *StringList = pair[1];
                            if (image_cfg.getObj(part_obj, key)) |volumes| {
                                var vol_str: std.Io.Writer.Allocating = .init(allocator);
                                defer vol_str.deinit();
                                try vol_str.writer.print("{s}:", .{entry.key_ptr.*});
                                var vit = volumes.iterator();
                                var first = true;
                                while (vit.next()) |vent| {
                                    if (!first) try vol_str.writer.writeByte(',');
                                    first = false;
                                    const vol = image_cfg.asObject(vent.value_ptr.*) orelse continue;
                                    const vsize = image_cfg.getStr(vol, "size") orelse "-";
                                    try vol_str.writer.print("{s}({s})", .{ vsize, vent.key_ptr.* });
                                }
                                try list.append(allocator, try vol_str.toOwnedSlice());
                                try addPartType(&part_types, allocator, key);
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, m.media_type, "mmc")) {
            var gpt_str: std.Io.Writer.Allocating = .init(allocator);
            defer gpt_str.deinit();
            for (parts, 0..) |p, idx| {
                if (idx != 0) try gpt_str.writer.writeByte(',');
                try appendItem(&gpt_str.writer, p);
            }
            try gpt_list.append(allocator, try gpt_str.toOwnedSlice());
            try addPartType(&part_types, allocator, "gpt");
        } else {
            return error.UnsupportedMedia;
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var fields: std.ArrayList([]const u8) = .empty;
    defer {
        for (fields.items) |f| allocator.free(f);
        fields.deinit(allocator);
    }

    const kinds = [_]struct { name: []const u8, list: *StringList }{
        .{ .name = "mtd", .list = &mtd_list },
        .{ .name = "ubi", .list = &ubi_list },
        .{ .name = "nftl", .list = &nftl_list },
        .{ .name = "levelx", .list = &levelx_list },
        .{ .name = "gpt", .list = &gpt_list },
    };
    for (kinds) |k| {
        if (k.list.items.len == 0) continue;
        var merged: std.Io.Writer.Allocating = .init(allocator);
        defer merged.deinit();
        for (k.list.items, 0..) |s, idx| {
            if (idx != 0) try merged.writer.writeByte(';');
            try merged.writer.writeAll(s);
        }
        try fields.append(allocator, try std.fmt.allocPrint(allocator, "\t\t\"{s}\" : \"{s}\"", .{ k.name, merged.written() }));
    }

    // type 数组（去重并保持顺序）
    var type_field: std.Io.Writer.Allocating = .init(allocator);
    defer type_field.deinit();
    try type_field.writer.writeAll("\t\t\"type\": [");
    for (part_types.items, 0..) |t, idx| {
        if (idx != 0) try type_field.writer.writeAll(", ");
        try type_field.writer.print("\"{s}\"", .{t});
    }
    try type_field.writer.writeByte(']');
    try fields.append(allocator, try type_field.toOwnedSlice());

    try w.writeAll("{\n\t\"partitions\": {\n");
    for (fields.items, 0..) |f, idx| {
        try w.writeAll(f);
        if (idx + 1 < fields.items.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try w.writeAll("\t}\n}");
    return out.toOwnedSlice();
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

fn addPartType(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, name: []const u8) !void {
    for (list.items) |t| {
        if (std.mem.eql(u8, t, name)) return;
    }
    try list.append(allocator, name);
}

/// 生成 `kuboot_env_create_image` 使用的分区串前缀（MTD/UBI/GPT/parts_mmc）。
pub fn partsForEnv(allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
    const media = try image_cfg.mediaList(allocator, root);
    defer allocator.free(media);

    var mtd_devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (mtd_devs.items) |s| allocator.free(s);
        mtd_devs.deinit(allocator);
    }
    var ubi_devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (ubi_devs.items) |s| allocator.free(s);
        ubi_devs.deinit(allocator);
    }
    var gpt_devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (gpt_devs.items) |s| allocator.free(s);
        gpt_devs.deinit(allocator);
    }

    const root_obj = image_cfg.asObject(root) orelse return error.BadConfig;
    for (media) |m| {
        const parts = try layout(allocator, root, m.name);
        defer allocator.free(parts);

        const is_mtd = std.mem.eql(u8, m.media_type, "spi-nor") or std.mem.eql(u8, m.media_type, "spi-nand");
        if (is_mtd) {
            var dev_str: std.Io.Writer.Allocating = .init(allocator);
            defer dev_str.deinit();
            try dev_str.writer.print("spi{d}.0:", .{m.controller});
            for (parts, 0..) |p, idx| {
                if (idx != 0) try dev_str.writer.writeByte(',');
                try appendItem(&dev_str.writer, p);
            }
            try mtd_devs.append(allocator, try dev_str.toOwnedSlice());

            if (image_cfg.getObj(root_obj, m.name)) |dev_obj| {
                if (image_cfg.getObj(dev_obj, "partitions")) |parts_obj| {
                    var pit = parts_obj.iterator();
                    while (pit.next()) |entry| {
                        const part_obj = image_cfg.asObject(entry.value_ptr.*) orelse continue;
                        const volumes = image_cfg.getObj(part_obj, "ubi") orelse continue;
                        var ubi_str: std.Io.Writer.Allocating = .init(allocator);
                        defer ubi_str.deinit();
                        try ubi_str.writer.print("{s}:", .{entry.key_ptr.*});
                        var vit = volumes.iterator();
                        var first = true;
                        while (vit.next()) |vent| {
                            if (!first) try ubi_str.writer.writeByte(',');
                            first = false;
                            const vol = image_cfg.asObject(vent.value_ptr.*) orelse continue;
                            const vsize = image_cfg.getStr(vol, "size") orelse "-";
                            try ubi_str.writer.print("{s}({s})", .{ vsize, vent.key_ptr.* });
                        }
                        try ubi_devs.append(allocator, try ubi_str.toOwnedSlice());
                    }
                }
            }
        } else if (std.mem.eql(u8, m.media_type, "mmc")) {
            var gpt_str: std.Io.Writer.Allocating = .init(allocator);
            defer gpt_str.deinit();
            for (parts, 0..) |p, idx| {
                if (idx != 0) try gpt_str.writer.writeByte(',');
                try appendItem(&gpt_str.writer, p);
            }
            try gpt_devs.append(allocator, try gpt_str.toOwnedSlice());
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (mtd_devs.items.len > 0) {
        try w.writeAll("MTD=");
        for (mtd_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeByte('\n');
    }
    if (ubi_devs.items.len > 0) {
        try w.writeAll("UBI=");
        for (ubi_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeByte('\n');
    }
    if (gpt_devs.items.len > 0) {
        try w.writeAll("GPT=");
        for (gpt_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeAll("\nparts_mmc=");
        for (gpt_devs.items, 0..) |s, idx| {
            if (idx != 0) try w.writeByte(';');
            try w.writeAll(s);
        }
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

const sample_cfg =
    \\{
    \\  "spi-nor": {
    \\    "size": "16m",
    \\    "partitions": {
    \\      "spl":  { "size": "512k" },
    \\      "env":  { "size": "128k" },
    \\      "os":   { "size": "2m" },
    \\      "data": { "size": "-" },
    \\    },
    \\  },
    \\  "image": {
    \\    "info": { "media": { "type": "spi-nor", "device_id": 0 } },
    \\  },
    \\}
;

test "分区布局与偏移计算" {
    const allocator = std.testing.allocator;
    const normalized = try image_cfg.normalize(allocator, sample_cfg);
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();

    const parts = try layout(allocator, parsed.value, "spi-nor");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqual(@as(u64, 0), parts[0].start);
    try std.testing.expectEqual(@as(u64, 512 * 1024), parts[1].start);
    try std.testing.expectEqual(@as(u64, 512 * 1024 + 128 * 1024), parts[2].start);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), parts[2].size);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 - (512 + 128 + 2048) * 1024), parts[3].size);
}

test "生成 MTD 宏与 FAL 表" {
    const allocator = std.testing.allocator;
    const normalized = try image_cfg.normalize(allocator, sample_cfg);
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();

    const header = try generateHeader(allocator, parsed.value);
    defer allocator.free(header);

    try std.testing.expect(std.mem.find(u8, header, "#define IMAGE_CFG_JSON_PARTS_MTD \"spi0.0:512k(spl),128k(env),2m(os),-(data)\"") != null);
    try std.testing.expect(std.mem.find(u8, header, "FAL_PART_TABLE") != null);
    try std.testing.expect(std.mem.find(u8, header, "{FAL_PART_MAGIC_WORD, \"spl\",FAL_USING_NOR_FLASH_DEV_NAME, 0,524288,0}, \\") != null);
}

test "生成 JSON 分区表" {
    const allocator = std.testing.allocator;
    const normalized = try image_cfg.normalize(allocator, sample_cfg);
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();

    const json = try generateJson(allocator, parsed.value);
    defer allocator.free(json);

    var reparsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer reparsed.deinit();
    const parts_obj = reparsed.value.object.get("partitions").?.object;
    try std.testing.expectEqualStrings("spi0.0:512k(spl),128k(env),2m(os),-(data)", parts_obj.get("mtd").?.string);
    const types = parts_obj.get("type").?.array;
    try std.testing.expectEqual(@as(usize, 1), types.items.len);
    try std.testing.expectEqualStrings("mtd", types.items[0].string);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\n\t\"partitions\": {\n\t\t\"mtd\" : "));
}
