// Zig 侧示例：导出 C ABI，供 Luban-Lite（SCons/GCC）链接。
// 编译目标（D13x）：rv32imafdc / ilp32d
export fn zig_add(a: i32, b: i32) i32 {
    return a +% b;
}

export fn zig_mul(a: i32, b: i32) i32 {
    return a *% b;
}
