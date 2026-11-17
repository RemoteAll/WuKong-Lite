# 用 Zig 在 Luban-Lite 上开发

## 结论

可以，但要分清“在哪一层用 Zig”：

| 方式 | 可行性 | 说明 |
|------|--------|------|
| Zig 写成**静态库/目标文件**，被 Luban-Lite 的 C/RT-Thread 应用链接 | ✅ 已验证 | 最稳，C ABI 互通，SCons 只需多链一个 `.a` |
| Zig 写成**主固件**（`_start` + 直接调 BSP/RT-Thread API） | ✅ 可行 | 需要链接脚本、启动代码；中断/调度仍建议留在 C/汇编 |
| Zig 替代 SCons/Kconfig 构建整个 SDK | ⚠️ 不建议 | Kconfig/SCons 深度耦合；本仓库已用 Zig 复刻了配置与打包层 |
| Zig 替代 RTOS/HAL/bootloader | ❌ 不现实 | 这些是 SDK 本体，与语言无关 |

## 已验证的目标参数（D13x）

D13x 的官方编译参数（`bsp/artinchip/sys/d13x/rtconfig.py`）：

```
-march=rv32imafdc -mabi=ilp32d
```

Zig 等价命令：

```powershell
# 目标文件（输出 ziglib.o 到当前目录）
zig build-obj examples/zig_riscv/ziglib.zig `
  -target riscv32-freestanding-none `
  -mcpu=generic_rv32+d+f+c+a+m -O ReleaseSmall

# 静态库（输出 libziglib.a）
zig build-lib examples/zig_riscv/ziglib.zig `
  -target riscv32-freestanding-none `
  -mcpu=generic_rv32+d+f+c+a+m -O ReleaseSmall
```

实测产物 ELF flags = `0x5`：`RVC=1` + `float ABI=double(ilp32d)`，与官方一致。
（注意：本机 Zig 0.17 的 `-femit-bin=...` 会报 `failed to open object .o`，
先让它输出到当前目录再移动即可。）

## 已验证：与官方 Xuantie GCC 混链

用 SDK 自带工具链
`tools/toolchain/Xuantie-900-gcc-elf-newlib-mingw-V3.2.0-*.tar.gz`：

```powershell
$gcc = "<toolchain>\bin\riscv64-unknown-elf-gcc.exe"
& $gcc -march=rv32imafdc -mabi=ilp32d -mcmodel=medany -ffreestanding -nostdlib `
  -c examples\zig_riscv\caller.c -o caller.o

& $gcc -march=rv32imafdc -mabi=ilp32d -mcmodel=medany -nostdlib -nostartfiles `
  "-Wl,-Ttext=0x41000000" "-Wl,-e,_start" caller.o ziglib.o -o zig_link_test.elf
```

结果：`machine=RISC-V`、`flags=0x5`、`entry=0x41000000`，
`nm` 能看到 `zig_add`/`zig_mul` 已进镜像。静态库方式（`libziglib.a`）同样链接通过。

## 方式 A：Zig 静态库接入 Luban-Lite（推荐）

1. Zig 侧只导出 C ABI：

   ```zig
   export fn zig_add(a: i32, b: i32) i32 {
       return a +% b;
   }
   ```

2. 生成 `libziglib.a`（见上）；
3. 在对应 `SConscript` 把库加入链接（按 SDK 的 SCons 写法）：

   ```python
   env.Append(LIBPATH=[os.path.join(Dir('#').abspath, 'libs')])
   env.Append(LIBS=['ziglib'])
   ```

   或直接把 `ziglib.o` 加进 `LOCAL_SRCS`/`LIBS`（取决于该 SConscript 的写法）；
4. C 侧声明并调用：

   ```c
   extern int zig_add(int a, int b);
   ```

5. 构建前跑一次 `zig build-lib ...` 生成库即可（可挂到 SCons 的
   `AddPreAction`/自定义 Command）。

## 方式 B：Zig 作为主固件

- 需要自己提供 `_start`（`export fn _start() callconv(.naked)` 或 C 启动文件）、
  链接脚本（官方板级 `*.ld`）和中断向量；
- 通过 `extern fn rt_thread_mdelay(...)` 之类调用 RT-Thread/BSP；
- 与 C 混编时保持 `ilp32d`，否则浮点参数 ABI 不一致会出错；
- RT-Thread 的上下文切换、异常入口仍应由 C/汇编负责，Zig 只写业务逻辑。

### 已在 WuKong-Lite 内跑通的裸机示例：`apps/hello_uart`

目录：

```
apps/hello_uart/
├── main.zig   # _start（设 sp）+ zig_main（轮询 LSR 写 UART0 THR）
└── link.ld    # . = 0x41000000，__stack_top = 0x41080000
```

构建（自动找 `wk\image\xuantie\...\riscv64-unknown-elf-gcc.exe`）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-zig-app.ps1 -App hello_uart
```

产物（`wk\image\apps\`）：

| 文件 | 说明 |
|------|------|
| `hello_uart.o` | Zig 目标文件（rv32imafdc/ilp32d） |
| `hello_uart.elf` | 与官方 GCC 链接，`entry=0x41000000`，`zig_main@0x41000010` |
| `hello_uart.aic` | `wk image elf2aic` 生成，checksum OK，load/entry=0x41000000 |
| `hello_uart.bin` | `objcopy -O binary`，供 upgcmd 直接写到 RAM |
| `hello_uart.map` | 链接映射 |

直接跑到 RAM（设备已进 USB/UART 升级模式）：

```powershell
upgcmd.exe write 0x41000000 wk\image\apps\hello_uart.bin
upgcmd.exe exec  0x41000000
```

串口应输出：

```
[WuKong-Lite] hello from Zig bare-metal on D13x
UART0 @ 0x18710000, entry 0x41000000
```

前提与风险：

- UART0 基址取自 SDK：`0x18710000`，THR=0x00、LSR=0x14（THRE=bit5）；
- 假定 bootloader 已配置好 UART0 的时钟与引脚复用；否则串口无输出；
- 若作为 `os` 分区镜像，FIT/AIC 的 load/entry 必须与 `0x41000000` 一致；
- 该示例不初始化时钟/DDR/中断，只用于 bring-up 验证。

## 限制与坑

- **ISA 扩展**：D13x 带 T-Head 私有扩展（`xtheade`、`zpsfoperand`）；
  Zig 的 `generic_rv32` 不会生成这些指令，标准指令子集没问题；
  若需要特定扩展指令，用 C 内联汇编或厂商 GCC 编译那一段。
- **libc**：`-freestanding` 下 Zig 没有 libc；要用 newlib（printf/malloc）时，
  需与官方 multilib（`rv32imafdc/ilp32d`）一致，或避免在 Zig 侧调用 libc。
- **FPU/ABI**：必须带 `+d`（ilp32d）；混入软浮点目标文件会链接/运行异常。
- **`std` 库**：`std.os` 在 freestanding 下能力有限；内存分配需自备 allocator
  （可用固定缓冲/FixedBufferAllocator）。
- **Zig 版本**：本仓库验证用 Zig 0.17.0；升级后需重新确认 `-mcpu` 语法与 flags。
- **中断/原子**：Zig 支持 `asm volatile`、`@atomicRmw`；但启动与异常入口建议沿用 C。

## 与 WuKong-Lite 的关系

- 本仓库本身就是“用 Zig 写主机侧工具链”的范例（Kconfig、FIT、FAT、RSA、flashpack）；
- 示例代码在 `examples/zig_riscv/`（`ziglib.zig` + `caller.c` + README）；
- 目标板固件仍应由 Luban-Lite SDK 构建 bootloader/OS，Zig 以库或应用模块方式加入。
