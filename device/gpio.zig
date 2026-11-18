//! RT-Thread PIN 设备 API 的 Zig 包装（C ABI）。
pub const Mode = enum(i32) {
    output = 0,
    input = 1,
    input_pullup = 2,
    input_pulldown = 3,
    output_od = 4,
};

pub const Level = enum(i32) {
    low = 0,
    high = 1,
};

pub extern fn rt_pin_mode(pin: i32, mode: i32) void;
pub extern fn rt_pin_write(pin: i32, value: i32) void;
pub extern fn rt_pin_read(pin: i32) c_int;
pub extern fn rt_pin_get(name: [*:0]const u8) i32;

pub fn setMode(pin: i32, mode: Mode) void {
    rt_pin_mode(pin, @intFromEnum(mode));
}

pub fn write(pin: i32, level: Level) void {
    rt_pin_write(pin, @intFromEnum(level));
}

pub fn read(pin: i32) Level {
    return if (rt_pin_read(pin) != 0) .high else .low;
}

pub fn get(name: [*:0]const u8) i32 {
    return rt_pin_get(name);
}
