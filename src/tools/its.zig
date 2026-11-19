//! ITS（FIT Image Tree Source）解析器 —— 对应 Luban-Lite 构建流程里
//! `mkimage -f xxx.its xxx.itb` 这一步。
//!
//! 支持 DTS 子集：
//!   * `/dts-v1/;` 头
//!   * 节点 `name { ... };` 与根节点 `/ { ... };`
//!   * 属性：字符串 `"..."`、单元列表 `<0x...>`、字节数组 `[00 11]`、布尔属性
//!   * `/incbin/("file")`（路径相对 ITS 文件所在目录）
//!   * `//` 与 `/* */` 注释
//!
//! 并自动完成 FIT 需要的后处理：
//!   * 根节点插入/覆盖 `timestamp`
//!   * `hash-N { algo = "crc32|md5|sha1|sha256"; }` 自动补 `value`（与 mkimage 一致：value 在前）
//!   * `signature` / `cipher` 节点明确拒绝（未实现签名/加密）
const std = @import("std");
const rsa = @import("rsa.zig");
const fdt = @import("fdt.zig");
const fdt_reader = @import("fdt_reader.zig");
const crc32 = @import("../bsp/common/crc32.zig");

pub const Prop = struct {
    name: []const u8,
    data: []const u8,
};

pub const Node = struct {
    name: []const u8,
    props: std.ArrayList(Prop) = .empty,
    children: std.ArrayList(*Node) = .empty,

    pub fn getProp(self: *const Node, name: []const u8) ?*const Prop {
        for (self.props.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    /// 生成 FDT/FIT blob。
    pub fn buildFdt(self: *Parsed, allocator: std.mem.Allocator, timestamp: u32) ![]u8 {
        _ = try ensureTimestamp(self, timestamp);
        const root = try toFdtNode(self.arena.allocator(), self.root);
        return fdt.build(allocator, root);
    }

    /// 生成 FIT blob，并把各 image 的 `data` 挪到 FIT 之外（等价 mkimage `-E -B <align>`）。
    ///
    /// 逐条对应参考 `itbimage/_core.py::_extract_external_data()`：
    ///   1. 去掉 `data`，加占位 `data-offset/data-size/data-position` → 先序列化量尺寸；
    ///   2. `aligned_boundary = align_up(dtb_size, align)`；
    ///   3. 每个 image 依次按 `align` 对齐后放进外部数据区；
    ///   4. 回填真实 offset/size/position（`data-position` 是**绝对**偏移）；
    ///   5. 重新序列化并补齐到 `aligned_boundary`，末尾接外部数据区（补齐到 `align`）。
    pub fn buildFdtExternal(
        self: *Parsed,
        allocator: std.mem.Allocator,
        timestamp: u32,
        align_to: usize,
    ) ![]u8 {
        _ = try ensureTimestamp(self, timestamp);
        const a = self.arena.allocator();
        const block_align = if (align_to == 0) 4 else align_to;

        const images = findChild(self.root, "images") orelse {
            const root = try toFdtNode(a, self.root);
            return fdt.build(allocator, root);
        };

        // 1) 收集 data 并换成占位属性
        const Img = struct { node: *Node, data: []const u8 };
        var entries: std.ArrayList(Img) = .empty;
        defer entries.deinit(a);
        for (images.children.items) |img| {
            const p = img.getProp("data") orelse continue;
            const data = p.data;
            if (data.len == 0) continue;
            try removeProp(img, a, "data");
            try setU32Prop(img, a, "data-offset", 0);
            try setU32Prop(img, a, "data-size", @intCast(data.len));
            try setU32Prop(img, a, "data-position", 0);
            try entries.append(a, .{ .node = img, .data = data });
        }
        if (entries.items.len == 0) {
            const root = try toFdtNode(a, self.root);
            return fdt.build(allocator, root);
        }

        // 2) 先序列化量尺寸
        var temp_root = try toFdtNode(a, self.root);
        const temp = try fdt.build(allocator, temp_root);
        const temp_size = temp.len;
        allocator.free(temp);
        const aligned_boundary = alignForward(temp_size, block_align);

        // 3) 外部数据区
        var ext: std.ArrayList(u8) = .empty;
        defer ext.deinit(allocator);
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(allocator);
        for (entries.items) |e| {
            const off = alignForward(ext.items.len, block_align);
            try ext.appendNTimes(allocator, 0, off - ext.items.len);
            try offsets.append(allocator, off);
            try ext.appendSlice(allocator, e.data);
        }
        const final_len = alignForward(ext.items.len, block_align);
        try ext.appendNTimes(allocator, 0, final_len - ext.items.len);

        // 4) 回填真实值
        for (entries.items, offsets.items) |e, off| {
            try setU32Prop(e.node, a, "data-offset", @intCast(off));
            try setU32Prop(e.node, a, "data-size", @intCast(e.data.len));
            try setU32Prop(e.node, a, "data-position", @intCast(aligned_boundary + off));
        }

        // 5) 最终序列化 + 补齐
        temp_root = try toFdtNode(a, self.root);
        const dtb = try fdt.build(allocator, temp_root);
        defer allocator.free(dtb);
        const out = try allocator.alloc(u8, aligned_boundary + final_len);
        @memset(out, 0);
        @memcpy(out[0..dtb.len], dtb);
        @memcpy(out[aligned_boundary..][0..final_len], ext.items);
        return out;
    }
};

/// 取字符串属性（去掉结尾 NUL）。
fn propString(node: *const Node, name: []const u8) ?[]const u8 {
    const p = node.getProp(name) orelse return null;
    return std.mem.trimEnd(u8, p.data, "\u{0}");
}

/// 给 `images/*/signature-*` 节点写签名（等价 `itbimage._sign.sign_images`）。
///
/// - 支持 `algo = "sha256,rsa2048"`（其它哈希/算法报 `UnsupportedAlgo`）；
/// - 私钥取 `{keydir}/{key-name-hint}.key`（PEM 或 DER）；
/// - 写入 `value`（签名本身）、`signer-name`/`signer-version`（带结尾 NUL 的字符串）、`timestamp`。
pub fn signImages(
    self: *Parsed,
    allocator: std.mem.Allocator,
    io: std.Io,
    keydir: []const u8,
    timestamp: u32,
) !usize {
    const images = findChild(self.root, "images") orelse return 0;
    const a = self.arena.allocator();
    var signed: usize = 0;

    for (images.children.items) |img| {
        const data_prop = img.getProp("data") orelse continue;
        const data = data_prop.data;
        if (data.len == 0) continue;

        for (img.children.items) |sub| {
            if (!std.mem.startsWith(u8, sub.name, "signature")) continue;
            const algo = propString(sub, "algo") orelse continue;
            const hint = propString(sub, "key-name-hint") orelse continue;

            // 只支持 sha256 + rsa
            if (!std.mem.startsWith(u8, algo, "sha256")) return error.UnsupportedAlgo;

            const key_path = try std.fmt.allocPrint(allocator, "{s}/{s}.key", .{
                std.mem.trimEnd(u8, keydir, "/\\"), hint,
            });
            defer allocator.free(key_path);
            const key_bytes = std.Io.Dir.cwd().readFileAlloc(io, key_path, allocator, .unlimited) catch
                return error.MissingKey;
            defer allocator.free(key_bytes);

            var key = try rsa.parsePrivate(allocator, key_bytes);
            defer key.deinit(allocator);
            const sig = try rsa.signSha256(allocator, &key, data);
            defer allocator.free(sig);

            try setBytesProp(sub, a, "value", sig);
            const name_bytes = try allocator.dupe(u8, "mkimage\x00");
            defer allocator.free(name_bytes);
            try setBytesProp(sub, a, "signer-name", name_bytes);
            const ver_bytes = try allocator.dupe(u8, "1.0.0\x00");
            defer allocator.free(ver_bytes);
            try setBytesProp(sub, a, "signer-version", ver_bytes);
            try setU32Prop(sub, a, "timestamp", timestamp);
            signed += 1;
        }
    }
    return signed;
}

// ----------------------------------------------------------------------
// 配置签名：FDT 区域提取（等价 itbimage/_fdt_regions.py）+ RSA
// ----------------------------------------------------------------------

const Region = struct { off: usize, size: usize };

const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;
const FDT_MAX_DEPTH: usize = 32;

fn fdtBe32(data: []const u8, off: usize) u32 {
    if (off + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

fn fdtCStr(data: []const u8, off: usize) []const u8 {
    if (off >= data.len) return "";
    const rest = data[off..];
    const end = std.mem.findScalar(u8, rest, 0) orelse return rest;
    return rest[0..end];
}

fn nameInList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, item, "/"), name)) return true;
    }
    return false;
}

fn joinFdtPath(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: []const []const u8,
) ![]const u8 {
    buf.clearRetainingCapacity();
    try buf.append(allocator, '/');
    var first = true;
    for (parts) |p| {
        if (p.len == 0) continue;
        if (!first) try buf.append(allocator, '/');
        try buf.appendSlice(allocator, p);
        first = false;
    }
    return buf.items;
}

const RegionSet = struct {
    regions: []Region,
    hashed_nodes: [][]const u8,

    fn deinit(self: RegionSet, allocator: std.mem.Allocator) void {
        allocator.free(self.regions);
        for (self.hashed_nodes) |p| allocator.free(p);
        allocator.free(self.hashed_nodes);
    }
};

/// 区域游标推进（对应参考里三段重复的 start/close 逻辑）。
fn regionStep(
    regions: *std.ArrayList(Region),
    allocator: std.mem.Allocator,
    include: bool,
    start: *?usize,
    offset: usize,
    stop: usize,
) !void {
    if (include) {
        if (start.* == null) {
            if (regions.items.len > 0) {
                const last = regions.items[regions.items.len - 1];
                if (offset == last.off + last.size) {
                    start.* = last.off;
                    _ = regions.pop();
                    return;
                }
            }
            start.* = offset;
        }
    } else if (start.*) |s| {
        try regions.append(allocator, .{ .off = s, .size = stop - s });
        start.* = null;
    }
}

/// `itbimage/_fdt_regions.find_regions()` 的移植（u-boot `fdt_find_regions` 语义）。
///
/// 只包含「命中 path 的节点自身属性与结构 tag」，子节点属性不含；
/// `exc_props` 里的属性一律跳过；`add_string_tab` 时最后一段额外覆盖字符串表。
fn findRegions(
    allocator: std.mem.Allocator,
    dtb: []const u8,
    inc_paths: []const []const u8,
    exc_props: []const []const u8,
    add_string_tab: bool,
) !RegionSet {
    const base: usize = fdtBe32(dtb, 8);
    const strings_base: usize = fdtBe32(dtb, 12);
    const strings_sz: usize = fdtBe32(dtb, 32);
    const struct_sz: usize = fdtBe32(dtb, 36);
    const end_idx: usize = if (struct_sz != 0) base + struct_sz else dtb.len;

    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(allocator);
    var hashed: std.ArrayList([]const u8) = .empty;
    defer hashed.deinit(allocator);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(allocator);

    var stack_want: [FDT_MAX_DEPTH]usize = @splat(0);
    var depth: isize = -1;
    var want: usize = 0;
    var start: ?usize = null;

    var idx: usize = base;
    while (idx < end_idx and idx + 4 <= dtb.len) {
        const tag = fdtBe32(dtb, idx);
        const offset = idx;

        if (tag == FDT_BEGIN_NODE) {
            idx += 4;
            const name = fdtCStr(dtb, idx);
            idx = (idx + name.len + 4) & ~@as(usize, 3);
            depth += 1;
            if (depth >= @as(isize, @intCast(FDT_MAX_DEPTH))) return error.FdtTooDeep;
            try parts.append(allocator, name);
            const cur = try joinFdtPath(&path_buf, allocator, parts.items);
            const key = std.mem.trimEnd(u8, cur, "/");

            stack_want[@intCast(depth)] = want;
            if (nameInList(inc_paths, key)) {
                want = 2;
                try hashed.append(allocator, try allocator.dupe(u8, cur));
            } else if (want > 0) {
                want -= 1;
            }
            try regionStep(&regions, allocator, want > 0, &start, offset, offset);
        } else if (tag == FDT_END_NODE) {
            idx += 4;
            const include = want > 0;
            if (depth >= 0) {
                want = stack_want[@intCast(depth)];
                depth -= 1;
            }
            if (parts.items.len > 0) parts.items.len -= 1;
            try regionStep(&regions, allocator, include, &start, offset, idx);
        } else if (tag == FDT_PROP) {
            idx += 4;
            const prop_size: usize = fdtBe32(dtb, idx);
            const name_off: usize = fdtBe32(dtb, idx + 4);
            idx += 8;
            const prop_name = fdtCStr(dtb, strings_base + name_off);
            idx += prop_size;
            idx = (idx + 3) & ~@as(usize, 3);

            var include = want >= 2;
            if (nameInList(exc_props, prop_name)) include = false;
            try regionStep(&regions, allocator, include, &start, offset, offset);
        } else if (tag == FDT_NOP) {
            idx += 4;
            const include = want >= 2;
            if (include) {
                if (start == null) start = offset;
            } else if (start) |s| {
                try regions.append(allocator, .{ .off = s, .size = offset - s });
                start = null;
            }
        } else if (tag == FDT_END) {
            idx += 4;
            if (start == null) start = offset;
            break;
        } else {
            return error.BadFdtTag;
        }
    }

    if (start) |s| {
        var size = idx - s;
        if (add_string_tab) size += strings_sz;
        try regions.append(allocator, .{ .off = s, .size = size });
    }

    return .{
        .regions = try regions.toOwnedSlice(allocator),
        .hashed_nodes = try hashed.toOwnedSlice(allocator),
    };
}

/// 收集一条 config 签名要覆盖的节点路径（`_sign._collect_config_hash_paths`）。
fn collectConfigPaths(
    allocator: std.mem.Allocator,
    root: *const Node,
    conf: *const Node,
    sig_node: *const Node,
) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    try paths.append(allocator, try std.fmt.allocPrint(allocator, "/configurations/{s}", .{conf.name}));

    var types: std.ArrayList([]const u8) = .empty;
    defer types.deinit(allocator);
    if (propString(sig_node, "sign-images")) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |t| {
            const trimmed = std.mem.trim(u8, t, " \t\r\n");
            if (trimmed.len > 0) try types.append(allocator, trimmed);
        }
    } else {
        try types.append(allocator, "firmware");
        try types.append(allocator, "flat_dt");
        try types.append(allocator, "script");
    }

    const images = findChild(root, "images");
    for (types.items) |t| {
        const p = conf.getProp(t) orelse continue;
        var nit = std.mem.splitScalar(u8, std.mem.trimEnd(u8, p.data, "\u{0}"), 0);
        while (nit.next()) |name_raw| {
            const name = std.mem.trim(u8, name_raw, " \t\r\n");
            if (name.len == 0) continue;
            const imgs = images orelse continue;
            var found = false;
            for (imgs.children.items) |c| {
                if (std.mem.eql(u8, c.name, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "/images/{s}", .{name}));
        }
    }
    return try paths.toOwnedSlice(allocator);
}

/// 给 `configurations/*/signature-*` 节点写签名（等价 `_sign.sign_configurations`）。
///
/// 与图像签名的区别：签名对象不是 image data，而是「FDT 区域哈希」——
/// 先按 `hashed-nodes` 规则提取 DTB 字节区域（跳过 `data`/`data-size`/
/// `data-position`/`data-offset`，末尾附字符串表），再对这些字节做 SHA-256，
/// 最后用 RSA 签这笔哈希；同时写出 `hashed-nodes` 与 `hashed-strings` 供
/// 引导程序复算。
pub fn signConfigurations(
    self: *Parsed,
    allocator: std.mem.Allocator,
    io: std.Io,
    keydir: []const u8,
    timestamp: u32,
) !usize {
    const confs = findChild(self.root, "configurations") orelse return 0;
    const a = self.arena.allocator();
    const exc_props = [_][]const u8{ "data", "data-size", "data-position", "data-offset" };
    var signed: usize = 0;

    for (confs.children.items) |conf| {
        for (conf.children.items) |sig_node| {
            if (!std.mem.startsWith(u8, sig_node.name, "signature")) continue;
            const algo = propString(sig_node, "algo") orelse continue;
            const hint = propString(sig_node, "key-name-hint") orelse continue;
            if (!std.mem.startsWith(u8, algo, "sha256")) return error.UnsupportedAlgo;

            const paths = try collectConfigPaths(a, self.root, conf, sig_node);

            // 参考在 image 签名写完之后序列化一次，用这份 DTB 取区域。
            const dtb = try self.buildFdt(allocator, timestamp);
            defer allocator.free(dtb);
            const strings_sz = fdtBe32(dtb, 32);

            const res = try findRegions(allocator, dtb, paths, &exc_props, true);
            defer res.deinit(allocator);
            if (res.regions.len == 0) return error.NoRegions;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            for (res.regions) |r| {
                if (r.off + r.size > dtb.len) return error.BadRegion;
                try buf.appendSlice(allocator, dtb[r.off..][0..r.size]);
            }
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(buf.items, &digest, .{});

            const key_path = try std.fmt.allocPrint(allocator, "{s}/{s}.key", .{
                std.mem.trimEnd(u8, keydir, "/\\"), hint,
            });
            defer allocator.free(key_path);
            const key_bytes = std.Io.Dir.cwd().readFileAlloc(io, key_path, allocator, .unlimited) catch
                return error.MissingKey;
            defer allocator.free(key_bytes);

            var key = try rsa.parsePrivate(allocator, key_bytes);
            defer key.deinit(allocator);
            const sig = try rsa.signSha256(allocator, &key, &digest);
            defer allocator.free(sig);

            try setBytesProp(sig_node, a, "value", sig);
            try setBytesProp(sig_node, a, "signer-name", "mkimage\x00");
            try setBytesProp(sig_node, a, "signer-version", "1.0.0\x00");
            try setU32Prop(sig_node, a, "timestamp", timestamp);

            var hn: std.ArrayList(u8) = .empty;
            defer hn.deinit(allocator);
            for (res.hashed_nodes) |p| {
                try hn.appendSlice(allocator, p);
                try hn.append(allocator, 0);
            }
            try setBytesProp(sig_node, a, "hashed-nodes", hn.items);

            var hs: [8]u8 = undefined;
            std.mem.writeInt(u32, hs[0..4], 0, .big);
            std.mem.writeInt(u32, hs[4..8], strings_sz, .big);
            try setBytesProp(sig_node, a, "hashed-strings", &hs);

            signed += 1;
        }
    }
    return signed;
}

// ----------------------------------------------------------------------
// 公钥注入（等价 _sign.inject_pubkeys / u-boot rsa_add_verify_data）
// ----------------------------------------------------------------------

/// 去掉大端整数前导零（参考按整数 `to_bytes((bit_length+7)//8)` 生成）。
fn stripLeadingZeros(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] == 0) i += 1;
    return bytes[i..];
}

/// 精确位长（模数最高位为 1 时等于字节数*8）。
fn bitLength(bytes: []const u8) u32 {
    const s = stripLeadingZeros(bytes);
    if (s.len == 0) return 0;
    const lead: u32 = @clz(s[0]);
    return @as(u32, @intCast(s.len)) * 8 - lead;
}

/// `n^{-1} mod 2^32`（n 必须是奇数；牛顿迭代每次翻倍精度）。
fn invMod2p32(n: u32) u32 {
    var x: u32 = 1;
    var i: usize = 0;
    while (i < 5) : (i += 1) x *%= 2 -% n *% x;
    return x;
}

fn readerToItsNode(allocator: std.mem.Allocator, rnode: *const fdt_reader.Node) !*Node {
    const node = try allocator.create(Node);
    node.* = .{ .name = rnode.name };
    for (rnode.props.items) |p| {
        try node.props.append(allocator, .{ .name = p.name, .data = p.value });
    }
    for (rnode.children.items) |c| {
        try node.children.append(allocator, try readerToItsNode(allocator, c));
    }
    return node;
}

/// 把 `{keydir}/*.key` 的公钥写入目标 DTB 的 `/signature/<key-name>` 节点。
///
/// 等价参考 `_sign.inject_pubkeys()`（u-boot `rsa_add_verify_data`）：
/// 每个密钥写 `algo = "sha256,rsa<bits>"`、`rsa,num-bits`、`rsa,modulus`、
/// `rsa,exponent`、`rsa,n0-inverse`（`-1/n mod 2^32`，Montgomery 用），
/// `require_keys` 时再加 `required = "image"`。返回注入的密钥数。
pub fn injectPubkeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    keydir: []const u8,
    keydest: []const u8,
    require_keys: bool,
) !usize {
    const blob = try std.Io.Dir.cwd().readFileAlloc(io, keydest, allocator, .unlimited);
    defer allocator.free(blob);

    var tree = try fdt_reader.parse(allocator, blob);
    defer tree.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try readerToItsNode(a, tree.root);

    // 收集 `{keydir}/*.key`（排序保证输出稳定；参考用 os.listdir 顺序）
    var dir = std.Io.Dir.cwd().openDir(io, keydir, .{ .iterate = true }) catch
        return error.MissingKey;
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".key")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    // `/signature` 节点（不存在则新建）
    var sig_parent: *Node = blk: {
        for (root.children.items) |c| {
            if (std.mem.eql(u8, c.name, "signature")) break :blk c;
        }
        const node = try a.create(Node);
        node.* = .{ .name = "signature" };
        try root.children.append(a, node);
        break :blk node;
    };

    var injected: usize = 0;
    for (names.items) |file_name| {
        const hint = file_name[0 .. file_name.len - 4];
        const key_path = try std.fmt.allocPrint(a, "{s}/{s}", .{
            std.mem.trimEnd(u8, keydir, "/\\"), file_name,
        });
        const key_bytes = std.Io.Dir.cwd().readFileAlloc(io, key_path, allocator, .unlimited) catch
            return error.MissingKey;
        defer allocator.free(key_bytes);

        var key = try rsa.parsePrivate(allocator, key_bytes);
        defer key.deinit(allocator);

        const n = stripLeadingZeros(key.n);
        const e = stripLeadingZeros(key.e);
        if (n.len == 0 or n.len % 4 != 0) return error.BadRsaKey;
        const bits = bitLength(key.n);

        // n0 = -1/n mod 2^32
        const n_low = std.mem.readInt(u32, n[n.len - 4 ..][0..4], .big);
        if (n_low % 2 == 0) return error.BadRsaKey;
        const n0: u32 = 0 -% invMod2p32(n_low);

        const key_node = try a.create(Node);
        key_node.* = .{ .name = try a.dupe(u8, hint) };
        try key_node.props.append(a, .{
            .name = "algo",
            .data = try std.fmt.allocPrint(a, "sha256,rsa{d}\x00", .{bits}),
        });
        var num_bits: [4]u8 = undefined;
        std.mem.writeInt(u32, &num_bits, bits, .big);
        try key_node.props.append(a, .{ .name = "rsa,num-bits", .data = try a.dupe(u8, &num_bits) });
        try key_node.props.append(a, .{ .name = "rsa,modulus", .data = try a.dupe(u8, n) });
        try key_node.props.append(a, .{ .name = "rsa,exponent", .data = try a.dupe(u8, e) });
        var n0_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &n0_bytes, n0, .big);
        try key_node.props.append(a, .{ .name = "rsa,n0-inverse", .data = try a.dupe(u8, &n0_bytes) });
        if (require_keys) {
            try key_node.props.append(a, .{ .name = "required", .data = "image\x00" });
        }
        try sig_parent.children.append(a, key_node);
        injected += 1;
    }

    if (injected == 0) return 0;

    const out_blob = try fdt.build(allocator, try toFdtNode(a, root));
    defer allocator.free(out_blob);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = keydest, .data = out_blob });
    return injected;
}

fn setBytesProp(node: *Node, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    for (node.props.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) {
            p.data = copy;
            return;
        }
    }
    try node.props.append(allocator, .{ .name = name, .data = copy });
}
/// 读 `{keydir}/{hint}.bin`（参考 `_cipher._read_binary_file`）。
fn readKeyBin(allocator: std.mem.Allocator, io: std.Io, keydir: []const u8, hint: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.bin", .{
        std.mem.trimEnd(u8, keydir, "/\\"), hint,
    });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch error.MissingKey;
}

/// AES-CTR（PyCryptodome 语义：128 位大端计数器，从 IV 整数值开始，无填充）。
fn aesCtr(
    allocator: std.mem.Allocator,
    data: []const u8,
    key: [16]u8,
    iv: [16]u8,
) ![]u8 {
    const out = try allocator.alloc(u8, data.len);
    errdefer allocator.free(out);
    var ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var counter: u128 = std.mem.readInt(u128, &iv, .big);
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var ctr_block: [16]u8 = undefined;
        std.mem.writeInt(u128, &ctr_block, counter, .big);
        var ks: [16]u8 = undefined;
        ctx.encrypt(&ks, &ctr_block);
        const n = @min(@as(usize, 16), data.len - off);
        for (0..n) |i| out[off + i] = data[off + i] ^ ks[i];
        counter +%= 1;
    }
    return out;
}

/// Zig 0.17 的 `std.crypto.aes` 只提供 `Aes128` / `Aes256`，没有 192 位密钥版本；
/// 参考实现支持 `aes192`，此处按 FIPS-197 自行实现（字节序密钥扩展 + 12 轮，单块）。
fn aes192EncryptBlock(ek: *const [208]u8, block: *[16]u8) void {
    // addRoundKey(0)
    for (0..16) |i| block[i] ^= ek[i];

    var round: u8 = 1;
    while (round <= 12) : (round += 1) {
        // SubBytes + ShiftRows（state[r][c] 线性化为 s[r + 4c]）
        var t: [16]u8 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                t[r + 4 * c] = AES_SBOX[block[r + 4 * ((c + r) % 4)]];
            }
        }
        // MixColumns（最后一轮不做）
        if (round != 12) {
            for (0..4) |c| {
                const a0 = t[4 * c + 0];
                const a1 = t[4 * c + 1];
                const a2 = t[4 * c + 2];
                const a3 = t[4 * c + 3];
                t[4 * c + 0] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
                t[4 * c + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
                t[4 * c + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
                t[4 * c + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
            }
        }
        // addRoundKey(round)
        const off = @as(usize, round) * 16;
        for (0..16) |i| block[i] = t[i] ^ ek[off + i];
    }
}

fn xtime(x: u8) u8 {
    const hi: u8 = if (x & 0x80 != 0) 0x1b else 0;
    return (x << 1) ^ hi;
}

/// AES-192 密钥扩展（Nk=6 / Nr=12 → 52 字 = 208 字节）。
fn aes192ExpandKey(key: *const [24]u8) [208]u8 {
    var ek: [208]u8 = undefined;
    @memcpy(ek[0..24], key);

    var rcon: u8 = 0x01;
    var i: usize = 6;
    while (i < 52) : (i += 1) {
        var t: [4]u8 = ek[(i - 1) * 4 ..][0..4].*;
        if (i % 6 == 0) {
            // 先把旧值取到局部：`t = .{ ...t[0]... }` 会按结果位置逐元素写回，
            // 第 4 个元素读到的是刚被覆盖的 t[0]（实测得到错密钥）。
            const b0 = t[0];
            const b1 = t[1];
            const b2 = t[2];
            const b3 = t[3];
            t = .{ AES_SBOX[b1] ^ rcon, AES_SBOX[b2], AES_SBOX[b3], AES_SBOX[b0] };
            rcon = xtime(rcon);
        }
        for (0..4) |j| ek[i * 4 + j] = ek[(i - 6) * 4 + j] ^ t[j];
    }
    return ek;
}

/// AES-CBC + PKCS7（支持 128/192/256 位密钥）。
fn aesCbcPkcs7(
    allocator: std.mem.Allocator,
    data: []const u8,
    key: []const u8,
    iv: [16]u8,
) ![]u8 {
    const pad_len: usize = 16 - (data.len % 16);
    const padded = try allocator.alloc(u8, data.len + pad_len);
    defer allocator.free(padded);
    @memcpy(padded[0..data.len], data);
    @memset(padded[data.len..], @intCast(pad_len));

    const out = try allocator.alloc(u8, padded.len);
    errdefer allocator.free(out);

    var ek192: [208]u8 = undefined;
    if (key.len == 24) ek192 = aes192ExpandKey(key[0..24]);

    var prev = iv;
    var i: usize = 0;
    while (i < padded.len) : (i += 16) {
        var block: [16]u8 = undefined;
        for (0..16) |k| block[k] = padded[i + k] ^ prev[k];
        switch (key.len) {
            16 => {
                var ctx = std.crypto.core.aes.Aes128.initEnc(key[0..16].*);
                ctx.encrypt(out[i..][0..16], &block);
            },
            24 => {
                // 自实现的 AES-192 直接在 block 上就地加密，需再拷回输出缓冲
                aes192EncryptBlock(&ek192, &block);
                @memcpy(out[i..][0..16], &block);
            },
            32 => {
                var ctx = std.crypto.core.aes.Aes256.initEnc(key[0..32].*);
                ctx.encrypt(out[i..][0..16], &block);
            },
            else => return error.UnsupportedAlgo,
        }
        @memcpy(&prev, out[i..][0..16]);
    }
    return out;
}

/// FIPS-197 图 2 的 S-box。
const AES_SBOX = [256]u8{
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};

fn loadOrRandomIv(
    allocator: std.mem.Allocator,
    io: std.Io,
    keydir: []const u8,
    hint: ?[]const u8,
    want: usize,
) ![]u8 {
    if (hint) |h| {
        const raw = try readKeyBin(allocator, io, keydir, h);
        defer allocator.free(raw);
        if (raw.len < want) return error.ShortIv;
        return allocator.dupe(u8, raw[0..want]);
    }
    const iv = try allocator.alloc(u8, want);
    // Zig 0.17 起随机源挂在 std.Io 上（`std.crypto.random` 已移除）。
    io.random(iv);
    return iv;
}

/// 图像数据加密（等价 `itbimage._cipher.cipher_images`）。
///
/// 支持 `aes128`/`aes192`/`aes256`（CBC+PKCS7）、`aes-128-ctr`、`chacha20`；
/// 密钥/IV 取 `{keydir}/{hint}.bin`（iv-name-hint 缺省时随机生成并写回 `iv` 属性，
/// 与参考一致，此时输出不可复现）。加密后重算该节点 `hash-*` 的 `value`（参考先加密后哈希）。
pub fn cipherImages(
    parsed: *Parsed,
    allocator: std.mem.Allocator,
    io: std.Io,
    keydir: []const u8,
) !usize {
    const images = findChild(parsed.root, "images") orelse return 0;
    const a = parsed.arena.allocator();
    var done: usize = 0;

    for (images.children.items) |img| {
        var cipher_node: ?*Node = null;
        for (img.children.items) |sub| {
            if (std.mem.startsWith(u8, sub.name, "cipher")) {
                cipher_node = sub;
                break;
            }
        }
        const cnode = cipher_node orelse continue;
        const data_prop = img.getProp("data") orelse continue;
        const data = data_prop.data;
        if (data.len == 0) continue;

        const algo = propString(cnode, "algo") orelse return error.BadCipherNode;
        const key_hint = propString(cnode, "key-name-hint") orelse return error.BadCipherNode;
        const iv_hint = propString(cnode, "iv-name-hint");

        const key_raw = try readKeyBin(allocator, io, keydir, key_hint);
        defer allocator.free(key_raw);

        var ciphertext: []u8 = undefined;
        var iv_used: []u8 = undefined;

        if (std.mem.eql(u8, algo, "aes128") or std.mem.eql(u8, algo, "aes192") or
            std.mem.eql(u8, algo, "aes256"))
        {
            const key_size: usize = if (std.mem.eql(u8, algo, "aes128")) 16 else if (std.mem.eql(u8, algo, "aes192")) 24 else 32;
            if (key_raw.len < key_size) return error.ShortKey;
            const iv = try loadOrRandomIv(allocator, io, keydir, iv_hint, 16);
            defer allocator.free(iv);
            ciphertext = try aesCbcPkcs7(allocator, data, key_raw[0..key_size], iv[0..16].*);
            iv_used = try allocator.dupe(u8, iv);
        } else if (std.mem.eql(u8, algo, "aes-128-ctr")) {
            if (key_raw.len < 16) return error.ShortKey;
            const iv = try loadOrRandomIv(allocator, io, keydir, iv_hint, 16);
            defer allocator.free(iv);
            ciphertext = try aesCtr(allocator, data, key_raw[0..16].*, iv[0..16].*);
            iv_used = try allocator.dupe(u8, iv);
        } else if (std.mem.eql(u8, algo, "chacha20")) {
            const ChaCha = std.crypto.stream.chacha.ChaCha20IETF;
            if (key_raw.len < ChaCha.key_length) return error.ShortKey;
            const nonce = try loadOrRandomIv(allocator, io, keydir, iv_hint, ChaCha.nonce_length);
            defer allocator.free(nonce);
            ciphertext = try allocator.alloc(u8, data.len);
            ChaCha.xor(ciphertext, data, 0, key_raw[0..32].*, nonce[0..12].*);
            iv_used = try allocator.dupe(u8, nonce);
        } else {
            return error.UnsupportedAlgo;
        }
        defer allocator.free(iv_used);
        defer allocator.free(ciphertext);

        try setBytesProp(img, a, "data", ciphertext);
        try setU32Prop(img, a, "data-size-unciphered", @intCast(data.len));
        try setBytesProp(cnode, a, "iv", iv_used);

        for (img.children.items) |sub| {
            if (!std.mem.startsWith(u8, sub.name, "hash-")) continue;
            const algo_p = propString(sub, "algo") orelse continue;
            const digest = try digestFor(allocator, algo_p, ciphertext);
            defer allocator.free(digest);
            try setBytesProp(sub, a, "value", digest);
        }
        done += 1;
    }
    return done;
}

fn alignForward(x: usize, y: usize) usize {
    return ((x + y - 1) / y) * y;
}

fn findChild(node: *const Node, name: []const u8) ?*Node {
    for (node.children.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

fn removeProp(node: *Node, allocator: std.mem.Allocator, name: []const u8) !void {
    var i: usize = 0;
    while (i < node.props.items.len) : (i += 1) {
        if (std.mem.eql(u8, node.props.items[i].name, name)) {
            _ = node.props.orderedRemove(i);
            _ = allocator;
            return;
        }
    }
}

fn setU32Prop(node: *Node, allocator: std.mem.Allocator, name: []const u8, value: u32) !void {
    const bytes = try allocator.alloc(u8, 4);
    std.mem.writeInt(u32, bytes[0..4], value, .big);
    for (node.props.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) {
            p.data = bytes;
            return;
        }
    }
    try node.props.append(allocator, .{ .name = name, .data = bytes });
}

// ----------------------------------------------------------------------
// 词法
// ----------------------------------------------------------------------

const Token = union(enum) {
    ident: []const u8,
    string: []const u8,
    number: []const u8,
    directive: []const u8,
    slash,
    lbrace,
    rbrace,
    semi,
    eq,
    comma,
    plus,
    minus,
    lt,
    gt,
    lparen,
    rparen,
    lbracket,
    rbracket,
    eof,
};

const Lexer = struct {
    text: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.text.len) {
                if (self.text[self.pos + 1] == '/') {
                    self.pos += 2;
                    while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                    continue;
                }
                if (self.text[self.pos + 1] == '*') {
                    self.pos += 2;
                    while (self.pos + 1 < self.text.len and !(self.text[self.pos] == '*' and self.text[self.pos + 1] == '/')) self.pos += 1;
                    if (self.pos + 1 < self.text.len) self.pos += 2;
                    continue;
                }
            }
            break;
        }
    }

    fn next(self: *Lexer) !Token {
        self.skipSpace();
        if (self.pos >= self.text.len) return .eof;
        const c = self.text[self.pos];
        switch (c) {
            '{' => {
                self.pos += 1;
                return .lbrace;
            },
            '}' => {
                self.pos += 1;
                return .rbrace;
            },
            ';' => {
                self.pos += 1;
                return .semi;
            },
            '=' => {
                self.pos += 1;
                return .eq;
            },
            ',' => {
                self.pos += 1;
                return .comma;
            },
            '+' => {
                self.pos += 1;
                return .plus;
            },
            '-' => {
                self.pos += 1;
                return .minus;
            },
            '<' => {
                self.pos += 1;
                return .lt;
            },
            '>' => {
                self.pos += 1;
                return .gt;
            },
            '(' => {
                self.pos += 1;
                return .lparen;
            },
            ')' => {
                self.pos += 1;
                return .rparen;
            },
            '[' => {
                self.pos += 1;
                return .lbracket;
            },
            ']' => {
                self.pos += 1;
                return .rbracket;
            },
            '"' => {
                self.pos += 1;
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(self.arena);
                while (self.pos < self.text.len and self.text[self.pos] != '"') {
                    if (self.text[self.pos] == '\\' and self.pos + 1 < self.text.len) {
                        self.pos += 1;
                        const esc = self.text[self.pos];
                        try buf.append(self.arena, switch (esc) {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            else => esc,
                        });
                    } else {
                        try buf.append(self.arena, self.text[self.pos]);
                    }
                    self.pos += 1;
                }
                if (self.pos < self.text.len) self.pos += 1;
                return .{ .string = try buf.toOwnedSlice(self.arena) };
            },
            '/' => {
                // 指令（/dts-v1/、/incbin/）或根节点斜杠
                const start = self.pos + 1;
                var i = start;
                while (i < self.text.len) : (i += 1) {
                    const ch = self.text[i];
                    if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') continue;
                    break;
                }
                if (i > start and i < self.text.len and self.text[i] == '/') {
                    const name = self.text[start..i];
                    self.pos = i + 1;
                    return .{ .directive = name };
                }
                self.pos += 1;
                return .slash;
            },
            else => {},
        }

        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.text.len) {
                const ch = self.text[self.pos];
                if (std.ascii.isAlphanumeric(ch) or ch == 'x' or ch == 'X') {
                    self.pos += 1;
                } else break;
            }
            return .{ .number = self.text[start..self.pos] };
        }

        if (std.ascii.isAlphabetic(c) or c == '_' or c == '#' or c == '@' or c == '.') {
            const start = self.pos;
            while (self.pos < self.text.len) {
                const ch = self.text[self.pos];
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '#' or ch == '@' or ch == '.' or ch == '+') {
                    self.pos += 1;
                } else break;
            }
            return .{ .ident = self.text[start..self.pos] };
        }

        return error.UnexpectedCharacter;
    }
};

// ----------------------------------------------------------------------
// 语法
// ----------------------------------------------------------------------

const Parser = struct {
    lexer: Lexer,
    arena: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    lookahead: ?Token = null,

    fn peek(self: *Parser) !Token {
        if (self.lookahead == null) self.lookahead = try self.lexer.next();
        return self.lookahead.?;
    }

    fn take(self: *Parser) !Token {
        const tok = try self.peek();
        self.lookahead = null;
        return tok;
    }

    fn expect(self: *Parser, comptime tag: std.meta.Tag(Token)) !void {
        const tok = try self.take();
        if (std.meta.activeTag(tok) != tag) return error.UnexpectedToken;
    }

    fn dup(self: *Parser, s: []const u8) ![]const u8 {
        return self.arena.dupe(u8, s);
    }

    fn parseFile(self: *Parser) !*Node {
        // 允许若干前置指令（/dts-v1/; /plugin/; /include/ ...）
        while (true) {
            const tok = try self.peek();
            switch (tok) {
                .directive => |d| {
                    _ = try self.take();
                    if (std.mem.eql(u8, d, "dts-v1") or std.mem.eql(u8, d, "plugin")) {
                        _ = try self.take(); // ';'
                    } else {
                        return error.UnsupportedDirective;
                    }
                },
                else => break,
            }
        }

        if (std.meta.activeTag(try self.peek()) != .slash) return error.MissingRootNode;
        _ = try self.take();
        return self.parseNodeBody("", true);
    }

    fn parseNodeBody(self: *Parser, name: []const u8, root: bool) anyerror!*Node {
        _ = root;
        try self.expect(.lbrace);
        const node = try self.arena.create(Node);
        node.* = .{ .name = try self.dup(name) };

        while (true) {
            const tok = try self.take();
            switch (tok) {
                .rbrace => break,
                .eof => return error.UnexpectedEof,
                .ident => |ident| {
                    const next_tok = try self.peek();
                    switch (next_tok) {
                        .lbrace => {
                            const child = try self.parseNodeBody(ident, false);
                            try node.children.append(self.arena, child);
                            // 可选的分号
                            if (std.meta.activeTag(try self.peek()) == .semi) _ = try self.take();
                        },
                        .eq => {
                            _ = try self.take();
                            const data = try self.parsePropertyValue();
                            try node.props.append(self.arena, .{ .name = try self.dup(ident), .data = data });
                            try self.expect(.semi);
                        },
                        .semi => {
                            _ = try self.take();
                            try node.props.append(self.arena, .{ .name = try self.dup(ident), .data = &.{} });
                        },
                        else => return error.UnexpectedToken,
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
        if (std.meta.activeTag(try self.peek()) == .semi) _ = try self.take();
        return node;
    }

    fn parsePropertyValue(self: *Parser) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.arena);

        while (true) {
            try self.appendOneValue(&buf);
            if (std.meta.activeTag(try self.peek()) == .comma) {
                _ = try self.take();
                continue;
            }
            break;
        }
        return buf.toOwnedSlice(self.arena);
    }

    fn appendOneValue(self: *Parser, buf: *std.ArrayList(u8)) anyerror!void {
        const tok = try self.take();
        switch (tok) {
            .string => |s| {
                try buf.appendSlice(self.arena, s);
                try buf.append(self.arena, 0);
            },
            .lt => {
                while (true) {
                    const inner = try self.take();
                    switch (inner) {
                        .gt => break,
                        .number => |n| {
                            const v = std.fmt.parseInt(u32, n, 0) catch return error.BadNumber;
                            var bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &bytes, v, .big);
                            try buf.appendSlice(self.arena, &bytes);
                        },
                        .lparen => {
                            const v = try self.parseCellExpression();
                            var bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &bytes, v, .big);
                            try buf.appendSlice(self.arena, &bytes);
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            .lbracket => {
                while (true) {
                    const inner = try self.take();
                    switch (inner) {
                        .rbracket => break,
                        .number => |n| {
                            const v = std.fmt.parseInt(u8, n, 16) catch return error.BadNumber;
                            try buf.append(self.arena, v);
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            .directive => |d| {
                if (!std.mem.eql(u8, d, "incbin")) return error.UnsupportedDirective;
                try self.expect(.lparen);
                const path_tok = try self.take();
                const rel = switch (path_tok) {
                    .string => |s| s,
                    else => return error.UnexpectedToken,
                };
                try self.expect(.rparen);
                const full = try std.fs.path.resolveAlloc(self.arena, &.{ self.base_dir, rel });
                const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, full, self.arena, .unlimited) catch |err| switch (err) {
                    error.FileNotFound => return error.IncbinNotFound,
                    else => return err,
                };
                try buf.appendSlice(self.arena, bytes);
            },
            else => return error.UnexpectedToken,
        }
    }

    /// `<(...)>`：支持单个整数或简单括号表达式（`+ - << | &`），足够覆盖 SDK 的 ITS。
    fn parseCellExpression(self: *Parser) anyerror!u32 {
        const v = try self.parseExprAdd();
        try self.expect(.rparen);
        return v;
    }

    fn parseExprAdd(self: *Parser) anyerror!u32 {
        var v = try self.parseExprShift();
        while (true) {
            const tok = try self.peek();
            if (std.meta.activeTag(tok) != .plus) break;
            _ = try self.take();
            v +%= try self.parseExprShift();
        }
        return v;
    }

    fn parseExprShift(self: *Parser) anyerror!u32 {
        var v = try self.parseExprPrimary();
        while (true) {
            const tok = try self.peek();
            if (std.meta.activeTag(tok) != .minus) break;
            _ = try self.take();
            v -%= try self.parseExprPrimary();
        }
        return v;
    }

    fn parseExprPrimary(self: *Parser) anyerror!u32 {
        const tok = try self.take();
        return switch (tok) {
            .number => |n| std.fmt.parseInt(u32, n, 0) catch error.BadNumber,
            .lparen => blk: {
                const v = try self.parseExprAdd();
                try self.expect(.rparen);
                break :blk v;
            },
            else => error.UnexpectedToken,
        };
    }
};

// ----------------------------------------------------------------------
// FIT 后处理
// ----------------------------------------------------------------------

fn propDataStr(data: []const u8) []const u8 {
    if (std.mem.findScalar(u8, data, 0)) |i| return data[0..i];
    return data;
}

fn digestFor(allocator: std.mem.Allocator, algo: []const u8, data: []const u8) ![]const u8 {
    if (std.mem.eql(u8, algo, "crc32")) {
        const bytes = try allocator.alloc(u8, 4);
        std.mem.writeInt(u32, bytes[0..4], crc32.calc(data), .big);
        return bytes;
    }
    if (std.mem.eql(u8, algo, "md5")) {
        const bytes = try allocator.alloc(u8, 16);
        std.crypto.hash.Md5.hash(data, bytes[0..16], .{});
        return bytes;
    }
    if (std.mem.eql(u8, algo, "sha1")) {
        const bytes = try allocator.alloc(u8, 20);
        std.crypto.hash.Sha1.hash(data, bytes[0..20], .{});
        return bytes;
    }
    if (std.mem.eql(u8, algo, "sha256")) {
        const bytes = try allocator.alloc(u8, 32);
        std.crypto.hash.sha2.Sha256.hash(data, bytes[0..32], .{});
        return bytes;
    }
    return error.UnsupportedHashAlgo;
}

fn postProcess(node: *Node, inherited_data: ?[]const u8, allocator: std.mem.Allocator) !void {
    var payload = inherited_data;
    if (node.getProp("data")) |p| payload = p.data;

    // `signature*` / `cipher*` 节点都保留：分别由 signImages() / cipherImages() 处理
    // （未给 keydir 时与参考一致：不签名、不加密，数据保持明文）。

    if (std.mem.startsWith(u8, node.name, "hash-")) {
        if (node.getProp("algo")) |algo_prop| {
            if (payload) |data| {
                const digest = try digestFor(allocator, propDataStr(algo_prop.data), data);
                // 参考 `_hash.compute_image_hashes` 用 `set_property`：已有则就地替换，
                // 否则**追加在 algo 之后**（写成插到 0 会让 FIT 字节与参考不一致，
                // 进而把配置签名的区域哈希带偏）。
                try setBytesProp(node, allocator, "value", digest);
            }
        }
    }

    for (node.children.items) |child| try postProcess(child, payload, allocator);
}

fn ensureTimestamp(parsed: *Parsed, timestamp: u32) !void {
    const allocator = parsed.arena.allocator();
    const bytes = try allocator.alloc(u8, 4);
    std.mem.writeInt(u32, bytes[0..4], timestamp, .big);

    for (parsed.root.props.items) |*p| {
        if (std.mem.eql(u8, p.name, "timestamp")) {
            p.data = bytes;
            return;
        }
    }
    // 参考用 `fdt_obj.set_property("timestamp", ts)`：不存在时**追加在末尾**。
    // （插到 0 会让 DTB 字节与参考不同，配置签名的区域哈希就跟着变。）
    try parsed.root.props.append(allocator, .{ .name = "timestamp", .data = bytes });
}

fn toFdtNode(allocator: std.mem.Allocator, node: *const Node) !*const fdt.Node {
    const props = try allocator.alloc(fdt.Property, node.props.items.len);
    for (node.props.items, 0..) |p, i| props[i] = .{ .name = p.name, .data = p.data };

    const children = try allocator.alloc(*const fdt.Node, node.children.items.len);
    for (node.children.items, 0..) |c, i| children[i] = try toFdtNode(allocator, c);

    const out = try allocator.create(fdt.Node);
    out.* = .{ .name = node.name, .props = props, .children = children };
    return out;
}

// ----------------------------------------------------------------------
// 入口
// ----------------------------------------------------------------------

pub fn parseText(allocator: std.mem.Allocator, io: std.Io, text: []const u8, base_dir: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parser = Parser{
        .lexer = .{ .text = text, .pos = 0, .arena = a },
        .arena = a,
        .io = io,
        .base_dir = base_dir,
    };
    const root = try parser.parseFile();
    try postProcess(root, null, a);
    return .{ .arena = arena, .root = root };
}

pub fn parse(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const base_dir = std.fs.path.dirname(path) orelse ".";

    var parser = Parser{
        .lexer = .{ .text = text, .pos = 0, .arena = a },
        .arena = a,
        .io = io,
        .base_dir = base_dir,
    };
    const root = try parser.parseFile();
    try postProcess(root, null, a);
    return .{ .arena = arena, .root = root };
}

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

test "ITS 解析：字符串/单元/incbin/hash/timestamp" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 准备 incbin 文件
    const seg_path = ".zig-cache/its_seg0.bin";
    try std.Io.Dir.cwd().createDirPath(io, ".zig-cache");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = seg_path, .data = "SEGDATA" });
    defer std.Io.Dir.cwd().deleteFile(io, seg_path) catch {};

    const text =
        \\/dts-v1/;
        \\/ {
        \\  description = "test-fit";
        \\  #address-cells = <1>;
        \\  images {
        \\    seg0 {
        \\      data = /incbin/(".zig-cache/its_seg0.bin");
        \\      type = "firmware";
        \\      load = <0x40100000>;
        \\      entry = <(0x40000000 + 0x100000)>;
        \\      hash-1 {
        \\        algo = "crc32";
        \\      };
        \\      hash-2 {
        \\        algo = "md5";
        \\      };
        \\    };
        \\  };
        \\  configurations {
        \\    default = "conf-1";
        \\    conf-1 {
        \\      firmware = "seg0";
        \\    };
        \\  };
        \\};
        \\
    ;

    var parsed = try parseText(allocator, io, text, ".");
    defer parsed.deinit();

    const blob = try parsed.buildFdt(allocator, 0x1234_5678);
    defer allocator.free(blob);

    try std.testing.expect(fdt.isValid(blob));
    try std.testing.expect(std.mem.find(u8, blob, "SEGDATA") != null);
    try std.testing.expect(std.mem.find(u8, blob, "test-fit") != null);
    try std.testing.expect(std.mem.find(u8, blob, "conf-1") != null);

    // crc32("SEGDATA") 应作为 hash-1 的 value 存在（大端）
    const crc = crc32.calc("SEGDATA");
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .big);
    try std.testing.expect(std.mem.find(u8, blob, &crc_bytes) != null);

    // timestamp 追加在根节点属性末尾（参考 set_property 语义）；已存在则就地替换
    try std.testing.expectEqualStrings("timestamp", parsed.root.props.items[parsed.root.props.items.len - 1].name);
    const ts_prop = parsed.root.getProp("timestamp").?;
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, ts_prop.data[0..4], .big));
}

test "findRegions：只覆盖命中节点自身属性与结构 tag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const text =
        \\/dts-v1/;
        \\
        \\/ {
        \\    description = "regions";
        \\
        \\    images {
        \\        kernel-1 {
        \\            data = [01 02 03 04];
        \\            hash-1 { algo = "sha256"; };
        \\        };
        \\    };
        \\
        \\    configurations {
        \\        default = "conf-1";
        \\        conf-1 {
        \\            kernel = "kernel-1";
        \\        };
        \\    };
        \\};
        \\
    ;
    var parsed = try parseText(allocator, io, text, ".");
    defer parsed.deinit();
    const dtb = try parsed.buildFdt(allocator, 0x11223344);
    defer allocator.free(dtb);

    const exc = [_][]const u8{ "data", "data-size", "data-position", "data-offset" };
    const inc = [_][]const u8{ "/configurations/conf-1", "/images/kernel-1" };
    const res = try findRegions(allocator, dtb, &inc, &exc, true);
    defer res.deinit(allocator);

    // hashed-nodes 按 DTB 里的出现顺序：先 images 再 configurations
    try std.testing.expectEqual(@as(usize, 2), res.hashed_nodes.len);
    try std.testing.expectEqualStrings("/images/kernel-1", res.hashed_nodes[0]);
    try std.testing.expectEqualStrings("/configurations/conf-1", res.hashed_nodes[1]);

    // 最后一段必须带字符串表；所有区域都不能越界
    try std.testing.expect(res.regions.len >= 1);
    const last = res.regions[res.regions.len - 1];
    try std.testing.expectEqual(dtb.len, last.off + last.size);
    for (res.regions) |r| try std.testing.expect(r.off + r.size <= dtb.len);

    // 被排除的 `data` 属性不能进入区域：改掉 data 后拼接哈希必须不变
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (res.regions) |r| try buf.appendSlice(allocator, dtb[r.off..][0..r.size]);
    var digest_before: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buf.items, &digest_before, .{});

    const images = findChild(parsed.root, "images").?;
    try setBytesProp(images.children.items[0], parsed.arena.allocator(), "data", &.{ 0xde, 0xad, 0xbe, 0xef });
    const dtb2 = try parsed.buildFdt(allocator, 0x11223344);
    defer allocator.free(dtb2);
    const res2 = try findRegions(allocator, dtb2, &inc, &exc, true);
    defer res2.deinit(allocator);
    buf.clearRetainingCapacity();
    for (res2.regions) |r| try buf.appendSlice(allocator, dtb2[r.off..][0..r.size]);
    var digest_after: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buf.items, &digest_after, .{});
    try std.testing.expectEqualSlices(u8, &digest_before, &digest_after);
}

test "AES-192 密钥扩展与单块加密（FIPS-197 附录 C.2）" {
    const key: [24]u8 = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    };
    const ek = aes192ExpandKey(&key);
    const plain: [16]u8 = .{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    var block: [16]u8 = plain;
    aes192EncryptBlock(&ek, &block);
    const expect: [16]u8 = .{
        0xdd, 0xa9, 0x7c, 0xa4, 0x86, 0x4c, 0xdf, 0xe0,
        0x6e, 0xaf, 0x70, 0xa0, 0xec, 0x0d, 0x71, 0x91,
    };
    try std.testing.expectEqualSlices(u8, &expect, &block);

    // AES-192 的 CBC 路径不能因缺 algo 而退化成 128 位
    const a = std.testing.allocator;
    const iv: [16]u8 = @splat(0);
    const out = try aesCbcPkcs7(a, &plain, &key, iv);
    defer a.free(out);
    // 16 字节数据 + 一整块 PKCS7 填充 = 32 字节密文
    try std.testing.expectEqual(@as(usize, 32), out.len);
    // IV 全零 ⇒ 首块应等于 FIPS-197 单块密文
    try std.testing.expectEqualSlices(u8, &expect, out[0..16]);
}

test "ITS cipher：未给 keydir 保留节点；给了则加密并重算 hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 未给 keydir：节点保留、数据保持明文（与参考一致）
    const plain_text =
        \\/ { images { seg0 { data = [01 02]; cipher-1 { algo = "aes128"; }; }; }; };
        \\
    ;
    var plain = try parseText(allocator, io, plain_text, ".");
    defer plain.deinit();
    const pimages = findChild(plain.root, "images") orelse return error.NoImages;
    const pseg = pimages.children.items[0];
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, pseg.getProp("data").?.data);
    try std.testing.expect(pseg.getProp("data-size-unciphered") == null);

    // 缺 algo 时明确报错
    const bad_text =
        \\/ { images { seg0 { data = [01 02]; cipher-1 { key-name-hint = "aes"; }; }; }; };
        \\
    ;
    var bad = try parseText(allocator, io, bad_text, ".");
    defer bad.deinit();
    try std.testing.expectError(
        error.BadCipherNode,
        cipherImages(&bad, allocator, io, "."),
    );

    // 给了 keydir：aes128 + 固定 IV，密文/IV/未加密长度/hash 全部落盘可复核
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const keydir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(keydir);

    const key: [16]u8 = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const iv: [16]u8 = .{
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };
    const key_path = try std.fmt.allocPrint(allocator, "{s}/aes.bin", .{keydir});
    defer allocator.free(key_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = key_path, .data = &key });
    const iv_path = try std.fmt.allocPrint(allocator, "{s}/iv.bin", .{keydir});
    defer allocator.free(iv_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = iv_path, .data = &iv });

    const enc_text =
        \\/ { images { seg0 {
        \\    data = [01 02 03];
        \\    cipher-1 { algo = "aes128"; key-name-hint = "aes"; iv-name-hint = "iv"; };
        \\    hash-1 { algo = "sha256"; };
        \\}; }; };
        \\
    ;
    var enc = try parseText(allocator, io, enc_text, ".");
    defer enc.deinit();

    const n = try cipherImages(&enc, allocator, io, keydir);
    try std.testing.expectEqual(@as(usize, 1), n);

    const eimages = findChild(enc.root, "images") orelse return error.NoImages;
    const seg = eimages.children.items[0];
    const body = seg.getProp("data").?;
    try std.testing.expectEqual(@as(usize, 16), body.data.len); // 3 字节 → PKCS7 补到 16
    // data-size-unciphered = 3（大端 u32）
    const unciphered = seg.getProp("data-size-unciphered").?;
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, unciphered.data[0..4], .big));
    // IV 写回 cipher 节点
    const cipher_node = seg.children.items[0];
    try std.testing.expectEqualSlices(u8, &iv, cipher_node.getProp("iv").?.data);
    // 密文 = AES-128-CBC(key, iv) 的 PKCS7 结果；hash-1 覆盖密文
    const expect_ct = try aesCbcPkcs7(allocator, &.{ 1, 2, 3 }, &key, iv);
    defer allocator.free(expect_ct);
    try std.testing.expectEqualSlices(u8, expect_ct, body.data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, seg.children.items[1].getProp("value").?.data);
}

test "ITS cipher：aes-128-ctr 与 chacha20 长度不变（无填充）" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const keydir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(keydir);

    const key16: [16]u8 = @splat(0x0f);
    const key32: [32]u8 = @splat(0x2a);
    const iv: [16]u8 = @splat(0x11);
    const nonce: [12]u8 = @splat(0x33);
    for ([_][]const u8{ "aes.bin", "cha.bin" }) |name| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ keydir, name });
        defer allocator.free(p);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = p,
            .data = if (std.mem.eql(u8, name, "aes.bin")) &key16 else &key32,
        });
    }
    const iv_path = try std.fmt.allocPrint(allocator, "{s}/iv16.bin", .{keydir});
    defer allocator.free(iv_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = iv_path, .data = &iv });
    // ChaCha20 的 nonce 只有 12 字节
    const nonce_path = try std.fmt.allocPrint(allocator, "{s}/nonce.bin", .{keydir});
    defer allocator.free(nonce_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nonce_path, .data = &nonce });

    const text =
        \\/ { images {
        \\    a { data = [01 02 03 04 05]; cipher-1 { algo = "aes-128-ctr"; key-name-hint = "aes"; iv-name-hint = "iv16"; }; };
        \\    b { data = [01 02 03 04 05]; cipher-1 { algo = "chacha20"; key-name-hint = "cha"; iv-name-hint = "nonce"; }; };
        \\}; };
        \\
    ;
    var parsed = try parseText(allocator, io, text, ".");
    defer parsed.deinit();
    _ = try cipherImages(&parsed, allocator, io, keydir);

    const images = findChild(parsed.root, "images") orelse return error.NoImages;
    for (images.children.items) |img| {
        try std.testing.expectEqual(@as(usize, 5), img.getProp("data").?.data.len);
        const u = img.getProp("data-size-unciphered").?;
        try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, u.data[0..4], .big));
    }
    // CTR 期望值：把 IV 当 128 位大端计数器
    const expect_ctr = try aesCtr(allocator, &.{ 1, 2, 3, 4, 5 }, key16, iv);
    defer allocator.free(expect_ctr);
    try std.testing.expectEqualSlices(
        u8,
        expect_ctr,
        images.children.items[0].getProp("data").?.data,
    );
    // ChaCha20 期望值
    var expect_chacha: [5]u8 = undefined;
    std.crypto.stream.chacha.ChaCha20IETF.xor(
        &expect_chacha,
        &.{ 1, 2, 3, 4, 5 },
        0,
        key32,
        nonce,
    );
    try std.testing.expectEqualSlices(
        u8,
        &expect_chacha,
        images.children.items[1].getProp("data").?.data,
    );
}

test "ITS signature-* 节点：未给 keydir 时不填 value（与参考一致）" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const sig_text =
        \\/ { images { seg0 { data = [01 02]; signature-1 { algo = "sha256,rsa2048"; key-name-hint = "dev"; }; }; }; };
        \\
    ;
    var parsed = try parseText(allocator, io, sig_text, ".");
    defer parsed.deinit();
    const images = findChild(parsed.root, "images") orelse return error.NoImages;
    const seg = images.children.items[0];
    const sig = seg.children.items[0];
    try std.testing.expect(sig.getProp("value") == null);
}

test "ITS 外部数据：data 挪出 FIT，写 data-offset/data-size/data-position" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-cache/its-ext-test";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const payload = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33 };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/k.bin", .data = &payload });

    const text =
        \\/dts-v1/;
        \\
        \\/ {
        \\    description = "ext";
        \\    images {
        \\        kernel-1 {
        \\            data = /incbin/("k.bin");
        \\            type = "kernel";
        \\        };
        \\    };
        \\    configurations {
        \\        default = "conf-1";
        \\        conf-1 {
        \\            kernel = "kernel-1";
        \\        };
        \\    };
        \\};
        \\
    ;
    var parsed = try parseText(allocator, io, text, dir);
    defer parsed.deinit();

    const blob = try parsed.buildFdtExternal(allocator, 0x11223344, 0x800);
    defer allocator.free(blob);

    var tree = try @import("fdt_reader.zig").parse(allocator, blob);
    defer tree.deinit();

    const images = @import("fdt_reader.zig").findChild(tree.root, "images") orelse return error.NoImages;
    const kernel = @import("fdt_reader.zig").findChild(images, "kernel-1") orelse return error.NoKernel;

    // data 已挪走
    try std.testing.expect(@import("fdt_reader.zig").findProp(kernel, "data") == null);
    const size = @import("fdt_reader.zig").getBe32(kernel, "data-size") orelse return error.NoSize;
    const off = @import("fdt_reader.zig").getBe32(kernel, "data-offset") orelse return error.NoOffset;
    const pos = @import("fdt_reader.zig").getBe32(kernel, "data-position") orelse return error.NoPosition;
    try std.testing.expectEqual(@as(u32, payload.len), size);
    try std.testing.expectEqual(@as(u32, 0), off);
    // data-position 是绝对偏移，且落在 0x800 边界之后
    try std.testing.expectEqual(@as(u32, 0x800), pos);
    // 外部数据按 align 补齐
    try std.testing.expectEqual(@as(usize, 0x800 + 0x800), blob.len);
    try std.testing.expectEqualSlices(u8, &payload, blob[pos..][0..payload.len]);
}
