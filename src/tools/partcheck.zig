//! 分区占用检查 —— 对应参考工程 `tools/scripts/partition_check.py`。
//!
//! 规则与参考一致：
//!   * `.jffs2` 按「最后一个含真实节点的擦除块末尾」计算（跳过每块头部节点）；
//!   * UBI 组件 `container:volume` 优先取卷固定大小，其次取容器固定大小；
//!   * 普通自动分区（size 为 `-`）使用 cfg 中的 `part_size`（mk_image 打包时回填）；
//!   * 其余文件按文件大小计算，`.aic` 是打包产物本身，同样按文件大小；
//!   * 默认只告警，`--strict` 时超过 100% 返回非零。
const std = @import("std");
const image_cfg = @import("image_cfg.zig");

pub const Error = error{ BadConfig, PartitionOverflow };

pub const Row = struct {
    image: []const u8,
    partition: []const u8,
    used: u64,
    part_size: u64,
    percent: f64,
    how: []const u8,
};

pub const Result = struct {
    media_type: []const u8,
    rows: []Row,
    overflow: usize,
    text: []u8,
};

/// `9m` / `512k` / `768K` / `128m` / `4096` → 字节；`-` / 空 / `auto` → null。
pub fn parseSize(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "-") or std.ascii.eqlIgnoreCase(t, "auto")) return null;

    var value = t;
    var mult: u64 = 1;
    const last = std.ascii.toLower(t[t.len - 1]);
    switch (last) {
        'k' => {
            mult = 1024;
            value = t[0 .. t.len - 1];
        },
        'm' => {
            mult = 1024 * 1024;
            value = t[0 .. t.len - 1];
        },
        'g' => {
            mult = 1024 * 1024 * 1024;
            value = t[0 .. t.len - 1];
        },
        else => {},
    }
    const num = std.fmt.parseFloat(f64, value) catch return null;
    if (num < 0) return null;
    return @intFromFloat(num * @as(f64, @floatFromInt(mult)));
}

/// 单个分区容量；`part` 支持 `container:volume`。
pub fn partCapacity(partitions: std.json.ObjectMap, part: []const u8) ?u64 {
    const colon = std.mem.findScalar(u8, part, ':');
    const container = if (colon) |i| part[0..i] else part;
    const volume = if (colon) |i| part[i + 1 ..] else "";

    const node = image_cfg.getObj(partitions, container) orelse return null;
    var size: ?u64 = null;
    if (volume.len > 0) {
        if (image_cfg.getObj(node, "ubi")) |ubi| {
            if (image_cfg.getObj(ubi, volume)) |vol| {
                if (image_cfg.getStr(vol, "size")) |s| size = parseSize(s);
            }
        }
    }
    if (size == null) {
        if (image_cfg.getStr(node, "size")) |s| size = parseSize(s);
    }
    return size;
}

fn lastUsed(seg: []const u8) usize {
    var end = seg.len;
    while (end > 0 and seg[end - 1] == 0xFF) end -= 1;
    return end;
}

fn detectEraseSize(buf: []const u8) ?usize {
    const candidates = [_]usize{
        0x1000,  0x2000,  0x4000,   0x8000,   0x10000,  0x20000,
        0x40000, 0x80000, 0x100000, 0x200000, 0x400000, 0x800000,
    };
    for (candidates) |size| {
        if (size > buf.len or buf.len % size != 0) continue;
        var ok = true;
        var b: usize = 0;
        while (b < buf.len) : (b += size) {
            if (!std.mem.eql(u8, buf[b .. b + 2], &.{ 0x85, 0x19 })) {
                ok = false;
                break;
            }
        }
        if (ok) return size;
    }
    return null;
}

/// jffs2 有效内容末尾：最后一个「除头部节点外还有真实数据」的擦除块末尾。
pub fn jffs2ContentSize(buf: []const u8) u64 {
    const erasesize = detectEraseSize(buf) orelse return lastUsed(buf);

    var content_end: u64 = 0;
    var block: usize = 0;
    while (block < buf.len) : (block += erasesize) {
        var head = block;
        if (head + 8 <= buf.len) {
            const magic = std.mem.readInt(u16, buf[head..][0..2], .little);
            const totlen = std.mem.readInt(u32, buf[head + 4 ..][0..4], .little);
            if (magic == 0x1985 and totlen > 0 and totlen <= erasesize) {
                head += @as(usize, (totlen + 3) & ~@as(u32, 3));
            }
        }
        if (head < buf.len and lastUsed(buf[head .. block + erasesize]) > 0) {
            content_end = block + lastUsed(buf[block .. block + erasesize]);
        }
    }
    return content_end;
}

fn effectiveUsage(a: std.mem.Allocator, io: std.Io, path: []const u8, stat_size: u64) !u64 {
    if (std.mem.endsWith(u8, path, ".jffs2")) {
        const buf = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        defer a.free(buf);
        return jffs2ContentSize(buf);
    }
    return stat_size;
}

/// 解析 cfg 并生成报告（不打印、不退出）。
pub fn analyze(
    a: std.mem.Allocator,
    io: std.Io,
    root_value: std.json.Value,
    dir_path: []const u8,
    threshold: f64,
) !Result {
    const root_obj = image_cfg.asObject(root_value) orelse return Error.BadConfig;
    const image_obj = image_cfg.getObj(root_obj, "image") orelse return Error.BadConfig;
    const info_obj = image_cfg.getObj(image_obj, "info") orelse return Error.BadConfig;
    const media_obj = image_cfg.getObj(info_obj, "media") orelse return Error.BadConfig;
    const media_type = image_cfg.getStr(media_obj, "type") orelse return Error.BadConfig;

    const media_root = image_cfg.getObj(root_obj, media_type) orelse return Error.BadConfig;
    const partitions = image_cfg.getObj(media_root, "partitions") orelse return Error.BadConfig;
    const targets = image_cfg.getObj(image_obj, "target") orelse return Error.BadConfig;

    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(a);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var it = targets.iterator();
    while (it.next()) |entry| try names.append(a, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names.items) |name| {
        const comp = image_cfg.getObj(targets, name) orelse continue;
        const file = image_cfg.getStr(comp, "file") orelse continue;
        if (file.len == 0) continue;

        const full = try std.fs.path.join(a, &.{ dir_path, file });
        defer a.free(full);
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        if (st.kind != .file) continue;

        const part_arr = image_cfg.getArray(comp, "part") orelse continue;
        var cap: u64 = 0;
        var part_names: std.ArrayList(u8) = .empty;
        defer part_names.deinit(a);
        var dynamic = false;
        var has_ubi = false;

        for (part_arr.items) |pv| {
            const part = switch (pv) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.findScalar(u8, part, ':') != null) {
                const container = part[0..std.mem.findScalar(u8, part, ':').?];
                if (image_cfg.getObj(partitions, container)) |node| {
                    if (image_cfg.getObj(node, "ubi") != null) has_ubi = true;
                }
            }
            if (part_names.items.len > 0) try part_names.append(a, ',');
            try part_names.appendSlice(a, part);
            const size = partCapacity(partitions, part) orelse {
                dynamic = true;
                continue;
            };
            if (!dynamic) cap += size;
        }

        if (dynamic or cap == 0) {
            if (!has_ubi) {
                if (image_cfg.getInt(comp, "part_size")) |resolved| {
                    if (resolved > 0) {
                        const used = try effectiveUsage(a, io, full, st.size);
                        try rows.append(a, .{
                            .image = name,
                            .partition = try part_names.toOwnedSlice(a),
                            .used = used,
                            .part_size = @intCast(resolved),
                            .percent = @as(f64, @floatFromInt(used)) * 100.0 / @as(f64, @floatFromInt(resolved)),
                            .how = if (std.mem.endsWith(u8, file, ".jffs2")) "content" else "file",
                        });
                    }
                }
            }
            continue;
        }

        const used = try effectiveUsage(a, io, full, st.size);
        try rows.append(a, .{
            .image = name,
            .partition = try part_names.toOwnedSlice(a),
            .used = used,
            .part_size = cap,
            .percent = @as(f64, @floatFromInt(used)) * 100.0 / @as(f64, @floatFromInt(cap)),
            .how = if (std.mem.endsWith(u8, file, ".jffs2")) "content" else "file",
        });
    }

    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, lhs: Row, rhs: Row) bool {
            return lhs.percent > rhs.percent;
        }
    }.lessThan);

    var overflow: usize = 0;
    for (rows.items) |r| {
        if (r.percent > 100.0) overflow += 1;
    }

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Partition space occupancy ({s}):\n", .{media_type});
    try w.writeAll("      image    partition          used  part_size   used%\n");
    for (rows.items) |r| {
        try w.print(
            "      {s:<8} {s:<12} {d:>10} {d:>10} {d:>7.1}% ({s})\n",
            .{ r.image, r.partition, r.used, r.part_size, r.percent, r.how },
        );
    }
    if (overflow > 0) {
        try w.writeAll("Partition overflow: ");
        var first = true;
        for (rows.items) |r| {
            if (r.percent <= 100.0) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(r.image);
        }
        try w.writeByte('\n');
    } else if (rows.items.len > 0 and rows.items[0].percent > threshold) {
        try w.print("Partition space is above {d}%\n", .{@as(u64, @intFromFloat(threshold))});
    }

    return .{
        .media_type = media_type,
        .rows = try rows.toOwnedSlice(a),
        .overflow = overflow,
        .text = try out.toOwnedSlice(),
    };
}

pub fn run(
    a: std.mem.Allocator,
    io: std.Io,
    cfg_path: []const u8,
    dir_path: []const u8,
    threshold: f64,
) !Result {
    var cfg = try image_cfg.load(a, io, cfg_path);
    defer cfg.deinit();
    return analyze(a, io, cfg.root().*, dir_path, threshold);
}

pub fn deinitResult(a: std.mem.Allocator, result: *Result) void {
    for (result.rows) |row| {
        a.free(row.partition);
    }
    a.free(result.rows);
    a.free(result.text);
}

test "partcheck：parseSize" {
    try std.testing.expectEqual(@as(?u64, 9 * 1024 * 1024), parseSize("9m"));
    try std.testing.expectEqual(@as(?u64, 512 * 1024), parseSize("512k"));
    try std.testing.expectEqual(@as(?u64, 768 * 1024), parseSize("768K"));
    try std.testing.expectEqual(@as(?u64, 4096), parseSize("4096"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("-"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("auto"));
}

test "partcheck：UBI 卷优先于容器" {
    const a = std.testing.allocator;
    const text =
        \\{"partitions":{
        \\  "ubisystem":{"size":"-","ubi":{"ota":{"size":"32m"}}},
        \\  "ubiroot":{"size":"32m","ubi":{"rootfs":{"size":"-"}}},
        \\  "os":{"size":"2m"}
        \\}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const parts = image_cfg.getObj(parsed.value.object, "partitions").?;
    try std.testing.expectEqual(@as(?u64, 32 * 1024 * 1024), partCapacity(parts, "ubisystem:ota"));
    try std.testing.expectEqual(@as(?u64, 32 * 1024 * 1024), partCapacity(parts, "ubiroot:rootfs"));
    try std.testing.expectEqual(@as(?u64, 2 * 1024 * 1024), partCapacity(parts, "os"));
    try std.testing.expectEqual(@as(?u64, null), partCapacity(parts, "ubisystem:user"));
}

test "partcheck：jffs2 跳过每块头部节点" {
    // 两个 4K 擦除块：第一块含真实数据，第二块只有头部节点 + 0xFF 填充。
    const block: usize = 0x1000;
    var buf: [8192]u8 = @splat(0xFF);
    // 块 0：12 字节 compat 节点 + 数据
    std.mem.writeInt(u16, buf[0..2], 0x1985, .little);
    std.mem.writeInt(u16, buf[2..4], 0x2000, .little);
    std.mem.writeInt(u32, buf[4..8], 12, .little);
    @memset(buf[12..24], 0xAA);
    // 块 1：只有头部节点
    std.mem.writeInt(u16, buf[block..][0..2], 0x1985, .little);
    std.mem.writeInt(u16, buf[block + 2 ..][0..2], 0x2000, .little);
    std.mem.writeInt(u32, buf[block + 4 ..][0..4], 12, .little);
    try std.testing.expectEqual(@as(u64, 24), jffs2ContentSize(&buf));
}
