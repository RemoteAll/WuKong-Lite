//! 扁平设备树（FDT/DTB）生成器 —— 用于生成 U-Boot FIT（ITB）镜像。
//!
//! 只实现写入方向：节点、属性、字符串表、内存保留区。
//! 结构按 Devicetree Specification v0.4（version 17）：
//!   header(40B) + mem_rsvmap(16B) + struct block + strings block
const std = @import("std");

pub const MAGIC: u32 = 0xd00dfeed;
pub const VERSION: u32 = 17;
pub const LAST_COMP_VERSION: u32 = 16;
pub const HEADER_SIZE: usize = 40;
pub const MEM_RSVMAP_SIZE: usize = 16;

const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_END: u32 = 9;

pub const Property = struct {
    name: []const u8,
    data: []const u8,
};

pub const Node = struct {
    name: []const u8,
    props: []const Property = &.{},
    children: []const *const Node = &.{},
};

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try list.appendSlice(allocator, &buf);
}

fn padTo4(list: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    while (list.items.len % 4 != 0) try list.append(allocator, 0);
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    structure: *std.ArrayList(u8),
    strings: *std.ArrayList(u8),
    string_offsets: *std.StringHashMap(u32),

    fn stringOffset(self: *Ctx, name: []const u8) !u32 {
        if (self.string_offsets.get(name)) |off| return off;
        const off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, name);
        try self.strings.append(self.allocator, 0);
        try self.string_offsets.put(name, off);
        return off;
    }

    fn emit(self: *Ctx, node: *const Node) !void {
        try appendU32(self.structure, self.allocator, FDT_BEGIN_NODE);
        try self.structure.appendSlice(self.allocator, node.name);
        try self.structure.append(self.allocator, 0);
        try padTo4(self.structure, self.allocator);

        for (node.props) |prop| {
            try appendU32(self.structure, self.allocator, FDT_PROP);
            try appendU32(self.structure, self.allocator, @intCast(prop.data.len));
            try appendU32(self.structure, self.allocator, try self.stringOffset(prop.name));
            try self.structure.appendSlice(self.allocator, prop.data);
            try padTo4(self.structure, self.allocator);
        }

        for (node.children) |child| try self.emit(child);

        try appendU32(self.structure, self.allocator, FDT_END_NODE);
    }
};

/// 构建 FDT blob，返回调用者拥有的缓冲。
pub fn build(allocator: std.mem.Allocator, root: *const Node) ![]u8 {
    var structure: std.ArrayList(u8) = .empty;
    defer structure.deinit(allocator);
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(allocator);
    var offsets = std.StringHashMap(u32).init(allocator);
    defer offsets.deinit();

    var ctx = Ctx{
        .allocator = allocator,
        .structure = &structure,
        .strings = &strings,
        .string_offsets = &offsets,
    };

    try ctx.emit(root);
    try appendU32(&structure, allocator, FDT_END);
    try padTo4(&strings, allocator);

    const off_mem_rsvmap: u32 = HEADER_SIZE;
    const off_dt_struct: u32 = HEADER_SIZE + MEM_RSVMAP_SIZE;
    const off_dt_strings: u32 = off_dt_struct + @as(u32, @intCast(structure.items.len));
    const total: u32 = off_dt_strings + @as(u32, @intCast(strings.items.len));

    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);

    // header
    std.mem.writeInt(u32, out[0..4], MAGIC, .big);
    std.mem.writeInt(u32, out[4..][0..4], total, .big);
    std.mem.writeInt(u32, out[8..][0..4], off_dt_struct, .big);
    std.mem.writeInt(u32, out[12..][0..4], off_dt_strings, .big);
    std.mem.writeInt(u32, out[16..][0..4], off_mem_rsvmap, .big);
    std.mem.writeInt(u32, out[20..][0..4], VERSION, .big);
    std.mem.writeInt(u32, out[24..][0..4], LAST_COMP_VERSION, .big);
    std.mem.writeInt(u32, out[28..][0..4], 0, .big); // boot_cpuid_phys
    std.mem.writeInt(u32, out[32..][0..4], @intCast(strings.items.len), .big);
    std.mem.writeInt(u32, out[36..][0..4], @intCast(structure.items.len), .big);

    // mem_rsvmap：全 0 终止项（已 memset）
    @memcpy(out[off_dt_struct..][0..structure.items.len], structure.items);
    @memcpy(out[off_dt_strings..][0..strings.items.len], strings.items);
    return out;
}

/// 用 FDT 头做基本校验（magic/长度/偏移）。
pub fn isValid(blob: []const u8) bool {
    if (blob.len < HEADER_SIZE) return false;
    if (std.mem.readInt(u32, blob[0..4], .big) != MAGIC) return false;
    const total = std.mem.readInt(u32, blob[4..][0..4], .big);
    if (total > blob.len) return false;
    const off_struct = std.mem.readInt(u32, blob[8..][0..4], .big);
    const off_strings = std.mem.readInt(u32, blob[12..][0..4], .big);
    const size_strings = std.mem.readInt(u32, blob[32..][0..4], .big);
    return off_struct <= total and off_strings <= total and @as(u64, off_strings) + size_strings <= total;
}

test "FDT 生成：头、属性、字符串表" {
    const allocator = std.testing.allocator;
    const desc_z = "test-image\x00";
    const value: u32 = 0x4010_0000;
    var value_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &value_bytes, value, .big);

    const child = Node{
        .name = "kernel-1",
        .props = &.{
            .{ .name = "description", .data = desc_z },
            .{ .name = "load", .data = &value_bytes },
        },
    };
    const children = [_]*const Node{&child};
    const root = Node{
        .name = "",
        .props = &.{.{ .name = "description", .data = "root\x00" }},
        .children = &children,
    };

    const blob = try build(allocator, &root);
    defer allocator.free(blob);

    try std.testing.expect(isValid(blob));
    try std.testing.expect(std.mem.find(u8, blob, "kernel-1") != null);
    try std.testing.expect(std.mem.find(u8, blob, "description") != null);
    try std.testing.expect(std.mem.find(u8, blob, "load") != null);
    try std.testing.expectEqual(@as(u32, 0x4010_0000), std.mem.readInt(u32, &value_bytes, .big));
}
