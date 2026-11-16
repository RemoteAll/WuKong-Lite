//! 设备框架 —— 对应 RT-Thread / Luban-Lite 的 `rt_device` 模型：
//! 设备名、类型、ops（init/open/close/read/write/control）、引用计数与注册表。
const std = @import("std");

pub const DeviceType = enum(u8) {
    char = 0,
    block = 1,
    net = 2,
    mtd = 3,
    misc = 4,
    graphic = 5,
    unknown = 9,

    pub fn label(t: DeviceType) []const u8 {
        return switch (t) {
            .char => "Character Device",
            .block => "Block Device",
            .net => "Network Interface",
            .mtd => "MTD Device",
            .misc => "Miscellaneous Device",
            .graphic => "Graphic Device",
            .unknown => "Unknown",
        };
    }
};

pub const DeviceOps = struct {
    init: ?*const fn (dev: *Device) c_int = null,
    open: ?*const fn (dev: *Device, oflag: u16) c_int = null,
    close: ?*const fn (dev: *Device) c_int = null,
    read: ?*const fn (dev: *Device, pos: u64, buffer: ?*anyopaque, size: usize) isize = null,
    write: ?*const fn (dev: *Device, pos: u64, buffer: ?*const anyopaque, size: usize) isize = null,
    control: ?*const fn (dev: *Device, cmd: c_int, arg: ?*anyopaque) c_int = null,
};

pub const NAME_MAX = 32;

pub const Device = struct {
    name: [NAME_MAX]u8 = @splat(0),
    typ: DeviceType = .misc,
    ops: ?*const DeviceOps = null,
    user_data: ?*anyopaque = null,
    open_flag: bool = false,
    ref_count: u32 = 0,

    pub fn setName(dev: *Device, name: []const u8) void {
        dev.name = @splat(0);
        const n = @min(name.len, NAME_MAX - 1);
        @memcpy(dev.name[0..n], name[0..n]);
    }

    pub fn nameStr(dev: *const Device) []const u8 {
        return std.mem.sliceTo(&dev.name, 0);
    }
};

/// 已注册设备表（设备本体由驱动持有，注册表只存指针）。
pub const Registry = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(*Device) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.devices.deinit(self.allocator);
    }

    pub fn register(self: *Registry, dev: *Device) !void {
        if (self.find(dev.nameStr()) != null) return error.DeviceExists;
        try self.devices.append(self.allocator, dev);
        if (dev.ops) |ops| {
            if (ops.init) |init_fn| _ = init_fn(dev);
        }
    }

    pub fn find(self: *Registry, name: []const u8) ?*Device {
        for (self.devices.items) |dev| {
            if (std.mem.eql(u8, dev.nameStr(), name)) return dev;
        }
        return null;
    }

    pub fn open(self: *Registry, name: []const u8) !*Device {
        const dev = self.find(name) orelse return error.DeviceNotFound;
        if (!dev.open_flag) {
            if (dev.ops) |ops| {
                if (ops.open) |open_fn| {
                    if (open_fn(dev, 0) != 0) return error.DeviceOpenFailed;
                }
            }
            dev.open_flag = true;
        }
        dev.ref_count += 1;
        return dev;
    }

    pub fn close(self: *Registry, dev: *Device) void {
        _ = self;
        if (dev.ref_count == 0 or !dev.open_flag) return;
        dev.ref_count -= 1;
        if (dev.ref_count == 0) {
            if (dev.ops) |ops| {
                if (ops.close) |close_fn| _ = close_fn(dev);
            }
            dev.open_flag = false;
        }
    }

    pub fn dump(self: *Registry, writer: *std.Io.Writer) !void {
        if (self.devices.items.len == 0) {
            try writer.writeAll("no device registered\n");
            return;
        }
        try writer.print("{s:<16} {s:<20} {s:<8} {s}\n", .{ "Name", "Type", "Ref", "Status" });
        try writer.writeAll("-------------------------------------------------------------\n");
        for (self.devices.items) |dev| {
            try writer.print("{s:<16} {s:<20} {d:<8} {s}\n", .{
                dev.nameStr(),
                dev.typ.label(),
                dev.ref_count,
                if (dev.open_flag) "opened" else "closed",
            });
        }
    }
};

test "设备注册/打开/读写/关闭" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const Fake = struct {
        dev: Device = .{ .typ = .misc },
        value: u32 = 0,

        fn write(dev: *Device, pos: u64, buffer: ?*const anyopaque, size: usize) isize {
            _ = pos;
            const self: *@This() = @ptrCast(@alignCast(dev.user_data.?));
            if (size != @sizeOf(u32)) return -1;
            const v: *const u32 = @ptrCast(@alignCast(buffer.?));
            self.value = v.*;
            return @intCast(size);
        }
    };
    var fake = Fake{};
    var ops = DeviceOps{ .write = Fake.write };
    fake.dev.ops = &ops;
    fake.dev.user_data = &fake;
    fake.dev.setName("fake0");

    try registry.register(&fake.dev);
    try std.testing.expectEqual(@as(usize, 1), registry.devices.items.len);
    try std.testing.expectError(error.DeviceExists, registry.register(&fake.dev));

    const dev = try registry.open("fake0");
    var val: u32 = 0x1234_5678;
    const n = dev.ops.?.write.?(dev, 0, &val, @sizeOf(u32));
    try std.testing.expectEqual(@as(isize, 4), n);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), fake.value);

    registry.close(dev);
    try std.testing.expect(!dev.open_flag);
    try std.testing.expectError(error.DeviceNotFound, registry.open("nope"));
}
