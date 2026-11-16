//! FIT / ITB 镜像生成 —— 对应 Luban-Lite `mk_image.py` 的 `itb` 预处理
//! （`image_cfg.json` 中 `"itb": {"xxx.itb": {"its": "xxx.its"}}`）。
//!
//! 本实现不做 ITS 语法解析，直接按 FIT 标准结构生成：
//!
//!   / {
//!       description;
//!       #address-cells = <1>; #size-cells = <1>;
//!       images { kernel-1 {...}; fdt-1 {...}; ramdisk-1 {...} };
//!       configurations { default; conf-1 { kernel; fdt; ramdisk; } };
//!   };
//!
//! 生成的 blob 可直接作为 U-Boot 的 `bootm` 输入。
const std = @import("std");
const fdt = @import("fdt.zig");

pub const Image = struct {
    /// FIT 节点名，例如 "kernel-1" / "fdt-1" / "ramdisk-1"
    name: []const u8,
    data: []const u8,
    /// kernel / flat_dt / ramdisk / firmware
    type_: []const u8 = "kernel",
    arch: []const u8 = "riscv",
    os: []const u8 = "linux",
    compression: []const u8 = "none",
    /// 装载地址 / 入口地址（写入 FIT 的 load/entry 属性）
    load: ?u32 = null,
    entry: ?u32 = null,
    description: ?[]const u8 = null,
};

pub const Options = struct {
    description: []const u8 = "WuKong-Lite FIT image",
    /// FIT 根节点 timestamp（U-Boot 部分版本要求存在该属性），0 表示省略
    timestamp: u32 = 0,
    /// configurations 下的默认配置名
    default_config: []const u8 = "conf-1",
    kernel: Image,
    fdt: ?Image = null,
    ramdisk: ?Image = null,
};

const Builder = struct {
    arena: std.mem.Allocator,

    fn z(self: *Builder, s: []const u8) ![]const u8 {
        const buf = try self.arena.alloc(u8, s.len + 1);
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        return buf;
    }

    fn u32Prop(self: *Builder, v: u32) ![]const u8 {
        const buf = try self.arena.alloc(u8, 4);
        std.mem.writeInt(u32, buf[0..4], v, .big);
        return buf;
    }

    fn imageNode(self: *Builder, img: Image) !*const fdt.Node {
        var props: std.ArrayList(fdt.Property) = .empty;
        try props.append(self.arena, .{ .name = "description", .data = try self.z(img.description orelse img.name) });
        try props.append(self.arena, .{ .name = "data", .data = img.data });
        try props.append(self.arena, .{ .name = "type", .data = try self.z(img.type_) });
        try props.append(self.arena, .{ .name = "arch", .data = try self.z(img.arch) });
        try props.append(self.arena, .{ .name = "os", .data = try self.z(img.os) });
        try props.append(self.arena, .{ .name = "compression", .data = try self.z(img.compression) });
        if (img.load) |v| try props.append(self.arena, .{ .name = "load", .data = try self.u32Prop(v) });
        if (img.entry) |v| try props.append(self.arena, .{ .name = "entry", .data = try self.u32Prop(v) });

        const node = try self.arena.create(fdt.Node);
        node.* = .{
            .name = img.name,
            .props = try props.toOwnedSlice(self.arena),
        };
        return node;
    }
};

/// 生成 FIT（ITB）镜像，返回调用者拥有的缓冲。
pub fn build(allocator: std.mem.Allocator, opt: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var b = Builder{ .arena = arena.allocator() };

    // ---- images ----
    var image_nodes: std.ArrayList(*const fdt.Node) = .empty;
    try image_nodes.append(b.arena, try b.imageNode(opt.kernel));
    if (opt.fdt) |img| try image_nodes.append(b.arena, try b.imageNode(img));
    if (opt.ramdisk) |img| try image_nodes.append(b.arena, try b.imageNode(img));

    const images_node = try b.arena.create(fdt.Node);
    images_node.* = .{
        .name = "images",
        .children = try image_nodes.toOwnedSlice(b.arena),
    };

    // ---- configurations ----
    var conf_props: std.ArrayList(fdt.Property) = .empty;
    try conf_props.append(b.arena, .{ .name = "description", .data = try b.z("default configuration") });
    try conf_props.append(b.arena, .{ .name = "kernel", .data = try b.z(opt.kernel.name) });
    if (opt.fdt) |img| try conf_props.append(b.arena, .{ .name = "fdt", .data = try b.z(img.name) });
    if (opt.ramdisk) |img| try conf_props.append(b.arena, .{ .name = "ramdisk", .data = try b.z(img.name) });

    const conf_node = try b.arena.create(fdt.Node);
    conf_node.* = .{
        .name = opt.default_config,
        .props = try conf_props.toOwnedSlice(b.arena),
    };
    const conf_children = try b.arena.alloc(*const fdt.Node, 1);
    conf_children[0] = conf_node;

    const configs_node = try b.arena.create(fdt.Node);
    configs_node.* = .{
        .name = "configurations",
        .props = &.{
            .{ .name = "default", .data = try b.z(opt.default_config) },
        },
        .children = conf_children,
    };

    // ---- root ----
    const root_children = try b.arena.alloc(*const fdt.Node, 2);
    root_children[0] = images_node;
    root_children[1] = configs_node;

    var root_props: std.ArrayList(fdt.Property) = .empty;
    try root_props.append(b.arena, .{ .name = "description", .data = try b.z(opt.description) });
    if (opt.timestamp != 0) {
        try root_props.append(b.arena, .{ .name = "timestamp", .data = try b.u32Prop(opt.timestamp) });
    }
    try root_props.append(b.arena, .{ .name = "#address-cells", .data = try b.u32Prop(1) });
    try root_props.append(b.arena, .{ .name = "#size-cells", .data = try b.u32Prop(1) });

    const root = fdt.Node{
        .name = "",
        .props = try root_props.toOwnedSlice(b.arena),
        .children = root_children,
    };

    return fdt.build(allocator, &root);
}

test "FIT 镜像包含 images/configurations 与数据" {
    const allocator = std.testing.allocator;
    const kernel_data = "FAKE-KERNEL-IMAGE";
    const itb = try build(allocator, .{
        .description = "wukong-fit",
        .timestamp = 0x1234_5678,
        .kernel = .{
            .name = "kernel-1",
            .data = kernel_data,
            .load = 0x41000000,
            .entry = 0x41000000,
        },
        .fdt = .{
            .name = "fdt-1",
            .data = "FAKE-DTB",
            .type_ = "flat_dt",
        },
    });
    defer allocator.free(itb);

    try std.testing.expect(fdt.isValid(itb));
    try std.testing.expect(std.mem.find(u8, itb, "kernel-1") != null);
    try std.testing.expect(std.mem.find(u8, itb, "fdt-1") != null);
    try std.testing.expect(std.mem.find(u8, itb, "configurations") != null);
    try std.testing.expect(std.mem.find(u8, itb, "FAKE-KERNEL-IMAGE") != null);
    try std.testing.expect(std.mem.find(u8, itb, "flat_dt") != null);
}
