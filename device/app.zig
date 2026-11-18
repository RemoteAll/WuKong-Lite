//! Zig SDK 示例入口：由官方 C 应用调用 `wk_sdk_demo()`。
const sdk = @import("sdk.zig");

pub export fn wk_sdk_demo() void {
    sdk.rt.print("[zig-sdk] WuKong-Lite Zig SDK v{s}\r\n", .{sdk.version});
    sdk.rt.print("[zig-sdk] board={s}, tick={d} ms={d}\r\n", .{
        sdk.board.name,
        sdk.rt.rt_tick_get(),
        sdk.rt.rt_tick_get_millisecond(),
    });
}

/// 可选：把 Zig 的版本号暴露给 C。
pub export fn wk_sdk_version() [*:0]const u8 {
    return "0.1.0";
}
