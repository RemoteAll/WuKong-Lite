//! 分区字符串解析 —— 等价于 Luban-Lite `bsp/common/partition/partition.c`
//! 中的 `aic_part_mtd_parse` / `aic_part_gpt_parse` / `aic_part_get_byname` / `aic_part_dump`。
//!
//! 支持的字符串形态（与 U-Boot / ArtInChip 一致）：
//!   MTD=spi0.0:512k(spl),2m@0x80000(os),-(data)
//!   GPT=120m@20m(boot),-(rootfs);parts_mmc=...
//!
//! 语义细节：
//!   * 解析从最后一个 `:` 或 `=` 之后开始（`get_part_start`）；
//!   * 大小为 `-` 表示剩余全部空间（size = 0）；
//!   * 后缀 `k/K`、`m/M`、`g/G`，支持 `0x` 前缀；
//!   * `@offset` 覆盖起始地址；下一分区起点 = 当前起点 + 当前大小；
//!   * MTD 起点为 0，GPT 起点为 0x4400（MBR + GPT 头/分区表保留区）。
const std = @import("std");

pub const MAX_PARTITION_NAME = 144;

pub const Partition = struct {
    name: []const u8,
    index: u32,
    start: u64,
    size: u64,
};

pub const List = struct {
    items: []Partition,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        // 名称切片指向入参字符串，无需释放；仅释放数组本身。
        allocator.free(self.items);
        self.items = &.{};
    }

    pub fn getByName(self: *const List, name: []const u8) ?*const Partition {
        for (self.items) |*p| {
            // 与 C 的 strncmp(name, part->name, strlen(name)) 对齐：前缀匹配即可
            if (std.mem.startsWith(u8, p.name, name)) return p;
        }
        return null;
    }
};

/// 扫描字符串尾部，跳过非 `:`/`=` 字符，返回最后一个分隔符之后的位置。
fn partStart(text: []const u8) []const u8 {
    var i = text.len;
    while (i > 0) {
        const c = text[i - 1];
        if (c == ':' or c == '=') return text[i..];
        i -= 1;
    }
    return text;
}

fn skipSpaces(text: []const u8, i: *usize) void {
    while (i.* < text.len and (text[i.*] == ' ' or text[i.*] == '\t')) i.* += 1;
}

fn parseNumber(text: []const u8, i: *usize) !u64 {
    skipSpaces(text, i);
    var j = i.*;
    var base: u8 = 10;
    if (j + 1 < text.len and text[j] == '0' and (text[j + 1] == 'x' or text[j + 1] == 'X')) {
        base = 16;
        j += 2;
    }
    const begin = j;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        const ok = if (base == 16) std.ascii.isHex(c) else std.ascii.isDigit(c);
        if (!ok) break;
    }
    if (j == begin) return error.InvalidNumber;
    const v = std.fmt.parseInt(u64, text[begin..j], base) catch return error.InvalidNumber;
    i.* = j;
    return v;
}

/// 解析 `size[@offset](name)` 序列。返回的 Partition.name 指向 `text`。
pub fn parse(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_start: u64,
) ![]Partition {
    var list: std.ArrayList(Partition) = .empty;
    errdefer list.deinit(allocator);

    const body = partStart(text);
    var i: usize = 0;
    var start = base_start;
    var index: u32 = 0;

    while (true) {
        skipSpaces(body, &i);
        if (i >= body.len) break;

        var size: u64 = 0;
        if (body[i] == '-') {
            // 剩余所有空间
            size = 0;
            i += 1;
        } else {
            const raw = try parseNumber(body, &i);
            if (i < body.len) {
                switch (body[i]) {
                    'k', 'K' => {
                        size = raw * 1024;
                        i += 1;
                    },
                    'm', 'M' => {
                        size = raw * 1024 * 1024;
                        i += 1;
                    },
                    'g', 'G' => {
                        size = raw * 1024 * 1024 * 1024;
                        i += 1;
                    },
                    else => size = raw,
                }
            } else size = raw;
        }

        // 可选的 @offset
        if (i < body.len and body[i] == '@') {
            i += 1;
            start = try parseNumber(body, &i);
        }

        // 名称必须紧跟在 '(' 之后
        if (i >= body.len or body[i] != '(') return error.MissingPartitionName;
        i += 1;
        const name_begin = i;
        while (i < body.len and body[i] != ')') i += 1;
        if (i >= body.len) return error.MissingPartitionName;
        const name = body[name_begin..i];
        if (name.len == 0 or name.len >= MAX_PARTITION_NAME) return error.InvalidPartitionName;
        i += 1; // 跳过 ')'

        try list.append(allocator, .{
            .name = name,
            .index = index,
            .start = start,
            .size = size,
        });
        index += 1;

        // 跳到下一个分隔符：',' 继续，';' 或结尾停止（与 C 版一致）
        while (i < body.len and body[i] != ',' and body[i] != ';') i += 1;
        if (i < body.len and body[i] == ',') {
            i += 1;
            start +%= size;
            continue;
        }
        break;
    }

    if (list.items.len == 0) return error.EmptyPartitionTable;
    return try list.toOwnedSlice(allocator);
}

/// `aic_part_mtd_parse()`：MTD 分区从 0 开始。
pub fn parseMtd(allocator: std.mem.Allocator, text: []const u8) ![]Partition {
    return parse(allocator, text, 0);
}

/// `aic_part_gpt_parse()`：GPT 数据区从 0x4400 开始（MBR+GPT 头占用）。
pub fn parseGpt(allocator: std.mem.Allocator, text: []const u8) ![]Partition {
    return parse(allocator, text, 0x4400);
}

pub fn dump(writer: *std.Io.Writer, partitions: []const Partition) !void {
    for (partitions) |p| {
        try writer.print("{s}:\n", .{p.name});
        try writer.print("\tstart 0x{X:0>8}\n", .{p.start});
        try writer.print("\tsize  0x{X:0>8}\n", .{p.size});
    }
}

test "解析 MTD 分区串（含单位、偏移、剩余空间）" {
    const allocator = std.testing.allocator;
    const text = "MTD=spi0.0:512k(spl),128k(env),2m@0x100000(os),-(data)";
    const parts = try parseMtd(allocator, text);
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqualStrings("spl", parts[0].name);
    try std.testing.expectEqual(@as(u64, 0), parts[0].start);
    try std.testing.expectEqual(@as(u64, 512 * 1024), parts[0].size);

    try std.testing.expectEqualStrings("env", parts[1].name);
    try std.testing.expectEqual(@as(u64, 512 * 1024), parts[1].start);

    try std.testing.expectEqualStrings("os", parts[2].name);
    try std.testing.expectEqual(@as(u64, 0x100000), parts[2].start);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), parts[2].size);

    try std.testing.expectEqualStrings("data", parts[3].name);
    try std.testing.expectEqual(@as(u64, 0x100000 + 2 * 1024 * 1024), parts[3].start);
    try std.testing.expectEqual(@as(u64, 0), parts[3].size);
}

test "解析 GPT 分区串起点为 0x4400" {
    const allocator = std.testing.allocator;
    const parts = try parseGpt(allocator, "GPT=120m(boot),-(rootfs)");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(u64, 0x4400), parts[0].start);
    try std.testing.expectEqual(@as(u64, 120 * 1024 * 1024), parts[0].size);
}

test "按名称查找分区（前缀匹配，与 C 版 strncmp 一致）" {
    const allocator = std.testing.allocator;
    const parts = try parseMtd(allocator, "spi0.0:1m(spl),-(data)");
    var list = List{ .items = parts };
    defer list.deinit(allocator);

    try std.testing.expect(list.getByName("data") != null);
    try std.testing.expect(list.getByName("dat") != null);
    try std.testing.expect(list.getByName("nope") == null);
}

test "非法分区串报错" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingPartitionName, parseMtd(allocator, "spi0.0:1m"));
    try std.testing.expectError(error.InvalidNumber, parseMtd(allocator, "spi0.0:k(spl)"));
}
