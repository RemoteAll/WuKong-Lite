//! GPIO 驱动（host 模拟）—— 对应 `bsp/artinchip/drv/gpio`：
//! 128 个引脚的电平表，提供 read/write 设备接口与直接访问方法。
const std = @import("std");
const device = @import("../../../kernel/common/device.zig");

pub const GPIO_MAX_PIN = 128;

pub const Gpio = struct {
    dev: device.Device = .{ .typ = .misc },
    pins: [GPIO_MAX_PIN]bool = @splat(false),

    pub fn init(self: *Gpio, name: []const u8) void {
        self.dev = .{ .typ = .misc, .ops = &ops, .user_data = self };
        self.dev.setName(name);
    }

    pub fn set(self: *Gpio, pin: u32, value: bool) !void {
        if (pin >= GPIO_MAX_PIN) return error.InvalidPin;
        self.pins[pin] = value;
    }

    pub fn get(self: *const Gpio, pin: u32) !bool {
        if (pin >= GPIO_MAX_PIN) return error.InvalidPin;
        return self.pins[pin];
    }

    /// 写入格式：`[pin, value]` 两个 u32。
    fn writeOp(dev: *device.Device, pos: u64, buffer: ?*const anyopaque, size: usize) isize {
        _ = pos;
        const self: *Gpio = @ptrCast(@alignCast(dev.user_data.?));
        if (buffer == null or size < @sizeOf([2]u32)) return -1;
        const values: *const [2]u32 = @ptrCast(@alignCast(buffer.?));
        self.set(values[0], values[1] != 0) catch return -1;
        return @intCast(@sizeOf([2]u32));
    }

    /// 读取格式：buffer 传入 pin（u32），返回当前电平。
    fn readOp(dev: *device.Device, pos: u64, buffer: ?*anyopaque, size: usize) isize {
        _ = pos;
        const self: *Gpio = @ptrCast(@alignCast(dev.user_data.?));
        if (buffer == null or size < @sizeOf(u32)) return -1;
        const pin: *u32 = @ptrCast(@alignCast(buffer.?));
        const level = self.get(pin.*) catch return -1;
        return if (level) 1 else 0;
    }
};

const ops = device.DeviceOps{ .write = Gpio.writeOp, .read = Gpio.readOp };

test "GPIO 电平读写" {
    var gpio: Gpio = .{};
    gpio.init("gpio0");
    try gpio.set(13, true);
    try std.testing.expect(try gpio.get(13));
    try gpio.set(13, false);
    try std.testing.expect(!(try gpio.get(13)));
    try std.testing.expectError(error.InvalidPin, gpio.set(200, true));

    var args = [2]u32{ 7, 1 };
    try std.testing.expectEqual(@as(isize, 8), Gpio.writeOp(&gpio.dev, 0, &args, @sizeOf([2]u32)));
    var pin: u32 = 7;
    try std.testing.expectEqual(@as(isize, 1), Gpio.readOp(&gpio.dev, 0, &pin, @sizeOf(u32)));
}
