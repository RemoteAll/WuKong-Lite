# Luban-Lite 官方源码库的定位

`artinchip/luban-lite`（<https://github.com/artinchip/luban-lite>）不是“跑在官方系统上的
一个 OS”，也不是单纯的应用层，而是**面向 ArtInChip 芯片的完整固件 SDK**。
OS（RT-Thread/FreeRTOS）只是其中的一层。

## 顶层结构与作用（官方仓库实测）

| 目录/文件 | 作用 |
|-----------|------|
| `SConstruct` / `SConscript` / `Kconfig` | 构建与配置入口（SCons + Kconfig，`aic_build.py` 驱动） |
| `win_env.bat` / `win_cmd.bat` / `onestep.sh` | Windows/Linux 环境与一键构建脚本 |
| `application/` | **应用层 + 三种运行形态**：`baremetal`（含 bootloader）、`rt-thread`（默认）、`freertos` |
| `kernel/` | 内核/启动移植支撑（与具体 OS 适配相关） |
| `bsp/` | **芯片 BSP/HAL/驱动**：`artinchip` 下按 SoC（d12x/d13x/d21x）分、`peripheral`、`examples` |
| `packages/` | 中间件与第三方包：RT-Thread、LVGL、lwIP、mbedTLS、文件系统、OTA、`artinchip` 厂商包 |
| `target/` | **板级方案**：`configs/*_defconfig`、`d13x/demo88-nor/pack/image_cfg.json` 等 |
| `tools/` | `env`（Kconfig/Python 环境）、`toolchain`、`scripts`（mkimage/mkenvimage/elf2image/makefatfs/cpio/upgcmd/AiBurn 相关） |
| `doc/` | 官方文档（含 `skills/aiburn` 烧写技能、topics/webhelp 站点） |

## 一次固件是怎么来的

```
target/<soc>/<board>/pack/image_cfg.json     ← 板级镜像配置（分区/组件/介质）
        │
tools/scripts/mk_image.py + mkimage/mkenvimage/...   ← 生成各组件镜像与 AIC.FW
        │
application/<os>/... + bsp/ + packages/       ← 编译出 bootloader / OS / 应用
        │
upgcmd / AiBurn                               ← 烧到 SPI NOR/NAND
```

## 三种“运行形态”

| 形态 | 说明 | 典型产物 |
|------|------|----------|
| baremetal | 无 OS，直接跑；**bootloader/PBP/升级协议**都在这里 | `bootloader.bin` → `loader.aic` / `pbp_ext.aic` |
| RT-Thread | SDK 默认 OS，`application/rt-thread` + `packages` | `d13x_os.itb`（FIT） |
| FreeRTOS | 可选的另一套 OS 适配 | 同上，换成 FreeRTOS 内核 |

## 与 WuKong-Lite 的对应关系

| 层 | 官方 | WuKong-Lite |
|----|------|-------------|
| 镜像格式/打包 | `tools/scripts/mk_image.py`、mkimage、mkenvimage、elf2image、img2simg、cpio、makefatfs | ✅ 已复刻并逐字节/结构验证 |
| 配置与构建 | Kconfig + SCons + `aic_build.py` | ✅ Kconfig/defconfig/codegen/模块评估 |
| 安全 | RSA/AES、签名/加密字段 | ✅ RSA PKCS#1 v1.5、AES-CBC；AIC 头联动未做 |
| bootloader/PBP | `application/baremetal/bootloader` | ❌ 未实现，必须用厂商产物 |
| RTOS 内核/中间件 | `kernel/` + `packages/` | ❌ 未实现（只做了 OSAL 模拟层） |
| 驱动/HAL | `bsp/artinchip` | ⚠️ 仅 uart0/gpio0 模拟，无寄存器级 HAL |
| 烧写主机端 | `upgcmd`（预编译）+ AiBurn | ✅ 已补齐 DLL 可运行；`flash-upgcmd.ps1` 直烧 |
| 烧写设备端协议 | `application/baremetal/bootloader/lib/aicupg` | 📖 开源可参考，未实现 |

## 结论

- 想要“能启动的固件”：必须用 `luban-lite` 编译出的 **bootloader + OS**，
  或厂商发布的整包；
- `WuKong-Lite` 的定位是**镜像格式与工具链的 Zig 复刻 + 烧写编排**，
  不是替换 RTOS/HAL/bootloader；
- `upgcmd` 主机端源码不在该仓库（内部 `aicupg` 仓库），详见
  `docs/official/upgcmd-binary-map.md`。
