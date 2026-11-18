//! 空 `echo` 垫片，供 Luban-Lite SCons POST_ACTION 在 Windows 上使用。
//!
//! 官方 POST_ACTION 末尾有裸 `@echo`（无参数）。当 `tools/env/tools/bin`
//! 在 PATH 中时，SCons 会调用旧 MSYS 的 `echo.exe`；它无参数时会等待 stdin，
//! 导致构建在最后一步看起来“卡住”。这里的垫片立即退出 0，只丢掉空行。
//!
//! 构建方法（Windows）：
//!   zig build-exe tools/echo_stub.zig -target x86_64-windows -O ReleaseSmall `
//!       -fstrip -femit-bin=build/toolbin/echo_stub
//!   Move-Item build/toolbin/echo_stub build/toolbin/echo.exe -Force
pub fn main() void {}
