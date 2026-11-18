//! Zig SDK 示例入口：由官方 C 应用调用 `wk_sdk_demo()`。
const sdk = @import("sdk.zig");

/// 官方 LVGL 移植层在 LVGL 线程里调用 `lv_user_gui_init()`。
/// 链接时用 `-Wl,--wrap=lv_user_gui_init` 把这次调用转到 Zig 包装函数，
/// 从而保证 Zig 的控件操作发生在 LVGL 线程上下文、且 `lv_init()` 已完成。
extern fn __real_lv_user_gui_init() void;

pub export fn __wrap_lv_user_gui_init() void {
    __real_lv_user_gui_init();

    const top = sdk.lvgl.layerTop() orelse {
        sdk.rt.print("[zig-sdk] LVGL top layer is null, skip Zig UI\r\n", .{});
        return;
    };
    const label = sdk.lvgl.lv_label_create(top) orelse {
        sdk.rt.print("[zig-sdk] lv_label_create failed\r\n", .{});
        return;
    };
    sdk.lvgl.lv_label_set_text(label, "Hello from Zig SDK\nWuKong-Lite + LVGL V9");
    sdk.lvgl.center(label);
    sdk.rt.print("[zig-sdk] Zig Label created on LVGL top layer\r\n", .{});
}

pub export fn wk_sdk_demo() void {
    sdk.rt.print("[zig-sdk] WuKong-Lite Zig SDK v{s}\r\n", .{sdk.version});
    sdk.rt.print("[zig-sdk] board={s}, tick={d} ms={d}\r\n", .{
        sdk.board.name,
        sdk.rt.rt_tick_get(),
        sdk.rt.rt_tick_get_millisecond(),
    });
    sdk.rt.print("[zig-sdk] waiting for LVGL thread to call lv_user_gui_init\r\n", .{});
}

/// 可选：把 Zig 的版本号暴露给 C。
pub export fn wk_sdk_version() [*:0]const u8 {
    return "0.1.0";
}
