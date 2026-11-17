// C 侧示例：与 Zig 目标文件按 C ABI 混链（D13x: rv32imafdc / ilp32d）
extern int zig_add(int a, int b);
extern int zig_mul(int a, int b);

volatile int sink;

void _start(void) {
    sink = zig_add(2, 3) + zig_mul(4, 5);
    for (;;) {
    }
}
