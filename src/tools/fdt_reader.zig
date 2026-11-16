//! FDT (Flattened Device Tree) / FIT 读取器 —— 对应参考工程里
//! U-Boot `bootm` 的 FIT 解析、`fdt_dump.py` 的树导出，以及
//! `mkimage -l` 的镜像信息打印。
//!
//! 只做**只读解析与校验**，写入仍由 `fdt.zig` 负责。
const std = @import("std");
const crc32 = @import("../bsp/common/crc32.zig");

pub const Token = enum(u32) {
    begin_node = 1,
    end_node = 2,
    prop = 3,
    nop = 4,
    end = 9,
    _,
};

pub const Header = struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

pub const Property = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    name: []const u8,
    props: std.ArrayList(Property) = .empty,
    children: std.ArrayList(*Node) = .empty,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    header: Header,
    /// 原始 blob（用于 `data-position`/`data-offset` 校验）
    blob: []const u8,

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }
};

pub const ReadError = error{
    TooShort,
    BadMagic,
    BadVersion,
    Truncated,
    BadToken,
    BadName,
    BadProp,
    UnexpectedEnd,
};

fn readBe32(bytes: []const u8, off: usize) ReadError!u32 {
    if (off + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

pub fn parseHeader(blob: []const u8) ReadError!Header {
    if (blob.len < 40) return error.TooShort;
    const h: Header = .{
        .magic = try readBe32(blob, 0),
        .totalsize = try readBe32(blob, 4),
        .off_dt_struct = try readBe32(blob, 8),
        .off_dt_strings = try readBe32(blob, 12),
        .off_mem_rsvmap = try readBe32(blob, 16),
        .version = try readBe32(blob, 20),
        .last_comp_version = try readBe32(blob, 24),
        .boot_cpuid_phys = try readBe32(blob, 28),
        .size_dt_strings = try readBe32(blob, 32),
        .size_dt_struct = try readBe32(blob, 36),
    };
    if (h.magic != 0xd00dfeed) return error.BadMagic;
    if (h.version < 16) return error.BadVersion;
    if (h.totalsize > blob.len) return error.Truncated;
    const struct_end = @as(usize, h.off_dt_struct) + h.size_dt_struct;
    const strings_end = @as(usize, h.off_dt_strings) + h.size_dt_strings;
    if (struct_end > h.totalsize or strings_end > h.totalsize) return error.Truncated;
    return h;
}

/// 解析 FDT blob 为树（内存由内部 arena 持有）。
pub fn parse(allocator: std.mem.Allocator, blob: []const u8) !Tree {
    const header = try parseHeader(blob);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var root: ?*Node = null;
    var stack: std.ArrayList(*Node) = .empty;

    const struct_off: usize = header.off_dt_struct;
    const struct_end = struct_off + header.size_dt_struct;
    const strings_off: usize = header.off_dt_strings;
    const strings_end = strings_off + header.size_dt_strings;

    var pos = struct_off;
    while (pos + 4 <= struct_end) {
        const tok_raw = try readBe32(blob, pos);
        pos += 4;
        if (tok_raw == @backingInt(Token.nop)) continue;
        if (tok_raw == @backingInt(Token.end)) break;

        if (tok_raw == @backingInt(Token.begin_node)) {
            const name_start = pos;
            const name_len = std.mem.findScalar(u8, blob[name_start..struct_end], 0) orelse return error.BadName;
            const name = blob[name_start .. name_start + name_len];
            pos = align4(name_start + name_len + 1);

            const node = try a.create(Node);
            node.* = .{ .name = try a.dupe(u8, name) };
            if (stack.items.len == 0) {
                if (root != null) return error.BadToken;
                root = node;
            } else {
                try stack.items[stack.items.len - 1].children.append(a, node);
            }
            try stack.append(a, node);
        } else if (tok_raw == @backingInt(Token.end_node)) {
            if (stack.items.len == 0) return error.UnexpectedEnd;
            _ = stack.pop();
        } else if (tok_raw == @backingInt(Token.prop)) {
            if (stack.items.len == 0) return error.BadProp;
            const len = try readBe32(blob, pos);
            const name_off = try readBe32(blob, pos + 4);
            pos += 8;
            if (pos + len > struct_end) return error.Truncated;
            const name_pos = strings_off + name_off;
            if (name_pos >= strings_end) return error.BadProp;
            const name_len = std.mem.findScalar(u8, blob[name_pos..strings_end], 0) orelse return error.BadProp;
            const node = stack.items[stack.items.len - 1];
            try node.props.append(a, .{
                .name = try a.dupe(u8, blob[name_pos .. name_pos + name_len]),
                .value = try a.dupe(u8, blob[pos .. pos + len]),
            });
            pos = align4(pos + len);
        } else {
            return error.BadToken;
        }
    }

    if (root == null) return error.BadToken;
    return .{
        .arena = arena,
        .root = root.?,
        .header = header,
        .blob = blob,
    };
}

pub fn findProp(node: *const Node, name: []const u8) ?[]const u8 {
    for (node.props.items) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

pub fn findChild(node: *const Node, name: []const u8) ?*Node {
    for (node.children.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

pub fn getString(node: *const Node, name: []const u8) ?[]const u8 {
    const v = findProp(node, name) orelse return null;
    if (v.len == 0) return "";
    const end = std.mem.findScalar(u8, v, 0) orelse v.len;
    return v[0..end];
}

pub fn getBe32(node: *const Node, name: []const u8) ?u32 {
    const v = findProp(node, name) orelse return null;
    if (v.len < 4) return null;
    return std.mem.readInt(u32, v[0..4], .big);
}

/// 按 fdt_dump.py 的风格导出整棵树（便于与参考实现做文本对比）。
pub fn dump(writer: *std.Io.Writer, node: *const Node, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
    try writer.print("{s} {{\n", .{node.name});
    for (node.props.items) |p| {
        var j: usize = 0;
        while (j < depth + 1) : (j += 1) try writer.writeAll("  ");
        try writer.print("{s}", .{p.name});
        if (p.value.len == 0) {
            try writer.writeAll(";\n");
        } else if (isPrintableString(p.value)) {
            try writer.print(" = \"{s}\";\n", .{p.value[0 .. p.value.len - 1]});
        } else {
            try writer.writeAll(" = [");
            for (p.value, 0..) |b, k| {
                if (k != 0) try writer.writeAll(" ");
                try writer.print("{x:0>2}", .{b});
            }
            try writer.writeAll("];\n");
        }
    }
    for (node.children.items) |c| try dump(writer, c, depth + 1);
    i = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
    try writer.writeAll("};\n");
}

fn isPrintableString(value: []const u8) bool {
    if (value.len < 2 or value[value.len - 1] != 0) return false;
    for (value[0 .. value.len - 1]) |b| {
        if (b < 0x20 or b > 0x7e) return false;
    }
    return true;
}

pub const HashAlgo = enum { crc32, md5, sha1, sha256 };

fn hashOf(algo: HashAlgo, data: []const u8, out: *[32]u8) usize {
    switch (algo) {
        .crc32 => {
            const v = crc32.calc(data);
            std.mem.writeInt(u32, out[0..4], v, .big);
            return 4;
        },
        .md5 => {
            var d: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(data, &d, .{});
            @memcpy(out[0..16], &d);
            return 16;
        },
        .sha1 => {
            var d: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(data, &d, .{});
            @memcpy(out[0..20], &d);
            return 20;
        },
        .sha256 => {
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
            @memcpy(out[0..32], &d);
            return 32;
        },
    }
}

fn parseAlgo(text: []const u8) ?HashAlgo {
    if (std.mem.eql(u8, text, "crc32")) return .crc32;
    if (std.mem.eql(u8, text, "md5")) return .md5;
    if (std.mem.eql(u8, text, "sha1")) return .sha1;
    if (std.mem.eql(u8, text, "sha256")) return .sha256;
    return null;
}

pub const VerifyResult = struct {
    checked: usize = 0,
    failed: usize = 0,
    skipped_external: usize = 0,
};

/// 校验 `images/` 下每个带 `hash-N` 子节点的镜像数据（等价 U-Boot bootm）。
/// * 支持内嵌 `data`；
/// * 支持 `data-position` / `data-offset`（按整个 FIT blob 定位）；
/// * 外置 `data = "file.bin"` 无法从 blob 内校验，计入 skipped。
pub fn verifyHashes(tree: *const Tree) VerifyResult {
    var res: VerifyResult = .{};
    const images = findChild(tree.root, "images") orelse return res;

    for (images.children.items) |img| {
        const data_prop = findProp(img, "data") orelse continue;
        for (img.children.items) |h| {
            if (!std.mem.startsWith(u8, h.name, "hash")) continue;
            const algo_name = getString(h, "algo") orelse continue;
            const algo = parseAlgo(algo_name) orelse continue;
            const expected = findProp(h, "value") orelse continue;
            if (expected.len == 0) continue;

            var payload: ?[]const u8 = null;
            if (getBe32(img, "data-position")) |p| {
                if (p <= tree.blob.len) payload = tree.blob[p..];
            } else if (getBe32(img, "data-offset")) |off| {
                if (getBe32(img, "data-size")) |size| {
                    if (@as(usize, off) + size <= data_prop.len) payload = data_prop[off .. off + size];
                }
            } else if (findProp(img, "data-size") != null) {
                payload = data_prop;
            } else if (isPrintableString(data_prop)) {
                res.skipped_external += 1;
                continue;
            } else {
                payload = data_prop;
            }
            const bytes = payload orelse {
                res.failed += 1;
                continue;
            };

            var digest: [32]u8 = undefined;
            const len = hashOf(algo, bytes, &digest);
            res.checked += 1;
            if (!std.mem.eql(u8, expected[0..@min(expected.len, len)], digest[0..@min(expected.len, len)])) {
                res.failed += 1;
            }
        }
    }
    return res;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const fdt = @import("fdt.zig");

test "FDT 读取器：写-读往返" {
    const allocator = std.testing.allocator;

    const ts: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    const zero: [4]u8 = .{ 0, 0, 0, 0 };
    const chosen_props = [_]fdt.Property{.{ .name = "bootargs", .data = &zero }};
    const chosen = fdt.Node{ .name = "chosen", .props = &chosen_props };
    const chosen_children = [_]*const fdt.Node{&chosen};
    const root_props = [_]fdt.Property{
        .{ .name = "model", .data = "WuKong-Lite\x00" },
        .{ .name = "timestamp", .data = &ts },
    };
    const root = fdt.Node{ .name = "", .props = &root_props, .children = &chosen_children };

    const blob = try fdt.build(allocator, &root);
    defer allocator.free(blob);

    var tree = try parse(allocator, blob);
    defer tree.deinit();

    try std.testing.expectEqualStrings("", tree.root.name);
    try std.testing.expectEqualStrings("WuKong-Lite", getString(tree.root, "model").?);
    try std.testing.expectEqual(@as(u32, 0x12345678), getBe32(tree.root, "timestamp").?);

    const chosen_node = findChild(tree.root, "chosen").?;
    try std.testing.expectEqual(@as(u32, 0), getBe32(chosen_node, "bootargs").?);
}

test "FDT 读取器：坏 magic 与截断" {
    const allocator = std.testing.allocator;
    const root = fdt.Node{ .name = "" };
    const blob = try fdt.build(allocator, &root);
    defer allocator.free(blob);

    var bad = try allocator.dupe(u8, blob);
    defer allocator.free(bad);
    bad[0] = 0;
    try std.testing.expectError(error.BadMagic, parse(allocator, bad));

    try std.testing.expectError(error.TooShort, parse(allocator, blob[0..16]));
}

test "verifyHashes：crc32 与篡改检测" {
    const allocator = std.testing.allocator;
    const payload = "hello-fit";
    const size: [4]u8 = .{ 0, 0, 0, payload.len };

    var digest: [32]u8 = undefined;
    const len = hashOf(.crc32, payload, &digest);

    const hash_props = [_]fdt.Property{
        .{ .name = "algo", .data = "crc32\x00" },
        .{ .name = "value", .data = digest[0..len] },
    };
    const hash_node = fdt.Node{ .name = "hash-1", .props = &hash_props };
    const hash_children = [_]*const fdt.Node{&hash_node};

    const kernel_props = [_]fdt.Property{
        .{ .name = "data-size", .data = &size },
        .{ .name = "data", .data = payload },
    };
    const kernel = fdt.Node{ .name = "kernel", .props = &kernel_props, .children = &hash_children };
    const kernel_children = [_]*const fdt.Node{&kernel};
    const images = fdt.Node{ .name = "images", .children = &kernel_children };
    const image_children = [_]*const fdt.Node{&images};
    const root = fdt.Node{ .name = "", .children = &image_children };

    const blob = try fdt.build(allocator, &root);
    defer allocator.free(blob);

    var tree = try parse(allocator, blob);
    defer tree.deinit();
    const ok = verifyHashes(&tree);
    try std.testing.expectEqual(@as(usize, 1), ok.checked);
    try std.testing.expectEqual(@as(usize, 0), ok.failed);

    // 篡改 payload 中一个字节
    var tampered = try allocator.dupe(u8, blob);
    defer allocator.free(tampered);
    const idx = std.mem.find(u8, tampered, "hello-fit").?;
    tampered[idx] = 'H';
    var tree2 = try parse(allocator, tampered);
    defer tree2.deinit();
    const bad = verifyHashes(&tree2);
    try std.testing.expectEqual(@as(usize, 1), bad.failed);
}
