//! `.map` 链接尺寸统计 —— 对应参考工程 `tools/scripts/linked_size.py`。
//!
//! 解析 "Linker script and memory map" 之后的段总行与文件行，生成：
//!   * `<base>.summary.csv`：Section,Size,Unused
//!   * `<base>.detail.csv`：Folder/File,Summary,<section...>
//!   * `<base>.dironly.csv`：同上，只保留目录
const std = @import("std");

pub const Error = error{NoMemoryMap, BadSection};

const FileInfo = struct {
    size: u64 = 0,
    is_file: bool = false,
};

const Section = struct {
    name: []u8,
    size: u64 = 0,
    files: std.StringHashMap(FileInfo),

    fn deinit(self: *Section, a: std.mem.Allocator) void {
        a.free(self.name);
        var it = self.files.iterator();
        while (it.next()) |e| a.free(e.key_ptr.*);
        self.files.deinit();
    }
};

pub const Stats = struct {
    allocator: std.mem.Allocator,
    sections: std.ArrayList(Section),

    pub fn deinit(self: *Stats) void {
        for (self.sections.items) |*s| s.deinit(self.allocator);
        self.sections.deinit(self.allocator);
    }

    fn find(self: *Stats, name: []const u8) ?*Section {
        for (self.sections.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn ensure(self: *Stats, name: []const u8) !*Section {
        if (self.find(name)) |s| return s;
        const copy = try self.allocator.dupe(u8, name);
        try self.sections.append(self.allocator, .{ .name = copy, .files = std.StringHashMap(FileInfo).init(self.allocator) });
        return &self.sections.items[self.sections.items.len - 1];
    }

    fn addPath(section: *Section, a: std.mem.Allocator, path: []const u8, size: u64, is_file: bool) !void {
        var norm_buf: std.ArrayList(u8) = .empty;
        defer norm_buf.deinit(a);
        for (path) |c| try norm_buf.append(a, if (c == '\\') '/' else c);
        const norm = norm_buf.items;
        if (norm.len == 0) return;

        if (section.files.getPtr(norm)) |info| {
            info.size += size;
            if (is_file) info.is_file = true;
        } else {
            const key = try a.dupe(u8, norm);
            try section.files.put(key, .{ .size = size, .is_file = is_file });
        }

        // 目录聚合
        var dir = norm;
        while (std.mem.lastIndexOfScalar(u8, dir, '/')) |idx| {
            dir = dir[0..idx];
            if (dir.len == 0) break;
            if (section.files.getPtr(dir)) |info| {
                info.size += size;
            } else {
                const key = try a.dupe(u8, dir);
                try section.files.put(key, .{ .size = size, .is_file = false });
            }
        }
    }

    fn addFile(self: *Stats, section_name: []const u8, path: []const u8, size: u64) !void {
        const s = try self.ensure(section_name);
        try addPath(s, self.allocator, path, size, true);
    }

    fn isSkipped(name: []const u8) bool {
        return std.mem.startsWith(u8, name, ".note") or
            std.mem.startsWith(u8, name, ".debug") or
            std.mem.startsWith(u8, name, ".comment");
    }

    fn summaryCsv(self: *Stats, a: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(a);
        errdefer aw.deinit();
        try aw.writer.writeAll("Section,Size,Unused\n");
        var total: u64 = 0;
        for (self.sections.items) |s| {
            if (isSkipped(s.name) or s.size == 0) continue;
            var unused: u64 = 0;
            if (s.files.getPtr("unknown")) |u| unused = u.size;
            try aw.writer.print("{s},{d},{d}\n", .{ s.name, s.size, unused });
            total += s.size;
        }
        try aw.writer.print("Total,{d},0\n", .{total});
        return aw.toOwnedSlice();
    }

    fn visible(self: *Stats) usize {
        var n: usize = 0;
        for (self.sections.items) |s| {
            if (!isSkipped(s.name) and s.size > 0) n += 1;
        }
        return n;
    }

    fn detailCsv(self: *Stats, a: std.mem.Allocator, dir_only: bool) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(a);
        errdefer aw.deinit();

        try aw.writer.writeAll("Folder/File,Summary");
        var total: u64 = 0;
        for (self.sections.items) |s| {
            if (isSkipped(s.name) or s.size == 0) continue;
            try aw.writer.print(",{s}", .{s.name});
            total += s.size;
        }
        try aw.writer.writeByte('\n');
        try aw.writer.print("Total,{d}", .{total});
        for (self.sections.items) |s| {
            if (isSkipped(s.name) or s.size == 0) continue;
            try aw.writer.print(",{d}", .{s.size});
        }
        try aw.writer.writeByte('\n');

        // 收集所有 key（同名只保留一次）并排序
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(a);
        for (self.sections.items) |s| {
            if (isSkipped(s.name) or s.size == 0) continue;
            var it = s.files.iterator();
            while (it.next()) |e| {
                var exists = false;
                for (keys.items) |k| {
                    if (std.mem.eql(u8, k, e.key_ptr.*)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) try keys.append(a, e.key_ptr.*);
            }
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);

        for (keys.items) |key| {
            var sum: u64 = 0;
            var is_file = false;
            for (self.sections.items) |s| {
                if (isSkipped(s.name) or s.size == 0) continue;
                if (s.files.getPtr(key)) |info| {
                    sum += info.size;
                    if (info.is_file) is_file = true;
                }
            }
            if (dir_only and is_file) continue;
            try aw.writer.print("{s},{d}", .{ key, sum });
            for (self.sections.items) |s| {
                if (isSkipped(s.name) or s.size == 0) continue;
                const v: u64 = if (s.files.getPtr(key)) |info| info.size else 0;
                try aw.writer.print(",{d}", .{v});
            }
            try aw.writer.writeByte('\n');
        }
        return aw.toOwnedSlice();
    }
};

fn isHex(s: []const u8) bool {
    return s.len > 2 and (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"));
}

fn parseHex(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, s, 0) catch Error.BadSection;
}

/// 解析 map 文本；只统计 "Linker script and memory map" 之后的内容。
pub fn parse(a: std.mem.Allocator, text: []const u8) !Stats {
    var stats = Stats{ .allocator = a, .sections = .empty };
    errdefer stats.deinit();

    var it = std.mem.splitScalar(u8, text, '\n');
    var in_map = false;
    var pending_section: ?[]const u8 = null;
    while (it.next()) |raw| {
        if (!in_map) {
            if (std.mem.find(u8, raw, "Linker script and memory map") != null) in_map = true;
            continue;
        }
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "LOAD ") or std.mem.startsWith(u8, line, "OUTPUT(")) continue;
        if (std.mem.find(u8, line, "*(COMMON)")) |_| continue;

        var toks: [8][]const u8 = undefined;
        var n: usize = 0;
        var tit = std.mem.tokenizeAny(u8, line, " \t");
        while (tit.next()) |t| {
            if (n < toks.len) toks[n] = t;
            n += 1;
        }
        if (n == 0) continue;

        const indented = line[0] == ' ' or line[0] == '\t';
        if (!indented) {
            if (n >= 3 and isHex(toks[1]) and isHex(toks[2])) {
                const s = try stats.ensure(toks[0]);
                s.size = try parseHex(toks[2]);
                pending_section = null;
            } else if (n == 1 and toks[0].len > 0 and toks[0][0] == '.') {
                // 段名单独一行，addr/size 在下一行
                pending_section = toks[0];
            }
            continue;
        }

        if (n == 2 and isHex(toks[0]) and isHex(toks[1]) and pending_section != null) {
            const s = try stats.ensure(pending_section.?);
            s.size = try parseHex(toks[1]);
            pending_section = null;
            continue;
        }
        if (n >= 4 and isHex(toks[1]) and isHex(toks[2])) {
            if (stats.sections.items.len == 0) continue;
            const cur = &stats.sections.items[stats.sections.items.len - 1];
            try Stats.addPath(cur, a, toks[3], try parseHex(toks[2]), true);
            continue;
        }
        if (n == 3 and isHex(toks[0]) and isHex(toks[1])) {
            if (stats.sections.items.len == 0) continue;
            const cur = &stats.sections.items[stats.sections.items.len - 1];
            try Stats.addPath(cur, a, toks[2], try parseHex(toks[1]), true);
            continue;
        }
    }
    return stats;
}

pub fn run(a: std.mem.Allocator, io: std.Io, map_path: []const u8, out_dir: ?[]const u8) !struct { summary: []u8, detail: []u8, dironly: []u8 } {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, map_path, a, .unlimited);
    defer a.free(text);
    var stats = try parse(a, text);
    defer stats.deinit();

    const summary = try stats.summaryCsv(a);
    errdefer a.free(summary);
    const detail = try stats.detailCsv(a, false);
    errdefer a.free(detail);
    const dironly = try stats.detailCsv(a, true);
    errdefer a.free(dironly);

    const base = if (std.mem.endsWith(u8, map_path, ".map")) map_path[0 .. map_path.len - 4] else map_path;
    const dir = out_dir orelse std.fs.path.dirname(map_path) orelse ".";
    const files = [_]struct { name: []const u8, data: []u8 }{
        .{ .name = ".summary.csv", .data = summary },
        .{ .name = ".detail.csv", .data = detail },
        .{ .name = ".dironly.csv", .data = dironly },
    };
    for (files) |f| {
        const name = try std.fmt.allocPrint(a, "{s}{s}", .{ std.fs.path.basename(base), f.name });
        defer a.free(name);
        const path = try std.fs.path.join(a, &.{ dir, name });
        defer a.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = f.data });
    }
    return .{ .summary = summary, .detail = detail, .dironly = dironly };
}

test "linksize：解析段总行与文件行" {
    const a = std.testing.allocator;
    const text =
        \\Memory Configuration
        \\Linker script and memory map
        \\
        \\.text           0x41000000       0x20
        \\ .text          0x41000000       0x10 G:\src\foo.o
        \\.rodata         0x41000020       0x08
        \\ .rodata        0x41000020       0x08 G:\src\foo.o
    ;
    var stats = try parse(a, text);
    defer stats.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.sections.items.len);
    try std.testing.expectEqual(@as(u64, 0x20), stats.sections.items[0].size);
    try std.testing.expectEqual(@as(u64, 0x08), stats.sections.items[1].size);
    const csv = try stats.summaryCsv(a);
    defer a.free(csv);
    try std.testing.expect(std.mem.find(u8, csv, ".text,32,0") != null);
    try std.testing.expect(std.mem.find(u8, csv, "Total,40,0") != null);
}
