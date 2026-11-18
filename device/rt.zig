//! RT-Thread 基础 API 的 Zig 包装（C ABI）。
const std = @import("std");

pub const Tick = u32;

pub extern fn rt_kprintf(fmt: [*:0]const u8, ...) c_int;
pub extern fn rt_thread_mdelay(ms: i32) i32;
pub extern fn rt_tick_get() Tick;
pub extern fn rt_tick_get_millisecond() Tick;

/// 通过 rt_kprintf 输出一段格式化文本（最长 255 字节）。
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..255], fmt, args) catch {
        _ = rt_kprintf("[zig-sdk] log too long\r\n");
        return;
    };
    buf[text.len] = 0;
    _ = rt_kprintf("%s", @as([*:0]const u8, @ptrCast(&buf)));
}

pub fn sleepMs(ms: u32) void {
    _ = rt_thread_mdelay(@intCast(ms));
}
