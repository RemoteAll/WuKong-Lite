//! `image_cfg.json` 解析 —— 复刻 Luban-Lite `tools/scripts/mk_image.py` 的
//! `parse_image_cfg()`：
//!   * 支持 `//` 行内/整行注释
//!   * 支持对象/数组末尾的逗号
//!   * 保留键的插入顺序（与 Python OrderedDict 一致）
const std = @import("std");

/// 去注释 + 去尾逗号，得到严格 JSON 文本。
pub fn normalize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var in_string = false;
    var escape = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            try out.append(allocator, c);
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            try out.append(allocator, c);
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            // 跳过到行尾
            while (i < text.len and text[i] != '\n') i += 1;
            if (i < text.len) try out.append(allocator, '\n');
            continue;
        }
        try out.append(allocator, c);
    }

    // 去掉 `,}` 与 `,]`（允许中间有空白）
    var cleaned: std.ArrayList(u8) = .empty;
    errdefer cleaned.deinit(allocator);
    var j: usize = 0;
    while (j < out.items.len) : (j += 1) {
        const c = out.items[j];
        if (c == ',' or c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            // 向后找第一个非空白字符
            var k = j + 1;
            while (k < out.items.len and std.ascii.isWhitespace(out.items[k])) k += 1;
            if (c == ',' and k < out.items.len and (out.items[k] == '}' or out.items[k] == ']')) {
                continue; // 丢弃尾逗号
            }
            try cleaned.append(allocator, c);
            continue;
        }
        try cleaned.append(allocator, c);
    }
    return cleaned.toOwnedSlice(allocator);
}

pub const ParsedConfig = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ParsedConfig) void {
        self.parsed.deinit();
    }

    pub fn root(self: *const ParsedConfig) *const std.json.Value {
        return &self.parsed.value;
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ParsedConfig {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(raw);
    const normalized = try normalize(allocator, raw);
    defer allocator.free(normalized);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    return .{ .parsed = parsed };
}

// ----------------------------------------------------------------------
// JSON 取值辅助
// ----------------------------------------------------------------------

pub fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 0) catch null,
        else => null,
    };
}

pub fn getObj(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return asObject(v);
}

pub fn getArray(obj: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

pub const Media = struct {
    /// 设备名（旧格式下等于类型名，如 "spi-nor"）
    name: []const u8,
    /// 介质类型：spi-nor / spi-nand / mmc
    media_type: []const u8,
    controller: u32,
};

/// `_extract_media_info()`：兼容旧格式 `{type, device_id}` 与新格式 `{name[], controller[]}`。
pub fn mediaList(allocator: std.mem.Allocator, root: std.json.Value) ![]Media {
    const root_obj = asObject(root) orelse return error.BadConfig;
    const image = getObj(root_obj, "image") orelse return error.BadConfig;
    const info = getObj(image, "info") orelse return error.BadConfig;
    const media = getObj(info, "media") orelse return error.BadConfig;

    var list: std.ArrayList(Media) = .empty;
    errdefer list.deinit(allocator);

    if (getStr(media, "type")) |mt| {
        // 旧格式：type 可为字符串或字符串数组
        const dev_id_v = media.get("device_id");
        const type_v = media.get("type").?;
        if (std.meta.activeTag(type_v) == .array) {
            const types = media.get("type").?.array;
            for (types.items, 0..) |tv, idx| {
                const mt_name = switch (tv) {
                    .string => |s| s,
                    else => return error.BadConfig,
                };
                var ctrl: u32 = 0;
                if (dev_id_v) |dv| switch (dv) {
                    .integer => |n| ctrl = @intCast(n),
                    .array => |arr| {
                        if (idx < arr.items.len) {
                            ctrl = @intCast(arr.items[idx].integer);
                        }
                    },
                    else => {},
                };
                try list.append(allocator, .{ .name = mt_name, .media_type = mt_name, .controller = ctrl });
            }
        } else {
            var ctrl: u32 = 0;
            if (dev_id_v) |dv| switch (dv) {
                .integer => |n| ctrl = @intCast(n),
                .string => |s| ctrl = std.fmt.parseInt(u32, s, 0) catch 0,
                else => {},
            };
            try list.append(allocator, .{ .name = mt, .media_type = mt, .controller = ctrl });
        }
        return list.toOwnedSlice(allocator);
    }

    // 新格式
    const names = getArray(media, "name") orelse return error.BadConfig;
    const controllers = getArray(media, "controller");
    for (names.items, 0..) |nv, idx| {
        const device_name = switch (nv) {
            .string => |s| s,
            else => return error.BadConfig,
        };
        var ctrl: u32 = 0;
        if (controllers) |arr| {
            if (idx < arr.items.len) {
                switch (arr.items[idx]) {
                    .integer => |n| ctrl = @intCast(n),
                    .string => |s| ctrl = std.fmt.parseInt(u32, s, 0) catch 0,
                    else => {},
                }
            }
        }
        const media_type = blk: {
            if (getObj(root_obj, device_name)) |dev_obj| {
                if (getStr(dev_obj, "type")) |t| break :blk t;
            }
            break :blk device_name;
        };
        try list.append(allocator, .{ .name = device_name, .media_type = media_type, .controller = ctrl });
    }
    return list.toOwnedSlice(allocator);
}

/// 组件字段 `part` 可能是字符串或数组；数组统一用 ';' 连接。
pub fn partString(allocator: std.mem.Allocator, comp: std.json.ObjectMap) ![]const u8 {
    const v = comp.get("part") orelse return "";
    switch (v) {
        .string => |s| return s,
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            for (arr.items, 0..) |item, idx| {
                if (idx != 0) try out.append(allocator, ';');
                switch (item) {
                    .string => |s| try out.appendSlice(allocator, s),
                    else => return error.BadConfig,
                }
            }
            return out.toOwnedSlice(allocator);
        },
        else => return "",
    }
}

/// `attr` 数组用 ';' 连接并去空格（与 mk_image.py 一致）。
pub fn attrString(allocator: std.mem.Allocator, comp: std.json.ObjectMap) ![]const u8 {
    const v = comp.get("attr") orelse return "";
    switch (v) {
        .string => |s| return s,
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            for (arr.items, 0..) |item, idx| {
                if (idx != 0) try out.append(allocator, ';');
                switch (item) {
                    .string => |s| {
                        for (s) |c| {
                            if (c == ' ') continue;
                            try out.append(allocator, c);
                        }
                    },
                    else => return error.BadConfig,
                }
            }
            return out.toOwnedSlice(allocator);
        },
        else => return "",
    }
}

test "去掉 // 注释与尾逗号" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\    // 设备
        \\    "spi-nor": { "size": "16m", // 容量
        \\        "partitions": {
        \\            "spl": { "size": "512k" },
        \\            "data": { "size": "-" },
        \\        },
        \\    },
        \\}
    ;
    const cleaned = try normalize(allocator, raw);
    defer allocator.free(cleaned);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, cleaned, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("spi-nor") != null);
    const dev = parsed.value.object.get("spi-nor").?.object;
    try std.testing.expectEqualStrings("16m", dev.get("size").?.string);
}

test "兼容新旧 media 格式" {
    const allocator = std.testing.allocator;
    const old_cfg =
        \\{"image":{"info":{"media":{"type":"spi-nor","device_id":0}}}}
    ;
    var parsed_old = try std.json.parseFromSlice(std.json.Value, allocator, old_cfg, .{});
    defer parsed_old.deinit();
    const old_list = try mediaList(allocator, parsed_old.value);
    defer allocator.free(old_list);
    try std.testing.expectEqual(@as(usize, 1), old_list.len);
    try std.testing.expectEqualStrings("spi-nor", old_list[0].media_type);
    try std.testing.expectEqual(@as(u32, 0), old_list[0].controller);

    const new_cfg =
        \\{"spi-nand0":{"type":"spi-nand"},
        \\ "image":{"info":{"media":{"name":["spi-nand0"],"controller":[1]}}}}
    ;
    var parsed_new = try std.json.parseFromSlice(std.json.Value, allocator, new_cfg, .{});
    defer parsed_new.deinit();
    const new_list = try mediaList(allocator, parsed_new.value);
    defer allocator.free(new_list);
    try std.testing.expectEqualStrings("spi-nand", new_list[0].media_type);
    try std.testing.expectEqual(@as(u32, 1), new_list[0].controller);
}
