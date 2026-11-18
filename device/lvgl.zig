//! LVGL（官方 C 库）最小 C ABI 绑定。
//!
//! Zig 不重写 LVGL；只声明官方 v9 的常用符号，链接时由官方 LVGL 库提供。
//! 注意：LVGL 对象操作应在 LVGL 线程上下文执行；跨线程请使用
//! `lv_timer_create` 注册回调，或在官方移植层提供的锁内调用。
pub const Obj = opaque {};
pub const Timer = opaque {};

pub extern fn lv_screen_active() ?*Obj;
pub extern fn lv_obj_create(parent: ?*Obj) ?*Obj;
pub extern fn lv_obj_set_pos(obj: ?*Obj, x: i32, y: i32) void;
pub extern fn lv_obj_set_size(obj: ?*Obj, w: i32, h: i32) void;
pub extern fn lv_obj_center(obj: ?*Obj) void;

pub extern fn lv_label_create(parent: ?*Obj) ?*Obj;
pub extern fn lv_label_set_text(obj: ?*Obj, text: [*:0]const u8) void;

pub extern fn lv_timer_create(cb: *const fn (?*Timer) callconv(.c) void, period: u32, user_data: ?*anyopaque) ?*Timer;
pub extern fn lv_timer_del(timer: ?*Timer) void;
pub extern fn lv_timer_handler() u32;
