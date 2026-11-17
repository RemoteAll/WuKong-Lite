// D13x 裸机 hello：直接写 UART0 THR（0x18710000），不依赖 RTOS/BSP。
// 构建：tools/build-zig-app.ps1 -App hello_uart
// 产物：wk/image/apps/hello_uart.elf / .aic（可再打成 FIT/AIC.FW）
const UART0_BASE: usize = 0x1871_0000;
const LSR: usize = 0x14;
const THR: usize = 0x00;
const LSR_THRE: u32 = 1 << 5;

fn putc(c: u8) void {
    const lsr = @as(*volatile u32, @ptrFromInt(UART0_BASE + LSR));
    while ((lsr.* & LSR_THRE) == 0) {}
    const thr = @as(*volatile u32, @ptrFromInt(UART0_BASE + THR));
    thr.* = c;
}

fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

export fn zig_main() noreturn {
    puts("\r\n[WuKong-Lite] hello from Zig bare-metal on D13x\r\n");
    puts("UART0 @ 0x18710000, entry 0x41000000\r\n");
    while (true) {}
}

// 启动入口：设置栈后跳到 Zig 代码。栈顶由 link.ld 提供。
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\la sp, __stack_top
        \\call zig_main
    );
    unreachable;
}
