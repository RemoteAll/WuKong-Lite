# Zig × Luban-Lite 示例

验证过的 D13x 目标参数：

```
-target riscv32-freestanding-none -mcpu=generic_rv32+d+f+c+a+m -O ReleaseSmall
```

对应官方 `rv32imafdc / ilp32d`，产物 ELF flags = `0x5`（RVC + double-float ABI）。

## 文件

| 文件 | 作用 |
|------|------|
| `ziglib.zig` | Zig 侧，导出 C ABI 的 `zig_add` / `zig_mul` |
| `caller.c` | C 侧，声明并调用 Zig 函数，`_start` 里写 `sink` 后死循环 |

## 复现（Windows）

```powershell
# 1) Zig 目标文件（输出 ziglib.o 到当前目录）
zig build-obj examples/zig_riscv/ziglib.zig `
  -target riscv32-freestanding-none `
  -mcpu=generic_rv32+d+f+c+a+m -O ReleaseSmall

# 2) 解压官方工具链（只需一次）
#    luban-lite/tools/toolchain/Xuantie-900-gcc-elf-newlib-mingw-V3.2.0-*.tar.gz

# 3) 编译 C 并与 Zig 目标文件链接
$gcc = "<toolchain>\bin\riscv64-unknown-elf-gcc.exe"
& $gcc -march=rv32imafdc -mabi=ilp32d -mcmodel=medany -ffreestanding -nostdlib `
  -c examples\zig_riscv\caller.c -o caller.o
& $gcc -march=rv32imafdc -mabi=ilp32d -mcmodel=medany -nostdlib -nostartfiles `
  "-Wl,-Ttext=0x41000000" "-Wl,-e,_start" caller.o ziglib.o -o zig_link_test.elf
```

成功标志：

- `riscv64-unknown-elf-nm.exe zig_link_test.elf` 能看到 `zig_add` / `zig_mul`；
- ELF `machine=RISC-V`、`flags=0x5`、`entry=0x41000000`。

> 本机 Zig 0.17 的 `-femit-bin=...` 会报 `failed to open object .o`，
> 先输出到当前目录再移动；`zig build-lib` 同理（默认生成 `libziglib.a`）。

更多说明见 `docs/ZIG_ON_LUBAN_LITE.md`。
