//! Zig SDK 示例入口：由官方 C 应用调用 `wk_sdk_demo()`。
const sdk = @import("sdk.zig");

fn createZigUi(timer: ?*sdk.lvgl.Timer) callconv(.c) void {
    const screen = sdk.lvgl.screenActive() orelse return;
    const label = sdk.lvgl.lv_label_create(screen) orelse return;
    sdk.lvgl.lv_label_set_text(label, "Hello from Zig SDK\nWuKong-Lite + LVGL V9");
    sdk.lvgl.center(label);
    sdk.lvgl.lv_timer_delete(timer);
}

pub export fn wk_sdk_demo() void {
    sdk.rt.print("[zig-sdk] WuKong-Lite Zig SDK v{s}\r\n", .{sdk.version});
    sdk.rt.print("[zig-sdk] board={s}, tick={d} ms={d}\r\n", .{
        sdk.board.name,
        sdk.rt.rt_tick_get(),
        sdk.rt.rt_tick_get_millisecond(),
    });

    // 在 LVGL 线程上下文创建 Label（定时器回调由 lv_timer_handler 调度）。
    _ = sdk.lvgl.lv_timer_create(createZigUi, 300, null);
}

/// 可选：把 Zig 的版本号暴露给 C。
pub export fn wk_sdk_version() [*:0]const u8 {
    return "0.1.0";
}
