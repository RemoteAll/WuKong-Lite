# 完整烧录教程（Luban-Lite / WuKong-Lite · D12x & D13x）

> 目的：把「工具准备 → 镜像自检 → 进升级模式 → 烧写 → 验证 → 排查」串成一页。
> 细节出处见文末「现有文档索引」，本文只写可执行的步骤与判据。

## 0. 先明确三件事

1. **镜像 platform 必须和板子一致**：D123BBV 属 **d12x**，要烧 `d12x_*` 镜像；烧成 d13x 会报“型号不对”。
2. **介质要一致**：本仓库默认 `demo68-nor`（SPI NOR）。NAND 板型不能烧 NOR 镜像。
3. **烧写本身是一条命令，但“进升级模式”是物理动作**：D12x/D13x 的 BROM 只在复位/上电瞬间检测到 **PA0 拉低**才进 UART/USB 升级模式。进入后串口是**静默**的（看不到任何输出属正常）。

## 1. 工具准备（只需一次）

`upgcmd.exe` 在 SDK 的 `tools/scripts/upgcmd`（Linux ELF / Windows exe），本仓库约定放到：

```text
wk\image\tools\upgcmd\upgcmd.exe
```

该目录已 gitignore，不会随仓库分发。缺 3 个 DLL 时运行会退出码 `0xC0000135`：

```powershell
# 需要本机有 SDK 根目录（官方 luban-lite 源码/发布包）
powershell -ExecutionPolicy Bypass -File tools\fetch-upgcmd-deps.ps1 -SdkRoot <SDK根目录>
```

补齐的 DLL：`UsbDkHelper.dll`（USB 后端）、`libgcc_s_dw2-1.dll`、`libwinpthread-1.dll`（32 位 GCC 运行库）。

自检：

```powershell
.\wk\image\tools\upgcmd\upgcmd.exe -h     # 能打印版本与子命令即可
.\wk\image\tools\upgcmd\upgcmd.exe -l     # 无设备时应输出 No usbupg device is found.
```

> **本机现状（2026-11-19，F: 工作区）**：`wk\image\tools\upgcmd` 不存在，且 `G:\Code\C\luban-lite`
> SDK 不存在 → 需要先从 SDK 包/旧机器拷 `upgcmd.exe` + 3 个 DLL，或准备一份 SDK 后跑上面的脚本。

## 2. 镜像准备与自检

### 2.1 生成镜像

全链路 Zig 打包（推荐）：

```powershell
# 默认：wk image preproc + wk image pack；同一输入可复现（-timestamp 固定时）
powershell -ExecutionPolicy Bypass -File tools\build-d12x-firmware.ps1 -Chip d12x -Board demo68-nor
```

- 需要回退厂商 Python 打包时加 `-UseReferencePacker`。
- 产物目录约定：`artifacts\firmware-<chip>\<board>_v1.0.0[_zig].img`。
- 混合对照镜像（`_MIX-*.img`）用于二分定位引导/应用问题，见 `docs/FLASH_DIFF_D12X.md`。

### 2.2 烧前自检（不需要板子）

```powershell
# 解析镜像结构：应列出 9 个组件，platform 与板型一致
.\wk\image\tools\upgcmd\upgcmd.exe -e <镜像绝对路径>
```

注意：`-e` 必须传**绝对路径**，相对路径会报 `Invalid arguments`。

期望组件：

```text
image.info / image.updater.psram / image.updater.spl
image.target.spl / image.target.env / image.target.env_r
image.target.os / image.target.rodata / image.target.data
```

也可以用 `wk image extract <img> -o <目录>` 回验。

## 3. 进入升级模式

1. 板子断电；
2. **PA0 短接到地**（或按住板上 `uboot` 键）；
3. 上电或按复位 → 进入 BROM；
4. 保持 PA0 接地（部分板子可松开）直到烧写开始。

现象：屏幕黑、串口无任何输出 —— 这是 BROM 的正常表现，不代表板子坏。

## 4. UART 烧写（只需一条命令）

```powershell
# 旧版语法（本仓库历史实测）
.\wk\image\tools\upgcmd\upgcmd.exe -u COM3 -b 3000000 -p -v image "<镜像路径>"

# 另一种语法（upgcmd V1.4.2）
.\wk\image\tools\upgcmd\upgcmd.exe -i <镜像路径> -u COM3 -p -v
```

要点：

- `COM3` 换成实际串口（本机 CH343 = `COM3`）；串口不能被其它工具占用（ZZCOM/串口助手先关）。
- 波特率：**3M 实测可用**（用户实测成功那份就是 3M）；若握手失败，去掉 `-b` 让工具自动协商，或降到 `921600`。
- 一定要带 `-v`：会打印握手、逐组件进度与错误码，失败时能看出是擦除、写入还是执行超时。
- 烧完：断开 PA0 / 松开按键，断电重新上电。

## 5. USB 烧写（可选，需要 UsbDk）

1. 安装 UsbDk 驱动；
2. USB 线接板子的 **USB0**（升级口，不是串口）；
3. PA0 接地后上电；
4. 执行：

```powershell
.\wk\image\tools\upgcmd\upgcmd.exe -l
# 记下 bus:port，例如 1:5

.\wk\image\tools\upgcmd\upgcmd.exe -i <镜像路径> -d 1:5 -p -v
```

## 6. 成功判据

- 命令行显示 `100%` 且无错误码；
- 设备重启后串口（UART0，**115200 8N1**）出现 SPL / U-Boot / RT-Thread 启动日志；
- 屏幕按固件配置点亮（d12x demo68：480×272）。

串口抓包（ZZCOM）：

```powershell
powershell -NoProfile -File F:\Code\Zig\ZZCOM\tools\serial-ctl.ps1 -Action capture `
  -Port COM3 -Baud 115200 -Seconds 30 -Log F:\Code\Zig\ZZCOM\artifacts\after-flash.txt
```

## 7. 失败排查

| 现象 | 含义 / 下一步 |
|---|---|
| `upgcmd.exe` 退出码 `0xC0000135` | 缺 DLL，跑 `tools\fetch-upgcmd-deps.ps1` |
| `No usbupg device is found` | 没进升级模式 / 未装 UsbDk；或改用 `-u COMx` |
| `Invalid arguments`（`-e`） | 镜像用了相对路径，改绝对路径 |
| 串口打不开 | 被占用（关掉 ZZCOM/助手），或 COM 号不对 |
| 烧到 ~3% 卡住、仍显示 BROM | 引导组件没被接管：先烧 `_MIX-both.img` 验证（见 `docs/FLASH_DIFF_D12X.md`） |
| 烧写 100% 但黑屏、串口有日志 | 应用/屏配置问题，按 `docs/FLASH_ZIG_FIRMWARE.md` 第 4 节判断表定位 |
| 烧写 100% 但串口完全静默 | 先确认不是还停在 BROM（重新上电、PA0 已松开），再抓 SPL 日志 |

## 8. 本机（2026-11-19）实测差异提醒

- 文档里的旧路径是 `G:\Code\Zig\WuKong-Lite`，本机工作区已迁到 **`F:\Code\Zig\WuKong-Lite`**；
  用 `-SdkRoot`/脚本时请按实际盘符替换。
- 本机 `artifacts\firmware-*` 与 `wk\image\tools\upgcmd` **都不存在**（未随仓库提交），
  开烧前必须先补镜像与工具。
- 串口是 **COM3（USB-SERIAL CH343）**，不是旧记录里的 COM25。
- 当前 COM3 在各波特率下 0 字节，可能原因之一就是**板子已停在 BROM/升级模式**（BROM 静默）。

## 9. 现有文档索引

| 文档 | 内容 |
|---|---|
| `docs/FLASHING.md` | upgcmd 是什么/是否开源、DLL 补齐、`wk image flashpack` 生成烧写脚本、常见问题 |
| `docs/FLASH_ZIG_FIRMWARE.md` | D13x demo88-nor 的完整示例：校验、USB/UART 烧写、串口判断表、回退纯 C 固件 |
| `docs/LVGL_FIRMWARE.md` | D13x LVGL 固件构建 + 第 3 节 USB/UART 烧录步骤 |
| `docs/FLASH_DIFF_D12X.md` | d12x 烧写失败定位、`_MIX-*` 二分镜像、3M 波特率实测结论 |
| `docs/official/skills/aiburn/` | 厂商 AIBURN 官方文档（含 upgcmd 二进制说明、协议） |
| `docs/SERIAL_DEBUG_ZZCOM.md` | 用 ZZCOM/串口抓日志与现场排查 |
