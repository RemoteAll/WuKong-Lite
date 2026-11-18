//! 生成 `partition_file_list.h` —— 对应参考工程 `tools/scripts/gen_partition_file_list.py`。
//! 输出格式：`<partition>,<file>,<partition_size>\n`，供 `wk image fat --fullpart` 等使用。
const std = @import("std");
const image_cfg = @import("image_cfg.zig");
const partition_table = @import("partition_table.zig");

pub const Error = error{ BadConfig, MissingTarget };

fn firstPart(comp: std.json.ObjectMap, a: std.mem.Allocator) !?[]u8 {
    const s = try image_cfg.partString(a, comp);
    defer a.free(s);
    if (s.len == 0) return null;
    if (std.mem.findScalar(u8, s, ';')) |i| return @as(?[]u8, try a.dupe(u8, s[0..i]));
    return @as(?[]u8, try a.dupe(u8, s));
}

pub fn generate(a: std.mem.Allocator, io: std.Io, cfg_path: []const u8) ![]u8 {
    var cfg = try image_cfg.load(a, io, cfg_path);
    defer cfg.deinit();
    return generateFromRoot(a, cfg.root().*);
}

pub fn generateFromRoot(a: std.mem.Allocator, root_value: std.json.Value) ![]u8 {
    const root = &root_value;
    const root_obj = image_cfg.asObject(root.*) orelse return Error.BadConfig;
    const image_obj = image_cfg.getObj(root_obj, "image") orelse return Error.BadConfig;
    const target_obj = image_cfg.getObj(image_obj, "target") orelse return Error.MissingTarget;

    const media = try image_cfg.mediaList(a, root.*);
    defer a.free(media);
    var parts = std.StringHashMap(u64).init(a);
    defer parts.deinit();
    for (media) |m| {
        const list = try partition_table.layout(a, root.*, m.name);
        defer a.free(list);
        for (list) |p| try parts.put(p.name, p.size);
    }

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var it = target_obj.iterator();
    while (it.next()) |entry| {
        const comp = image_cfg.asObject(entry.value_ptr.*) orelse return Error.BadConfig;
        const file = image_cfg.getStr(comp, "file") orelse return Error.BadConfig;
        const part = (try firstPart(comp, a)) orelse continue;
        defer a.free(part);
        const size = parts.get(part) orelse 0;
        try out.writer.print("{s},{s},{d}\n", .{ part, file, size });
    }
    return out.toOwnedSlice();
}

test "partlist：target 顺序与分区大小" {
    const a = std.testing.allocator;
    const cfg =
        \\{
        \\  "spi-nor": {"size":"1m","partitions":{"os":{"size":"2m"},"data":{"size":"1m"}}},
        \\  "image": {"info":{"media":{"type":"spi-nor"}},
        \\    "target":{"os":{"file":"os.itb","part":["os"]},"data":{"file":"data.lfs","part":["data"]}}}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, cfg, .{});
    defer parsed.deinit();
    const out = try generateFromRoot(a, parsed.value);
    defer a.free(out);
    try std.testing.expectEqualStrings("os,os.itb,2097152\ndata,data.lfs,1048576\n", out);
}
