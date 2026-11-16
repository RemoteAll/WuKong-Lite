//! 串口驱动（host 模拟）—— 对应 `bsp/artinchip/drv/uart`：
//! 注册为 char 设备，write 输出到 stdout，作为系统控制台。
const std = @import("std");
const device = @import("../../../kernel/common/device.zig");

pub const Uart = struct {
    dev: device.Device = .{ .typ = .char },
    io: std.Io,
    out: std.Io.File.Writer,
    out_buf: [2048]u8 = undefined,

    /// 必须在稳定地址上初始化（writer 持有 out_buf 指针）。
    pub fn init(self: *Uart, name: []const u8, io: std.Io) void {
        self.io = io;
        self.out = std.Io.File.stdout().writer(io, &self.out_buf);
        self.dev = .{ .typ = .char, .ops = &ops, .user_data = self };
        self.dev.setName(name);
    }

    pub fn writeText(self: *Uart, text: []const u8) !void {
        try self.out.interface.writeAll(text);
        try self.out.interface.flush();
    }

    pub fn print(self: *Uart, comptime fmt: []const u8, args: anytype) !void {
        try self.out.interface.print(fmt, args);
        try self.out.interface.flush();
    }

    fn writeOp(dev: *device.Device, pos: u64, buffer: ?*const anyopaque, size: usize) isize {
        _ = pos;
        const self: *Uart = @ptrCast(@alignCast(dev.user_data.?));
        if (buffer == null) return -1;
        const bytes: [*]const u8 = @ptrCast(buffer.?);
        self.out.interface.writeAll(bytes[0..size]) catch return -1;
        self.out.interface.flush() catch {};
        return @intCast(size);
    }
};

const ops = device.DeviceOps{ .write = Uart.writeOp };

test "串口设备注册后可写" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = device.Registry.init(std.testing.allocator);
    defer registry.deinit();

    var uart: Uart = undefined;
    uart.init("uart0", io);
    try registry.register(&uart.dev);
    const dev = try registry.open("uart0");
    try std.testing.expectEqualStrings("uart0", dev.nameStr());
    const n = dev.ops.?.write.?(dev, 0, "hi", 2);
    try std.testing.expectEqual(@as(isize, 2), n);
    registry.close(dev);
}
