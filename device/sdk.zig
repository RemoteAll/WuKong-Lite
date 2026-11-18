//! WuKong-Lite 设备侧 Zig SDK（0.1）
//!
//! 设计边界：官方 C SDK 继续提供 bootloader / RT-Thread / HAL / LVGL；
//! 本 SDK 只提供 **可从 Zig 调用的稳定 C ABI 包装**，编译成静态库后链接进官方固件。
//! 这样设备侧既能保留官方 C SDK，又能用 Zig 写应用/业务代码。
const std = @import("std");

pub const version = "0.1.0";

pub const rt = @import("rt.zig");
pub const gpio = @import("gpio.zig");
pub const lvgl = @import("lvgl.zig");
pub const board = @import("board.zig");

test "SDK 版本" {
    try std.testing.expectEqualStrings("0.1.0", version);
}
