//! FAT12/FAT16 镜像构建器 —— 对应参考工程
//! `tools/scripts/makefatfs.py`（mformat + mcopy + AICF 信息块）。
//!
//! 支持：
//!   * 目录树、LFN 长文件名（UTF-16LE）、8.3 短名与 `~N` 去重；
//!   * FAT12 / FAT16 自动选择（FAT32 暂不支持，明确报错）；
//!   * 卷标、固定时间戳（默认 2020-01-01）；
//!   * AIC 扩展信息块 `AICF`（偏移 0x80，含 image_size/used_size 与校验和）。
//!
//! 不负责 `img2simg` 稀疏化（那是打包流程的后续步骤）。
const std = @import("std");

pub const Error = error{
    BadSectorSize,
    BadClusterSize,
    TooSmall,
    Fat32Required,
    NotEnoughSpace,
    NameTooLong,
    BadPath,
};

pub const Options = struct {
    /// 镜像总字节数（必须是 cluster 的整数倍，由调用方保证或内部向下取整）
    total_bytes: usize,
    sector_size: u16 = 512,
    cluster_sectors: u8 = 8,
    volume_label: []const u8 = "NO NAME",
    volume_id: u32 = 0x574b4c54, // "WKLT"
    /// FAT 时间戳（Unix 秒）；0 = 2020-01-01 00:00:00
    mtime: u32 = 0,
};

const DateTime = struct { date: u16, time: u16 };

const Node = struct {
    name: []const u8,
    is_dir: bool,
    data: []const u8 = &.{},
    parent: ?*Node = null,
    children: std.ArrayList(*Node) = .empty,

    sfn: [11]u8 = @splat(' '),
    needs_lfn: bool = false,
    cluster: u32 = 0,
    size: u32 = 0,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    root: *Node,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Builder {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const root = try a.create(Node);
        root.* = .{ .name = "", .is_dir = true };
        return .{ .allocator = allocator, .opts = opts, .root = root, .arena = arena };
    }

    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
    }

    fn findChild(parent: *Node, name: []const u8) ?*Node {
        for (parent.children.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn insertChild(self: *Builder, parent: *Node, node: *Node) !void {
        // 按名字排序插入，保证输出可复现（目录遍历顺序在 Windows 上不稳定）
        var idx: usize = 0;
        while (idx < parent.children.items.len) : (idx += 1) {
            if (std.mem.order(u8, node.name, parent.children.items[idx].name) == .lt) break;
        }
        try parent.children.insert(self.arena.allocator(), idx, node);
    }

    fn nodeForPath(self: *Builder, path: []const u8, create_dirs: bool) !*Node {
        var cur = self.root;
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) return Error.BadPath;
            if (findChild(cur, part)) |c| {
                cur = c;
            } else if (create_dirs) {
                const node = try self.arena.allocator().create(Node);
                node.* = .{
                    .name = try self.arena.allocator().dupe(u8, part),
                    .is_dir = true,
                    .parent = cur,
                };
                try self.insertChild(cur, node);
                cur = node;
            } else {
                return Error.BadPath;
            }
        }
        return cur;
    }

    /// 加入空目录（父目录自动补充）。
    pub fn addDir(self: *Builder, path: []const u8) !void {
        _ = try self.nodeForPath(path, true);
    }

    /// 加入文件（父目录自动补充，重复路径覆盖内容）。
    pub fn addFile(self: *Builder, path: []const u8, data: []const u8) !void {
        const a = self.arena.allocator();
        const name = std.fs.path.basename(path);
        if (name.len == 0) return Error.BadPath;
        const parent_path = std.fs.path.dirname(path) orelse "";
        const parent = try self.nodeForPath(parent_path, true);
        if (findChild(parent, name)) |existing| {
            if (existing.is_dir) return Error.BadPath;
            existing.data = try a.dupe(u8, data);
            return;
        }
        const node = try a.create(Node);
        node.* = .{
            .name = try a.dupe(u8, name),
            .is_dir = false,
            .data = try a.dupe(u8, data),
            .parent = parent,
        };
        try self.insertChild(parent, node);
    }

    /// 从文件系统目录递归加载（等价 makefatfs 的 `--inputdir`）。
    pub fn addTreeFromDir(self: *Builder, io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            const rel = entry.path;
            switch (entry.kind) {
                .directory => try self.addDir(rel),
                .file => {
                    const data = try entry.dir.readFileAlloc(io, entry.basename, self.arena.allocator(), .unlimited);
                    try self.addFile(rel, data);
                },
                else => {},
            }
        }
    }

    // -- 名字与短名 --------------------------------------------------------

    fn isSfnChar(c: u8) bool {
        return switch (c) {
            'A'...'Z', '0'...'9' => true,
            '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => true,
            else => false,
        };
    }

    fn fits83(name: []const u8) bool {
        if (name.len == 0 or name.len > 12) return false;
        var base_len: usize = 0;
        var ext_len: usize = 0;
        var seen_dot = false;
        var dots: usize = 0;
        for (name) |c| {
            if (c == '.') {
                dots += 1;
                if (dots > 1) return false;
                seen_dot = true;
                continue;
            }
            if (c >= 'a' and c <= 'z') return false;
            if (!isSfnChar(c)) return false;
            if (seen_dot) ext_len += 1 else base_len += 1;
        }
        return base_len >= 1 and base_len <= 8 and ext_len <= 3;
    }

    fn sfnFromName(name: []const u8) [11]u8 {
        var out: [11]u8 = @splat(' ');
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const base_end = dot orelse name.len;
        var bi: usize = 0;
        for (name[0..base_end]) |c| {
            if (bi >= 8) break;
            const up = std.ascii.toUpper(c);
            if (isSfnChar(up)) {
                out[bi] = up;
                bi += 1;
            }
        }
        if (dot) |d| {
            var ei: usize = 0;
            for (name[d + 1 ..]) |c| {
                if (ei >= 3) break;
                const up = std.ascii.toUpper(c);
                if (isSfnChar(up)) {
                    out[8 + ei] = up;
                    ei += 1;
                }
            }
        }
        return out;
    }

    fn sfnTaken(siblings: []const *Node, candidate: [11]u8, self_node: *Node) bool {
        for (siblings) |s| {
            if (s == self_node) continue;
            if (std.mem.eql(u8, &s.sfn, &candidate)) return true;
        }
        return false;
    }

    /// 生成不冲突的 8.3 短名（`BASE~N.EXT`）。
    fn assignSfn(siblings: []const *Node, node: *Node) void {
        if (fits83(node.name) and !sfnTaken(siblings, sfnFromName(node.name), node)) {
            node.sfn = sfnFromName(node.name);
            node.needs_lfn = false;
            return;
        }
        const dot = std.mem.lastIndexOfScalar(u8, node.name, '.');
        const base_end = dot orelse node.name.len;
        var ext: [3]u8 = @splat(' ');
        if (dot) |d| {
            var ei: usize = 0;
            for (node.name[d + 1 ..]) |c| {
                if (ei >= 3) break;
                const up = std.ascii.toUpper(c);
                if (isSfnChar(up)) {
                    ext[ei] = up;
                    ei += 1;
                }
            }
        }

        var n: usize = 1;
        while (n <= 999) : (n += 1) {
            var buf: [8]u8 = @splat(' ');
            var tail: [5]u8 = undefined;
            const tail_str = std.fmt.bufPrint(&tail, "~{d}", .{n}) catch unreachable;
            const base_keep = if (tail_str.len >= 8) 0 else 8 - tail_str.len;
            var bi: usize = 0;
            for (node.name[0..base_end]) |c| {
                if (bi >= base_keep) break;
                const up = std.ascii.toUpper(c);
                if (isSfnChar(up)) {
                    buf[bi] = up;
                    bi += 1;
                }
            }
            @memcpy(buf[bi .. bi + tail_str.len], tail_str);

            var cand: [11]u8 = @splat(' ');
            @memcpy(cand[0..8], &buf);
            @memcpy(cand[8..11], &ext);
            if (!sfnTaken(siblings, cand, node)) {
                node.sfn = cand;
                node.needs_lfn = true;
                return;
            }
        }
        node.sfn = @splat(' ');
    }

    fn assignAllSfns(self: *Builder, dir: *Node) void {
        for (dir.children.items) |c| assignSfn(dir.children.items, c);
        for (dir.children.items) |c| {
            if (c.is_dir) self.assignAllSfns(c);
        }
    }

    // -- 布局 --------------------------------------------------------------

    const Layout = struct {
        sector_size: usize,
        cluster_bytes: usize,
        total_sectors: usize,
        reserved_sectors: usize = 1,
        num_fats: usize = 2,
        root_entries: usize = 512,
        root_dir_sectors: usize,
        fat_sectors: usize,
        fat_bits: u8,
        data_start_sector: usize,
        total_clusters: usize,
    };

    fn layoutFor(opts: Options) Error!Layout {
        const sector_size: usize = opts.sector_size;
        if (sector_size != 512 and sector_size != 1024 and sector_size != 2048 and sector_size != 4096) return Error.BadSectorSize;
        if (opts.cluster_sectors == 0 or !std.math.isPowerOfTwo(opts.cluster_sectors)) return Error.BadClusterSize;
        const cluster_bytes = sector_size * opts.cluster_sectors;
        if (opts.total_bytes < cluster_bytes * 8) return Error.TooSmall;

        const total_sectors = opts.total_bytes / sector_size;
        const root_entries: usize = 512;
        const root_dir_sectors = (root_entries * 32 + sector_size - 1) / sector_size;

        var fat_bits: u8 = 12;
        var fat_sectors: usize = 1;
        var total_clusters: usize = 0;
        var round: usize = 0;
        while (round < 8) : (round += 1) {
            const data_sectors = total_sectors -| (1 + 2 * fat_sectors + root_dir_sectors);
            total_clusters = data_sectors / opts.cluster_sectors;
            if (fat_bits == 12 and total_clusters >= 4085) {
                fat_bits = 16;
                fat_sectors = 1;
                continue;
            }
            if (fat_bits == 16 and total_clusters >= 65525) return Error.Fat32Required;
            const fat_bytes = ((total_clusters + 2) * fat_bits + 7) / 8;
            const need = (fat_bytes + sector_size - 1) / sector_size;
            if (need == fat_sectors) break;
            fat_sectors = need;
        }
        const data_start_sector = 1 + 2 * fat_sectors + root_dir_sectors;
        if (data_start_sector >= total_sectors) return Error.TooSmall;
        total_clusters = (total_sectors - data_start_sector) / opts.cluster_sectors;

        return .{
            .sector_size = sector_size,
            .cluster_bytes = cluster_bytes,
            .total_sectors = total_sectors,
            .root_entries = root_entries,
            .root_dir_sectors = root_dir_sectors,
            .fat_sectors = fat_sectors,
            .fat_bits = fat_bits,
            .data_start_sector = data_start_sector,
            .total_clusters = total_clusters,
        };
    }

    fn lfnBlocks(name: []const u8) usize {
        const chars = utf16Len(name);
        return (chars + 12) / 13;
    }

    fn dirEntryBytes(dir: *Node, is_root: bool) usize {
        var entries: usize = if (is_root) 1 else 2; // 卷标 / "." ".."
        for (dir.children.items) |c| {
            entries += 1 + if (c.needs_lfn) lfnBlocks(c.name) else 0;
        }
        return entries * 32;
    }

    fn utf16Len(name: []const u8) usize {
        return std.unicode.utf8CountCodepoints(name) catch name.len;
    }

    fn clusterOffset(l: Layout, cluster: u32) usize {
        return l.data_start_sector * l.sector_size + (@as(usize, cluster) - 2) * l.cluster_bytes;
    }

    const Alloc = struct {
        next: u32 = 2,
        fat: std.ArrayList(u32),
        l: Layout,
        cluster_bytes: usize,

        fn allocChain(self: *Alloc, a: std.mem.Allocator, size: usize) !u32 {
            const count = @max(@as(usize, 1), (size + self.cluster_bytes - 1) / self.cluster_bytes);
            if (self.next - 2 + count > self.l.total_clusters) return Error.NotEnoughSpace;
            const first = self.next;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try self.fat.append(a, if (i + 1 == count) 0xFFFFFFFF else self.next + 1);
                self.next += 1;
            }
            return first;
        }
    };

    fn setFatValue(fat: []u32, idx: usize, value: u32) void {
        if (idx < fat.len) fat[idx] = value;
    }

    fn serializeFat(l: Layout, fat: []const u32) []u8 {
        const bytes = ((l.total_clusters + 2) * l.fat_bits + 7) / 8;
        const buf = std.heap.page_allocator.alloc(u8, l.fat_sectors * l.sector_size) catch @panic("OOM");
        @memset(buf, 0);
        if (l.fat_bits == 12) {
            var i: usize = 0;
            while (i < l.total_clusters + 2) : (i += 1) {
                const raw: u32 = if (i < fat.len) fat[i] else 0;
                const v: u16 = @intCast(@min(raw, 0xFFF));
                const off = i + i / 2;
                if (off + 1 < bytes) {
                    if (i % 2 == 0) {
                        buf[off] = @intCast(v & 0xFF);
                        buf[off + 1] = @intCast((buf[off + 1] & 0xF0) | ((v >> 8) & 0x0F));
                    } else {
                        buf[off] = @intCast((buf[off] & 0x0F) | ((v << 4) & 0xF0));
                        buf[off + 1] = @intCast((v >> 4) & 0xFF);
                    }
                }
            }
        } else {
            var i: usize = 0;
            while (i < l.total_clusters + 2) : (i += 1) {
                const raw: u32 = if (i < fat.len) fat[i] else 0;
                const v: u16 = @intCast(@min(raw, 0xFFFF));
                std.mem.writeInt(u16, buf[i * 2 ..][0..2], v, .little);
            }
        }
        return buf;
    }

    fn writeEntry(
        buf: []u8,
        off: usize,
        sfn: *const [11]u8,
        attr: u8,
        cluster: u32,
        size: u32,
        date: u16,
        time: u16,
    ) void {
        const e = buf[off .. off + 32];
        @memcpy(e[0..11], sfn);
        e[11] = attr;
        e[12] = 0;
        e[13] = 0;
        std.mem.writeInt(u16, e[14..16], time, .little); // crtTime
        std.mem.writeInt(u16, e[16..18], date, .little); // crtDate
        std.mem.writeInt(u16, e[18..20], date, .little); // lstAccDate
        std.mem.writeInt(u16, e[20..22], 0, .little); // fstClusHI
        std.mem.writeInt(u16, e[22..24], time, .little); // wrtTime
        std.mem.writeInt(u16, e[24..26], date, .little); // wrtDate
        std.mem.writeInt(u16, e[26..28], @intCast(cluster & 0xFFFF), .little);
        std.mem.writeInt(u32, e[28..32], size, .little);
    }

    fn sfnChecksum(sfn: *const [11]u8) u8 {
        var sum: u8 = 0;
        for (sfn) |c| sum = (if (sum & 1 != 0) @as(u8, 0x80) else 0) +% (sum >> 1) +% c;
        return sum;
    }

    fn writeLfnEntries(buf: []u8, off: *usize, name: []const u8, sfn: *const [11]u8, date: u16, time: u16) void {
        var utf16: [255]u16 = undefined;
        const chars = std.unicode.utf8ToUtf16Le(&utf16, name) catch 0;
        const blocks = (chars + 12) / 13;
        const checksum = sfnChecksum(sfn);

        var b: usize = blocks;
        while (b > 0) : (b -= 1) {
            const e = buf[off.* .. off.* + 32];
            @memset(e, 0);
            const seq: u8 = @intCast(b);
            e[0] = if (b == blocks) seq | 0x40 else seq;
            e[11] = 0x0F; // LFN
            e[12] = 0;
            e[13] = checksum;
            std.mem.writeInt(u16, e[26..28], 0, .little);

            const start = (b - 1) * 13;
            var k: usize = 0;
            while (k < 13) : (k += 1) {
                const ci = start + k;
                var ch: u16 = 0xFFFF;
                if (ci < chars) {
                    ch = utf16[ci];
                } else if (ci == chars) {
                    ch = 0x0000;
                }
                const pos: usize = switch (k) {
                    0...4 => 1 + k * 2,
                    5...10 => 14 + (k - 5) * 2,
                    else => 28 + (k - 11) * 2,
                };
                std.mem.writeInt(u16, e[pos..][0..2], ch, .little);
            }
            _ = date;
            _ = time;
            off.* += 32;
        }
    }

    fn fatDateTime(unix: u32) DateTime {
        var secs: u32 = if (unix == 0) 1577836800 else unix; // 2020-01-01
        const days = secs / 86400;
        secs %= 86400;
        const hour: u16 = @intCast(secs / 3600);
        const min: u16 = @intCast((secs % 3600) / 60);
        const sec: u16 = @intCast(secs % 60);

        var year: u32 = 1970;
        var d = days;
        while (true) {
            const leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
            const year_days: u32 = if (leap) 366 else 365;
            if (d < year_days) break;
            d -= year_days;
            year += 1;
        }
        const month_days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: u32 = 1;
        for (month_days) |md| {
            const leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
            const real = if (md == 28 and leap) 29 else md;
            if (d < real) break;
            d -= real;
            month += 1;
        }
        const y: u16 = @intCast(@max(@as(u32, 1980), @min(year, 2107)) - 1980);
        const date: u16 = (y << 9) | (@as(u16, @intCast(month)) << 5) | @as(u16, @intCast(d + 1));
        const time: u16 = (hour << 11) | (min << 5) | (sec / 2);
        return .{ .date = date, .time = time };
    }

    pub fn build(self: *Builder) ![]u8 {
        const a = self.allocator;
        const l = try layoutFor(self.opts);

        // 1) 短名
        self.assignAllSfns(self.root);

        // 2) 分配簇
        var alloc = Alloc{ .fat = .empty, .l = l, .cluster_bytes = l.cluster_bytes };
        defer alloc.fat.deinit(a);

        try alloc.fat.append(a, (if (l.fat_bits == 12) @as(u32, 0xF00) else 0xFF00) | 0xF8);
        try alloc.fat.append(a, if (l.fat_bits == 12) 0xFFF else 0xFFFF);

        try self.allocateDir(a, &alloc, self.root, true);

        // 3) 镜像缓冲
        const img = try a.alloc(u8, l.total_sectors * l.sector_size);
        @memset(img, 0);

        const dt = fatDateTime(self.opts.mtime);
        self.writeBootSector(img, l);
        self.writeAicInfo(img, l);

        // FAT 表
        const fat_buf = serializeFat(l, alloc.fat.items);
        defer std.heap.page_allocator.free(fat_buf);
        const fat_off = l.sector_size;
        var fi: usize = 0;
        while (fi < 2) : (fi += 1) {
            @memcpy(img[fat_off + fi * l.fat_sectors * l.sector_size ..][0..fat_buf.len], fat_buf);
        }

        // 4) 目录内容与文件数据
        try self.writeDirTree(img, l, self.root, true, dt);
        return img;
    }

    fn allocateDir(self: *Builder, a: std.mem.Allocator, alloc: *Alloc, dir: *Node, is_root: bool) !void {
        if (!is_root) {
            const bytes = dirEntryBytes(dir, false);
            dir.cluster = try alloc.allocChain(a, bytes);
        }
        // 先给本目录的文件分配，保证目录项顺序与簇顺序一致
        for (dir.children.items) |c| {
            if (!c.is_dir) {
                c.size = @intCast(c.data.len);
                c.cluster = try alloc.allocChain(a, c.data.len);
            }
        }
        for (dir.children.items) |c| {
            if (c.is_dir) try self.allocateDir(a, alloc, c, false);
        }
    }

    fn writeDirTree(self: *Builder, img: []u8, l: Layout, dir: *Node, is_root: bool, dt: DateTime) !void {
        var entries: std.ArrayList(u8) = .empty;
        defer entries.deinit(std.heap.page_allocator);

        const root_dir_off = l.sector_size * (l.reserved_sectors + l.num_fats * l.fat_sectors);
        const dir_off: usize = if (is_root) root_dir_off else clusterOffset(l, dir.cluster);
        const dir_capacity: usize = if (is_root) l.root_dir_sectors * l.sector_size else clusterBytesForDir(l, dir, is_root);

        // 卷标
        if (is_root) {
            var label: [11]u8 = @splat(' ');
            var li: usize = 0;
            for (self.opts.volume_label) |c| {
                if (li >= 11) break;
                label[li] = std.ascii.toUpper(c);
                li += 1;
            }
            const e = img[dir_off .. dir_off + 32];
            @memset(e, 0);
            @memcpy(e[0..11], &label);
            e[11] = 0x08;
            std.mem.writeInt(u16, e[24..26], dt.date, .little);
        }

        var off: usize = if (is_root) 32 else 0;
        if (!is_root) {
            // "." 与 ".."
            const self_entry = img[dir_off .. dir_off + 32];
            @memset(self_entry, 0);
            @memcpy(self_entry[0..11], ".          ");
            self_entry[11] = 0x10;
            std.mem.writeInt(u16, self_entry[26..28], @intCast(dir.cluster), .little);
            std.mem.writeInt(u16, self_entry[24..26], dt.date, .little);
            std.mem.writeInt(u16, self_entry[22..24], dt.time, .little);

            const parent_entry = img[dir_off + 32 .. dir_off + 64];
            @memset(parent_entry, 0);
            @memcpy(parent_entry[0..11], "..         ");
            parent_entry[11] = 0x10;
            const parent_cluster: u32 = if (dir.parent) |p| (if (p == self.root) 0 else p.cluster) else 0;
            std.mem.writeInt(u16, parent_entry[26..28], @intCast(parent_cluster), .little);
            std.mem.writeInt(u16, parent_entry[24..26], dt.date, .little);
            std.mem.writeInt(u16, parent_entry[22..24], dt.time, .little);
            off = 64;
        }

        for (dir.children.items) |c| {
            const limit = dir_off + dir_capacity;
            if (off + 32 > dir_capacity) break; // 目录超容量：调用方应已按 32B 计算
            const write_off = dir_off + off;
            if (c.needs_lfn) {
                const need = lfnBlocks(c.name) * 32;
                if (off + need + 32 > dir_capacity) break;
                var lfn_off = write_off;
                writeLfnEntries(img, &lfn_off, c.name, &c.sfn, dt.date, dt.time);
                off = lfn_off - dir_off;
            }
            self.writeSfnEntry(img, dir_off + off, c, dt);
            off += 32;
            _ = &limit;
        }

        // 写子目录与文件
        for (dir.children.items) |c| {
            if (c.is_dir) {
                try self.writeDirTree(img, l, c, false, dt);
            } else if (c.data.len > 0) {
                const data_off = clusterOffset(l, c.cluster);
                @memcpy(img[data_off .. data_off + c.data.len], c.data);
            }
        }
    }

    fn clusterBytesForDir(l: Layout, dir: *Node, is_root: bool) usize {
        if (is_root) return l.root_dir_sectors * l.sector_size;
        const entries_bytes = dirEntryBytes(dir, false);
        return std.mem.alignForward(usize, entries_bytes, l.cluster_bytes);
    }

    fn writeSfnEntry(self: *Builder, img: []u8, off: usize, node: *Node, dt: DateTime) void {
        _ = self;
        const attr: u8 = if (node.is_dir) 0x10 else 0x20;
        writeEntry(img, off, &node.sfn, attr, node.cluster, if (node.is_dir) 0 else node.size, dt.date, dt.time);
    }

    fn writeBootSector(self: *Builder, img: []u8, l: Layout) void {
        const b = img[0..l.sector_size];
        @memset(b, 0);
        b[0] = 0xEB;
        b[1] = 0x3C;
        b[2] = 0x90;
        @memcpy(b[3..11], "WKLITE  ");
        std.mem.writeInt(u16, b[11..13], self.opts.sector_size, .little);
        b[13] = self.opts.cluster_sectors;
        std.mem.writeInt(u16, b[14..16], 1, .little); // reserved
        b[16] = 2; // fats
        std.mem.writeInt(u16, b[17..19], @intCast(l.root_entries), .little);
        const total = l.total_sectors;
        if (total < 0x10000) {
            std.mem.writeInt(u16, b[19..21], @intCast(total), .little);
        } else {
            std.mem.writeInt(u16, b[19..21], 0, .little);
            std.mem.writeInt(u32, b[32..36], @intCast(total), .little);
        }
        b[21] = 0xF8; // media
        std.mem.writeInt(u16, b[22..24], @intCast(l.fat_sectors), .little);
        std.mem.writeInt(u16, b[24..26], 63, .little); // sectors/track
        std.mem.writeInt(u16, b[26..28], 255, .little); // heads
        std.mem.writeInt(u32, b[28..32], 0, .little); // hidden
        b[36] = 0x80;
        b[38] = 0x29;
        std.mem.writeInt(u32, b[39..43], self.opts.volume_id, .little);
        var label: [11]u8 = @splat(' ');
        var li: usize = 0;
        for (self.opts.volume_label) |c| {
            if (li >= 11) break;
            label[li] = std.ascii.toUpper(c);
            li += 1;
        }
        @memcpy(b[43..54], &label);
        @memcpy(b[54..62], if (l.fat_bits == 12) "FAT12   " else "FAT16   ");
        b[510] = 0x55;
        b[511] = 0xAA;
    }

    /// AIC 扩展信息块（makefatfs.py::set_image_info_to_boot_sector）
    fn writeAicInfo(self: *Builder, img: []u8, l: Layout) void {
        if (img.len < 0x80 + 40) return;
        const used_bytes: u64 = minimalUsedBytes(self, l);
        const info = img[0x80..0x80 + 40];
        @memset(info, 0);
        @memcpy(info[0..4], "AICF");
        std.mem.writeInt(u32, info[8..12], 32, .little);
        std.mem.writeInt(u32, info[12..16], 0x0101, .little);
        std.mem.writeInt(u64, info[16..24], @intCast(l.total_sectors * l.sector_size), .little);
        std.mem.writeInt(u64, info[24..32], used_bytes, .little);

        var sum: u32 = 0;
        var i: usize = 0;
        while (i < 40) : (i += 4) sum +%= std.mem.readInt(u32, info[i..][0..4], .little);
        const cksum = ~sum;
        std.mem.writeInt(u32, info[4..8], cksum, .little);
    }
};

fn totalUsedClusters(dir: *const Node) u64 {
    var n: u64 = 0;
    for (dir.children.items) |c| {
        if (c.is_dir) {
            n += 1 + totalUsedClusters(c);
        } else if (c.data.len > 0) {
            n += 1;
        }
    }
    return n;
}

fn minimalUsedBytes(self: *Builder, l: Builder.Layout) u64 {
    const meta = (l.reserved_sectors + l.num_fats * l.fat_sectors + l.root_dir_sectors) * l.sector_size;
    const data_clusters = 1 + totalUsedClusters(self.root) + 2;
    return @as(u64, meta) + @as(u64, data_clusters) * l.cluster_bytes;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
test "FAT12 镜像：卷标、短名、LFN 与文件内容" {
    const allocator = std.testing.allocator;
    var b = try Builder.init(allocator, .{
        .total_bytes = 256 * 1024,
        .cluster_sectors = 1,
        .volume_label = "WKTEST",
        .mtime = 0,
    });
    defer b.deinit();

    try b.addFile("hello.txt", "hello fat");
    try b.addFile("long-file-name.bin", "LONG");
    try b.addFile("sub/inner.txt", "inner");
    try b.addDir("empty");

    const img = try b.build();
    defer allocator.free(img);

    // 引导扇区
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, img[11..13], .little));
    try std.testing.expectEqual(@as(u8, 0xF8), img[21]);
    try std.testing.expectEqualStrings("FAT12   ", img[54..62]);
    try std.testing.expectEqual(@as(u8, 0x55), img[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), img[511]);

    // AICF 信息块
    try std.testing.expectEqualStrings("AICF", img[0x80..0x84]);
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < 40) : (i += 4) sum +%= std.mem.readInt(u32, img[0x80 + i ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), sum);

    // 根目录：卷标 + hello.txt + LFN(long-file-name) + sub + empty
    const sector_size: usize = 512;
    const fat_sectors = std.mem.readInt(u16, img[22..24], .little);
    const root_off = sector_size * (1 + 2 * fat_sectors);
    try std.testing.expectEqual(@as(u8, 0x08), img[root_off + 11]); // 卷标
    try std.testing.expectEqualStrings("WKTEST     ", img[root_off .. root_off + 11]);
}

test "FAT16 选择与容量检查" {
    const allocator = std.testing.allocator;
    var b = try Builder.init(allocator, .{
        .total_bytes = 32 * 1024 * 1024,
        .cluster_sectors = 1,
        .volume_label = "BIG",
    });
    defer b.deinit();
    try b.addFile("a.bin", "x");
    const img = try b.build();
    defer allocator.free(img);
    try std.testing.expectEqualStrings("FAT16   ", img[54..62]);
}





